COMPOSE = docker compose

# The node currently running puremyhad (resource group owner).
# Most MySQL-related commands must run on this node.
ACTIVE_NODE = $$($(COMPOSE) exec ha1 crm_mon -1 --output-as=xml 2>/dev/null \
	| sed -n 's/.*resource id="puremyhad"[^/]*role="Started"[^/]*node="\([^"]*\)".*/\1/p' \
	| head -1 | grep . || echo ha1)

.PHONY: build start setup status quorum failover unstandby \
        switchover stop-source start-source ack-recovery topology \
        haproxy-stat pause-failover resume-failover logs clean

## Build the puremyhad binary and cluster node images
build:
	@echo "==> Building puremyhad binary..."
	docker build -t puremyha ../../
	mkdir -p ../../dist-bins
	docker create --name puremyha-tmp puremyha
	docker cp puremyha-tmp:/usr/sbin/puremyhad ../../dist-bins/puremyhad
	docker rm puremyha-tmp
	@echo "==> Building cluster images..."
	$(COMPOSE) build

## Start all containers (db1, db2, ha1, ha2, qdevice)
start:
	$(COMPOSE) up -d
	@echo ""
	@echo "Containers started. Run 'make setup' to initialize the cluster."

## Initialize MySQL replication and the Pacemaker cluster (run once after 'make start')
setup:
	@echo "==> Phase 0: Setup MySQL replication (db1 → db2)..."
	./scripts/setup-replication.sh
	@echo "==> Phase 1: Auth and cluster setup..."
	$(COMPOSE) exec ha1 /setup/setup-cluster.sh
	@echo "==> Starting corosync on both nodes..."
	$(COMPOSE) exec ha1 corosync
	$(COMPOSE) exec ha2 corosync
	@sleep 3
	@echo "==> Starting pacemaker on both nodes..."
	$(COMPOSE) exec -d ha1 pacemakerd
	$(COMPOSE) exec -d ha2 pacemakerd
	@echo "    Waiting for daemons to initialize..."
	@sleep 15
	@echo "==> Phase 2: Configure resources..."
	$(COMPOSE) exec ha1 /setup/configure-resources.sh

## Show cluster status (uses crm_mon — pcs status requires systemd)
status:
	$(COMPOSE) exec ha1 crm_mon -1

## Show quorum status
quorum:
	$(COMPOSE) exec ha1 pcs quorum status

## Simulate failover: move puremyhad from ha1 to ha2
failover:
	@echo "==> Putting ha1 in standby (puremyhad will move to ha2)..."
	$(COMPOSE) exec ha1 pcs node standby ha1
	@sleep 3
	$(COMPOSE) exec ha1 crm_mon -1

## Restore ha1 to active state
unstandby:
	$(COMPOSE) exec ha1 pcs node unstandby ha1
	@sleep 3
	$(COMPOSE) exec ha1 crm_mon -1

## ---- MySQL operations (via puremyha CLI) ----

## Graceful switchover: swap source ↔ replica roles
## Usage: make switchover              (auto-select best replica)
##        make switchover TO=db2       (switch to a specific host)
switchover:
	@node=$(ACTIVE_NODE); \
	echo "==> Running switchover on $$node..."; \
	if [ -n "$(TO)" ]; then \
		$(COMPOSE) exec $$node puremyha switchover --to=$(TO); \
	else \
		$(COMPOSE) exec $$node puremyha switchover; \
	fi

## Simulate MySQL source failure by stopping the container.
## MySQL receives SIGTERM, closes all connections immediately, and the
## container's network interface is removed — subsequent TCP connections
## fail at ARP level.  Auto-failover triggers within ~20-30 seconds.
## Usage: make stop-source              (stops db1)
##        make stop-source HOST=db2     (stops db2)
stop-source:
	@host=$${HOST:-db1}; \
	echo "==> Stopping MySQL container $$host (simulating crash)..."; \
	$(COMPOSE) stop $$host; \
	echo "    puremyhad should detect the failure within ~20-30 seconds."

## Restart a previously stopped MySQL container
## Usage: make start-source             (starts db1)
##        make start-source HOST=db2    (starts db2)
start-source:
	@host=$${HOST:-db1}; \
	echo "==> Starting MySQL container $$host..."; \
	$(COMPOSE) start $$host; \
	echo "    Done. The node will rejoin as a replica after unfencing."

## Show current MySQL topology as seen by puremyhad
topology:
	@node=$(ACTIVE_NODE); \
	$(COMPOSE) exec $$node curl -s http://127.0.0.1:8080/cluster/main/topology | python3 -m json.tool 2>/dev/null \
	|| $(COMPOSE) exec $$node curl -s http://127.0.0.1:8080/cluster/main/topology

## Show HAProxy backend server status (source/replica routing)
haproxy-stat:
	@node=$(ACTIVE_NODE); \
	echo "BACKEND          SERVER     STATUS   CHECK        CONN  ADDR"; \
	$(COMPOSE) exec $$node sh -c \
	  'echo "show stat" | socat stdio /run/haproxy/admin.sock' \
	| awk -F, '/^mysql_/ { printf "%-16s %-10s %-8s %-12s %-5s %s\n", $$1, $$2, $$18, $$37, $$5, $$74 }'

## Acknowledge recovery block after auto-failover (re-enables auto-failover)
ack-recovery:
	@node=$(ACTIVE_NODE); \
	echo "==> Acknowledging recovery block on $$node..."; \
	$(COMPOSE) exec $$node puremyha ack-recovery

## Pause automatic failover (e.g. during maintenance)
pause-failover:
	@node=$(ACTIVE_NODE); \
	echo "==> Pausing auto-failover..."; \
	$(COMPOSE) exec $$node puremyha pause-failover

## Resume automatic failover
resume-failover:
	@node=$(ACTIVE_NODE); \
	echo "==> Resuming auto-failover..."; \
	$(COMPOSE) exec $$node puremyha resume-failover

## ---- General ----

## Follow logs from all containers
logs:
	$(COMPOSE) logs -f

## Stop and remove all containers and volumes
clean:
	$(COMPOSE) down -v
