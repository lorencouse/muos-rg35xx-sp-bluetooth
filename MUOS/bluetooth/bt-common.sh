#!/bin/sh
# Shared Bluetooth/audio helpers for the Anbernic RG35XX SP (RTL8821CS, HCI
# over UART). muOS ships the whole stack but never attaches the adapter, so we
# do it here. Lives on the exfat card so muOS updates cannot wipe it.
#
# Sourced by 10-bluetooth.sh, usb-audio-watch.sh and bt-ui.py (via sh -c).

BT_DIR="/mnt/mmc/MUOS/bluetooth"
BT_STATE="$BT_DIR/state"
BT_KMOD="/lib/modules/4.9.170/kernel/drivers/bluetooth/rtl_btlpm.ko"

mkdir -p "$BT_STATE"

# Attach hci0 on /dev/ttyS1. Returns non-zero if the adapter never shows up.
BT_UP() {
	[ -e /sys/class/bluetooth/hci0 ] && return 0

	insmod "$BT_KMOD" 2>/dev/null
	rfkill unblock bluetooth 2>/dev/null

	pgrep -f rtk_hciattach >/dev/null 2>&1 ||
		setsid rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 >/dev/null 2>&1 </dev/null &

	I=0
	while [ ! -e /sys/class/bluetooth/hci0 ] && [ "$I" -lt 30 ]; do
		sleep 0.5
		I=$((I + 1))
	done

	[ -e /sys/class/bluetooth/hci0 ]
}

BT_DAEMON() {
	pgrep -f "bluetooth/bluetoothd" >/dev/null 2>&1 && return 0
	setsid /usr/libexec/bluetooth/bluetoothd >/dev/null 2>&1 </dev/null &
	sleep 3
}

# Everything needed before any bluetoothctl call.
BT_READY() {
	BT_UP || return 1
	hciconfig hci0 up 2>/dev/null
	BT_DAEMON
	bluetoothctl --timeout 5 power on </dev/null >/dev/null 2>&1
	return 0
}

# Resolve a PipeWire node id from (a prefix of) its node.name.
BT_ID_FOR_NODE() {
	[ -n "$1" ] || return 1
	pw-cli ls Node 2>/dev/null | awk -v n="node.name = \"$1" '
		/^[[:space:]]*id [0-9]+,/ { gsub(/[^0-9]/, "", $2); id = $2 }
		index($0, n) { print id; exit }'
}

# The built-in speaker, taken from the device profile. Do NOT match on the
# label: card0 (speaker) and card2 (HDMI) are both "Built-in Audio Stereo",
# so a label match silently sends audio out the HDMI port.
BT_SPEAKER_ID() {
	NODE="$(cat /opt/muos/device/config/audio/pf_internal 2>/dev/null)"
	[ -n "$NODE" ] && BT_ID_FOR_NODE "$NODE"
}

# Make the built-in speaker the default sink. Fails (leaving audio where it
# is) rather than guessing when the speaker node cannot be resolved.
BT_RESTORE_SPEAKER() {
	SPK="$(BT_SPEAKER_ID)"
	[ -n "$SPK" ] || return 1
	wpctl set-default "$SPK" 2>/dev/null
	wpctl set-mute "$SPK" 0 2>/dev/null
}
