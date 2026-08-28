#!/bin/sh
# HELP: Bluetooth
# ICON: bluetooth
# GRID: Bluetooth

. /opt/muos/script/var/func.sh

SETUP_APP "btui" ""

APP_DIR="$1"
/opt/muos/frontend/muterm -s 20 "$APP_DIR/bt-ui.sh"
