#!/usr/bin/env zsh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./drivers/micbridge-hal/scripts/uninstall-driver.sh" >&2
  exit 1
fi

TARGET_BUNDLE="/Library/Audio/Plug-Ins/HAL/MicBridge.driver"

if [[ -d "$TARGET_BUNDLE" ]]; then
  rm -rf "$TARGET_BUNDLE"
  echo "Removed: $TARGET_BUNDLE"
else
  echo "Driver not installed: $TARGET_BUNDLE"
fi

killall coreaudiod >/dev/null 2>&1 || true

echo "CoreAudio daemon restarted."
