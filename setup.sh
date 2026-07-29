#!/usr/bin/env bash
# Recreates the oci-ipsec-container project in the current directory.
# Paste this whole thing into your Codespace terminal and press Enter.
set -euo pipefail

cat > ".gitignore" <<'__OCI_FILE_00__'
# Secrets / local config — NEVER commit these
docker-compose.override.yml
.env
*.pem
.oci/
oci_api_key*

# misc
*.log
__OCI_FILE_00__

cat > "Dockerfile" <<'__OCI_FILE_01__'
FROM debian:bookworm-slim

# strongSwan (swanctl backend) + routing tools + OCI CLI + jq (for the watcher)
RUN apt-get update && apt-get install -y --no-install-recommends \
        strongswan \
        strongswan-swanctl \
        libcharon-extra-plugins \
        iproute2 \
        iptables \
        iputils-ping \
        ca-certificates \
        python3 \
        python3-venv \
        curl \
        jq \
    && rm -rf /var/lib/apt/lists/*

# OCI CLI in an isolated venv, exposed as /usr/local/bin/oci
RUN python3 -m venv /opt/oci \
    && /opt/oci/bin/pip install --no-cache-dir --upgrade pip oci-cli \
    && ln -s /opt/oci/bin/oci /usr/local/bin/oci

# strongswan.conf and ~/.oci/config are rendered at runtime by entrypoint.sh.
COPY entrypoint.sh /entrypoint.sh
COPY watcher.sh /watcher.sh
RUN chmod +x /entrypoint.sh /watcher.sh

ENTRYPOINT ["/entrypoint.sh"]
__OCI_FILE_01__

cat > "entrypoint.sh" <<'__OCI_FILE_02__'
#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# MODE selects behaviour:
#   static  (default) - you supply OCI_VPN_IP_1/PSK_1; the tunnel is fixed.
#   managed           - the watcher grabs your public IP and recreates the OCI
#                       CPE + IPSec connection whenever it changes.
#
# Always required: LOCAL_SUBNET, VCN_SUBNET, LOCAL_ID
# static  also needs: OCI_VPN_IP_1, PSK_1  (+ optional OCI_VPN_IP_2/PSK_2)
# managed also needs: OCI account link (see below) + OCI_COMPARTMENT_ID, OCI_DRG_ID
# ---------------------------------------------------------------------------

MODE="${MODE:-static}"

: "${LOCAL_SUBNET:?set LOCAL_SUBNET (your on-prem CIDR)}"
: "${VCN_SUBNET:?set VCN_SUBNET (OCI VCN CIDR)}"
: "${LOCAL_ID:?set LOCAL_ID (your CPE IKE identifier)}"

IKE_VERSION="${IKE_VERSION:-2}"
IKE_PROPOSAL="${IKE_PROPOSAL:-aes256-sha384-modp2048}"
ESP_PROPOSAL="${ESP_PROPOSAL:-aes256-sha256-modp2048}"
DPD_DELAY="${DPD_DELAY:-30s}"
DPD_ACTION="${DPD_ACTION:-restart}"
START_ACTION="${START_ACTION:-start}"
ENCAP="${ENCAP:-yes}"
IKE_REKEY_TIME="${IKE_REKEY_TIME:-8h}"
ESP_REKEY_TIME="${ESP_REKEY_TIME:-1h}"
LOG_LEVEL="${LOG_LEVEL:-1}"

# ----- Link the OCI account (required for managed mode, optional otherwise) --
OCI_LINKED=0
setup_oci_link() {
    if [[ "${OCI_CLI_AUTH:-}" == "instance_principal" ]]; then
        echo "[oci] auth = instance principal"
        export OCI_CLI_AUTH=instance_principal
    elif [[ -n "${OCI_CLI_USER:-}" && -n "${OCI_KEY_CONTENT:-}" ]]; then
        echo "[oci] auth = API key (from environment)"
        : "${OCI_CLI_TENANCY:?set OCI_CLI_TENANCY}"
        : "${OCI_CLI_FINGERPRINT:?set OCI_CLI_FINGERPRINT}"
        : "${OCI_CLI_REGION:?set OCI_CLI_REGION}"
        mkdir -p /root/.oci
        printf '%s\n' "${OCI_KEY_CONTENT}" > /root/.oci/oci_api_key.pem
        cat > /root/.oci/config <<EOF
[DEFAULT]
user=${OCI_CLI_USER}
tenancy=${OCI_CLI_TENANCY}
fingerprint=${OCI_CLI_FINGERPRINT}
region=${OCI_CLI_REGION}
key_file=/root/.oci/oci_api_key.pem
EOF
        chmod 600 /root/.oci/oci_api_key.pem /root/.oci/config
        export OCI_CLI_KEY_FILE=/root/.oci/oci_api_key.pem
    else
        echo "[oci] no OCI credentials set"
        return 0
    fi
    if oci iam region list >/dev/null 2>&1; then
        echo "[oci] account link OK"; OCI_LINKED=1
    else
        echo "[oci] WARN: link test failed - check your OCI_* variables / policy"
    fi
}
setup_oci_link

# ----- strongswan.conf (log verbosity from env) -----
cat > /etc/strongswan.conf <<EOF
charon {
    load_modular = yes
    plugins { include strongswan.d/charon/*.conf }
    filelog { stderr { default = ${LOG_LEVEL}  time_format = %b %e %T } }
}
EOF

echo "[entrypoint] IP forwarding: only matters if this container routes others' traffic"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
    && echo "[entrypoint] IP forwarding enabled" \
    || echo "[entrypoint] IP forwarding not set (fine unless this container is a gateway)"

echo "[entrypoint] starting charon (MODE=${MODE})"
/usr/lib/ipsec/charon &
CHARON_PID=$!
for i in $(seq 1 30); do
    [[ -S /var/run/charon.vici || -S /run/charon.vici ]] && break
    sleep 0.5
done

if [[ "$MODE" == "managed" ]]; then
    if [[ "$OCI_LINKED" != "1" ]]; then
        echo "[entrypoint] FATAL: MODE=managed needs a working OCI account link"; exit 1
    fi
    : "${OCI_COMPARTMENT_ID:?managed mode needs OCI_COMPARTMENT_ID}"
    : "${OCI_DRG_ID:?managed mode needs OCI_DRG_ID}"
    export IKE_VERSION IKE_PROPOSAL ESP_PROPOSAL DPD_DELAY DPD_ACTION \
           START_ACTION ENCAP IKE_REKEY_TIME ESP_REKEY_TIME LOCAL_SUBNET \
           VCN_SUBNET LOCAL_ID
    trap 'echo "[entrypoint] stopping"; kill -TERM "$CHARON_PID" 2>/dev/null; wait "$CHARON_PID"' TERM INT
    /watcher.sh &
    WATCHER_PID=$!
    wait -n "$CHARON_PID" "$WATCHER_PID"
    exit $?
fi

# ----- static mode: build a fixed tunnel from env -----
: "${OCI_VPN_IP_1:?static mode needs OCI_VPN_IP_1}"
: "${PSK_1:?static mode needs PSK_1}"

CONF=/etc/swanctl/swanctl.conf
mkdir -p /etc/swanctl

emit_tunnel() {
    local n="$1" ip="$2"
    cat <<EOF
    oci-tunnel${n} {
        version = ${IKE_VERSION}
        local_addrs  = %any
        remote_addrs = ${ip}
        proposals = ${IKE_PROPOSAL}
        dpd_delay = ${DPD_DELAY}
        rekey_time = ${IKE_REKEY_TIME}
        encap = ${ENCAP}
        local  { auth = psk  id = ${LOCAL_ID} }
        remote { auth = psk  id = ${ip} }
        children {
            oci-child${n} {
                local_ts  = ${LOCAL_SUBNET}
                remote_ts = ${VCN_SUBNET}
                esp_proposals = ${ESP_PROPOSAL}
                rekey_time = ${ESP_REKEY_TIME}
                start_action = ${START_ACTION}
                dpd_action = ${DPD_ACTION}
                mode = tunnel
            }
        }
    }
EOF
}
emit_secret() { cat <<EOF
    ike-oci${1} { id = ${2}  secret = "${3}" }
EOF
}

{
    echo "connections {"
    emit_tunnel 1 "$OCI_VPN_IP_1"
    [[ -n "${OCI_VPN_IP_2:-}" && -n "${PSK_2:-}" ]] && emit_tunnel 2 "$OCI_VPN_IP_2"
    echo "}"
    echo "secrets {"
    emit_secret 1 "$OCI_VPN_IP_1" "$PSK_1"
    [[ -n "${OCI_VPN_IP_2:-}" && -n "${PSK_2:-}" ]] && emit_secret 2 "$OCI_VPN_IP_2" "$PSK_2"
    echo "}"
} > "$CONF"
chmod 600 "$CONF"

echo "[entrypoint] loading swanctl config"
swanctl --load-all
swanctl --initiate --child oci-child1 || true
[[ -n "${OCI_VPN_IP_2:-}" ]] && { swanctl --initiate --child oci-child2 || true; }
swanctl --list-sas || true

trap 'echo "[entrypoint] stopping"; kill -TERM "$CHARON_PID" 2>/dev/null; wait "$CHARON_PID"' TERM INT
wait "$CHARON_PID"
__OCI_FILE_02__

cat > "watcher.sh" <<'__OCI_FILE_03__'
#!/bin/bash
# Managed mode: OCI is the source of truth. Each cycle we ask OCI what IP the
# current CPE has, compare it to our real public IP, and if they differ we
# recreate the CPE + IPSec connection, reload strongSwan, and delete the stale
# OCI resources. No local state file needed.
set -uo pipefail

CONF=/etc/swanctl/swanctl.conf
mkdir -p /etc/swanctl

# ---- required inputs ----
: "${OCI_COMPARTMENT_ID:?managed mode needs OCI_COMPARTMENT_ID}"
: "${OCI_DRG_ID:?managed mode needs OCI_DRG_ID}"
: "${LOCAL_SUBNET:?set LOCAL_SUBNET (your on-prem CIDR = OCI static route)}"
: "${VCN_SUBNET:?set VCN_SUBNET (OCI VCN CIDR)}"
: "${LOCAL_ID:?set LOCAL_ID (CPE IKE identifier)}"

# ---- tunables ----
CHECK_INTERVAL="${CHECK_INTERVAL:-120}"
IP_CHECK_URL="${IP_CHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
IKE_VERSION="${IKE_VERSION:-2}"
IKE_PROPOSAL="${IKE_PROPOSAL:-aes256-sha384-modp2048}"
ESP_PROPOSAL="${ESP_PROPOSAL:-aes256-sha256-modp2048}"
DPD_DELAY="${DPD_DELAY:-30s}"
DPD_ACTION="${DPD_ACTION:-restart}"
START_ACTION="${START_ACTION:-start}"
ENCAP="${ENCAP:-yes}"
IKE_REKEY_TIME="${IKE_REKEY_TIME:-8h}"
ESP_REKEY_TIME="${ESP_REKEY_TIME:-1h}"

# logs go to stderr so they never pollute a function's captured stdout
log() { echo "[watcher] $(date '+%F %T') $*" >&2; }

get_public_ip() {
    local url resp ip
    for url in "$IP_CHECK_URL" https://1.1.1.1/cdn-cgi/trace https://api.ipify.org; do
        resp=$(curl -fsS --max-time 10 "$url" 2>/dev/null) || continue
        ip=$(printf '%s\n' "$resp" | sed -n 's/^ip=//p' | head -1)
        [[ -z "$ip" ]] && ip=$(printf '%s\n' "$resp" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

# newest AVAILABLE IPSec connection we manage (by display-name prefix)
current_ipsc() {
    oci network ip-sec-connection list --compartment-id "$OCI_COMPARTMENT_ID" 2>/dev/null \
      | jq -r '[.data[]
                | select((."display-name"//"")|startswith("auto-ipsec-"))
                | select(."lifecycle-state"=="AVAILABLE")]
               | sort_by(."time-created") | (last.id // empty)'
}
cpe_id_of() { oci network ip-sec-connection get --ipsc-id "$1" --query 'data."cpe-id"' --raw-output 2>/dev/null; }
cpe_ip_of() { oci network cpe get --cpe-id "$1" --query 'data."ip-address"' --raw-output 2>/dev/null; }

emit_conn() {
    local n="$1" ip="$2"
    cat <<EOF
    oci-tunnel${n} {
        version = ${IKE_VERSION}
        local_addrs = %any
        remote_addrs = ${ip}
        proposals = ${IKE_PROPOSAL}
        dpd_delay = ${DPD_DELAY}
        rekey_time = ${IKE_REKEY_TIME}
        encap = ${ENCAP}
        local  { auth = psk  id = ${LOCAL_ID} }
        remote { auth = psk  id = ${ip} }
        children {
            oci-child${n} {
                local_ts = ${LOCAL_SUBNET}
                remote_ts = ${VCN_SUBNET}
                esp_proposals = ${ESP_PROPOSAL}
                rekey_time = ${ESP_REKEY_TIME}
                start_action = ${START_ACTION}
                dpd_action = ${DPD_ACTION}
                mode = tunnel
            }
        }
    }
EOF
}
emit_secret() { printf '    ike-oci%s { id = %s  secret = "%s" }\n' "$1" "$2" "$3"; }

# read an IPSec connection's tunnel headends + secrets, render config, reload
read_and_load() {
    local ipsc="$1" tjson tid1 tid2 ip1 ip2 psk1 psk2 ready tries=0
    while :; do
        tjson=$(oci network ip-sec-connection-tunnel list --ipsc-id "$ipsc" 2>/dev/null)
        ready=$(echo "$tjson" | jq '[.data[] | select(."lifecycle-state"=="AVAILABLE" and (."vpn-ip"!=null))] | length' 2>/dev/null || echo 0)
        [[ "$ready" -ge 2 ]] && break
        (( tries++ >= 30 )) && { log "ERROR: tunnels for $ipsc not ready"; return 1; }
        sleep 10
    done
    tid1=$(echo "$tjson" | jq -r '.data[0].id'); tid2=$(echo "$tjson" | jq -r '.data[1].id')
    ip1=$(echo "$tjson"  | jq -r '.data[0]."vpn-ip"'); ip2=$(echo "$tjson" | jq -r '.data[1]."vpn-ip"')
    oci network ip-sec-connection-tunnel update --ipsc-id "$ipsc" --tunnel-id "$tid1" --ike-version "V${IKE_VERSION}" --force >/dev/null 2>&1 || true
    oci network ip-sec-connection-tunnel update --ipsc-id "$ipsc" --tunnel-id "$tid2" --ike-version "V${IKE_VERSION}" --force >/dev/null 2>&1 || true
    psk1=$(oci network ip-sec-connection-tunnel-shared-secret get --ipsc-id "$ipsc" --tunnel-id "$tid1" --query 'data."shared-secret"' --raw-output 2>/dev/null) || return 1
    psk2=$(oci network ip-sec-connection-tunnel-shared-secret get --ipsc-id "$ipsc" --tunnel-id "$tid2" --query 'data."shared-secret"' --raw-output 2>/dev/null) || return 1

    { echo "connections {"; emit_conn 1 "$ip1"; emit_conn 2 "$ip2"; echo "}"
      echo "secrets {"; emit_secret 1 "$ip1" "$psk1"; emit_secret 2 "$ip2" "$psk2"; echo "}"; } > "$CONF"
    chmod 600 "$CONF"
    log "loading strongSwan onto headends ${ip1}, ${ip2}"
    swanctl --load-all
    swanctl --terminate --ike oci-tunnel1 >/dev/null 2>&1 || true
    swanctl --terminate --ike oci-tunnel2 >/dev/null 2>&1 || true
    swanctl --initiate --child oci-child1 >/dev/null 2>&1 || true
    swanctl --initiate --child oci-child2 >/dev/null 2>&1 || true
}

# create a new CPE + IPSec connection for $1; echo the new IPSec connection id
rebuild() {
    local newip="$1" ts cpe ipsc
    ts=$(date +%s)
    log "creating CPE for ${newip}"
    cpe=$(oci network cpe create --compartment-id "$OCI_COMPARTMENT_ID" --ip-address "$newip" \
            --display-name "auto-cpe-${ts}" --query 'data.id' --raw-output 2>/dev/null) || { log "ERROR: CPE create failed"; return 1; }
    log "creating IPSec connection"
    ipsc=$(oci network ip-sec-connection create --compartment-id "$OCI_COMPARTMENT_ID" --cpe-id "$cpe" \
            --drg-id "$OCI_DRG_ID" --static-routes "[\"${LOCAL_SUBNET}\"]" \
            --display-name "auto-ipsec-${ts}" --query 'data.id' --raw-output 2>/dev/null) || { log "ERROR: IPSec create failed"; return 1; }
    echo "$ipsc"
}

# delete every managed IPSec connection + CPE except the one to keep
cleanup_stale() {
    local keep="$1" keepcpe id cpe
    keepcpe=$(cpe_id_of "$keep")
    for id in $(oci network ip-sec-connection list --compartment-id "$OCI_COMPARTMENT_ID" 2>/dev/null \
                | jq -r '.data[] | select((."display-name"//"")|startswith("auto-ipsec-")) | select(."lifecycle-state"=="AVAILABLE") | .id'); do
        [[ "$id" == "$keep" ]] && continue
        cpe=$(cpe_id_of "$id")
        log "deleting stale IPSec connection $id"
        oci network ip-sec-connection delete --ipsc-id "$id" --force --wait-for-state TERMINATED >/dev/null 2>&1 || log "WARN: delete $id failed"
        [[ -n "$cpe" && "$cpe" != "$keepcpe" ]] && oci network cpe delete --cpe-id "$cpe" --force >/dev/null 2>&1 || true
    done
    # sweep any leftover managed CPEs not attached to the kept connection
    for cpe in $(oci network cpe list --compartment-id "$OCI_COMPARTMENT_ID" 2>/dev/null \
                 | jq -r '.data[] | select((."display-name"//"")|startswith("auto-cpe-")) | .id'); do
        [[ "$cpe" == "$keepcpe" ]] && continue
        oci network cpe delete --cpe-id "$cpe" --force >/dev/null 2>&1 && log "swept orphan CPE $cpe" || true
    done
}

log "managed watcher started (interval ${CHECK_INTERVAL}s, IP source: ${IP_CHECK_URL})"
LOADED_IPSC=""
while :; do
    if ! myip=$(get_public_ip); then
        log "WARN: could not determine public IP this cycle"; sleep "$CHECK_INTERVAL"; continue
    fi

    cur=$(current_ipsc)
    need_rebuild=0
    if [[ -z "$cur" ]]; then
        log "no managed IPSec connection on OCI yet"; need_rebuild=1
    else
        ociip=$(cpe_ip_of "$(cpe_id_of "$cur")")
        if [[ "$ociip" != "$myip" ]]; then
            log "OCI CPE IP (${ociip:-none}) != public IP (${myip}) - correcting"; need_rebuild=1
        fi
    fi

    if [[ "$need_rebuild" == "1" ]]; then
        if new=$(rebuild "$myip") && [[ -n "$new" ]]; then
            if read_and_load "$new"; then
                cleanup_stale "$new"; LOADED_IPSC="$new"
                log "OCI now matches public IP ${myip}"
            else
                log "loaded config failed for $new; will retry"
            fi
        else
            log "rebuild failed; will retry next cycle"
        fi
    elif [[ "$cur" != "$LOADED_IPSC" ]]; then
        # OCI is already correct but this process hasn't loaded it (e.g. restart)
        log "OCI IP already correct; loading existing tunnel $cur"
        read_and_load "$cur" && LOADED_IPSC="$cur"
    fi

    sleep "$CHECK_INTERVAL"
done
__OCI_FILE_03__

cat > "docker-compose.yml" <<'__OCI_FILE_04__'
services:
  oci-ipsec:
    build: .
    image: oci-ipsec:latest
    container_name: oci-ipsec
    restart: unless-stopped

    # ----- Docker-level settings (NOT environment variables) -----
    networks:
      - ipsecnet
    cap_add:
      - NET_ADMIN            # required: lets charon install XFRM policy + routes
    # IP forwarding is only needed if OTHER containers/hosts route through this
    # one to reach the VCN. Uncomment to enable:
    #sysctls:
    #  - net.ipv4.ip_forward=1

    environment:
      # ===== Which mode? =====
      # static  = fixed tunnel from the values you paste below.
      # managed = watcher grabs your public IP and recreates the OCI tunnel
      #           whenever it changes (this is the "auto" behaviour you want).
      MODE: "managed"

      # ===== Always required =====
      LOCAL_SUBNET: "172.28.0.0/24"         # your on-prem CIDR = the OCI static route
      VCN_SUBNET: "10.0.0.0/16"             # the OCI VCN CIDR you want to reach
      LOCAL_ID: "home.example.com"          # CPE IKE identifier

      # ===== managed mode: OCI targets =====
      OCI_COMPARTMENT_ID: "ocid1.compartment.oc1..xxxx"
      OCI_DRG_ID: "ocid1.drg.oc1..xxxx"
      CHECK_INTERVAL: "120"                 # seconds between public-IP checks
      IP_CHECK_URL: "https://www.cloudflare.com/cdn-cgi/trace"   # Cloudflare

      # ===== static mode only (ignored when MODE=managed) =====
      #OCI_VPN_IP_1: "203.0.113.10"
      #PSK_1: "CHANGE_ME_tunnel1_shared_secret"
      #OCI_VPN_IP_2: "203.0.113.11"
      #PSK_2: "CHANGE_ME_tunnel2_shared_secret"

      # ===== crypto (MUST match your OCI tunnel) =====
      IKE_VERSION: "2"
      IKE_PROPOSAL: "aes256-sha384-modp2048"
      ESP_PROPOSAL: "aes256-sha256-modp2048"

      # ===== behaviour / timers =====
      DPD_DELAY: "30s"
      DPD_ACTION: "restart"
      START_ACTION: "start"
      ENCAP: "yes"
      IKE_REKEY_TIME: "8h"
      ESP_REKEY_TIME: "1h"
      LOG_LEVEL: "1"

      # ===== OCI ACCOUNT LINK (required for managed mode) =====
      # Option A: container runs ON an OCI VM (simplest, no keys)
      #OCI_CLI_AUTH: "instance_principal"
      # Option B: API key (off-OCI)
      #OCI_CLI_USER: "ocid1.user.oc1..xxxx"
      #OCI_CLI_TENANCY: "ocid1.tenancy.oc1..xxxx"
      #OCI_CLI_FINGERPRINT: "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
      #OCI_CLI_REGION: "us-ashburn-1"
      #OCI_KEY_CONTENT: |
      #  -----BEGIN PRIVATE KEY-----
      #  ...paste the whole private key here, indented like this...
      #  -----END PRIVATE KEY-----

networks:
  ipsecnet:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24
__OCI_FILE_04__

cat > "docker-compose.override.yml.example" <<'__OCI_FILE_05__'
# Copy to docker-compose.override.yml (which is gitignored) and put your REAL
# values here. Docker Compose automatically merges this over docker-compose.yml,
# so the committed file keeps placeholders and your secrets never touch git.
#
#   cp docker-compose.override.yml.example docker-compose.override.yml
#   # edit it, then:
#   docker compose up -d

services:
  oci-ipsec:
    # To run the image published to GHCR instead of building locally,
    # uncomment this and run `docker compose pull && docker compose up -d`.
    # (You can also delete the `build:` line from docker-compose.yml.)
    #image: ghcr.io/YOUR_GH_USERNAME/YOUR_REPO:latest

    environment:
      # --- your real values ---
      LOCAL_SUBNET: "172.28.0.0/24"
      VCN_SUBNET: "10.0.0.0/16"
      LOCAL_ID: "home.example.com"
      OCI_COMPARTMENT_ID: "ocid1.compartment.oc1..REAL"
      OCI_DRG_ID: "ocid1.drg.oc1..REAL"

      # --- OCI auth: instance principal (on an OCI VM) ---
      #OCI_CLI_AUTH: "instance_principal"

      # --- OCI auth: API key (off-OCI) ---
      OCI_CLI_USER: "ocid1.user.oc1..REAL"
      OCI_CLI_TENANCY: "ocid1.tenancy.oc1..REAL"
      OCI_CLI_FINGERPRINT: "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
      OCI_CLI_REGION: "us-ashburn-1"
      OCI_KEY_CONTENT: |
        -----BEGIN PRIVATE KEY-----
        ...paste your real private key here...
        -----END PRIVATE KEY-----
__OCI_FILE_05__

mkdir -p ".github/workflows"
cat > ".github/workflows/docker-publish.yml" <<'__OCI_FILE_06__'
name: build-and-push

# Builds the container and pushes it to GitHub Container Registry (GHCR) at
# ghcr.io/<owner>/<repo>. Runs on pushes to main and on version tags.
on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=ref,event=tag
            type=sha,format=short

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
__OCI_FILE_06__

cat > "README.md" <<'__OCI_FILE_07__'
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
__OCI_FILE_07__

echo
echo "Created:"; find . -type f -not -name setup.sh | sort
echo
echo "Next: git add . && git commit -m \"Add OCI IPsec container\" && git push"
