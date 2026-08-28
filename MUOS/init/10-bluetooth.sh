#!/bin/sh
# muOS user-init hook: bring up Bluetooth on the RG35XX SP.
#
# muOS ships BlueZ, rtk_hciattach, the RTL8821C firmware and PipeWire's bluez5
# plugin, but sets board/bluetooth=0 for rg35xx-sp and never attaches the
# adapter. This does the missing bringup, then reconnects any known device
# marked auto-connect (most recently used first, first success wins).
#
# Managed by the Bluetooth app: /mnt/mmc/MUOS/application/Bluetooth
# Enabled by: Configuration > Advanced Settings > User Init Scripts

. /opt/muos/script/var/func.sh
. /mnt/mmc/MUOS/bluetooth/bt-common.sh

LOG="/mnt/mmc/MUOS/log/bluetooth.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') bluetooth init ==="

# USB-C audio: load the class driver so USB-C headphones work when plugged
# into the OTG port. The kernel auto-switches the port to host on detection
# (flip the plug if nothing happens - ID sensing is one-orientation here).
for M in snd-hwdep snd-usbmidi-lib snd-usb-audio; do
	insmod "/mnt/mmc/MUOS/bluetooth/modules/$M.ko" 2>/dev/null
done
echo "usb-audio modules loaded"

# Route audio to USB headphones automatically while they are plugged in.
pgrep -f "usb-audio-watch.s[h]" >/dev/null 2>&1 ||
	setsid /mnt/mmc/MUOS/bluetooth/usb-audio-watch.sh >/dev/null 2>&1 </dev/null &
echo "usb-audio route watcher started"

if BT_READY; then
	echo "hci0 up: $(hciconfig hci0 2>/dev/null | sed -n 's/.*BD Address: \([0-9A-F:]*\).*/\1/p')"
else
	echo "FAILED to bring up hci0"
	exit 1
fi

# Wait for the audio stack before trying to route anything.
I=0
while ! pgrep -f wireplumber >/dev/null 2>&1 && [ "$I" -lt 30 ]; do
	sleep 1
	I=$((I + 1))
done
sleep 2

python3 - <<'PYEOF'
import json, re, subprocess, time

REG = "/mnt/mmc/MUOS/bluetooth/state/devices.json"

def bt(*args, timeout=8):
    try:
        return subprocess.run(
            ["bluetoothctl", "--timeout", str(timeout)] + list(args),
            capture_output=True, text=True, stdin=subprocess.DEVNULL,
            timeout=timeout + 8).stdout
    except subprocess.TimeoutExpired:
        return ""

try:
    reg = json.load(open(REG))
except Exception:
    reg = []

autos = sorted([d for d in reg if d.get("auto")],
               key=lambda d: -d.get("last", 0))
if not autos:
    print("autoconnect: no devices marked auto")
    raise SystemExit

for d in autos:
    mac, name = d["mac"], d["name"]
    print("autoconnect: trying %s (%s)" % (name, mac))
    bt("connect", mac, timeout=15)
    ok = False
    for _ in range(8):
        if "Connected: yes" in bt("info", mac, timeout=4):
            ok = True
            break
        time.sleep(1)
    if not ok:
        print("autoconnect: %s not reachable" % name)
        continue
    node = "bluez_output." + mac.replace("_", ":").replace(":", "_")
    for _ in range(8):
        out = subprocess.run(["pw-cli", "ls", "Node"], capture_output=True,
                             text=True).stdout
        ids, cur, sid = {}, None, None
        for line in out.splitlines():
            m = re.match(r"\s*id (\d+),", line)
            if m:
                cur = m.group(1)
            m = re.search(r'node\.name = "(.+)"', line)
            if m and cur and m.group(1).startswith(node):
                sid = cur
        if sid:
            subprocess.run(["wpctl", "set-default", sid], capture_output=True)
            subprocess.run(["wpctl", "set-mute", sid, "0"], capture_output=True)
            subprocess.run(["wpctl", "set-volume", sid, "0.8"], capture_output=True)
            print("autoconnect: connected, audio on %s" % name)
            break
        time.sleep(1)
    d["last"] = int(time.time())
    json.dump(reg, open(REG, "w"), indent=1)
    break
PYEOF

echo "=== done ==="
exit 0
