#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ch.hefti.macvirtualmicbridge.daemon"
USER_ID="$(id -u)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
DAEMON_BIN="$HOME/Library/Application Support/MacVirtualMicBridge/bin/current/micbridge-daemon"
LOG_DIR="$HOME/Library/Logs/MacVirtualMicBridge"
STDOUT_LOG="$LOG_DIR/launchd-daemon.stdout.log"
STDERR_LOG="$LOG_DIR/launchd-daemon.stderr.log"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
"$ROOT_DIR/scripts/install-runtime-binaries.sh" >/dev/null

# Avoid duplicate manual + launchd daemon instances.
"$ROOT_DIR/scripts/stop-daemon.sh" >/dev/null 2>&1 || true

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DAEMON_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
</dict>
</plist>
PLIST

chmod 0644 "$PLIST_PATH"

launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true

launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH"
launchctl enable "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$USER_ID/$LABEL"

echo "Installed and started launchd service:"
echo "  Label: $LABEL"
echo "  Plist: $PLIST_PATH"
echo
echo "Check status:"
echo "  launchctl print gui/$USER_ID/$LABEL"
