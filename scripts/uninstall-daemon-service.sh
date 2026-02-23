#!/usr/bin/env zsh
set -euo pipefail

LABEL="ch.hefti.macvirtualmicbridge.daemon"
USER_ID="$(id -u)"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
fi

echo "Removed launchd service:"
echo "  Label: $LABEL"
echo "  Plist: $PLIST_PATH"
