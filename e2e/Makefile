.PHONY: e2e e2e-clean e2e-logs e2e-status

# Run all E2E tests
e2e:
	bash run-all.sh

# Run a specific test (e.g., make e2e-test T=02)
e2e-test:
	bash run-all.sh $(T)

# Tear down the E2E environment
e2e-clean:
	docker compose down -v --remove-orphans

# Follow puremyhad logs
e2e-logs:
	docker compose logs -f puremyhad

# Show status of all containers
e2e-status:
	docker compose ps
