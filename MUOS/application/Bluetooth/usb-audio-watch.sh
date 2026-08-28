#!/bin/sh
# When a USB audio sink appears (USB-C headphones plugged in), make it the
# default output; when it disappears, return audio to the built-in speaker.
# Started at boot by 10-bluetooth.sh. Polls every 3s.
#
# Keyed on node.name AND node id: a WirePlumber restart keeps the name but
# hands out a new id, and the default must be re-applied then too.

. /run/muos/storage/application/Bluetooth/bt-common.sh

PREV=""
while :; do
	NODES=$(pw-cli ls Node 2>/dev/null)
	NODE=$(printf '%s\n' "$NODES" |
		sed -n 's/.*node\.name = "\(alsa_output\.usb[^"]*\)".*/\1/p' | head -1)
	ID=""
	[ -n "$NODE" ] && ID=$(printf '%s\n' "$NODES" | awk -v n="node.name = \"$NODE" '
		/^[[:space:]]*id [0-9]+,/ { gsub(/[^0-9]/, "", $2); id = $2 }
		index($0, n) { print id; exit }')
	CUR=""
	[ -n "$NODE" ] && CUR="$NODE:$ID"

	if [ -n "$NODE" ] && [ "$CUR" != "$PREV" ]; then
		if [ -n "$ID" ]; then
			wpctl set-default "$ID"
			wpctl set-mute "$ID" 0
			wpctl set-volume "$ID" 0.75
		fi
		# inline media buttons (exits on its own at unplug)
		pgrep -f "usb-media-buttons.p[y]" >/dev/null 2>&1 ||
			setsid python3 "$BT_DIR/usb-media-buttons.py" >/dev/null 2>&1 </dev/null &
	elif [ -z "$NODE" ] && [ -n "$PREV" ]; then
		BT_RESTORE_SPEAKER
	fi

	PREV="$CUR"
	sleep 3
done
