#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

run_and_log() {
  local label="$1"
  shift
  local log_file
  log_file="$(mktemp -t micbridge-validate-swift.XXXXXX.log)"
  if ! "$@" >"$log_file" 2>&1; then
    echo "[validate-swift] Failed: $label" >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    exit 1
  fi
  rm -f "$log_file"
}

echo "[validate-swift] Swift debug build"
run_and_log "swift debug build" \
  swift build -c debug \
    --product micbridge-daemon \
    --product micbridge-menubar \
    --product micbridge-fixture-validate \
    --product micbridge-capture-fixture \
    --product micbridge-audio-e2e-validate

echo "[validate-swift] Swift release build"
run_and_log "swift release build" \
  swift build -c release \
    --product micbridge-daemon \
    --product micbridge-menubar \
    --product micbridge-fixture-validate \
    --product micbridge-capture-fixture \
    --product micbridge-audio-e2e-validate

echo "[validate-swift] Fixture validation"
swift run -c release micbridge-fixture-validate

echo "[validate-swift] OK"
