#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
LOG_DIR="$HOME/Library/Logs/MacVirtualMicBridge"
PID_FILE="$APP_SUPPORT_DIR/daemon.pid"
LOG_FILE="$LOG_DIR/daemon.log"
DAEMON_NAME="micbridge-daemon"
RUNTIME_BIN="$APP_SUPPORT_DIR/bin/current/micbridge-daemon"

is_expected_daemon_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1

  local cmd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" == *"$DAEMON_NAME"* ]]
}

mkdir -p "$APP_SUPPORT_DIR" "$LOG_DIR"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" | tr -d '[:space:]')"
  if is_expected_daemon_pid "$PID"; then
    echo "Daemon already running with PID $PID"
    exit 0
  fi
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    echo "Stale pid file points to non-$DAEMON_NAME process (PID $PID); removing stale pid file."
  fi
  rm -f "$PID_FILE"
fi

"$ROOT_DIR/scripts/install-runtime-binaries.sh" --ensure >/dev/null

if [[ ! -x "$RUNTIME_BIN" ]]; then
  echo "Runtime daemon binary missing: $RUNTIME_BIN" >&2
  exit 1
fi

nohup "$RUNTIME_BIN" >> "$LOG_FILE" 2>&1 &
NEW_PID=$!
sleep 0.4

if ! is_expected_daemon_pid "$NEW_PID"; then
  rm -f "$PID_FILE"
  echo "Daemon failed to stay running; check log at $LOG_FILE" >&2
  exit 1
fi

echo "$NEW_PID" > "$PID_FILE"
echo "Daemon started with PID $NEW_PID"
