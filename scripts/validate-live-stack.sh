#!/usr/bin/env zsh
set -euo pipefail

# Live smoke validation against the current macOS audio stack.
# Does not restart coreaudiod and does not require sudo.

APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
STATUS_FILE="$APP_SUPPORT_DIR/status.json"
CONFIG_FILE="$APP_SUPPORT_DIR/config.json"
DEFAULT_TARGET_UID="ch.hefti.micbridge.virtualmic.device"

EXPECTED_TARGET_UID="$DEFAULT_TARGET_UID"
if [[ -f "$STATUS_FILE" || -f "$CONFIG_FILE" ]]; then
  EXPECTED_TARGET_UID="$(python3 - <<'PY'
import json
import pathlib

app = pathlib.Path.home() / "Library/Application Support/MacVirtualMicBridge"
status_path = app / "status.json"
config_path = app / "config.json"
default_uid = "ch.hefti.micbridge.virtualmic.device"

value = None
if status_path.exists():
    try:
        status = json.loads(status_path.read_text())
        value = status.get("targetDeviceUID")
    except Exception:
        value = None
if not value and config_path.exists():
    try:
        config = json.loads(config_path.read_text())
        value = config.get("targetDeviceUID")
    except Exception:
        value = None

print(value if value else default_uid)
PY
)"
fi

echo "[live] Checking target device visibility for UID: $EXPECTED_TARGET_UID"
EXPECTED_TARGET_UID="$EXPECTED_TARGET_UID" swift - <<'SWIFT'
import CoreAudio
import Foundation

let expected = ProcessInfo.processInfo.environment["EXPECTED_TARGET_UID"] ?? ""

func deviceString(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(id, &address) else {
        return nil
    }

    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else {
        return nil
    }
    return value as String?
}

var systemAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, &size)
var deviceIDs = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, &size, &deviceIDs)

let found = deviceIDs.contains { id in
    (deviceString(id, selector: kAudioDevicePropertyDeviceUID) ?? "") == expected
}
if !found {
    fputs("Target device UID not visible in CoreAudio device list: \(expected)\n", stderr)
    exit(1)
}
SWIFT

echo "[live] Checking daemon status file"
if [[ ! -f "$STATUS_FILE" ]]; then
  echo "Status file missing: $STATUS_FILE" >&2
  exit 1
fi

python3 - <<'PY'
import json, os, pathlib, sys
status_path = pathlib.Path.home()/"Library/Application Support/MacVirtualMicBridge/status.json"
status = json.loads(status_path.read_text())
if status.get("state") != "running":
    print(f"Daemon not running: {status.get('state')} / {status.get('message')}", file=sys.stderr)
    sys.exit(1)
if not status.get("targetDeviceUID"):
    print("Daemon status does not include a targetDeviceUID", file=sys.stderr)
    sys.exit(1)
print("live validation passed")
PY
