#!/bin/sh
# docker-compose against OrbStack, with a project-local docker config.
export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"
export DOCKER_CONFIG="$(cd "$(dirname "$0")" && pwd)/.docker"
mkdir -p "$DOCKER_CONFIG" && [ -f "$DOCKER_CONFIG/config.json" ] || echo '{}' > "$DOCKER_CONFIG/config.json"
exec /Applications/OrbStack.app/Contents/MacOS/xbin/docker-compose -f "$(dirname "$0")/docker-compose.yml" "$@"
