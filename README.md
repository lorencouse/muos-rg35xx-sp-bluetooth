# Bluetooth audio for the Anbernic RG35XX SP on muOS

Bluetooth headphones on the RG35XX SP running [muOS](https://muos.dev) — with a
full-screen manager app for pairing, connecting, switching audio output, and
auto-reconnect at boot.

![Main screen](docs/img/main-screen.png)

## Why this exists

muOS already ships **everything** Bluetooth audio needs on this device — BlueZ,
`rtk_hciattach`, the RTL8821C firmware, PipeWire's bluez5 plugin and codecs —
but disables Bluetooth for the `rg35xx-sp` device profile and never attaches
the adapter, so none of it is reachable. Toggling *Has Bluetooth* in the muOS
settings only reveals a menu entry; there is still no radio behind it and no
management UI at all (muOS 2601 has five screens for Wi-Fi and zero for
Bluetooth).

The actual fix is three commands muOS never runs:

```sh
insmod /lib/modules/4.9.170/kernel/drivers/bluetooth/rtl_btlpm.ko
rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5
bluetoothd
```

This project wraps that bringup in a boot hook and adds the missing UI.

## What you get

**Applications → Bluetooth** — a full-screen manager:

- **Pair new device** — live scan, filtered to audio devices (no more pairing
  your neighbour's garage door opener), one press to pair + connect + route audio
- **Device list** with live status: connected, battery % (when the device
  reports it), auto-connect tag
- **Y** — instantly switch audio between the speaker and your headphones
- Per-device **auto-connect at boot** toggle, **disconnect**, **forget**
- Multi-device registry — keep headphones, earbuds and a speaker side by side

![Pair screen](docs/img/pair-screen.png)

Plus a boot hook that brings the adapter up on every boot and reconnects your
last-used auto-connect device, so sound is already in your ears by the time
you're at the launcher.

## Install

1. Power off the device and put its SD1 card in your computer
   (or use the muOS USB/SFTP file transfer — everything lives on the exfat
   partition your computer can see).
2. Copy the `MUOS` folder from this repo onto the root of the card, merging
   with the existing `MUOS` folder. Nothing is overwritten; it only adds:
   ```
   MUOS/application/Bluetooth/   the manager app
   MUOS/bluetooth/bt-common.sh   shared bringup helpers
   MUOS/init/10-bluetooth.sh     boot hook
   ```
3. Boot the device and enable **Configuration → Advanced Settings →
   User Init Scripts** so the boot hook runs.
4. Reboot, then open **Applications → Bluetooth** and pair your headphones.

Everything lives on the SD card's exfat partition, so muOS updates won't
remove it. Log file: `MUOS/log/bluetooth.log`. To uninstall, delete the three
paths above (and `MUOS/bluetooth/state/`).

## Tested on

- Anbernic **RG35XX SP**, muOS **2601.0 Jacaranda**

Other H700 Anbernic boards muOS supports (RG35XX Plus / 2024 / RG34XX / RG40XX
/ CubeXX) use the same RTL8821CS combo chip and may work unchanged — untested.
Reports welcome.

## Limitations

- **SBC/Opus codecs only** (whatever PipeWire ships) — no AAC/aptX/LDAC.
  Fine for games, adequate for music.
- Some devices (AirPods included) don't report battery over standard Bluetooth
  profiles; battery shows only when available.
- **USB-C headphones are a kernel problem, not a config problem** — muOS's
  kernel is built without `CONFIG_SND_USB_AUDIO` and ships no sound modules,
  so no userspace work can enable them.

## How it works

- `MUOS/init/10-bluetooth.sh` runs via muOS's user-init hook: loads
  `rtl_btlpm.ko`, attaches the RTL8821CS HCI on `/dev/ttyS1` with
  `rtk_hciattach`, starts `bluetoothd`, then auto-connects the most recently
  used device marked `auto` in the registry and makes it the default PipeWire
  sink.
- The app (`bt-ui.py`) is a Python TUI rendered inside `muterm` (muOS's
  built-in virtual terminal). Gamepad input is read straight from the evdev
  node, so it works regardless of what the terminal forwards.
- Audio routing resolves PipeWire sinks by `node.name`, never by label —
  the SP exposes two sinks both labelled "Built-in Audio Stereo" (speaker and
  HDMI), and Bluetooth sink ids change on every reconnect.
- Device registry: `MUOS/bluetooth/state/devices.json`.

## Credits

This builds on prior work by others:

- **[donfreiday/rgxx35sp-bluetooth](https://github.com/donfreiday/rgxx35sp-bluetooth)** —
  first documented the RTL8821CS bringup on the RG35XX SP (`rtk_hciattach` on
  `/dev/ttyS1`) and the wpctl audio routing approach this project uses.
- **[nvcuong1312/bltMuos](https://github.com/nvcuong1312/bltMuos)** — earlier
  Bluetooth support for muOS (Pixie/Goose/Banana releases), which proved the
  demand and the approach on this hardware family.
- **[MustardOS](https://github.com/MustardOS)** — muOS itself ships the entire
  Bluetooth stack this project switches on; `muterm` makes the UI possible.

## License

MIT — see [LICENSE](LICENSE).
