#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_BIN="$HOME/Library/Application Support/MacVirtualMicBridge/bin/current/micbridge-menubar"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/install-runtime-binaries.sh" --ensure >/dev/null
exec env MICBRIDGE_REPO_ROOT="$ROOT_DIR" "$RUNTIME_BIN"
