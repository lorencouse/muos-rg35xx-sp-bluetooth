#!/bin/sh
# muOS user-init hook: connect to the best saved Wi-Fi profile that is in range.
#
# Stock muOS only ever reconnects to the *last used* network. This scans once,
# matches what it sees against the saved profiles in MUOS/network/*.ini, picks
# the highest "priority=" (strongest signal on a tie), loads that profile into
# the active network config exactly as the Network Profiles screen would, and
# hands over to muOS's own network.sh so all of its error handling applies.
#
# Profile keys honoured (add them to the .ini by hand or leave the defaults):
#   autoconnect=0   never pick this profile automatically   (default 1)
#   priority=N      higher wins when several are in range   (default 0)
#
# Enabled by: Configuration > Advanced Settings > User Init Scripts
# Leave "Start Network on Boot" OFF; this hook replaces it. If it is on and
# muOS already connected, this hook does nothing.

. /opt/muos/script/var/func.sh

ROM_MOUNT="$(GET_VAR "device" "storage/rom/mount")"
[ -n "$ROM_MOUNT" ] || ROM_MOUNT="/mnt/mmc"
PROFILES="$MUOS_STORE_DIR/network"   # bind: SD1 or SD2, whichever muOS uses
LOG="$ROM_MOUNT/MUOS/log/wifi.log"
STATUS="$MUOS_RUN_DIR/network.status"

mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 400 ]; then
	tail -n 300 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') wifi autoconnect ==="

[ "$(GET_VAR "device" "board/network")" = "1" ] || { echo "no network capability"; exit 0; }

# If "Start Network on Boot" is on, muOS's own connect may still be running
# when we start. Scanning on top of it would disturb the association, so
# wait for it to settle (network.sh clears the status file when it fails).
I=0
while [ "$I" -lt 45 ]; do
	case "$(cat "$STATUS" 2>/dev/null)" in
		"" | CONNECTED) break ;;
		*) sleep 1; I=$((I + 1)) ;;
	esac
done
if [ "$(cat "$STATUS" 2>/dev/null)" = "CONNECTED" ]; then
	echo "already connected to '$(GET_VAR "config" "network/ssid")' (Start Network on Boot); nothing to do"
	exit 0
fi
[ "$I" -gt 0 ] && echo "waited ${I}s for muOS's own boot connect to finish (it did not succeed)"

# Bring the driver/interface up the same way muOS does.
IFCE="$(GET_VAR "device" "network/iface_active")"
[ -n "$IFCE" ] || IFCE="$(GET_VAR "device" "network/iface")"
[ -n "$IFCE" ] || IFCE="wlan0"
if [ ! -d "/sys/class/net/$IFCE" ]; then
	/opt/muos/script/device/network.sh load
	IFCE="$(GET_VAR "device" "network/iface_active")"
	[ -n "$IFCE" ] || IFCE="wlan0"
fi
ip link set dev "$IFCE" up 2>/dev/null

# ---- 1. what is in range: "<signal dBm>\t<ssid>" (best BSS per SSID) ----
SCAN=""
I=0
while [ -z "$SCAN" ] && [ "$I" -lt 3 ]; do
	SCAN=$(timeout 20 iw dev "$IFCE" scan 2>/dev/null | awk '
		/^BSS / { sig = -100 }
		/^\tsignal:/ { sig = $2 + 0 }
		/^\tSSID: ./ {
			s = $0; sub(/^\tSSID: /, "", s)
			if (!(s in best) || sig > best[s]) best[s] = sig
		}
		END { for (s in best) printf "%d\t%s\n", best[s], s }')
	[ -n "$SCAN" ] || { I=$((I + 1)); sleep 2; }
done
[ -n "$SCAN" ] || echo "scan returned nothing (continuing; hidden profiles may still match)"

# ---- 2. saved profiles, ranked ----
INI_GET() { sed -n "s/^$2=//p" "$1" | head -1; }

BEST=""
BEST_PRI=""
BEST_SIG=""
for INI in "$PROFILES"/*.ini; do
	[ -f "$INI" ] || continue
	SSID=$(INI_GET "$INI" ssid)
	[ -n "$SSID" ] || continue
	AUTO=$(INI_GET "$INI" autoconnect)
	[ "${AUTO:-1}" = "0" ] && { echo "skip  '$SSID' (autoconnect=0)"; continue; }
	PRI=$(INI_GET "$INI" priority)
	PRI=$(printf '%s' "${PRI:-0}" | tr -cd '0-9-')
	HIDDEN=$(INI_GET "$INI" hidden)
	[ -n "$HIDDEN" ] || HIDDEN=$(INI_GET "$INI" scan)

	SIG=$(printf '%s\n' "$SCAN" | awk -F'\t' -v s="$SSID" '$2 == s { print $1; exit }')
	if [ -z "$SIG" ]; then
		if [ "${HIDDEN:-0}" = "1" ]; then
			SIG=-100  # hidden: cannot see it, try it last
		else
			echo "away  '$SSID' (priority ${PRI:-0})"
			continue
		fi
	fi
	echo "seen  '$SSID' ${SIG} dBm, priority ${PRI:-0}"

	if [ -z "$BEST" ] || [ "$PRI" -gt "$BEST_PRI" ] ||
		{ [ "$PRI" -eq "$BEST_PRI" ] && [ "$SIG" -gt "$BEST_SIG" ]; }; then
		BEST="$INI"; BEST_PRI="$PRI"; BEST_SIG="$SIG"
	fi
done

[ -n "$BEST" ] || { echo "no saved network in range"; exit 0; }

# ---- 3. load the winner into the active config (what the profile screen does) ----
SSID=$(INI_GET "$BEST" ssid)
echo "using '$SSID' from $(basename "$BEST")"
SET_VAR "config" "network/ssid" "$SSID"
SET_VAR "config" "network/pass" "$(INI_GET "$BEST" pass)"
case "$(INI_GET "$BEST" type)" in
	static | 1) SET_VAR "config" "network/type" "1" ;;
	*) SET_VAR "config" "network/type" "0" ;;
esac
for K in address subnet gateway dns; do
	SET_VAR "config" "network/$K" "$(INI_GET "$BEST" $K)"
done
HIDDEN=$(INI_GET "$BEST" hidden)
[ -n "$HIDDEN" ] || HIDDEN=$(INI_GET "$BEST" scan)
SET_VAR "config" "network/hidden" "${HIDDEN:-0}"
SET_VAR "config" "network/interface" "$IFCE"

# ---- 4. let muOS do the connecting ----
/opt/muos/script/system/network.sh connect
RC=$?
echo "network.sh connect rc=$RC status=$(cat "$STATUS" 2>/dev/null) ip=$(ip -4 -o addr show dev "$IFCE" 2>/dev/null | awk '{print $4}')"
echo "=== done ==="
exit 0
