#!/usr/bin/env zsh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/install-driver-bundle.sh <MicBridge.driver path>" >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo ./scripts/install-driver-bundle.sh <MicBridge.driver path>" >&2
  exit 1
fi

SOURCE_BUNDLE="$1"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET_BUNDLE="$TARGET_DIR/MicBridge.driver"

if [[ ! -d "$SOURCE_BUNDLE" ]]; then
  echo "Driver bundle not found: $SOURCE_BUNDLE" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_BUNDLE"
ditto "$SOURCE_BUNDLE" "$TARGET_BUNDLE"
chown -R root:wheel "$TARGET_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >/dev/null
killall coreaudiod >/dev/null 2>&1 || true

echo "Installed driver bundle:"
echo "  $TARGET_BUNDLE"
echo "CoreAudio daemon restarted."
