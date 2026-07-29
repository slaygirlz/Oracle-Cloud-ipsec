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
