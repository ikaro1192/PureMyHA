COMPOSE = docker compose

.PHONY: build start setup status failover unstandby logs clean

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

## Start all containers (ha1, ha2, qdevice)
start:
	$(COMPOSE) up -d
	@echo ""
	@echo "Containers started. Run 'make setup' to initialize the cluster."

## Initialize the Pacemaker cluster (run once after 'make start')
setup:
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

## Follow logs from all containers
logs:
	$(COMPOSE) logs -f

## Stop and remove all containers and volumes
clean:
	$(COMPOSE) down -v
