#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/packages/bridge-core/fixtures"

if [[ "${1:-}" == "" ]]; then
  echo "Usage: ./scripts/capture-fixture.sh <fixture-name>" >&2
  echo "Example: ./scripts/capture-fixture.sh sleep_wake_target_missing" >&2
  exit 1
fi

NAME="$1"
NAME="${NAME%.json}"
OUT_PATH="$FIXTURE_DIR/$NAME.json"

cd "$ROOT_DIR"
swift run -c release micbridge-capture-fixture "$OUT_PATH"
echo "Fixture saved: $OUT_PATH"
