# OCI IPsec container (strongSwan CPE side)

A strongSwan container that brings up your site-to-site IPsec tunnel to Oracle
Cloud, driven entirely by environment variables in `docker-compose.yml`.

It has two modes, set by `MODE`:

- **`managed`** — the container watches this host's public IP and, whenever it
  changes, recreates the OCI CPE + IPSec connection, reads back the new Oracle
  headend IPs and shared secrets, reloads the tunnel, and deletes the stale OCI
  resources. This is the "grab my IP and rebuild the tunnel automatically"
  behaviour. Needs the OCI account linked.
- **`static`** — a fixed tunnel built from an IP/PSK you paste in. Simple, but
  you update it by hand when your IP changes.

## How managed mode works

OCI is the source of truth. Because OCI makes both the CPE's IP *and* the IPSec
connection's CPE reference immutable, correcting your IP means recreating those
resources. Each cycle the watcher:

1. Gets your real public IP (via Cloudflare's trace endpoint).
2. Asks OCI what IP the current managed CPE has, and compares.
3. If they differ (or nothing exists yet): creates a new CPE with the correct
   IP, creates a new IPSec connection to your DRG, waits for its two tunnels,
   reads back their Oracle headend IPs + shared secrets, reloads strongSwan,
   and deletes the previous CPE + IPSec connection.
4. If they already match: nothing to do (and on a fresh start it just loads the
   existing connection's tunnels into strongSwan).

It finds "its" resources by the `auto-cpe-…` / `auto-ipsec-…` display names it
gives them, so no local state file or volume is needed — a restart re-reads the
truth from OCI. Managed mode owns the resources it creates; if you have a CPE or
IPSec connection you built by hand, delete it so it doesn't sit alongside.

### Managed mode needs

- The **OCI account linked** (see "Linking your OCI account" below).
- `OCI_COMPARTMENT_ID` and `OCI_DRG_ID`.
- `LOCAL_SUBNET` (your on-prem CIDR — becomes the OCI static route),
  `VCN_SUBNET`, and `LOCAL_ID`.

The IAM user (or instance-principal dynamic group) must be allowed to manage
`cpes` and `ip-sec-connections` in the compartment.

## Static mode: what you need from OCI

From the OCI console, open your Site-to-Site VPN → IPSec connection → each tunnel:

- The tunnel **VPN IP** (Oracle headend public IP) — one per tunnel, up to two.
- The **shared secret (PSK)** for each tunnel.
- The **cpe-local-identifier** you set on the CPE object — put the same value in
  `LOCAL_ID`. An FQDN is recommended, and is effectively required when you're
  behind NAT.
- Your **VCN CIDR** (`VCN_SUBNET`) and your **on-prem CIDR** (`LOCAL_SUBNET`).

## Setup

Edit the values directly in the `environment:` block of `docker-compose.yml`,
then:

```bash
docker compose up -d --build
docker compose logs -f
```

After changing any value, apply it with `docker compose up -d` (recreates the
container with the new environment).

A healthy start ends with an ESTABLISHED IKE SA and an INSTALLED child SA in
the logs / in `swanctl --list-sas`.

## Verify

```bash
docker exec -it oci-ipsec swanctl --list-sas
# then, from a host on your LOCAL_SUBNET, ping something on the VCN_SUBNET
```

## Routing (the part outside the tunnel)

Bringing the tunnel up is only half of a site-to-site setup. On **bridge**
networking the "local" side of the tunnel is the Docker network, not your
physical LAN, so:

- **What reaches OCI:** the container itself, and any other container you
  attach to the `ipsecnet` network, can reach `VCN_SUBNET` through the tunnel.
  This is the natural fit for the OCI watcher and for app containers that need
  the VCN.
- **Traffic selectors:** set `LOCAL_SUBNET` to the `ipsecnet` subnet
  (`172.28.0.0/24` by default) and configure OCI's static route /
  encryption-domain to match it, so OCI knows to route that range back through
  the tunnel.
- **Other containers as clients:** a sibling container on `ipsecnet` reaches
  the VCN once it routes VCN traffic via this container
  (`ip route add <VCN_SUBNET> via <oci-ipsec container IP>`), since Docker's
  default gateway is the bridge, not this container.
- **Whole physical LAN:** routing your entire LAN through the tunnel is awkward
  on bridge (the container isn't on the LAN). If that's the goal later, host
  networking is the better fit; bridge is right when the clients are containers.
- **On OCI:** add a VCN route rule + security rules for `LOCAL_SUBNET`, and for
  a self-hosted A1 endpoint turn off source/dest check on the VNIC.

## Where this fits (managed OCI VPN vs self-hosted)

- **Self-hosted (A1):** run this container on an OCI compute VM that has a
  **reserved public IP**, configured as the responder for a dynamic peer. Your
  home IP can change freely and the tunnel just re-establishes. This container +
  a reserved-IP VM = the whole "set and forget" solution.
- **Managed OCI VPN (A2):** OCI pins the tunnel to the CPE object's IP, which
  **can't be edited after creation** — so when your home IP changes you must
  recreate the CPE + IPSec connection (via the OCI CLI) and feed the new PSKs
  back into this container's `.env`. This container makes the local side
  reproducible, but it can't remove that OCI-side step on its own.

## Troubleshooting

- **`no proposal chosen`** → your `IKE_PROPOSAL` / `ESP_PROPOSAL` don't match
  what the OCI tunnel is configured with. Line them up with the tunnel's
  parameters in the OCI console and restart.
- **Authy/PSK failures** → `PSK_x` or `LOCAL_ID` mismatch. `LOCAL_ID` must equal
  the CPE's `cpe-local-identifier` exactly.
- **Tunnel up but no traffic** → routing/forwarding issue, see the Routing
  section, not IKE. Check the VCN route table and security rules first.
- **`could not set ip_forward`** → run with the compose file as-is (it sets the
  sysctl and NET_ADMIN); on some hosts you may need `privileged: true`.

## Configuration

All VPN settings are environment variables in the `environment:` block of
`docker-compose.yml` — there is no `.env` file. Everything about the tunnel
(subnets, PSKs, IKE identity, crypto proposals, DPD/rekey timers, log level)
is editable there.

Docker-level settings (`networks`, `cap_add`, `sysctls`) are
*not* environment variables — they configure Docker itself, not the process
inside the container, so they stay as compose keys in the same file. This
setup uses **bridge** networking: the container sits on the `ipsecnet` bridge
(subnet `172.28.0.0/24`) behind Docker's NAT, and the tunnel gets through that
NAT via NAT-T (`ENCAP: "yes"`). Because the container initiates the tunnel, no
inbound ports need publishing.

## Linking your OCI account (optional)

Only needed if you want the container to call the OCI API (e.g. the A2 watcher
that recreates the CPE when your IP changes). The tunnel itself does **not**
need this.

You can't fully automate the link — one step happens once in your browser,
because it authorises access to your tenancy. After that, the container links
itself on startup from the `environment:` block. Pick one:

- **Option A — instance principal (simplest, no keys).** Use this when the
  container runs on an OCI compute VM. Set `OCI_CLI_AUTH: "instance_principal"`.
  One-time browser step: create a Dynamic Group that matches the instance and a
  policy granting it the VPN permissions. No keys, nothing to rotate.
- **Option B — API key.** Use this when the container runs off-OCI (e.g. your
  home box). One-time browser step: add an API key to your user (Profile →
  User settings → API keys → Add API key). Then paste `OCI_CLI_USER`,
  `OCI_CLI_TENANCY`, `OCI_CLI_FINGERPRINT`, `OCI_CLI_REGION`, and the private
  key into `OCI_KEY_CONTENT` (as a YAML block scalar).

On startup the container runs `oci iam region list` and prints `account link
OK` in the logs if it worked. If you provide no OCI variables, it prints
`tunnel-only mode` and just runs the VPN.

Keep the private key out of any git repo — anyone with it can act as you.

## Putting this on GitHub (and GHCR)

**Keep secrets out of git.** Your real values (OCI key, OCIDs, any PSKs) must
not be committed. The committed `docker-compose.yml` holds only placeholders;
put real values in `docker-compose.override.yml`, which `.gitignore` excludes
and Compose merges automatically:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# edit it with your real values, then:
docker compose up -d
```

**Publish the image to GHCR.** The included workflow
(`.github/workflows/docker-publish.yml`) builds and pushes to
`ghcr.io/<owner>/<repo>` on every push to `main` and on `v*` tags — no extra
secrets needed, it uses the built-in `GITHUB_TOKEN`. After the first run, make
the package public (or authenticate to pull it) under your repo's Packages tab.

**Run the published image** instead of building locally: in your
`docker-compose.override.yml`, set
`image: ghcr.io/<owner>/<repo>:latest`, then:

```bash
docker compose pull && docker compose up -d
```

## Files

- `Dockerfile` – strongSwan (swanctl backend) on Debian slim.
- `entrypoint.sh` – renders `swanctl.conf` and `strongswan.conf` from the
  environment, starts charon, loads and initiates the tunnels.
- `docker-compose.yml` – all VPN settings (env vars) plus the Docker-level
  keys (host networking, `NET_ADMIN`, IP forwarding).
