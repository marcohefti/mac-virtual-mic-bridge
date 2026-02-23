#!/usr/bin/env zsh
set -euo pipefail

PID_FILE="$HOME/Library/Application Support/MacVirtualMicBridge/daemon.pid"
DAEMON_NAME="micbridge-daemon"

is_expected_daemon_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1

  local cmd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" == *"$DAEMON_NAME"* ]]
}

if [[ ! -f "$PID_FILE" ]]; then
  echo "Daemon is not running (pid file missing)."
  exit 0
fi

PID="$(cat "$PID_FILE" | tr -d '[:space:]')"
if [[ -z "$PID" ]]; then
  rm -f "$PID_FILE"
  echo "Daemon is not running (empty pid file)."
  exit 0
fi

if ! kill -0 "$PID" >/dev/null 2>&1; then
  rm -f "$PID_FILE"
  echo "Daemon is not running (stale pid file for PID $PID)."
  exit 0
fi

if ! is_expected_daemon_pid "$PID"; then
  rm -f "$PID_FILE"
  echo "Refusing to kill PID $PID: process is not $DAEMON_NAME. Removed stale pid file."
  exit 0
fi

kill "$PID"
sleep 0.3
if kill -0 "$PID" >/dev/null 2>&1; then
  kill -9 "$PID" >/dev/null 2>&1 || true
fi

if kill -0 "$PID" >/dev/null 2>&1; then
  echo "Failed to stop daemon PID $PID" >&2
  exit 1
fi

rm -f "$PID_FILE"
echo "Daemon stopped."
