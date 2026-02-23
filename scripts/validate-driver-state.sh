#!/usr/bin/env zsh
set -euo pipefail

EXPECT_STATE=""
EXPECTED_NAME=""
TIMEOUT_SECONDS=20

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-driver-state.sh --expect <present|absent> [options]

Validates CoreAudio visibility for MicBridge device UID prefix:
  ch.hefti.micbridge.

Options:
  --expect <present|absent>  Required expected state.
  --name <device-name>       When --expect present, require this exact device name (case-insensitive).
  --timeout-seconds <sec>    Wait timeout for state convergence (default: 20).
  --help                     Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect)
      EXPECT_STATE="$2"
      shift 2
      ;;
    --name)
      EXPECTED_NAME="$2"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$EXPECT_STATE" != "present" && "$EXPECT_STATE" != "absent" ]]; then
  echo "--expect must be present or absent" >&2
  usage >&2
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 1 ]]; then
  echo "--timeout-seconds must be a positive integer" >&2
  exit 1
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if EXPECT_STATE="$EXPECT_STATE" EXPECTED_NAME="$EXPECTED_NAME" swift - <<'SWIFT'
import CoreAudio
import Foundation

let expectState = ProcessInfo.processInfo.environment["EXPECT_STATE"] ?? ""
let expectedName = ProcessInfo.processInfo.environment["EXPECTED_NAME"] ?? ""
let expectPresent = (expectState == "present")

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(id, &address) else {
        return nil
    }

    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    guard status == noErr else {
        return nil
    }
    return value as String?
}

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
    exit(1)
}

var ids = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
    exit(1)
}

let matches = ids.compactMap { id -> (String, String)? in
    let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
    guard uid.hasPrefix("ch.hefti.micbridge.") else { return nil }
    let name = stringProperty(id, kAudioObjectPropertyName) ?? ""
    return (uid, name)
}

let hasAny = !matches.isEmpty

if expectPresent {
    guard hasAny else {
        exit(1)
    }
    if expectedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        exit(0)
    }
    let hasName = matches.contains { _, name in
        name.compare(expectedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    exit(hasName ? 0 : 1)
} else {
    exit(hasAny ? 1 : 0)
}
SWIFT
  then
    if [[ "$EXPECT_STATE" == "present" ]]; then
      if [[ -n "$EXPECTED_NAME" ]]; then
        echo "[driver-state] PASS present name='$EXPECTED_NAME'"
      else
        echo "[driver-state] PASS present"
      fi
    else
      echo "[driver-state] PASS absent"
    fi
    exit 0
  fi
  sleep 1
done

if [[ "$EXPECT_STATE" == "present" ]]; then
  if [[ -n "$EXPECTED_NAME" ]]; then
    echo "[driver-state] FAIL expected present with name '$EXPECTED_NAME'" >&2
  else
    echo "[driver-state] FAIL expected present" >&2
  fi
else
  echo "[driver-state] FAIL expected absent" >&2
fi
exit 1
