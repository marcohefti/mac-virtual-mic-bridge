#!/usr/bin/env zsh
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/micbridge-codex"

if [[ -f "$SUDOERS_FILE" ]]; then
  sudo rm -f "$SUDOERS_FILE"
  echo "Removed sudoers rule: $SUDOERS_FILE"
else
  echo "No sudoers rule found at: $SUDOERS_FILE"
fi
