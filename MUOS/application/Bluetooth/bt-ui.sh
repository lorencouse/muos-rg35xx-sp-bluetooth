#!/bin/sh
# Runs inside muterm so early failures are visible on screen.
exec python3 "$(dirname "$0")/bt-ui.py"
