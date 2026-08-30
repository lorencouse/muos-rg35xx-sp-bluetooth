#!/bin/sh
# bt-watch.sh <MAC> - Bluetooth link watchdog, one per connected device.
#
# Started after a successful connect (from the UI or the boot autoconnect).
# Every 5s it checks that the controller still answers HCI requests and that
# the device is still connected. A wedged controller (seen after sleep) gets
# re-attached; a dropped link gets 3 reconnect attempts; if the device is
# really gone, audio falls back to the built-in speaker and the watchdog
# exits - without this, the default sink stays pointed at the dead Bluetooth
# node and everything is silent. Every transition is logged with a timestamp
# so a dropout can be diagnosed after the fact.
#
# The UI kills this before a manual disconnect so it never fights the user.
# Log: MUOS/log/bluetooth.log

. /run/muos/storage/application/Bluetooth/bt-common.sh

MAC="$1"
[ -n "$MAC" ] || exit 1
NODE="bluez_output.$(echo "$MAC" | tr ':' '_')"

LOG="/mnt/mmc/MUOS/log/bluetooth.log"
if [ -f /opt/muos/script/var/func.sh ]; then
	. /opt/muos/script/var/func.sh
	D="$(GET_VAR "device" "storage/rom/mount" 2>/dev/null)"
	[ -n "$D" ] && LOG="$D/MUOS/log/bluetooth.log"
fi
mkdir -p "$(dirname "$LOG")" 2>/dev/null

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') bt-watch: $*" >>"$LOG"; }

CONNECTED() {
	bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"
}

# Re-point the default sink at the device; its node id changes every reconnect.
ROUTE_BT() {
	I=0
	while [ "$I" -lt 8 ]; do
		ID="$(BT_ID_FOR_NODE "$NODE")"
		if [ -n "$ID" ]; then
			wpctl set-default "$ID" 2>/dev/null
			wpctl set-mute "$ID" 0 2>/dev/null
			return 0
		fi
		sleep 1
		I=$((I + 1))
	done
	return 1
}

RECONNECT() {
	N=0
	while [ "$N" -lt 3 ]; do
		N=$((N + 1))
		bluetoothctl disconnect "$MAC" >/dev/null 2>&1 # clear any half-open state
		bluetoothctl connect "$MAC" >/dev/null 2>&1
		sleep 2
		if CONNECTED; then
			ROUTE_BT || say "reconnected but no audio sink appeared"
			return 0
		fi
	done
	return 1
}

say "watching $MAC"
MISS=0
while :; do
	sleep 5
	if ! BT_ALIVE; then
		say "controller unresponsive - re-attaching hci0"
		if BT_READY; then
			say "controller recovered"
		else
			say "controller recovery FAILED - audio back to speaker"
			BT_RESTORE_SPEAKER
			exit 1
		fi
	fi
	if CONNECTED; then
		MISS=0
		continue
	fi
	MISS=$((MISS + 1))
	[ "$MISS" -lt 2 ] && continue # one blip is not a drop
	say "link to $MAC dropped - reconnecting"
	if RECONNECT; then
		say "reconnected"
		MISS=0
	else
		say "reconnect failed - audio back to speaker"
		BT_RESTORE_SPEAKER
		exit 0
	fi
done
