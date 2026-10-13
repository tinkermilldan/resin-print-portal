# Deployment guide

Production has two halves:

- **The portal** — one container image, deployed to Kubernetes with the Helm
  chart in `deploy/helm/resin-portal`. It runs the API and admin UI, the
  TinkerAccess roster sync, and a Postgres database.
- **The Pis** — one per printer, provisioned from an SD card
  ([pi-provisioning.md](pi-provisioning.md)) and from then on updated by the
  portal itself. The agent binary ships *inside* the portal image.

## Building a release image

Tag the commit, then build and push:

```bash
git tag v0.4.0
make docker IMAGE=ghcr.io/dangerweenie/resin-portal TAG=v0.4.0
docker push ghcr.io/dangerweenie/resin-portal:v0.4.0
```

The image (`build/Dockerfile`) contains:

| Path | What |
|---|---|
| `/portal` | The portal binary. The container's args pick `server`, `worker`, or `migrate`. |
| `/agent/pi-agent-armv6` | The Pi agent built from the same commit, served to Pis for self-update |

Both carry the version from `git describe` (`v0.4.0`, or
`v0.4.0-3-gabc1234-dirty` for an untagged or modified tree). Build releases
from a clean, tagged tree so the version the fleet reports means something.

The portal binary is built for the architecture of the machine running
`docker build`. The agent is always cross-compiled for ARMv6.

## Installing the portal

### What you need

- A Kubernetes cluster you can `helm install` into, with a default
  StorageClass (the bundled Postgres claims a 10 Gi volume).
- An ingress controller and a hostname, if the portal should be reachable
  outside the cluster. It must be, at least from the printers' Wi-Fi.
- Network reachability from the cluster to TinkerAccess, for the roster sync.
- The image pushed somewhere the cluster can pull from.

### Values

Keep your settings in a values file outside the repo. It holds secrets.

```yaml
# portal-values.yaml
image:
  tag: v0.4.0

app:
  adminPassword: "<initial admin password>"
  sessionSecret: "<output of: openssl rand -base64 48>"
  statusApiKey: ""        # set to enable GET /api/v1/status
  enrollToken: ""         # set if the portal is reachable from the internet

postgresql:
  auth:
    password: "<database password>"

tinkerAccess:
  baseURL: "http://tinker-access.default.svc.cluster.local:3000"
  getUsersPath: "/api/get_users<hash>"   # see reference/tinkeraccess-get-users.md

ingress:
  enabled: true
  className: nginx
  host: portal.tinkermill.org
  tls: true
  tlsSecretName: portal-tls
```

`values.yaml` in the chart documents every option. The ones that matter in
production:

- **`app.sessionSecret`** — set it. If you leave it blank, a random one is
  generated, and regenerated on every upgrade, logging every admin out.
- **`postgresql.auth.password`** — change it from the placeholder.
- **`app.enrollToken`** — set it if the portal is on the public internet; it
  must match `ENROLL_TOKEN` in `provisioning/fleet.env`. See
  [configuration.md](configuration.md#enrollment).
- **`existingSecret`** — supply your own Secret (keys `DATABASE_URL`,
  `SESSION_SECRET`, `ADMIN_PASSWORD`, `STATUS_API_KEY`, `ENROLL_TOKEN`)
  instead of putting secrets in values.
- **`postgresql.enabled: false`** + **`externalDatabase.dsn`** — use a
  database you already run instead of the bundled one.

### Install

```bash
make helm-deps      # fetch the Bitnami postgresql subchart
helm install portal deploy/helm/resin-portal \
  --namespace resin-portal --create-namespace \
  -f portal-values.yaml
```

That creates:

| Object | Notes |
|---|---|
| `server` Deployment (2 replicas) | API, admin UI, `/upload`. Stateless, so scale freely. Probes: `/healthz`, `/readyz`. |
| `worker` Deployment (1 replica) | Roster sync. **Keep it at one replica.** |
| `migrate` Job | Runs `portal migrate up` after install and before every upgrade |
| Secret, ConfigMap | Configuration; see [configuration.md](configuration.md) |
| Service, Ingress | Ingress only if enabled |
| Postgres StatefulSet + PVC | Unless you disabled the bundled database |

The install notes printed by Helm repeat the next steps with your real names
filled in.

### First login

Open `https://<host>/admin/login` (or `kubectl port-forward svc/portal-resin-portal 8080:80`
without an ingress) and sign in as `captain` with `app.adminPassword`. Change
the password under **Settings**. The seed password is only used to create the
first admin, so changing the value later does nothing.

### Connecting TinkerAccess

Watch the worker's first sync:

```bash
kubectl -n resin-portal logs -l app.kubernetes.io/component=worker -f
```

`roster synced received=N` means members are flowing in, and they appear under
**Members**. A 404 means the `get_users` path is stale: TinkerAccess's path
carries a build hash that changes whenever TinkerAccess is redeployed.
[reference/tinkeraccess-get-users.md](reference/tinkeraccess-get-users.md)
explains how to recover it. Update `tinkerAccess.getUsersPath` and upgrade.

Members are matched to fobs by the `code` field TinkerAccess holds. Nothing
needs linking by hand. A member whose status goes inactive, or who drops off
the roster, is denied at the printer from the next sync on.

## Upgrading

```bash
make docker IMAGE=ghcr.io/dangerweenie/resin-portal TAG=v0.5.0
docker push ghcr.io/dangerweenie/resin-portal:v0.5.0
helm upgrade portal deploy/helm/resin-portal -n resin-portal \
  -f portal-values.yaml --set image.tag=v0.5.0
```

Migrations run before the new pods roll out. The Pis then follow on their own,
if you've enabled that. See the next section.

## Updating the Pi fleet

Each Pi reports its agent version on every request, and the **Printers** page
shows it, with a *behind* badge for any Pi not on the portal's build. Updates
happen in place: the Pi downloads the binary from the portal, verifies its
SHA-256, swaps it in, and restarts. A Pi never updates in the middle of a
print.

| Setting / control | Effect |
|---|---|
| `agentUpdate.auto: true` | Every Pi converges to the portal's build within about 5 minutes of an upgrade. Deploy the portal and the fleet follows. |
| `agentUpdate.auto: false` (default) | Nothing updates on its own |
| `agentUpdate.targetVersion` | Pin the fleet to a specific version instead of the portal's own |
| **Update now** (per Pi) | Update this Pi now, whatever the global setting |
| **Hold** (per Pi) | Freeze this Pi on its current version |
| **Resume updates** / **Unpin** | Clear a hold or a per-Pi pin |

If a new build crash-loops (5 starts within 10 minutes), the Pi rolls back to
the previous binary on its own. After 3 failed attempts at the same version it
stops trying and stays *behind* for someone to look at.

### Out-of-band updates

For a Pi that can't reach the portal, push the agent over SSH:

```bash
make pi-agent
scp bin/pi-agent-armv6 usb-refresh.sh pi/agent-guard.sh captain@<pi>.lan:~/
ssh captain@<pi>.lan '
  sudo install -m0755 ~/pi-agent-armv6  /usr/local/bin/pi-agent &&
  sudo install -m0755 ~/usb-refresh.sh  /usr/local/bin/usb-refresh.sh &&
  sudo install -m0755 ~/agent-guard.sh  /usr/local/bin/agent-guard.sh &&
  sudo systemctl restart resin-pi-agent'
```

Anything beyond replacing the binary (config, services, the drive image) is
a reflash, not a hand edit. See [pi-provisioning.md](pi-provisioning.md#troubleshooting).

## Operating

| Task | How |
|---|---|
| Health | `GET /healthz` (process up), `GET /readyz` (database reachable) |
| Logs | `kubectl -n resin-portal logs -l app.kubernetes.io/component=server` (or `worker`, `migrate`). JSON lines. |
| Who tapped / uploaded what | Admin **Log**: every check, claim, and upload decision, with its reason |
| A job stuck as *printing* | Admin **Jobs → Force clear** |
| Status for other tools | `GET /api/v1/status` with `Authorization: Bearer <statusApiKey>` |
| Rotate a Pi's key | **Printers → Rotate key**. A self-registered Pi re-registers on its own within a couple of minutes. |
| Retire a Pi | **Printers → Disable**, or delete it |

### Backups

Postgres is the only state. Members, printers, certifications, jobs, the audit
log, and staged uploads all live there. The Pis hold nothing that can't be
recreated by reflashing. Back up the database:

```bash
kubectl -n resin-portal exec portal-postgresql-0 -- \
  sh -c 'PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" pg_dump -U portal portal' \
  > portal-$(date +%F).sql
```
