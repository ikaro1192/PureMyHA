FROM debian:bookworm

# Install Pacemaker, Corosync, pcs, and fence agents
RUN apt-get update && apt-get install -y --no-install-recommends \
    pacemaker \
    pcs \
    corosync \
    corosync-qdevice \
    fence-agents \
    iproute2 \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Set hacluster password (used by pcs for cluster authentication)
RUN echo "hacluster:hacluster" | chpasswd

# Install the OCF Resource Agent
RUN mkdir -p /usr/lib/ocf/resource.d/puremyha
COPY ../ocf/puremyha /usr/lib/ocf/resource.d/puremyha/puremyhad
RUN chmod 755 /usr/lib/ocf/resource.d/puremyha/puremyhad

# Copy setup script
RUN mkdir -p /setup
COPY scripts/setup-cluster.sh /setup/setup-cluster.sh
RUN chmod 755 /setup/setup-cluster.sh

COPY scripts/node-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
