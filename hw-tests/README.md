# On-hardware tests

The Go test suites (`make test`, `make test-integration`) need no Pi. The tests
here do: a real Pi running the agent and the real USB gadget, talking to a
reachable portal. They're run by hand, never in CI.

## How they run

Every script runs **on your workstation** and drives the Pi over SSH. Nothing
is installed on the Pi for testing, so the system under test stays exactly
as provisioning built it:

- Fixture building (FAT32 and MBR images, a synthetic `.goo`) and HTTP calls
  happen locally. Workstation tools: `ssh`, `scp`, `curl`, `sha256sum`,
  `python3`, plus `mkdosfs`, `parted`, and `losetup` for Layer 1, which asks
  for your local `sudo` password. `make deps` checks most of these.
- On the Pi, scripts only use what production already depends on: `losetup`,
  `mount`, `modprobe`, `dd`, `sha256sum`, `systemctl`. If a preflight check
  fails on the Pi, that's a provisioning bug. Fix it in `provisioning/` and
  reflash, don't `apt install` around it.

## The test rig: `resin1`

Point these scripts only at `resin1`, a Pi provisioned specifically for
testing. Never use `resin` or any Pi in service. The scripts cycle the USB
drive repeatedly and create real job and audit-log rows. Each one asks the
Pi for its hostname and makes you type it back before doing anything.

Build it like any other Pi ([docs/pi-provisioning.md](../docs/pi-provisioning.md)):

```bash
sudo ./provisioning/provision-sd.sh --device /dev/sdX \
  --image ~/Downloads/<raspios-trixie-armhf-lite>.img.xz \
  --hostname resin1 --password '<password>' \
  --wifi-ssid '<site Wi-Fi>' --wifi-password '<Wi-Fi password>'
```

To test against a portal on your workstation instead of production, add
`--central-url http://<your-LAN-IP>:8080` (see
[docs/development.md](../docs/development.md#testing-against-a-real-pi)).

Then, once, in that portal:

1. **Approve** `resin1` under **Printers → Pending approval**. Its slug is
   `resin1`.
2. **Certify** a test member for it, one whose fob you have and who's on the
   roster (or on `fake-tinkeraccess`'s roster, locally).
3. Note `resin1`'s API key, which Layer 2 needs for its portal-side checks.
   The Pi holds it:
   `ssh captain@resin1.lan sudo cat /var/lib/resin-pi-agent/creds.env`.
   Don't use **Rotate key** for this; that would invalidate the Pi's copy.

Plug `resin1` into whichever printer is free. The Elegoo Saturn 3 is the best
default for frequent runs, since it tolerates rapid disconnect and reconnect.
Re-run the manual checklist against the M7 Pro periodically.

## Authentication

Each script opens one multiplexed SSH connection for the whole run (one login
prompt) and pipes the `sudo` password over `sudo -S` for anything that needs
root. `lib/remote.sh` asks for it once up front. The Pi's login and `sudo`
passwords are the same, both set by `--password` at provisioning.

## The four layers

| Layer | What | Printer needed? | Script |
|---|---|---|---|
| 1 | `usb-refresh.sh`'s load and clear contract against the real gadget, using throwaway images built locally | No | `test-usb-refresh-against-pi.sh` |
| 2 | The member flow end to end: upload to the portal → fob tap → file on the drive, byte-checked → finish → drive cleared | No (checked by mounting the image) | `test-full-flow-against-pi.sh` |
| 3 | The agent service crashing and being restarted by systemd, with the USB drive unaffected | No | `test-service-resilience-against-pi.sh` |
| 4 | Anything that needs eyes on a printer screen or a physical power cut or replug | **Yes** | [`MANUAL-CHECKLIST.md`](MANUAL-CHECKLIST.md) |

Run 1 → 2 → 3 (a few minutes total). Run Layer 4 after any change to the
gadget, `usb-refresh.sh`, or the job lifecycle, and periodically regardless.

### Layer 1 — `test-usb-refresh-against-pi.sh`

Re-validates `usb-refresh.sh` against the real kernel driver: bare-FAT32 and
MBR-partitioned images, the guarantee that a failed mount never leaves the
printer without a drive, and `--clear`.

```bash
bash hw-tests/test-usb-refresh-against-pi.sh --host resin1.lan --yes
```

Set `SCRIPT_UNDER_TEST=<path>` to test a working-tree `usb-refresh.sh` instead
of the one installed on the Pi.

### Layer 2 — `test-full-flow-against-pi.sh`

The direct answer to "does a member's file actually reach the printer, and
actually leave when they're done":

1. checks the Pi's page responds and the portal knows the printer;
2. builds a small synthetic `.goo` (valid header, non-zero print time);
3. uploads it through the portal's `/upload` as the test member;
4. asks you to **tap the test member's fob** on `resin1`, then waits for the Pi
   to report the file loaded;
5. checks the portal shows the job printing, with an exact ETA;
6. unloads the real drive image over SSH, mounts it, and checks it holds
   exactly that file, byte for byte;
7. marks the job finished and checks the drive is cleared.

```bash
bash hw-tests/test-full-flow-against-pi.sh \
  --host resin1.lan --central https://portal.tinkermill.org \
  --slug resin1 --api-key <resin1's key> --slack-name 'Test Member' --yes
```

`--slack-name` is whatever the member types on the upload page: their linked
Slack name, or their full name exactly as TinkerAccess has it. The run leaves
one finished job and its audit-log entries under the test member. That's
expected.

### Layer 3 — `test-service-resilience-against-pi.sh`

Kills the agent with `SIGKILL`, confirms systemd (`Restart=always`) brings it
back and its page answers again, and confirms the **USB drive never drops**:
the printer keeps its file whether or not the agent or the portal is up. This
doesn't reboot the Pi; Layer 4 covers that.

```bash
bash hw-tests/test-service-resilience-against-pi.sh --host resin1.lan --yes
```

### Layer 4 — `MANUAL-CHECKLIST.md`

Per-printer screen checks, a full print to completion, reboot and power-cut
recovery, physical replug, and filename edge cases.

## Before running anything

- Run from a normal, non-root shell. Only Layer 1's image building needs
  local root, and it asks.
- Layers 1 and 2 disconnect and reconnect the Pi's USB drive several times.
  Never run them during a print anyone cares about.
- Layer 1 keeps scratch images in `~/hw-test-scratch` on the Pi (real disk;
  the Pi's `/tmp` is a small tmpfs) and removes them on exit, including on
  failure or Ctrl-C.
- Every script takes `--host` (default `resin1.lan`) and `--user` (default
  `captain`).
