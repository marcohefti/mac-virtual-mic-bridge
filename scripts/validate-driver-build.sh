#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[validate-driver] HAL driver build"
./drivers/micbridge-hal/scripts/build-driver.sh >/dev/null
echo "[validate-driver] OK"
