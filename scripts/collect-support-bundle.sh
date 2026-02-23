#!/usr/bin/env zsh
set -euo pipefail

APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
LOG_DIR="$HOME/Library/Logs/MacVirtualMicBridge"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
OUT_DIR="${1:-$HOME/Desktop}"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
BUNDLE_NAME="micbridge-support-${TIMESTAMP}"
STAGING_DIR="$OUT_DIR/$BUNDLE_NAME"
ARCHIVE_PATH="$OUT_DIR/$BUNDLE_NAME.tar.gz"
USER_ID="$(id -u)"

mkdir -p "$OUT_DIR" "$STAGING_DIR"
mkdir -p "$STAGING_DIR/app-support" "$STAGING_DIR/logs" "$STAGING_DIR/launchd"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    cp -R "$src" "$dst"
  fi
}

copy_if_exists "$APP_SUPPORT_DIR/config.json" "$STAGING_DIR/app-support/"
copy_if_exists "$APP_SUPPORT_DIR/status.json" "$STAGING_DIR/app-support/"
copy_if_exists "$APP_SUPPORT_DIR/daemon.pid" "$STAGING_DIR/app-support/"

if [[ -d "$LOG_DIR" ]]; then
  cp -R "$LOG_DIR/." "$STAGING_DIR/logs/"
fi

copy_if_exists "$LAUNCH_AGENTS_DIR/ch.hefti.macvirtualmicbridge.daemon.plist" "$STAGING_DIR/launchd/"
copy_if_exists "$LAUNCH_AGENTS_DIR/ch.hefti.macvirtualmicbridge.menubar.plist" "$STAGING_DIR/launchd/"

launchctl print "gui/$USER_ID/ch.hefti.macvirtualmicbridge.daemon" > "$STAGING_DIR/launchd/daemon-service.txt" 2>&1 || true
launchctl print "gui/$USER_ID/ch.hefti.macvirtualmicbridge.menubar" > "$STAGING_DIR/launchd/menubar-service.txt" 2>&1 || true
launchctl list | rg "ch\.hefti\.macvirtualmicbridge" > "$STAGING_DIR/launchd/launchctl-list.txt" 2>&1 || true

{
  echo "captured_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo
  echo "== sw_vers =="
  sw_vers
  echo
  echo "== uname -a =="
  uname -a
} > "$STAGING_DIR/system.txt"

tar -czf "$ARCHIVE_PATH" -C "$OUT_DIR" "$BUNDLE_NAME"
rm -rf "$STAGING_DIR"

echo "Support bundle created: $ARCHIVE_PATH"
