# Configuration reference

Every binary is configured through environment variables only. Kubernetes sets
them from the Helm chart; on the Pi, systemd reads them from
`/etc/resin-pi-agent.env`. Nothing else reads config files.

## Portal (`portal server`, `portal worker`, `portal migrate`)

The same binary runs all three roles, and each one validates only the
variables it uses.

| Variable | Used by | Default | Helm value | Notes |
|---|---|---|---|---|
| `DATABASE_URL` | all | — **required** | built from `postgresql.*`, or `externalDatabase.dsn` | pgx/libpq DSN |
| `LOG_LEVEL` | all | `info` | `app.logLevel` | `debug` · `info` · `warn` · `error` |
| `LISTEN_ADDR` | server | `:8080` | fixed at `:8080` | |
| `SESSION_SECRET` | server | — **required** | `app.sessionSecret` | ≥ 32 bytes. Signs admin session cookies. Changing it logs every admin out. |
| `ADMIN_USERNAME` | server | `captain` | `app.adminUsername` | Seed admin account. Only used when the admins table is empty. |
| `ADMIN_PASSWORD` | server | — | `app.adminPassword` | Seed admin password. Same rule: only used when the table is empty. |
| `STATUS_API_KEY` | server | blank (endpoint off) | `app.statusApiKey` | Bearer key for `GET /api/v1/status` (read-only org-wide job status). |
| `ENROLL_TOKEN` | server | blank (open) | `app.enrollToken` | If set, a Pi must present it to self-register. See [Enrollment](#enrollment). |
| `AGENT_AUTO_UPDATE` | server | `false` | `agentUpdate.auto` | Move every non-held Pi to the target agent build automatically. |
| `AGENT_TARGET_VERSION` | server | blank | `agentUpdate.targetVersion` | Pin the fleet to a version string. Blank means the portal's own build. |
| `AGENT_BINARY_PATH` | server | `/agent/pi-agent-armv6` | `agentUpdate.binaryPath` | The pi-agent binary bundled in the image, served to Pis for updates. |
| `TINKERACCESS_BASE_URL` | worker | — **required** | `tinkerAccess.baseURL` | e.g. `http://tinker-access.default.svc.cluster.local:3000` |
| `TINKERACCESS_GET_USERS_PATH` | worker | — **required** | `tinkerAccess.getUsersPath` | Includes a build-hash suffix that changes on each TinkerAccess deploy. See [reference/tinkeraccess-get-users.md](reference/tinkeraccess-get-users.md). |
| `TINKERACCESS_WASM_PATH` | worker | blank | — | Optional: a local copy of the TinkerAccess wasm bundle, used to recover the path above automatically. |
| `SYNC_INTERVAL` | worker | `10m` | `sync.interval` | Go duration (`90s`, `10m`) or a bare number of seconds. |

The Helm chart puts the secrets (`DATABASE_URL`, `SESSION_SECRET`,
`ADMIN_PASSWORD`, `STATUS_API_KEY`, `ENROLL_TOKEN`) in a Secret and everything
else in a ConfigMap. Set `existingSecret` to supply your own Secret with those
five keys instead.

Per-printer settings (display name, model, allowed file extensions, safety
checklist, Slack webhook URL) live in the database and are edited in the admin
UI under **Printers**, not through environment variables.

## Pi agent (`/etc/resin-pi-agent.env`)

Provisioning writes this file. You should never need to edit it on a running
Pi. To change it, change `provisioning/fleet.env` and reflash.

| Variable | Default | Notes |
|---|---|---|
| `CENTRAL_BASE_URL` | — **required** | The portal's base URL, **including** `http://` or `https://`. The agent refuses to start without the scheme. |
| `ENROLL_TOKEN` | blank | Only if the portal requires one. |
| `PRINTER_SLUG`, `PRINTER_API_KEY` | blank | Manual override that skips self-enrollment. Leave unset on fleet Pis. |
| `CREDS_PATH` | `/var/lib/resin-pi-agent/creds.env` | Where the slug and API key from enrollment are stored. |
| `GADGET_IMAGE` | `/piusb.bin` | The emulated drive image. |
| `LISTEN_ADDR` | `:80` | The tap-status page on the makerspace LAN. |
| `USB_REFRESH_SCRIPT` | `/usr/local/bin/usb-refresh.sh` | Writes a file onto the drive image. |
| `LOG_LEVEL` | `info` | |

The serial device (`/dev/serial0`, 9600 baud) and the LED/buzzer pins are fixed
in code. See [hardware.md](hardware.md).

## Provisioning (`provisioning/fleet.env`)

Read by `provision-sd.sh` and baked into every card. Copy
`provisioning/fleet.env.example` to start. This file is gitignored.

| Variable | Notes |
|---|---|
| `CENTRAL_URL` | **Required.** Becomes the Pi's `CENTRAL_BASE_URL`. Must include `http://` or `https://`; the script checks. |
| `ENROLL_TOKEN` | Optional. Must match the portal's `ENROLL_TOKEN` if one is set. |

## Enrollment

A freshly flashed Pi calls `POST /api/v1/enroll` with its hardware ID and
hostname. The portal creates a printer row (slug = hostname) in the **Pending**
state and returns an API key, which the Pi stores in `CREDS_PATH`. Nothing
happens for that printer until an admin clicks **Approve**. That approval is
the security gate.

`ENROLL_TOKEN` adds a second gate: without it, anything that can reach the
portal can create a *pending* row (capped, so the list can't be flooded). Set
one if the portal is reachable from the public internet.

If the portal ever rejects a Pi's stored key (the printer was deleted, the key
was rotated, or the database was rebuilt), the Pi discards its credentials and
enrolls again on its own. It shows up under **Pending** again, waiting for
approval.
