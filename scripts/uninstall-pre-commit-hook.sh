#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CURRENT_HOOKS_PATH="$(git -C "$ROOT_DIR" config --get core.hooksPath || true)"

if [[ "$CURRENT_HOOKS_PATH" != ".githooks" ]]; then
  echo "core.hooksPath is not .githooks (current: ${CURRENT_HOOKS_PATH:-<unset>})"
  echo "No changes made."
  exit 0
fi

git -C "$ROOT_DIR" config --unset core.hooksPath

echo "Removed repo-local pre-commit hook configuration (core.hooksPath unset)."
