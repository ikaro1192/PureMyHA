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
	$(COMPOSE) exec ha1 /setup/setup-cluster.sh

## Show cluster status
status:
	$(COMPOSE) exec ha1 pcs status

## Show quorum status
quorum:
	$(COMPOSE) exec ha1 pcs quorum status

## Simulate failover: move puremyhad from ha1 to ha2
failover:
	@echo "==> Putting ha1 in standby (puremyhad will move to ha2)..."
	$(COMPOSE) exec ha1 pcs node standby ha1
	@sleep 3
	$(COMPOSE) exec ha1 pcs status

## Restore ha1 to active state
unstandby:
	$(COMPOSE) exec ha1 pcs node unstandby ha1
	@sleep 3
	$(COMPOSE) exec ha1 pcs status

## Follow logs from all containers
logs:
	$(COMPOSE) logs -f

## Stop and remove all containers and volumes
clean:
	$(COMPOSE) down -v
