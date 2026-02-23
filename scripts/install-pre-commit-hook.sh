#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_PATH="$ROOT_DIR/.githooks/pre-commit"

if [[ ! -d "$ROOT_DIR/.git" ]]; then
  echo "Not a git repository: $ROOT_DIR" >&2
  exit 1
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "Hook file missing: $HOOK_PATH" >&2
  exit 1
fi

chmod +x "$HOOK_PATH"
git -C "$ROOT_DIR" config core.hooksPath .githooks

echo "Installed pre-commit hook via core.hooksPath=.githooks"
echo "Current setting:"
git -C "$ROOT_DIR" config --get core.hooksPath
