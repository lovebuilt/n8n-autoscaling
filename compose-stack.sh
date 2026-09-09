#!/bin/bash
# Run one lifecycle action using the runtime and COMPOSE_FILE currently stored
# in .env. systemd calls this wrapper so later wizard changes do not go stale.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

get_env_value() {
    local key="$1" default="$2" value=""
    if [ -f .env ]; then
        value=$(grep "^${key}=" .env 2>/dev/null | cut -d= -f2- | sed 's/#.*//' | xargs) || true
    fi
    if [ -n "$value" ]; then echo "$value"; else echo "$default"; fi
}

detect_docker_socket_path() {
    local mode="$1" endpoint="${DOCKER_HOST:-}"
    if [ -z "$endpoint" ] && docker context show &>/dev/null; then
        endpoint=$(docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    fi
    if [ -z "$endpoint" ]; then
        if [ "$mode" = "rootless" ]; then
            endpoint="/run/user/$(id -u)/docker.sock"
        else
            endpoint="/var/run/docker.sock"
        fi
    fi
    endpoint=${endpoint#unix://}
    [[ "$endpoint" = /* ]] || return 1
    echo "$endpoint"
}

RUNTIME=$(get_env_value "CONTAINER_RUNTIME" "")
CONFIGURED_MODE=$(get_env_value "CONTAINER_RUNTIME_MODE" "")
CONFIGURED_SOCKET=$(get_env_value "DOCKER_SOCK" "")
CONFIGURED_SOCKET=${CONFIGURED_SOCKET#unix://}
ACTION="${1:-}"
case "$ACTION" in
    pull|up|reload|down) ;;
    *)
        echo "Usage: $0 {pull|up|reload|down}" >&2
        exit 2
        ;;
esac

# Docker lifecycle calls should target the persisted daemon even when systemd
# does not inherit the interactive user's current Docker context.
if [ "$RUNTIME" = "docker" ] && [[ "$CONFIGURED_SOCKET" = /* ]]; then
    export DOCKER_HOST="unix://${CONFIGURED_SOCKET}"
fi

# Engine and socket units can start in parallel with this service at boot.
# Give them a bounded window to become usable for start/reload actions. During
# shutdown the generated unit's After= ordering keeps them alive for `down`.
wait_for_command() {
    local description="$1"
    shift
    local attempt
    for attempt in {1..30}; do
        if "$@" &>/dev/null; then
            return 0
        fi
        [ "$attempt" -lt 30 ] && sleep 2
    done
    echo "Error: ${description} did not become accessible within 60 seconds." >&2
    return 1
}

case "$RUNTIME" in
    docker)
        if ! command -v docker &>/dev/null; then
            echo "Error: .env selects Docker, but the Docker CLI is unavailable." >&2
            exit 1
        fi
        if [ "$ACTION" != "down" ] && ! docker info &>/dev/null 2>&1; then
            wait_for_command "Docker" docker info || exit 1
        elif [ "$ACTION" = "down" ] && ! docker info &>/dev/null 2>&1; then
            echo "Error: .env selects Docker, but Docker is not accessible." >&2
            exit 1
        fi
        if docker info 2>/dev/null | grep -q rootless; then ACTIVE_MODE="rootless"; else ACTIVE_MODE="rootful"; fi
        if ! ACTIVE_SOCKET=$(detect_docker_socket_path "$ACTIVE_MODE"); then
            echo "Error: the active Docker context does not expose a local Unix socket." >&2
            exit 1
        fi
        if docker compose version &>/dev/null; then
            COMPOSE_COMMAND=(docker compose)
        elif command -v docker-compose &>/dev/null; then
            COMPOSE_COMMAND=(docker-compose)
        else
            echo "Error: no Docker Compose command is available." >&2
            exit 1
        fi
        ;;
    podman)
        if ! command -v podman &>/dev/null; then
            echo "Error: .env selects Podman, but the Podman CLI is unavailable." >&2
            exit 1
        fi
        if [ "$ACTION" != "down" ] && ! podman info &>/dev/null 2>&1; then
            wait_for_command "Podman" podman info || exit 1
        elif [ "$ACTION" = "down" ] && ! podman info &>/dev/null 2>&1; then
            echo "Error: .env selects Podman, but Podman is not accessible." >&2
            exit 1
        fi
        if [ "$(podman info --format '{{.Host.ServiceIsRemote}}' 2>/dev/null)" = "true" ]; then
            echo "Error: remote Podman cannot provide the autoscaler's local socket mount." >&2
            exit 1
        fi
        ACTIVE_SOCKET=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
        ACTIVE_SOCKET=${ACTIVE_SOCKET#unix://}
        PODMAN_SOCKET="$CONFIGURED_SOCKET"
        if [[ "$PODMAN_SOCKET" != /* ]] || [ ! -S "$PODMAN_SOCKET" ]; then
            if [ "$ACTION" != "down" ] && [[ "$PODMAN_SOCKET" = /* ]]; then
                wait_for_command "Podman API socket at '$PODMAN_SOCKET'" test -S "$PODMAN_SOCKET" || exit 1
            else
                echo "Error: local Podman API socket is unavailable at '$PODMAN_SOCKET'." >&2
                exit 1
            fi
        fi
        if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
            ACTIVE_MODE="rootless"
            export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        else
            ACTIVE_MODE="rootful"
        fi
        if command -v podman-compose &>/dev/null; then
            COMPOSE_COMMAND=(podman-compose)
        elif podman compose version &>/dev/null; then
            COMPOSE_COMMAND=(podman compose)
        else
            echo "Error: no Podman Compose command is available." >&2
            exit 1
        fi
        ;;
    "")
        echo "Error: CONTAINER_RUNTIME is not set; rerun ./n8n-setup.sh." >&2
        exit 1
        ;;
    *)
        echo "Error: unsupported CONTAINER_RUNTIME '$RUNTIME'." >&2
        exit 1
        ;;
esac

if [ -z "$CONFIGURED_MODE" ] || [ -z "$CONFIGURED_SOCKET" ]; then
    echo "Error: incomplete container-daemon identity in .env; rerun ./n8n-setup.sh." >&2
    exit 1
fi
if [ "$CONFIGURED_MODE" != "$ACTIVE_MODE" ] || [ "$CONFIGURED_SOCKET" != "$ACTIVE_SOCKET" ]; then
    echo "Error: active daemon identity differs from .env; refusing to touch daemon-local volumes." >&2
    echo "Recorded: $RUNTIME/$CONFIGURED_MODE at $CONFIGURED_SOCKET" >&2
    echo "Active:   $RUNTIME/$ACTIVE_MODE at $ACTIVE_SOCKET" >&2
    echo "Run ./n8n-setup.sh to perform or acknowledge a manual data cutover." >&2
    exit 1
fi

if [ "$(get_env_value "ENABLE_AI_ASSISTANT" "false")" = "true" ] && \
   [ "$(get_env_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "")" = "n8n-sandbox" ]; then
    if [ "$RUNTIME" != "docker" ] || [ "$ACTIVE_MODE" != "rootful" ]; then
        echo "Error: the self-hosted n8n Sandbox requires rootful Docker." >&2
        exit 1
    fi
fi

case "$ACTION" in
    pull)
        "${COMPOSE_COMMAND[@]}" pull --ignore-pull-failures
        ;;
    up|reload)
        "${COMPOSE_COMMAND[@]}" up -d --build --remove-orphans
        ;;
    down)
        "${COMPOSE_COMMAND[@]}" down --remove-orphans
        ;;
esac
