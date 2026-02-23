#!/usr/bin/env zsh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/safe-install-driver.sh [--device-name \"Name\"]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-driver.sh"
TARGET_BUNDLE="/Library/Audio/Plug-Ins/HAL/MicBridge.driver"

DEVICE_NAME="MicBridge Virtual Mic"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-name)
      DEVICE_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${DEVICE_NAME// /}" ]]; then
  echo "--device-name cannot be empty" >&2
  exit 1
fi

if [[ ! -x "$INSTALL_SCRIPT" ]]; then
  echo "Install script not found or not executable: $INSTALL_SCRIPT" >&2
  exit 1
fi

BACKUP_ROOT="$(mktemp -d /tmp/micbridge-driver-backup.XXXXXX)"
BACKUP_BUNDLE="$BACKUP_ROOT/MicBridge.driver"
HAD_EXISTING=0

cleanup() {
  rm -rf "$BACKUP_ROOT"
}
trap cleanup EXIT

if [[ -d "$TARGET_BUNDLE" ]]; then
  HAD_EXISTING=1
  ditto "$TARGET_BUNDLE" "$BACKUP_BUNDLE"
fi

coreaudio_health_check() {
  local expected_name="$1"
  EXPECTED_DEVICE_NAME="$expected_name" swift - <<'SWIFT'
import CoreAudio
import Foundation

let expectedName = ProcessInfo.processInfo.environment["EXPECTED_DEVICE_NAME"] ?? ""
let systemObject = AudioObjectID(kAudioObjectSystemObject)

func getString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
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
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else {
        return nil
    }
    return value as String?
}

func hasDefaultOutputDevice() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(systemObject, &address) else {
        return false
    }
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr && id != 0
}

func hasExpectedDriverDevice() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
        return false
    }

    var ids = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
        return false
    }

    for id in ids {
        let uid = getString(id, kAudioDevicePropertyDeviceUID) ?? ""
        let name = getString(id, kAudioObjectPropertyName) ?? ""

        if uid.hasPrefix("ch.hefti.micbridge.") {
            return true
        }

        if !expectedName.isEmpty &&
            name.compare(expectedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
    }
    return false
}

exit((hasDefaultOutputDevice() && hasExpectedDriverDevice()) ? 0 : 1)
SWIFT
}

wait_for_post_install_health() {
  local expected_name="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if coreaudio_health_check "$expected_name"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

rollback_install() {
  echo "Health verification failed. Rolling back driver install..." >&2
  rm -rf "$TARGET_BUNDLE"

  if [[ "$HAD_EXISTING" -eq 1 && -d "$BACKUP_BUNDLE" ]]; then
    ditto "$BACKUP_BUNDLE" "$TARGET_BUNDLE"
    chown -R root:wheel "$TARGET_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >/dev/null || true
  fi

  killall coreaudiod >/dev/null 2>&1 || true
}

echo "Starting safe driver install (device name: $DEVICE_NAME)"

if ! "$INSTALL_SCRIPT" --device-name "$DEVICE_NAME"; then
  echo "Install script failed before post-install verification." >&2
  rollback_install
  exit 1
fi

if ! wait_for_post_install_health "$DEVICE_NAME" 30; then
  rollback_install
  exit 1
fi

echo "Safe install completed and health checks passed."
