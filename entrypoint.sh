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
