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
