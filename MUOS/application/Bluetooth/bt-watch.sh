#!/bin/sh
# bt-watch.sh <MAC> - Bluetooth link watchdog, one per device.
#
# Started after a successful connect (from the UI or the boot autoconnect)
# and runs until the UI kills it (manual disconnect/forget) or a new one
# replaces it. Two modes:
#
#   watching (5s tick)  device is connected. Recovers a wedged controller
#                       (seen after sleep), reconnects a dropped link (3
#                       tries), falls back to the built-in speaker if the
#                       device is really gone. Holds a sleep wakelock while
#                       audio is actually streaming (see below).
#   standby (15s tick)  device is gone. Still heals the controller, and when
#                       the device reconnects on its own (headphones turned
#                       back on) routes audio to it and resumes watching -
#                       without this, self-initiated reconnects play nothing.
#
# Wakelock: while the Bluetooth sink is state "running", /tmp/bt-audio-
# wakelock holds our PID and a marker line patched into muOS's idle.sh (by
# 10-bluetooth.sh) upgrades idle_inhibit to sleep-only - the screen still
# dims, but the ~5 min idle suspend no longer kills the music. The file is
# ignored if this process dies, so a stale lock cannot block sleep.
#
# Every transition is logged with a timestamp: MUOS/log/bluetooth.log

. /run/muos/storage/application/Bluetooth/bt-common.sh

MAC="$1"
[ -n "$MAC" ] || exit 1
NODE="bluez_output.$(echo "$MAC" | tr ':' '_')"
WAKELOCK="/tmp/bt-audio-wakelock"

LOG="/mnt/mmc/MUOS/log/bluetooth.log"
if [ -f /opt/muos/script/var/func.sh ]; then
	. /opt/muos/script/var/func.sh
	D="$(GET_VAR "device" "storage/rom/mount" 2>/dev/null)"
	[ -n "$D" ] && LOG="$D/MUOS/log/bluetooth.log"
fi
mkdir -p "$(dirname "$LOG")" 2>/dev/null

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') bt-watch: $*" >>"$LOG"; }

# Keep the log bounded even between boots (a flapping link writes a lot).
TRIM_LOG() {
	[ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 500 ] &&
		{ tail -n 300 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; }
}

CONNECTED() {
	bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"
}

PLAYING() {
	ID="$(BT_ID_FOR_NODE "$NODE")"
	[ -n "$ID" ] || return 1
	pw-cli i "$ID" 2>/dev/null | grep -q 'state: "running"'
}

LOCK_ON() {
	[ -f "$WAKELOCK" ] || { echo "$$" >"$WAKELOCK"; say "wakelock on (audio streaming)"; }
}
LOCK_OFF() {
	[ -f "$WAKELOCK" ] && { rm -f "$WAKELOCK"; say "wakelock off"; }
}
# INT/TERM must exit (which fires the EXIT trap) - a bare handler would
# swallow the signal and leave an unkillable watchdog behind.
trap 'LOCK_OFF' EXIT
trap 'exit 1' INT TERM

# Singleton: two watchdogs fight over the controller (each kills the other's
# rtk_hciattach mid-init) and recovery never converges.
PIDFILE="/tmp/bt-watch.pid"
OLD="$(cat "$PIDFILE" 2>/dev/null)"
if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then
	kill "$OLD" 2>/dev/null
	sleep 1
	kill -9 "$OLD" 2>/dev/null
fi
echo "$$" >"$PIDFILE"

# Re-point the default sink at the device; its node id changes on every
# reconnect. Never steals the default from plugged-in USB headphones.
ROUTE_BT() {
	wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
		grep -q 'node.name = "alsa_output.usb' && return 0
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
	BT_READY # also heals a dead bluetoothd, not just the controller
	N=0
	while [ "$N" -lt 3 ]; do
		N=$((N + 1))
		bluetoothctl disconnect "$MAC" >/dev/null 2>&1 # clear half-open state
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
QUIET=0
MODE=watching
while :; do
	if [ "$MODE" = watching ]; then
		sleep 5
	else
		sleep 15
	fi

	if ! BT_ALIVE; then
		say "controller unresponsive - re-attaching hci0"
		if BT_READY; then
			say "controller recovered"
			if [ "$MODE" = watching ]; then
				# The old link died with the controller; get it back
				# before the miss counter even notices.
				CONNECTED || RECONNECT || {
					say "device did not come back - audio to speaker, standby"
					LOCK_OFF
					BT_RESTORE_SPEAKER
					MODE=standby
				}
				[ "$MODE" = watching ] && ROUTE_BT
			fi
		else
			say "controller recovery FAILED - audio to speaker, standby"
			LOCK_OFF
			BT_RESTORE_SPEAKER
			MODE=standby
		fi
		MISS=0
		continue
	fi

	if [ "$MODE" = standby ]; then
		if CONNECTED; then
			say "$MAC reconnected on its own - routing audio"
			ROUTE_BT
			MODE=watching
			MISS=0
		fi
		TRIM_LOG
		continue
	fi

	# watching
	if CONNECTED; then
		MISS=0
		# A fast drop+reconnect (inside one tick) or a WirePlumber restart
		# recreates the node under a new id, leaving the default sink dead.
		# Re-route unless the user deliberately picked another output
		# (USB headphones, or Y-switch to speaker = user-speaker flag).
		DEF="$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
			sed -n 's/.*node\.name = "\([^"]*\)".*/\1/p' | head -1)"
		case "$DEF" in
		"$NODE"* | alsa_output.usb*) ;;
		*)
			if [ ! -f "$BT_STATE/user-speaker" ]; then
				say "default sink lost ($DEF) - re-routing"
				ROUTE_BT
			fi
			;;
		esac
		# Sleep wakelock tracks whether audio is actually streaming, with
		# hysteresis so a brief pause between tracks does not flap it.
		if PLAYING; then
			QUIET=0
			LOCK_ON
		else
			QUIET=$((QUIET + 1))
			[ "$QUIET" -ge 3 ] && LOCK_OFF
		fi
		continue
	fi
	LOCK_OFF
	MISS=$((MISS + 1))
	[ "$MISS" -lt 2 ] && continue # one blip is not a drop
	say "link to $MAC dropped - reconnecting"
	if RECONNECT; then
		say "reconnected"
		MISS=0
	else
		say "reconnect failed - audio to speaker, standby"
		BT_RESTORE_SPEAKER
		MODE=standby
		TRIM_LOG
	fi
done
