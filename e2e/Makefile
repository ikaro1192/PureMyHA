.PHONY: e2e e2e-clean e2e-logs e2e-status e2e-coverage e2e-coverage-test e2e-coverage-clean

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

# Run all E2E tests with HPC coverage collection
e2e-coverage:
	bash collect-coverage.sh

# Run a specific E2E test with coverage (e.g., make e2e-coverage-test T=02)
e2e-coverage-test:
	bash collect-coverage.sh $(T)

# Clean coverage artifacts
e2e-coverage-clean:
	rm -rf coverage-output
