#!/usr/bin/env zsh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./drivers/micbridge-hal/scripts/install-driver.sh" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVER_DIR="$ROOT_DIR/drivers/micbridge-hal"
BUILD_BUNDLE="$DRIVER_DIR/build/MicBridge.driver"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET_BUNDLE="$TARGET_DIR/MicBridge.driver"

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

"$DRIVER_DIR/scripts/build-driver.sh" --device-name "$DEVICE_NAME"

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_BUNDLE"
ditto "$BUILD_BUNDLE" "$TARGET_BUNDLE"
chown -R root:wheel "$TARGET_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >/dev/null

killall coreaudiod >/dev/null 2>&1 || true

cat <<MSG
Installed driver to:
  $TARGET_BUNDLE

Device name:
  $DEVICE_NAME

CoreAudio daemon has been restarted.
Open Audio MIDI Setup and verify "$DEVICE_NAME" is visible.
MSG
