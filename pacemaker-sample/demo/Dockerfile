FROM debian:bookworm

# Install Pacemaker, Corosync, pcs, and fence agents
RUN apt-get update && apt-get install -y --no-install-recommends \
    pacemaker \
    pacemaker-cli-utils \
    pcs \
    corosync \
    corosync-qdevice \
    fence-agents \
    iproute2 \
    iputils-ping \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set hacluster password (used by pcs for cluster authentication)
# Ensure pacemaker log directory exists
RUN mkdir -p /var/log/pacemaker

# Set hacluster password (used by pcs for cluster authentication)
RUN echo "hacluster:hacluster" | chpasswd

# Install the OCF Resource Agent
RUN mkdir -p /usr/lib/ocf/resource.d/puremyha
COPY ocf/puremyha /usr/lib/ocf/resource.d/puremyha/puremyhad
RUN chmod 755 /usr/lib/ocf/resource.d/puremyha/puremyhad

# Copy setup script
RUN mkdir -p /setup
COPY demo/scripts/setup-cluster.sh /setup/setup-cluster.sh
COPY demo/scripts/configure-resources.sh /setup/configure-resources.sh
RUN chmod 755 /setup/setup-cluster.sh /setup/configure-resources.sh

COPY demo/scripts/node-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
