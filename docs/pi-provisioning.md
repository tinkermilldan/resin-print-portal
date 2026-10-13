# Provisioning a printer's Pi

Turning a blank SD card into a working printer Pi is one command on your
workstation, then booting the Pi and clicking **Approve** in the portal.
Nothing is configured on the Pi itself, ever.

```text
 provision-sd.sh          first boot (unattended)               admin
┌──────────────┐   ┌──────────────────────────────────┐   ┌───────────┐
│ flash OS     │   │ cloud-init: hostname, user, SSH, │   │ Printers →│
│ write cloud- │──▶│   Wi-Fi                          │──▶│ Pending → │
│  init config │   │ provision-boot.sh: USB drive,    │   │ Approve   │
│ stage agent  │   │   UART, pi-agent  → reboot       │   └───────────┘
└──────────────┘   │ pi-agent registers with portal   │
                   └──────────────────────────────────┘
```

## Requirements

**Hardware** — a Pi Zero W wired up as described in [hardware.md](hardware.md),
and an SD card of 8 GB or more. The fob reader must be wired before first boot.
The agent won't start without it.

**On the workstation** (Linux; `make deps` checks all of this):

- `sudo`. Writing a raw block device requires root.
- `xz` or `zstd`, whichever matches your OS image's compression.
- `lsblk`, `findmnt` (util-linux), `partprobe` (parted), `udevadm` (udev).
- Go, to build the agent.

**An OS image** — **Raspberry Pi OS Lite (32-bit), Trixie**, downloaded from
[raspberrypi.com/software/operating-systems](https://www.raspberrypi.com/software/operating-systems/)
as a `.img.xz`. It must be the 32-bit Lite build: the Zero W is ARMv6, and
the desktop and 64-bit images won't boot on it. Older releases (Bookworm and
earlier) don't provision correctly, because the script relies on Trixie's
cloud-init.

**On site:**

- The Wi-Fi network's name and password. The Zero W's radio is **2.4 GHz
  only**, so the network must offer 2.4 GHz.
- A network path from that Wi-Fi to the portal at `CENTRAL_URL`.

## One-time setup

Build the agent and record the portal's address. Every card gets the same
values.

```bash
make pi-agent                                        # -> bin/pi-agent-armv6
cp provisioning/fleet.env.example provisioning/fleet.env
$EDITOR provisioning/fleet.env
```

```bash
# provisioning/fleet.env  (gitignored)
CENTRAL_URL=https://portal.tinkermill.org   # scheme required
ENROLL_TOKEN=                               # only if the portal requires one
```

Rebuild with `make pi-agent` whenever you want new cards to ship a newer agent.
You don't strictly have to: once approved, a Pi updates itself to the portal's
build anyway (see [deployment.md](deployment.md#updating-the-pi-fleet)).

## Flashing a card

Insert the card and identify it. You want the **whole disk** (`/dev/sdb`,
`/dev/mmcblk0`), not a partition (`/dev/sdb1`):

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT
```

Then flash and provision in one step:

```bash
sudo ./provisioning/provision-sd.sh \
  --device /dev/sdb \
  --image ~/Downloads/2026-xx-xx-raspios-trixie-armhf-lite.img.xz \
  --hostname resin2 \
  --password '<login password for the Pi>' \
  --wifi-ssid '<site Wi-Fi>' --wifi-password '<Wi-Fi password>'
```

The script shows the device's size and model and makes you type the device
path back before it writes anything. When it says the card is safe to remove,
it's done.

### Options

| Option | Default | Notes |
|---|---|---|
| `--device <disk>` | — | Flash this card, then provision it. Requires `--image` and `sudo`. |
| `--image <file>` | — | `.img`, `.img.xz`, or `.img.zst` |
| `--boot <dir>` | — | Instead of `--device`: provision an **already-flashed** card through its mounted boot partition (e.g. one written with Raspberry Pi Imager). No root needed. |
| `--hostname <name>` | **required** | Becomes the printer's slug in the portal. One per printer; keep it short (`resin2`, `resin-saturn`). |
| `--password <pw>` | **required** | Login and `sudo` password for the Pi's user |
| `--wifi-ssid`, `--wifi-password` | **required** | Site Wi-Fi (WPA-PSK) |
| `--wifi-country <cc>` | `US` | Wi-Fi regulatory domain |
| `--user <name>` | `captain` | Login user |
| `--central-url <url>` | from `fleet.env` | Override for this card only, e.g. to point a test Pi at your workstation |
| `--enroll-token <tok>` | from `fleet.env` | Override for this card only |
| `--yes` | off | Skip the type-the-device-to-confirm prompt. For scripted use only. |

### Safety checks

`--device` mode erases the whole target, so the script refuses to run if:

- the device backs this machine's `/`, `/boot`, `/boot/firmware`, or `/home`;
- the device is larger than 128 GB (no card in this fleet is);
- `CENTRAL_URL` has no `http://` or `https://` (the most common `fleet.env`
  mistake, and otherwise only visible after the Pi boots);
- `bin/pi-agent-armv6` hasn't been built.

## First boot

Put the card in the Pi, connect the Pi to the printer through the **USB**
port, and switch the printer on. Leave it alone for about five minutes. The
Pi reboots once on its own along the way.

1. **cloud-init** sets the hostname, creates the user, enables SSH, and joins
   the Wi-Fi.
2. **`provision-boot.sh`** runs once:
   - enables the UART for the fob reader (`enable_uart=1`,
     `dtoverlay=disable-bt`) and USB device mode (`dtoverlay=dwc2,dr_mode=peripheral`);
   - creates the 1 GiB drive image `/piusb.bin` and the `piusb-gadget`
     service that presents it to the printer on every boot;
   - installs the agent (`/usr/local/bin/pi-agent`, `resin-pi-agent.service`,
     and `/etc/resin-pi-agent.env` holding your `CENTRAL_URL`);
   - disables Bluetooth and a couple of unneeded services, and makes the
     journal persistent;
   - reboots.
3. On the second boot the **agent** starts, registers with the portal, and
   waits for approval.

The printer shows a USB drive (`RESINUSB`) once the second boot is done.

## Approving it

In the admin UI, **Printers → Pending approval** lists the new Pi under its
hostname. Click **Approve**. That's the only security gate. Until then the
portal refuses everything from that Pi.

Then, for that printer:

- **Edit** it to set the printer **model** (enables the "this file was sliced
  for a different machine" warning), **allowed file extensions**, the safety
  checklist, and an optional Slack webhook. The defaults accept any file
  with the standard checklist.
- **Certifications** — certify the members who may use it. **Certify by tap**
  is the fastest way: arm it, and the next fob tapped on that Pi is certified.

Members can now upload at `/upload` on the portal and tap their fob at the
printer to load the print.

## Checking it

```bash
ssh captain@resin2.lan                     # or the IP from your router
systemctl status resin-pi-agent piusb-gadget
journalctl -u resin-pi-agent -f            # then tap a fob
```

A healthy agent logs `pi-agent starting`, `enrolled` (first boot only), and
`fob reader ready`, then one `fob tap` line per tap.
Every tap also appears in the portal's admin **Log**, which is the
authoritative record. The Pi keeps none.

## Troubleshooting

You can read the provisioning progress without the Pi on the network: put the
card in your workstation and open `boot-progress.log` on its boot partition. It
records `provision-boot-started` → `gadget-configured` → `pi-agent-installed`
→ `provision-boot-finished`. The full log is `/var/log/provision-boot.log` on
the root partition, next to `/var/log/cloud-init-output.log`.

| Symptom | Likely cause |
|---|---|
| Never joins Wi-Fi; no SSH | Wrong SSID or password, a 5 GHz-only network, or the wrong `--wifi-country`. Check `cloud-init-output.log` on the card. |
| Agent exits: `CENTRAL_BASE_URL … is missing an http:// or https:// scheme` | `fleet.env` has a bare host or IP. Fix it and reflash. |
| Agent exits: `RDM6300 fob reader won't start` | Reader wiring or power. Run `sudo pi-agent -probe` ([hardware.md](hardware.md#checking-the-reader)). |
| Agent logs `enrollment attempt failed` repeatedly | The Pi can't reach the portal (try `curl <CENTRAL_URL>/healthz` from the Pi), or `ENROLL_TOKEN` doesn't match the portal's. |
| Pi never shows under **Pending approval** | Same as above. Also check the portal hasn't hit its cap on pending printers; approve or reject some. |
| Tap shows in the Log as `unknown_fob` | The fob's code isn't on the TinkerAccess roster, or the roster hasn't synced yet. The Log shows the code it saw (`fob:…`). |
| Printer doesn't see a drive | The cable is in the **PWR** port or is charge-only. Check `systemctl status piusb-gadget` on the Pi. |

**Fix it in the repo, then reflash.** If bring-up goes wrong, find the cause,
fix it here (in the scripts, `fleet.env`, or the wiring), and flash a fresh
card. Don't hand-patch a running Pi. A hand-fixed Pi no longer matches what
this repo produces, and the fix is lost the next time anyone reflashes it.
Looking around on the Pi to diagnose (logs, `-probe`) is fine; changes go
through the repo.

## Reflashing and replacing

- **Reflashing the same Pi** keeps its place in the portal. It re-registers
  under its hardware serial number, gets a fresh API key, and keeps its
  approval, settings, and certifications. Nothing to click.
- **A different Pi** (even with the same card or hostname) registers as a new
  printer under **Pending approval**. Disable or delete the old one under
  **Printers**.

## Without `--device`

If you'd rather flash the card yourself (Raspberry Pi Imager, `dd`), do that
with the same Trixie Lite image and *no* Imager customisation, mount the
card's boot partition, and run:

```bash
./provisioning/provision-sd.sh --boot /media/$USER/bootfs \
  --hostname resin2 --password '…' --wifi-ssid '…' --wifi-password '…'
```

Everything from [First boot](#first-boot) onward is identical.

## Updating an existing Pi's agent by hand

Approved Pis update themselves from the portal, so normally you never do this.
For a Pi that can't reach the portal, see
[deployment.md](deployment.md#out-of-band-updates).
