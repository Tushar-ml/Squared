# Local stack runs on OrbStack's docker engine.
export PATH := /Applications/OrbStack.app/Contents/MacOS/xbin:$(PATH)
export DOCKER_HOST := unix://$(HOME)/.orbstack/run/docker.sock
# project-local docker config: avoids the Docker Desktop credential helper
export DOCKER_CONFIG := $(CURDIR)/.docker
XBIN := /Applications/OrbStack.app/Contents/MacOS/xbin
DC := $(XBIN)/docker-compose

.PHONY: up down logs test reset ps ios

up:            ## start db, api, worker, vendor sandbox, mailpit
	$(DC) up -d --build

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
