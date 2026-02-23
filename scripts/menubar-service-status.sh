#!/usr/bin/env zsh
set -euo pipefail

LABEL="ch.hefti.macvirtualmicbridge.menubar"
USER_ID="$(id -u)"

launchctl print "gui/$USER_ID/$LABEL"
