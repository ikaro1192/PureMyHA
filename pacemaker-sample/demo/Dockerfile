FROM debian:bookworm

# Install Pacemaker, Corosync, pcs, fence agents, HAProxy, and socat
RUN apt-get update && apt-get install -y --no-install-recommends \
    pacemaker \
    pacemaker-cli-utils \
    pcs \
    corosync \
    corosync-qdevice \
    fence-agents \
    haproxy \
    socat \
    iproute2 \
    iputils-ping \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Ensure pacemaker log directory exists
RUN mkdir -p /var/log/pacemaker

# Set hacluster password (used by pcs for cluster authentication)
RUN echo "hacluster:hacluster" | chpasswd

# Install the OCF Resource Agent
RUN mkdir -p /usr/lib/ocf/resource.d/puremyha
COPY ocf/puremyha /usr/lib/ocf/resource.d/puremyha/puremyhad
RUN chmod 755 /usr/lib/ocf/resource.d/puremyha/puremyhad

# Deploy HAProxy configuration
COPY haproxy/haproxy.cfg.example /etc/haproxy/haproxy.cfg
RUN mkdir -p /run/haproxy

# Install PureMyHA hook scripts for HAProxy integration
RUN mkdir -p /etc/puremyha/hooks
COPY haproxy/hooks/haproxy-common.sh /etc/puremyha/hooks/haproxy-common.sh
COPY haproxy/hooks/post_failover.sh /etc/puremyha/hooks/post_failover.sh
COPY haproxy/hooks/post_switchover.sh /etc/puremyha/hooks/post_switchover.sh
RUN chmod 755 /etc/puremyha/hooks/*.sh

# Copy setup scripts
RUN mkdir -p /setup
COPY demo/scripts/setup-cluster.sh /setup/setup-cluster.sh
COPY demo/scripts/configure-resources.sh /setup/configure-resources.sh
RUN chmod 755 /setup/setup-cluster.sh /setup/configure-resources.sh

COPY demo/scripts/node-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
