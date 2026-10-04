# Local stack runs on OrbStack's docker engine.
export PATH := /Applications/OrbStack.app/Contents/MacOS/xbin:$(PATH)
export DOCKER_HOST := unix://$(HOME)/.orbstack/run/docker.sock
# project-local docker config: avoids the Docker Desktop credential helper
export DOCKER_CONFIG := $(CURDIR)/.docker
XBIN := /Applications/OrbStack.app/Contents/MacOS/xbin
DC := $(XBIN)/docker-compose

.PHONY: up down logs test reset ps ios

up: backend/.env.dev   ## start db, api, worker, vendor sandbox, mailpit
	$(DC) up -d --build

backend/.env.dev:      ## first run: local env from the example, with random secrets
	sed -e "s/^SURPRISE_SECRET=.*/SURPRISE_SECRET=$$(openssl rand -hex 24)/" \
	    -e "s/^INVITE_SECRET=.*/INVITE_SECRET=$$(openssl rand -hex 24)/" \
	    -e "s/^VOUCHER_KEY=.*/VOUCHER_KEY=$$(openssl rand -hex 24)/" backend/.env.example > $@

down:
	$(DC) down

reset:         ## wipe the database and start fresh with demo data
	$(DC) down -v && $(DC) up -d --build

logs:
	$(DC) logs -f api worker

ps:
	$(DC) ps

test:          ## run the backend test suite inside the api container
	$(DC) exec -T db psql -U coins -tc "SELECT 1 FROM pg_database WHERE datname='coins_test'" | grep -q 1 || \
	  $(DC) exec -T db psql -U coins -c "CREATE DATABASE coins_test"
	$(DC) run --rm --no-deps -e APP_ENV=test api pytest -q tests

ios:           ## regenerate the Xcode project
	cd ios && xcodegen generate
