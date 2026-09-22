#!/usr/bin/env zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ch.hefti.macvirtualmicbridge.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [[ ! -f "$PLIST" || ! -d /Applications/MicBridge.app ]]; then
  exec "$ROOT_DIR/scripts/install-menubar-service.sh"
fi
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi
launchctl kickstart "$DOMAIN/$LABEL"
echo "MicBridge menu is running from /Applications/MicBridge.app"
