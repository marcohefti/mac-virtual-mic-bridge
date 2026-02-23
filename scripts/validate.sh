#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INCLUDE_LIVE=0
if [[ "${1:-}" == "--live" ]]; then
  INCLUDE_LIVE=1
  shift
fi

if [[ $# -gt 0 ]]; then
  echo "Usage: ./scripts/validate.sh [--live]" >&2
  exit 1
fi

run_and_log() {
  local label="$1"
  shift
  local log_file
  log_file="$(mktemp -t micbridge-validate-step.XXXXXX.log)"
  if ! "$@" >"$log_file" 2>&1; then
    echo "[validate] Failed: $label" >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    exit 1
  fi
  rm -f "$log_file"
}

echo "[validate] Shell syntax checks"
for script in scripts/*.sh drivers/micbridge-hal/scripts/*.sh; do
  zsh -n "$script"
done
zsh -n .githooks/pre-commit

echo "[validate] Swift validation"
run_and_log "swift validation" ./scripts/validate-swift.sh

echo "[validate] Driver build validation"
run_and_log "driver build validation" ./scripts/validate-driver-build.sh

if [[ "$INCLUDE_LIVE" -eq 1 ]]; then
  echo "[validate] Live local stack validation"
  ./scripts/validate-live-stack.sh
fi

echo "[validate] OK"
