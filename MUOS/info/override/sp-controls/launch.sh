#!/bin/sh
# SP control pack: per-system D-pad / analog-stick mode, applied at launch.
#
# The RG35XX SP has no analog stick. muOS lets the D-pad act as the left
# stick (L2+R2+A in game, flips /sys/.../nds_pwrkey), but the setting is
# per-session and resets on every launch. This is a muOS "launch override"
# (MUOS/info/override/<folder>.sh, run by launch.sh instead of the normal
# launcher): it sets the mode for the content's folder, then hands over to
# the launcher muOS would have used. launch.sh resets the mode to D-pad
# when the game exits.
#
# Modes come from sp-controls/dpad.conf next to this file:
#   n64=stick                 whole folder
#   psx/Ape Escape (USA)=stick  one game (muOS's friendly name, no extension)
# Folders with no entry keep the plain D-pad.

. /opt/muos/script/var/func.sh

NAME="$1"
CORE="$2"
ROM="$3"

HERE="$(dirname "$0")"
CONF="$HERE/sp-controls/dpad.conf"
[ -f "$CONF" ] || CONF="$(dirname "$HERE")/sp-controls/dpad.conf"
LOG="$(GET_VAR "device" "storage/rom/mount")/MUOS/log/controls.log"
DPAD_FILE="/sys/class/power_supply/axp2202-battery/nds_pwrkey"

FOLDER="$(basename "$(dirname "$ROM")")"

CONF_GET() { sed -n "s|^$1=||p" "$CONF" 2>/dev/null | head -1; }
MODE="$(CONF_GET "$FOLDER/$NAME")"
[ -n "$MODE" ] || MODE="$(CONF_GET "$FOLDER")"

if [ -f "$DPAD_FILE" ]; then
	case "$MODE" in
		stick)
			echo 2 >"$DPAD_FILE"
			RUMBLE "$(GET_VAR "device" "board/rumble")" .1
			;;
		*) echo 0 >"$DPAD_FILE" ;;
	esac
fi

# ---- find the launcher muOS would have used ----
# launch.sh leaves NAME / system / core in /tmp/ovl_go for the overlay.
ASSIGN=""
[ -f /tmp/ovl_go ] && ASSIGN="$(sed -n 2p /tmp/ovl_go)"
EXEC=""
if [ -n "$ASSIGN" ] && [ -d "$MUOS_SHARE_DIR/info/assign/$ASSIGN" ]; then
	for INI in "$MUOS_SHARE_DIR/info/assign/$ASSIGN"/*.ini; do
		grep -q "^core=$CORE\$" "$INI" 2>/dev/null || continue
		EXEC="$(PARSE_INI "$INI" launch exec)"
		[ -n "$EXEC" ] && break
	done
fi
case "$EXEC" in
	"") case "$CORE" in
		*.so) EXEC="/opt/muos/script/launch/lr-general.sh" ;;
		ext-*) EXEC="/opt/muos/script/launch/$CORE.sh" ;;
	esac ;;
esac

printf '%s  %s/%s  mode=%s  exec=%s\n' "$(date '+%F %T')" "$FOLDER" "$NAME" "${MODE:-dpad}" "$EXEC" >>"$LOG" 2>/dev/null

[ -n "$SP_CONTROLS_DRYRUN" ] && { echo "dry-run: mode=${MODE:-dpad} exec=$EXEC"; exit 0; }
[ -x "$EXEC" ] || {
	printf '%s  ERROR: no launcher for core "%s" (system "%s")\n' "$(date '+%F %T')" "$CORE" "$ASSIGN" >>"$LOG"
	exit 1
}
exec "$EXEC" "$NAME" "$CORE" "$ROM"
