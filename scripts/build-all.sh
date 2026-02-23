#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"
swift build -c release --product micbridge-daemon
swift build -c release --product micbridge-menubar
"$ROOT_DIR/drivers/micbridge-hal/scripts/build-driver.sh"

echo "All components built."
