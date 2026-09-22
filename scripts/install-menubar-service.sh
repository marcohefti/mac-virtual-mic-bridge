#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ch.hefti.macvirtualmicbridge.menubar"
USER_ID="$(id -u)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
MENUBAR_BIN="/Applications/MicBridge.app/Contents/MacOS/micbridge-menubar"
LOG_DIR="$HOME/Library/Logs/MacVirtualMicBridge"
STDOUT_LOG="$LOG_DIR/launchd-menubar.stdout.log"
STDERR_LOG="$LOG_DIR/launchd-menubar.stderr.log"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
# Package and stage the visible app, without replacing or restarting audio runtime.
STAGING_DIR="$(mktemp -d -t micbridge-menu-install)"
trap 'rm -rf "$STAGING_DIR"' EXIT
"$ROOT_DIR/scripts/package-app.sh" --output-dir "$STAGING_DIR" --repo-root "$ROOT_DIR" --no-zip >/dev/null
BACKUP_DIR="$HOME/Library/Application Support/MacVirtualMicBridge/backups/menu-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [[ -d /Applications/MicBridge.app ]]; then
  ditto /Applications/MicBridge.app "$BACKUP_DIR/MicBridge.app"
fi

# Retire session and persistent supervisors before stopping their processes.
launchctl bootout "gui/$USER_ID/ch.hefti.micbridge.session.menubar" >/dev/null 2>&1 || true
launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true

# Avoid duplicate manual + launchd menubar instances.
pkill -f '/MacVirtualMicBridge/bin/current/micbridge-menubar' >/dev/null 2>&1 || true
pkill -f '/\.build/release/micbridge-menubar' >/dev/null 2>&1 || true

pkill -f '^/Applications/MicBridge.app/Contents/MacOS/micbridge-menubar$' >/dev/null 2>&1 || true
ditto "$STAGING_DIR/MicBridge.app" /Applications/MicBridge.app
codesign --verify --deep --strict /Applications/MicBridge.app

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MENUBAR_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MICBRIDGE_REPO_ROOT</key>
    <string>$ROOT_DIR</string>
    <key>MICBRIDGE_LOG_STDOUT</key>
    <string>0</string>
  </dict>
</dict>
</plist>
PLIST

chmod 0644 "$PLIST_PATH"

launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true

launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH"
launchctl enable "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true


echo "Installed and started menubar launchd service:"
echo "  Label: $LABEL"
echo "  Plist: $PLIST_PATH"
echo
echo "Check status:"
echo "  launchctl print gui/$USER_ID/$LABEL"
