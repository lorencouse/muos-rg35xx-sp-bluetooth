#!/usr/bin/env python3
"""Media buttons for USB-C headphones on muOS (RG35XX SP).

The kernel exposes the headset's inline buttons as a HID input device; nothing
listens to it. This maps them to muOS's own handlers:
  volume up/down -> /opt/muos/script/device/audio.sh U|D  (same as the
                    built-in volume buttons, on-screen overlay included)
  play/pause     -> RetroArch PAUSE_TOGGLE over its UDP command port (muOS
                    ships retroarch.cfg with network_cmd_enable=true), when
                    RetroArch is running; ignored otherwise

Spawned by usb-audio-watch.sh when USB headphones appear; exits by itself
when they are unplugged (the event node vanishes).
"""
import os, re, socket, struct, subprocess, sys, time

EV_KEY = 1
KEY_VOLUMEDOWN, KEY_VOLUMEUP = 114, 115
PLAY_KEYS = {164, 163, 165, 200, 201}  # playpause, next, prev, play, pause
WANTED = PLAY_KEYS | {KEY_VOLUMEDOWN, KEY_VOLUMEUP}

AUDIO_SH = "/opt/muos/script/device/audio.sh"
REPEAT_INTERVAL = 0.15  # s between volume steps while a button is held
BITS_PER_LONG = struct.calcsize("l") * 8


def key_bits(block):
    """Set of key codes a /proc/bus/input/devices block reports in B: KEY=."""
    m = re.search(r"^B: KEY=(.*)$", block, re.M)
    if not m:
        return set()
    words = m.group(1).split()  # most significant word first, unpadded
    bits = set()
    for i, w in enumerate(reversed(words)):
        try:
            v = int(w, 16)
        except ValueError:
            continue
        base = i * BITS_PER_LONG
        while v:
            low = v & -v
            bits.add(base + low.bit_length() - 1)
            v ^= low
    return bits


def find_usb_input_event():
    """Event node of a USB input device that actually has media/volume keys.

    Picking "first USB device" would grab a keyboard or gamepad on a hub
    instead of the headset, so the key bitmap decides.
    """
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except OSError:
        return None
    for b in blocks:
        sysfs = re.search(r"^S: Sysfs=(.*)$", b, re.M)
        if not sysfs or "/usb" not in sysfs.group(1):
            continue
        if not (key_bits(b) & WANTED):
            continue
        m = re.search(r"^H: Handlers=.*?(event\d+)", b, re.M)
        if m:
            return "/dev/input/" + m.group(1)
    return None


def ra_pause():
    if subprocess.run(["pgrep", "-x", "retroarch"],
                      capture_output=True).returncode == 0:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(b"PAUSE_TOGGLE", ("127.0.0.1", 55355))
            s.close()
        except OSError:
            pass


def main():
    # The HID interface can register a moment after the audio card.
    dev = None
    for _ in range(10):
        dev = find_usb_input_event()
        if dev:
            break
        time.sleep(1)
    if not dev:
        sys.exit(0)

    try:
        fd = os.open(dev, os.O_RDONLY)
    except OSError:
        sys.exit(0)

    last_vol = 0.0
    while True:
        try:
            buf = os.read(fd, 24)
        except OSError:
            sys.exit(0)  # unplugged
        if len(buf) < 24:
            continue
        _s, _u, etype, code, val = struct.unpack("llHHi", buf)
        if etype != EV_KEY or val not in (1, 2):  # press or hold-repeat
            continue
        if code in (KEY_VOLUMEUP, KEY_VOLUMEDOWN):
            now = time.monotonic()
            if val == 2 and now - last_vol < REPEAT_INTERVAL:
                continue
            last_vol = now
            try:
                subprocess.run([AUDIO_SH, "U" if code == KEY_VOLUMEUP else "D"],
                               capture_output=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
        elif code in PLAY_KEYS and val == 1:
            ra_pause()


if __name__ == "__main__":
    main()
