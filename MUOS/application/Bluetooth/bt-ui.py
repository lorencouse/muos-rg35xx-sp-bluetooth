#!/usr/bin/env python3
"""bt-ui.py - full-screen Bluetooth manager for muOS on the RG35XX SP.

Runs inside muterm (ANSI clear/home, bold and 30-37 colours work; inverse
video does not, so selection is drawn with a cursor + colour). Input is read
straight from the gamepad's evdev node, independent of the pty.
"""
import json, os, re, select, struct, subprocess, sys, time

EV_DEV = "/dev/input/event1"
STATE = "/mnt/mmc/MUOS/bluetooth/state"
REGISTRY = os.path.join(STATE, "devices.json")
PF_INTERNAL = "/opt/muos/device/config/audio/pf_internal"

EV_KEY, EV_ABS = 1, 3
KEYMAP = {304: "A", 305: "B", 306: "Y", 307: "X",
          308: "L1", 309: "R1", 310: "SELECT", 311: "START"}

CSI = "\033["


def sgr(s, *codes):
    return CSI + ";".join(map(str, codes)) + "m" + str(s) + CSI + "0m"


def yellow(s): return sgr(s, 1, 33)
def green(s): return sgr(s, 32)
def dim(s): return sgr(s, 90)
def bold(s): return sgr(s, 1)


def draw(lines):
    sys.stdout.write(CSI + "2J" + CSI + "H" + "\n".join(lines) + "\n")
    sys.stdout.flush()


# ---------------- gamepad ----------------
class Pad:
    def __init__(self):
        self.fd = os.open(EV_DEV, os.O_RDONLY | os.O_NONBLOCK)

    def poll(self, timeout):
        """One symbolic button press, or None after timeout seconds."""
        end = time.monotonic() + timeout
        while True:
            rem = end - time.monotonic()
            if rem <= 0:
                return None
            r, _, _ = select.select([self.fd], [], [], rem)
            if not r:
                return None
            try:
                buf = os.read(self.fd, 24)
            except BlockingIOError:
                continue
            if len(buf) < 24:
                continue
            _s, _u, etype, code, val = struct.unpack("llHHi", buf)
            if etype == EV_KEY and val == 1 and code in KEYMAP:
                return KEYMAP[code]
            if etype == EV_ABS and val != 0:
                if code == 16:
                    return "RIGHT" if val > 0 else "LEFT"
                if code == 17:
                    return "DOWN" if val > 0 else "UP"

    def drain(self):
        while True:
            try:
                os.read(self.fd, 24)
            except BlockingIOError:
                return


# ---------------- bluetoothctl ----------------
def bt(*args, timeout=8):
    # One-shot bluetoothctl commands exit on their own; --timeout N would
    # instead hold the session open for the full N seconds and freeze the UI.
    # The subprocess timeout is only a kill-guard for a hung daemon call.
    try:
        return subprocess.run(
            ["bluetoothctl"] + list(args),
            capture_output=True, text=True, stdin=subprocess.DEVNULL,
            timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


def bt_info(mac, timeout=4):
    out = bt("info", mac, timeout=timeout)
    d = {"paired": "Paired: yes" in out,
         "connected": "Connected: yes" in out,
         "trusted": "Trusted: yes" in out,
         "audio": bool(re.search(r"Icon: audio|Audio Sink|Headset", out)),
         "battery": None, "name": None, "class": None}
    m = re.search(r"Battery Percentage: 0x[0-9a-fA-F]+ \((\d+)\)", out)
    if m:
        d["battery"] = int(m.group(1))
    m = re.search(r"^\s*Name: (.+)$", out, re.M)
    if m:
        d["name"] = m.group(1).strip()
    m = re.search(r"Class: (0x[0-9a-fA-F]+)", out)
    if m:
        d["class"] = int(m.group(1), 16)
    return d


def is_audio(info):
    if info["audio"]:
        return True
    c = info.get("class")
    return c is not None and ((c >> 8) & 0x1F) == 4


# ---------------- audio routing ----------------
def sink_ids():
    """{node.name: id} for every PipeWire node."""
    try:
        out = subprocess.run(["pw-cli", "ls", "Node"], capture_output=True,
                             text=True, timeout=8).stdout
    except Exception:
        return {}
    ids, cur = {}, None
    for line in out.splitlines():
        m = re.match(r"\s*id (\d+),", line)
        if m:
            cur = m.group(1)
        m = re.search(r'node\.name = "(.+)"', line)
        if m and cur:
            ids[m.group(1)] = cur
    return ids


def default_sink_node():
    try:
        out = subprocess.run(["wpctl", "inspect", "@DEFAULT_AUDIO_SINK@"],
                             capture_output=True, text=True, timeout=8).stdout
        m = re.search(r'node\.name = "(.+)"', out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def wpctl(*args):
    subprocess.run(["wpctl"] + list(args), capture_output=True, timeout=8)


def speaker_node():
    try:
        return open(PF_INTERNAL).read().strip()
    except OSError:
        return ""


def bt_node_of(mac):
    return "bluez_output." + mac.replace(":", "_")


def route_to(node_prefix, volume=None):
    ids = sink_ids()
    for node, i in ids.items():
        if node.startswith(node_prefix):
            wpctl("set-default", i)
            wpctl("set-mute", i, "0")
            if volume:
                wpctl("set-volume", i, volume)
            return True
    return False


# ---------------- registry ----------------
def load_reg():
    try:
        return json.load(open(REGISTRY))
    except Exception:
        return []


def save_reg(reg):
    os.makedirs(STATE, exist_ok=True)
    tmp = REGISTRY + ".tmp"
    json.dump(reg, open(tmp, "w"), indent=1)
    os.replace(tmp, REGISTRY)


def reg_get(reg, mac):
    for d in reg:
        if d["mac"] == mac:
            return d
    return None


# ---------------- flows ----------------
def log_screen(title, lines):
    draw([bold(" " + title), " " + "-" * 50] + [" " + l for l in lines])


def connect_flow(pad, reg, mac, name):
    steps = []

    def step(s):
        steps.append(s)
        log_screen("CONNECTING", steps + ["", dim("please wait...")])

    entry = reg_get(reg, mac)
    info = bt_info(mac)
    if not info["paired"]:
        step("Pairing with %s ..." % name)
        bt("pair", mac, timeout=35)
        info = bt_info(mac)
        if not info["paired"]:
            step(sgr("Pairing FAILED.", 1, 31))
            step("Is the device still in pairing mode?")
            wait_key(pad, steps, "CONNECTING")
            return False
    bt("trust", mac, timeout=5)
    step("Connecting to %s ..." % name)
    bt("connect", mac, timeout=30)
    ok = False
    for _ in range(10):
        if bt_info(mac, timeout=3)["connected"]:
            ok = True
            break
        time.sleep(1)
    if not ok:
        step(sgr("Connection FAILED.", 1, 31))
        step("Make sure the device is powered on and near.")
        wait_key(pad, steps, "CONNECTING")
        return False
    step("Routing audio ...")
    routed = False
    for _ in range(8):
        if route_to(bt_node_of(mac), "0.8"):
            routed = True
            break
        time.sleep(1)
    if entry is None:
        entry = {"mac": mac, "name": name, "auto": True, "last": 0}
        reg.append(entry)
    entry["name"] = name
    entry["last"] = int(time.time())
    save_reg(reg)
    step(green("Connected!") if routed else
         "Connected (no audio sink - not an audio device?)")
    if routed:
        step("Sound now plays through %s." % name)
    wait_key(pad, steps, "CONNECTING")
    return True


def wait_key(pad, lines, title):
    log_screen(title, lines + ["", yellow("press any button")])
    pad.drain()
    pad.poll(3600)


def scan_screen(pad, reg):
    scan = subprocess.Popen(["bluetoothctl", "--timeout", "600", "scan", "on"],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            stdin=subprocess.DEVNULL)
    known = {d["mac"] for d in reg}
    probed, found, sel = {}, [], 0
    spin = "|/-\\"
    tick = 0
    try:
        while True:
            out = bt("devices", timeout=4)
            for m in re.finditer(r"Device ([0-9A-Fa-f:]{17}) (.+)", out):
                mac, name = m.group(1).upper(), m.group(2).strip()
                if mac in known or mac in probed:
                    continue
                if name == mac.replace(":", "-"):
                    continue
                probed[mac] = True
                inf = bt_info(mac, timeout=2)
                if is_audio(inf):
                    found.append((mac, inf["name"] or name))
            lines = [bold(" PAIR NEW DEVICE") +
                     dim("   scanning " + spin[tick % 4]),
                     " " + "-" * 50,
                     " Put your headphones in pairing mode.", ""]
            if not found:
                lines.append(dim("   ...listening for audio devices..."))
            for i, (mac, name) in enumerate(found):
                cur = i == sel
                row = " %s %s" % (">" if cur else " ", name)
                lines.append(yellow(row) if cur else row)
                lines.append(dim("     " + mac))
            lines += ["", " " + "-" * 50,
                      " " + dim("A connect    B back")]
            draw(lines)
            key = pad.poll(1.2)
            tick += 1
            if key == "B":
                return
            if key == "UP" and found:
                sel = (sel - 1) % len(found)
            elif key == "DOWN" and found:
                sel = (sel + 1) % len(found)
            elif key == "A" and found:
                mac, name = found[sel]
                scan.kill()
                connect_flow(pad, reg, mac, name)
                return
    finally:
        if scan.poll() is None:
            scan.kill()


def device_screen(pad, reg, mac):
    sel = 0
    confirm_forget = False
    while True:
        entry = reg_get(reg, mac)
        if entry is None:
            return
        inf = bt_info(mac, timeout=3)
        status = green("connected") if inf["connected"] else dim("not connected")
        if inf["battery"] is not None:
            status += "  battery %d%%" % inf["battery"]
        items = [("Disconnect" if inf["connected"] else "Connect"),
                 "Auto-connect at boot: " + (green("ON") if entry.get("auto")
                                             else dim("OFF")),
                 (sgr("Really forget? press A to confirm", 1, 31)
                  if confirm_forget else "Forget this device")]
        lines = [bold(" " + entry["name"][:46]), " " + status,
                 " " + "-" * 50, ""]
        for i, it in enumerate(items):
            cur = i == sel
            row = " %s %s" % (">" if cur else " ", it)
            lines.append(yellow(row) if cur and not it.startswith("\033")
                         else row)
        lines += ["", " " + "-" * 50, " " + dim("A select    B back")]
        draw(lines)
        key = pad.poll(5)
        if key is None:
            continue
        if key == "B":
            if confirm_forget:
                confirm_forget = False
                continue
            return
        if key == "UP":
            sel = (sel - 1) % len(items)
            confirm_forget = False
        elif key == "DOWN":
            sel = (sel + 1) % len(items)
            confirm_forget = False
        elif key == "A":
            if sel == 0:
                if inf["connected"]:
                    log_screen("DISCONNECT", ["Disconnecting..."])
                    bt("disconnect", mac, timeout=10)
                    route_to(speaker_node())
                else:
                    connect_flow(pad, reg, mac, entry["name"])
            elif sel == 1:
                entry["auto"] = not entry.get("auto")
                save_reg(reg)
            elif sel == 2:
                if not confirm_forget:
                    confirm_forget = True
                else:
                    log_screen("FORGET", ["Removing %s..." % entry["name"]])
                    bt("disconnect", mac, timeout=8)
                    bt("remove", mac, timeout=8)
                    reg.remove(entry)
                    save_reg(reg)
                    route_to(speaker_node())
                    return


def main_screen(pad):
    sel = 0
    while True:
        reg = load_reg()
        reg.sort(key=lambda d: -d.get("last", 0))
        cur_node = default_sink_node()
        on_bt = cur_node.startswith("bluez_output")
        out_name = "Speaker"
        if on_bt:
            mac = cur_node[len("bluez_output."):].split(".")[0].replace("_", ":")
            e = reg_get(reg, mac)
            out_name = (e["name"] if e else "Bluetooth")[:28]
        conn = {}
        for d in reg:
            conn[d["mac"]] = bt_info(d["mac"], timeout=2)
        n = len(reg) + 1
        sel = max(0, min(sel, n - 1))
        lines = [bold(" BLUETOOTH"),
                 " " + "-" * 50,
                 " Audio output: " + (green(out_name) if on_bt
                                      else bold(out_name)),
                 "", " " + dim("MY DEVICES")]
        for i, d in enumerate(reg):
            inf = conn[d["mac"]]
            tags = []
            if inf["connected"]:
                tags.append(green("connected"))
                if inf["battery"] is not None:
                    tags.append("%d%%" % inf["battery"])
            if d.get("auto"):
                tags.append(dim("auto"))
            cur = i == sel
            row = " %s %-30s %s" % (">" if cur else " ",
                                    d["name"][:30], " ".join(tags))
            lines.append(yellow(" > " + d["name"][:30]) +
                         "  " + " ".join(tags) if cur else row)
        cur = sel == n - 1
        row = " %s + Pair new device" % (">" if cur else " ")
        lines.append(yellow(row) if cur else row)
        lines += ["", " " + "-" * 50,
                  " " + dim("A select    Y switch audio    B exit")]
        draw(lines)
        key = pad.poll(6)
        if key is None:
            continue
        if key == "B":
            return
        if key == "UP":
            sel = (sel - 1) % n
        elif key == "DOWN":
            sel = (sel + 1) % n
        elif key == "Y":
            if on_bt:
                route_to(speaker_node())
            else:
                for d in reg:
                    if conn.get(d["mac"], {}).get("connected"):
                        route_to(bt_node_of(d["mac"]), "0.8")
                        break
        elif key == "A":
            if sel == n - 1:
                scan_screen(pad, load_reg())
            else:
                device_screen(pad, load_reg(), reg[sel]["mac"])


def main():
    draw([bold(" BLUETOOTH"), "", " Starting Bluetooth adapter..."])
    r = subprocess.run(["sh", "-c",
                        ". /mnt/mmc/MUOS/bluetooth/bt-common.sh; BT_READY"],
                       capture_output=True, timeout=60)
    if r.returncode != 0:
        draw([bold(" BLUETOOTH"), "",
              sgr(" Bluetooth adapter failed to start.", 1, 31),
              " Try rebooting the device.", "",
              yellow(" press any button to exit")])
        pad = Pad()
        pad.poll(3600)
        return
    pad = Pad()
    main_screen(pad)
    draw([" bye"])


if __name__ == "__main__":
    main()
