#!/bin/sh
# When a USB audio sink appears (USB-C headphones plugged in), make it the
# default output; when it disappears, return audio to the built-in speaker.
# Started at boot by 10-bluetooth.sh. Polls every 3s.

. /mnt/mmc/MUOS/bluetooth/bt-common.sh

PREV=""
while :; do
	NODE=$(pw-cli ls Node 2>/dev/null |
		sed -n 's/.*node\.name = "\(alsa_output\.usb[^"]*\)".*/\1/p' | head -1)

	if [ -n "$NODE" ] && [ "$NODE" != "$PREV" ]; then
		ID=$(BT_ID_FOR_NODE "$NODE")
		if [ -n "$ID" ]; then
			wpctl set-default "$ID"
			wpctl set-mute "$ID" 0
			wpctl set-volume "$ID" 0.75
		fi
		# inline media buttons (exits on its own at unplug)
		pgrep -f "usb-media-buttons.p[y]" >/dev/null 2>&1 ||
			setsid python3 /mnt/mmc/MUOS/bluetooth/usb-media-buttons.py >/dev/null 2>&1 </dev/null &
	elif [ -z "$NODE" ] && [ -n "$PREV" ]; then
		BT_RESTORE_SPEAKER
	fi

	PREV="$NODE"
	sleep 3
done
