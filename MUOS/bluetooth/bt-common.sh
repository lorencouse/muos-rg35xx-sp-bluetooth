#!/bin/sh
# Shared Bluetooth helpers for the Anbernic RG35XX SP (RTL8821CS, HCI over UART).
# muOS ships the whole stack but never attaches the adapter, so we do it here.
# Master copy lives on the exfat card so muOS updates cannot wipe it.

BT_DIR="/mnt/mmc/MUOS/bluetooth"
BT_STATE="$BT_DIR/state"
BT_KMOD="/lib/modules/4.9.170/kernel/drivers/bluetooth/rtl_btlpm.ko"

mkdir -p "$BT_STATE"

# Hold output on screen until a button is pressed, or $1 seconds elapse.
# A running muOS task cannot be cancelled, so a bare sleep leaves the user
# staring at a screen that ignores B. Reading evdev is non-exclusive, so the
# press still reaches the frontend.
BT_PAUSE() {
	echo ""
	echo "(press any button to continue)"
	timeout "${1:-15}" head -c 32 /dev/input/event1 >/dev/null 2>&1
}

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

# Leading id of the sink whose label contains $1. Last-resort fallback only -
# two sinks share the label "Built-in Audio Stereo" (speaker and HDMI).
BT_SINK_ID() {
	wpctl status 2>/dev/null |
		sed -n '/Sinks:/,/Sink endpoints:/p' |
		grep -F "$1" |
		sed -nE 's/^[^0-9]*([0-9]+)\..*/\1/p' |
		head -1
}

# Leading id of the sink currently marked default.
BT_DEFAULT_SINK_ID() {
	wpctl status 2>/dev/null |
		sed -n '/Sinks:/,/Sink endpoints:/p' |
		grep '\*' |
		sed -nE 's/^[^0-9]*([0-9]+)\..*/\1/p' |
		head -1
}

# Resolve a PipeWire sink id from its node.name.
BT_ID_FOR_NODE() {
	pw-cli ls Node 2>/dev/null | awk -v n="$1" '
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

BT_RESTORE_SPEAKER() {
	SPK="$(BT_SPEAKER_ID)"
	[ -z "$SPK" ] && SPK="$(cat "$BT_STATE/speaker_sink" 2>/dev/null)"
	[ -z "$SPK" ] && SPK="$(BT_SINK_ID 'Built-in Audio')"
	[ -n "$SPK" ] || return 1
	wpctl set-default "$SPK" 2>/dev/null
	wpctl set-mute "$SPK" 0 2>/dev/null
}

# Sink id for a Bluetooth MAC, resolved through the PipeWire node name.
# More reliable than matching the label, which can carry non-ASCII characters.
BT_SINK_ID_MAC() {
	BT_ID_FOR_NODE "bluez_output.$(echo "$1" | tr ':' '_')"
}

# Pair (if needed), trust, connect, then hand audio to the device.
BT_CONNECT() {
	MAC="$1"
	NAME="$2"

	echo "Starting Bluetooth..."
	BT_READY || {
		echo "FAILED: no Bluetooth adapter."
		return 1
	}

	# Remember where audio was, so 'Audio Output - Speaker' can put it back.
	SPK="$(BT_DEFAULT_SINK_ID)"
	[ -n "$SPK" ] && echo "$SPK" >"$BT_STATE/speaker_sink"

	if bluetoothctl --timeout 5 info "$MAC" </dev/null 2>/dev/null | grep -q "Paired: yes"; then
		echo "Already paired."
	else
		echo "Pairing with $NAME..."
		bluetoothctl --timeout 20 pair "$MAC" </dev/null 2>&1 | tail -1
	fi
	bluetoothctl --timeout 5 trust "$MAC" </dev/null >/dev/null 2>&1

	echo "Connecting..."
	bluetoothctl --timeout 20 connect "$MAC" </dev/null 2>&1 | tail -1
	sleep 3

	ID="$(BT_SINK_ID_MAC "$MAC")"
	[ -n "$ID" ] || ID="$(BT_SINK_ID "$NAME")"
	if [ -n "$ID" ]; then
		wpctl set-default "$ID"
		wpctl set-mute "$ID" 0 2>/dev/null
		wpctl set-volume "$ID" 0.8
		printf '%s' "$MAC" >"$BT_STATE/last_mac"
		printf '%s' "$NAME" >"$BT_STATE/last_name"
		echo ""
		echo "Connected. Audio now goes to $NAME."
	else
		echo ""
		echo "Connected, but no audio sink appeared."
		echo "The device may not support A2DP."
	fi
}
