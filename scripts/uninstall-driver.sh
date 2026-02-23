#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT_DIR/drivers/micbridge-hal/scripts/uninstall-driver.sh" "$@"
