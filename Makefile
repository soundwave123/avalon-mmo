# Avalon dev orchestration
# Common operations: bring infra up/down, tail logs, psql shell, redis-cli shell

.PHONY: dev-up dev-down dev-logs dev-status dev-psql dev-redis-cli dev-clean

COMPOSE := podman-compose -f infra/docker-compose.yml

dev-up:
	$(COMPOSE) up -d
	@echo "Waiting for services to become healthy..."
	@for i in $$(seq 1 30); do \
		pg_status=$$(podman inspect --format '{{.State.Health.Status}}' avalon-postgres 2>/dev/null || echo "starting"); \
		redis_status=$$(podman inspect --format '{{.State.Health.Status}}' avalon-redis 2>/dev/null || echo "starting"); \
		if [ "$$pg_status" = "healthy" ] && [ "$$redis_status" = "healthy" ]; then \
			echo "All services healthy."; \
			exit 0; \
		fi; \
		printf '.'; \
		sleep 2; \
	done; \
	echo ""; \
	echo "Timeout waiting for services. Check 'make dev-logs'."; \
	exit 1

dev-down:
	$(COMPOSE) down

dev-logs:
	$(COMPOSE) logs -f --tail=50

dev-status:
	@podman ps --filter 'name=avalon-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

dev-psql:
	@PGPASSWORD=avalon_dev_only_not_for_prod psql -h 127.0.0.1 -U avalon -d avalon

dev-redis-cli:
	@redis-cli -h 127.0.0.1 -p 6379

# Nuclear: wipe all data and start fresh. Useful when schema changes.
dev-clean:
	$(COMPOSE) down -v
	@echo "All Avalon data volumes deleted. Run 'make dev-up' to recreate."

integration:
	@echo "=== M0 integration: direct gameplay loop ==="
	bash scripts/demo-m0.sh
	@echo "=== M0 integration: gateway auth chain ==="
	bash scripts/demo-m0-gateway.sh
	@echo "=== M0 integration: latency check ==="
	bash scripts/check-latency.sh
	@echo "=== M1 integration: server-authoritative kill loop ==="
	bash scripts/test-kill-loop.sh

help:
	@echo "Avalon dev commands:"
	@echo "  make dev-up        Bring up Postgres + Redis"
	@echo "  make dev-down      Stop containers (keeps data)"
	@echo "  make dev-clean     Stop + delete all data (fresh start)"
	@echo "  make dev-status    Show running containers"
	@echo "  make dev-logs      Tail container logs"
	@echo "  make dev-psql      Open psql shell"
	@echo "  make dev-redis-cli Open redis-cli shell"
