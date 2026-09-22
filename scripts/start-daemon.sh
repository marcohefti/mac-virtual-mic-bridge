#!/usr/bin/env zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ch.hefti.macvirtualmicbridge.daemon"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ ! -f "$PLIST" ]]; then
  exec "$ROOT_DIR/scripts/install-daemon-service.sh"
fi
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi
launchctl kickstart "$DOMAIN/$LABEL"
echo "Daemon supervised by $DOMAIN/$LABEL"
