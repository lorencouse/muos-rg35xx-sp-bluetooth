#!/usr/bin/env python3
"""Media buttons for USB-C headphones on muOS (RG35XX SP).

The kernel exposes the headset's inline buttons as a HID input device; nothing
listens to it. This maps them to muOS's own handlers:
  volume up/down -> /opt/muos/script/device/audio.sh U|D  (same as the
                    built-in volume buttons, on-screen overlay included)
  play/pause     -> RetroArch PAUSE_TOGGLE over its UDP command port, when
                    RetroArch is running; ignored otherwise

Spawned by usb-audio-watch.sh when USB headphones appear; exits by itself
when they are unplugged (the event node vanishes).
"""
import os, re, socket, struct, subprocess, sys, time

EV_KEY = 1
KEY_VOLUMEDOWN, KEY_VOLUMEUP = 114, 115
PLAY_KEYS = {164, 163, 165, 200, 201}  # playpause, next, prev, play, pause

AUDIO_SH = "/opt/muos/script/device/audio.sh"


def find_usb_input_event():
    """Event node of the first input device that lives on the USB bus."""
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except OSError:
        return None
    for b in blocks:
        if "Sysfs=" in b and ("usb" in b.split("Sysfs=")[1].split("\n")[0]):
            m = re.search(r"Handlers=.*?(event\d+)", b)
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
        if code == KEY_VOLUMEUP:
            subprocess.run([AUDIO_SH, "U"], capture_output=True, timeout=10)
        elif code == KEY_VOLUMEDOWN:
            subprocess.run([AUDIO_SH, "D"], capture_output=True, timeout=10)
        elif code in PLAY_KEYS and val == 1:
            ra_pause()


if __name__ == "__main__":
    main()
