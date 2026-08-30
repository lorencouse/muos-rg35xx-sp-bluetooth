#!/bin/sh
# Shared Bluetooth/audio helpers for the Anbernic RG35XX SP (RTL8821CS, HCI
# over UART). muOS ships the whole stack but never attaches the adapter, so we
# do it here. Lives on the SD card so muOS updates cannot wipe it.
#
# Sourced by 10-bluetooth.sh, usb-audio-watch.sh and bt-ui.py (via sh -c).
#
# Paths go through muOS's storage binds (/run/muos/storage/...) so they are
# right whether MUOS/ lives on SD1 or SD2.

BT_DIR="/run/muos/storage/application/Bluetooth"
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

	# A cold attach takes ~5s, but after a crash mid-connection the firmware
	# init can take 20s+; giving up early kills an attach that was about to
	# succeed and churns forever.
	I=0
	while [ ! -e /sys/class/bluetooth/hci0 ] && [ "$I" -lt 60 ]; do
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

# True when the controller answers an actual HCI request. After the device
# sleeps, hci0 can survive with its UP flag set while the UART link behind it
# is dead ("Connected: yes" forever, disconnect ignored) - only a real
# round-trip like Read Local Version tells the truth.
BT_ALIVE() {
	hciconfig hci0 version >/dev/null 2>&1
}

# Tear down a wedged attach and redo the bringup. Killing rtk_hciattach makes
# hci0 disappear, but a plain re-attach then fails: the chip is still running
# the old session's firmware at the negotiated (higher) baud and never syncs
# at 115200. The sunxi-bt rfkill block/unblock power-cycles the chip so the
# attach starts from scratch (verified on-device 2026-08-30). This also drops
# any half-dead audio link at the radio level.
BT_RECOVER() {
	pkill -f 'rtk_hciattac[h]' 2>/dev/null
	hciconfig hci0 down 2>/dev/null # flush pending state so hci0 can unregister
	# A stuck HCI command pins the dying hci0 for its own 10s timeout, so
	# allow up to 30s. Re-attaching while the old hci0 is still registered
	# can never work, so give up honestly if it refuses to go.
	I=0
	while [ -e /sys/class/bluetooth/hci0 ] && [ "$I" -lt 60 ]; do
		sleep 0.5
		I=$((I + 1))
	done
	[ -e /sys/class/bluetooth/hci0 ] && return 1
	rfkill block bluetooth 2>/dev/null
	sleep 1
	rfkill unblock bluetooth 2>/dev/null
	# The chip needs a few seconds after power-on before the UART will sync;
	# attaching at ~1s reliably fails, at ~5s it reliably works.
	sleep 5
	BT_UP
}

# Everything needed before any bluetoothctl call.
BT_READY() {
	# A failed plain attach means the chip is stuck in its previous
	# session's state (hci0 gone, firmware at the negotiated baud) - only
	# BT_RECOVER's power cycle can bring it back from that.
	if ! BT_UP; then
		BT_RECOVER || return 1
	fi
	hciconfig hci0 up 2>/dev/null
	if ! BT_ALIVE; then
		BT_RECOVER || return 1
		# Right after a re-attach the firmware can still be settling.
		I=0
		until hciconfig hci0 up 2>/dev/null && BT_ALIVE; do
			I=$((I + 1))
			[ "$I" -ge 5 ] && return 1
			sleep 1
		done
	fi
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
