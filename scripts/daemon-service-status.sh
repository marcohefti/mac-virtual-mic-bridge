#!/usr/bin/env zsh
set -euo pipefail

LABEL="ch.hefti.macvirtualmicbridge.daemon"
USER_ID="$(id -u)"

launchctl print "gui/$USER_ID/$LABEL"
