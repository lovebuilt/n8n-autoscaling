#!/bin/bash
# generate-systemd.sh - Generate a systemd service file for n8n-autoscaling
# Detects container runtime (Docker/Podman), selects appropriate compose overrides,
# and creates a system or user-level service file.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="n8n-autoscaling"

get_env_value() {
    local key="$1" default="$2" value=""
    if [ -f "${PROJECT_DIR}/.env" ]; then
        value=$(grep "^${key}=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d= -f2- | sed 's/#.*//' | xargs) || true
    fi
    if [ -n "$value" ]; then echo "$value"; else echo "$default"; fi
}

set_env_value() {
    local key="$1" value="$2" env_file="${PROJECT_DIR}/.env" escaped
    [ -f "$env_file" ] || { echo -e "${RED}Error: ${env_file} does not exist; run n8n-setup.sh first.${NC}" >&2; exit 1; }
    escaped=${value//\\/\\\\}
    escaped=${escaped//&/\\&}
    escaped=${escaped//|/\\|}
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$env_file"
    elif grep -q "^#${key}=" "$env_file" 2>/dev/null; then
        sed -i.bak "s|^#${key}=.*|${key}=${escaped}|" "$env_file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
    fi
    rm -f "${env_file}.bak"
    chmod 600 "$env_file"
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

# --- Detect container runtime ---
detect_runtime() {
    local configured_runtime configured_mode configured_socket setup_completed detected_mode detected_socket
    configured_runtime=$(get_env_value "CONTAINER_RUNTIME" "")
    configured_mode=$(get_env_value "CONTAINER_RUNTIME_MODE" "")
    configured_socket=$(get_env_value "DOCKER_SOCK" "")
    configured_socket=${configured_socket#unix://}
    setup_completed=$(get_env_value "SETUP_COMPLETED" "false")

    if [ -z "$configured_runtime" ] && [ "$setup_completed" = "true" ]; then
        echo -e "${RED}Error: completed setup has no recorded container runtime identity.${NC}" >&2
        echo "Run n8n-setup.sh to identify the data-owning daemon safely." >&2
        exit 1
    fi

    case "$configured_runtime" in
        docker)
            if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
                echo -e "${RED}Error: .env selects Docker, but Docker is not accessible.${NC}" >&2
                echo "Rerun n8n-setup.sh to deliberately select a different runtime." >&2
                exit 1
            fi
            RUNTIME="docker"
            ;;
        podman)
            if ! command -v podman &>/dev/null || ! podman info &>/dev/null 2>&1; then
                echo -e "${RED}Error: .env selects Podman, but Podman is not accessible.${NC}" >&2
                echo "Rerun n8n-setup.sh to deliberately select a different runtime." >&2
                exit 1
            fi
            RUNTIME="podman"
            ;;
        "")
            if command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && \
               command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
                echo -e "${RED}Error: both Docker and Podman are available, but CONTAINER_RUNTIME is unset.${NC}" >&2
                echo "Run n8n-setup.sh and explicitly choose the engine that owns the existing data volumes." >&2
                exit 1
            elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
                RUNTIME="docker"
            elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
                RUNTIME="podman"
            else
                echo -e "${RED}Error: Neither Docker nor Podman found or accessible.${NC}" >&2
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}Error: Unsupported CONTAINER_RUNTIME '${configured_runtime}'.${NC}" >&2
            exit 1
            ;;
    esac

    if [ "$RUNTIME" = "podman" ]; then
        if command -v podman-compose &>/dev/null; then
            COMPOSE_CMD="podman-compose"
        else
            COMPOSE_CMD="podman compose"
        fi
        # Check if rootless
        if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
            ROOTLESS=true
        else
            ROOTLESS=false
        fi
    else
        if docker compose version &>/dev/null; then
            COMPOSE_CMD="docker compose"
        elif command -v docker-compose &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        else
            echo -e "${RED}Error: No Docker Compose tool found.${NC}"
            exit 1
        fi
        # Check if rootless
        if docker info 2>/dev/null | grep -q "rootless"; then
            ROOTLESS=true
        else
            ROOTLESS=false
        fi
    fi

    if [ "$ROOTLESS" = true ]; then detected_mode="rootless"; else detected_mode="rootful"; fi
    if [ "$RUNTIME" = "docker" ]; then
        if ! detected_socket=$(detect_docker_socket_path "$detected_mode"); then
            echo -e "${RED}Error: the selected Docker context does not expose a local Unix socket.${NC}" >&2
            exit 1
        fi
    else
        if [ "$(podman info --format '{{.Host.ServiceIsRemote}}' 2>/dev/null)" = "true" ]; then
            echo -e "${RED}Error: remote Podman cannot provide the autoscaler's local socket mount.${NC}" >&2
            exit 1
        fi
        detected_socket=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
        detected_socket=${detected_socket#unix://}
        if [[ "$detected_socket" != /* ]] || [ ! -S "$detected_socket" ]; then
            echo -e "${RED}Error: local Podman API socket is not active; rerun n8n-setup.sh.${NC}" >&2
            exit 1
        fi
        if [ "$ROOTLESS" = true ]; then
            if ! systemctl --user is-enabled --quiet podman.socket; then
                echo -e "${RED}Error: rootless podman.socket is not enabled for reboot; rerun n8n-setup.sh.${NC}" >&2
                exit 1
            fi
        elif ! systemctl is-enabled --quiet podman.socket; then
            echo -e "${RED}Error: rootful podman.socket is not enabled for reboot; rerun n8n-setup.sh.${NC}" >&2
            exit 1
        fi
    fi

    if [ "$setup_completed" = "true" ] && { [ -z "$configured_mode" ] || [ -z "$configured_socket" ]; }; then
        echo -e "${RED}Error: completed setup has no complete container-daemon identity.${NC}" >&2
        echo "Run n8n-setup.sh to infer and persist it without risking the database volumes." >&2
        exit 1
    fi
    if { [ -n "$configured_mode" ] && [ "$configured_mode" != "$detected_mode" ]; } || \
       { [ -n "$configured_socket" ] && [ "$configured_socket" != "$detected_socket" ]; }; then
        echo -e "${RED}Error: the active daemon does not match the identity recorded in .env.${NC}" >&2
        echo "Recorded: ${configured_runtime:-unset}/${configured_mode:-unset} at ${configured_socket:-unset}" >&2
        echo "Active:   ${RUNTIME}/${detected_mode} at ${detected_socket}" >&2
        echo "Run n8n-setup.sh; it will block unsafe rootless/rootful, context, or engine changes." >&2
        exit 1
    fi

    set_env_value "CONTAINER_RUNTIME" "$RUNTIME"
    set_env_value "CONTAINER_RUNTIME_MODE" "$detected_mode"
    set_env_value "DOCKER_SOCK" "$detected_socket"
    echo -e "${CYAN}Detected runtime:${NC} ${RUNTIME} (${detected_mode}) at ${detected_socket}"
}

# --- Build compose file list ---
build_compose_files() {
    local compose_file_value separator compose_file provider isolation joined_files=""
    local -a compose_file_names
    compose_file_value=$(get_env_value "COMPOSE_FILE" "")
    separator=$(get_env_value "COMPOSE_PATH_SEPARATOR" ":")

    if [ -n "$compose_file_value" ]; then
        local IFS="$separator"
        read -ra compose_file_names <<< "$compose_file_value"
    else
        compose_file_names=("docker-compose.yml")
        if [ "$(get_env_value "ENABLE_CLOUDFLARE_OVERRIDE" "false")" = "true" ]; then
            compose_file_names+=("docker-compose.cloudflare.yml")
        fi
        if [ "$(get_env_value "ENABLE_AI_ASSISTANT" "false")" = "true" ]; then
            compose_file_names+=("docker-compose.instance-ai.yml")
            provider=$(get_env_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "n8n-sandbox")
            if [ "$provider" = "n8n-sandbox" ]; then
                compose_file_names+=("docker-compose.ai-sandbox.yml")
                isolation=$(get_env_value "N8N_SANDBOX_ISOLATION" "sysbox")
                compose_file_names+=("docker-compose.ai-sandbox.${isolation}.yml")
            elif [ "$provider" = "daytona" ]; then
                compose_file_names+=("docker-compose.ai-daytona.yml")
            fi
        fi
        [ "$RUNTIME" = "podman" ] && compose_file_names+=("docker-compose.podman.yml")
        [ -f "${PROJECT_DIR}/docker-compose.override.yml" ] && compose_file_names+=("docker-compose.override.yml")

        for compose_file in "${compose_file_names[@]}"; do
            [ -n "$joined_files" ] && joined_files+="$separator"
            joined_files+="$compose_file"
        done
        set_env_value "COMPOSE_FILE" "$joined_files"
        echo -e "${CYAN}Persisted Compose file list:${NC} ${joined_files}"
    fi

    provider=$(get_env_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "")
    if [ "$(get_env_value "ENABLE_AI_ASSISTANT" "false")" = "true" ] && [ "$provider" = "n8n-sandbox" ]; then
        if [ "$RUNTIME" != "docker" ] || [ "$ROOTLESS" = true ]; then
            echo -e "${RED}Error: the self-hosted n8n Sandbox requires rootful Docker.${NC}" >&2
            exit 1
        fi
    fi

    COMPOSE_FILES=""
    for compose_file in "${compose_file_names[@]}"; do
        [ -z "$compose_file" ] && continue
        if [[ "$compose_file" != /* ]]; then compose_file="${PROJECT_DIR}/${compose_file}"; fi
        if [ ! -f "$compose_file" ]; then
            echo -e "${RED}Error: Compose file not found: ${compose_file}${NC}" >&2
            exit 1
        fi
        COMPOSE_FILES="${COMPOSE_FILES} -f ${compose_file}"
    done
    COMPOSE_FILES=${COMPOSE_FILES# }

    echo -e "${CYAN}Compose files:${NC} ${COMPOSE_FILES}"
}

# --- Generate service file ---
generate_service() {
    local service_name="${PROJECT_NAME}"
    local service_file service_write_file service_temp_file=""

    # Rootless engines live in the user's systemd manager. Rootful engines must
    # use the system manager so their shutdown is ordered before the engine.
    if [ "$ROOTLESS" = true ]; then
        SERVICE_TYPE="user"
        local user_dir="${HOME}/.config/systemd/user"
        mkdir -p "$user_dir"
        service_file="${user_dir}/${service_name}.service"
        service_write_file="$service_file"
    else
        SERVICE_TYPE="system"
        service_file="/etc/systemd/system/${service_name}.service"
        if [ "$EUID" -eq 0 ]; then
            service_write_file="$service_file"
        else
            if ! command -v sudo &>/dev/null; then
                echo -e "${RED}Error: sudo is required to install the rootful runtime's system service.${NC}" >&2
                exit 1
            fi
            service_temp_file=$(mktemp)
            service_write_file="$service_temp_file"
        fi
    fi

    echo -e "${CYAN}Generating ${SERVICE_TYPE} service:${NC} ${service_file}"

    local working_dir="${PROJECT_DIR}"
    # This wrapper re-reads the persisted daemon identity and COMPOSE_FILE for
    # every action, so later safe wizard changes do not leave the unit on an old
    # engine or provider stack.
    local stack_script="${PROJECT_DIR}/compose-stack.sh"

    cat > "$service_write_file" <<EOF
[Unit]
Description=n8n Autoscaling Stack
# Keep the stack ahead of either supported local engine during shutdown. The
# wrapper still chooses the current engine dynamically from .env.
After=network-online.target docker.service podman.socket
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${working_dir}
Environment="AUTOSCALER_PROJECT_DIRECTORY=${working_dir}"
ExecStartPre=${stack_script} pull
ExecStart=${stack_script} up
ExecStop=${stack_script} down
ExecReload=${stack_script} reload
TimeoutStartSec=300
TimeoutStopSec=300
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600

[Install]
$([ "$SERVICE_TYPE" = "system" ] && echo "WantedBy=multi-user.target" || echo "WantedBy=default.target")
EOF

    if [ -n "$service_temp_file" ]; then
        if ! sudo install -m 0644 "$service_temp_file" "$service_file"; then
            rm -f "$service_temp_file"
            echo -e "${RED}Error: failed to install ${service_file}.${NC}" >&2
            return 1
        fi
        rm -f "$service_temp_file"
    fi

    echo -e "${GREEN}Service file created:${NC} ${service_file}"
}

# --- Install and enable ---
install_service() {
    local conflict_scope="" invoking_home="$HOME" invoking_user="${SUDO_USER:-}" invoking_uid=""
    local systemctl_display user_systemctl_display
    local -a systemctl_command=(systemctl) user_systemctl=(systemctl --user)
    [ "$EUID" -ne 0 ] && systemctl_command=(sudo systemctl)

    if [ "$SERVICE_TYPE" = "system" ]; then
        if [ "$EUID" -eq 0 ] && [ -n "$invoking_user" ] && [ "$invoking_user" != "root" ]; then
            invoking_home=$(getent passwd "$invoking_user" 2>/dev/null | cut -d: -f6) || true
            [ -z "$invoking_home" ] && invoking_home="/home/${invoking_user}"
            invoking_uid=$(id -u "$invoking_user")
            user_systemctl=(sudo -u "$invoking_user" env "XDG_RUNTIME_DIR=/run/user/${invoking_uid}" systemctl --user)
        fi
        if [ -n "$invoking_home" ] && [ -f "${invoking_home}/.config/systemd/user/${PROJECT_NAME}.service" ] && \
           { "${user_systemctl[@]}" is-active --quiet "${PROJECT_NAME}.service" || \
             "${user_systemctl[@]}" is-enabled --quiet "${PROJECT_NAME}.service"; }; then
            conflict_scope="user"
        fi
    elif [ -f "/etc/systemd/system/${PROJECT_NAME}.service" ] && \
         { systemctl is-active --quiet "${PROJECT_NAME}.service" || \
           systemctl is-enabled --quiet "${PROJECT_NAME}.service"; }; then
        conflict_scope="system"
    fi

    printf -v systemctl_display '%q ' "${systemctl_command[@]}"
    printf -v user_systemctl_display '%q ' "${user_systemctl[@]}"
    systemctl_display=${systemctl_display% }
    user_systemctl_display=${user_systemctl_display% }

    echo ""
    read -p "Enable and start the service now? [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ "$SERVICE_TYPE" = "system" ]; then
            # Avoid two systemd managers issuing lifecycle commands against the
            # same rootful stack after upgrading from an older generated unit.
            if [ "$conflict_scope" = "user" ]; then
                echo -e "${YELLOW}Disabling the old user-scoped unit before starting the system unit.${NC}"
                "${user_systemctl[@]}" disable --now "${PROJECT_NAME}.service"
            fi

            "${systemctl_command[@]}" daemon-reload
            "${systemctl_command[@]}" enable "${PROJECT_NAME}.service"
            if "${systemctl_command[@]}" is-active --quiet "${PROJECT_NAME}.service"; then
                "${systemctl_command[@]}" restart "${PROJECT_NAME}.service"
            else
                "${systemctl_command[@]}" start "${PROJECT_NAME}.service"
            fi
            echo -e "${GREEN}Service enabled and started.${NC}"
            echo -e "  Check status: ${CYAN}systemctl status ${PROJECT_NAME}${NC}"
            echo -e "  View logs:    ${CYAN}journalctl -u ${PROJECT_NAME} -f${NC}"
        else
            if [ "$conflict_scope" = "system" ]; then
                echo -e "${YELLOW}Disabling the old system-scoped unit before starting the rootless user unit.${NC}"
                if [ "$EUID" -ne 0 ] && ! command -v sudo &>/dev/null; then
                    echo -e "${RED}Error: sudo is required to disable the conflicting system unit.${NC}" >&2
                    return 1
                fi
                "${systemctl_command[@]}" disable --now "${PROJECT_NAME}.service"
            fi
            systemctl --user daemon-reload
            systemctl --user enable "${PROJECT_NAME}.service"
            if systemctl --user is-active --quiet "${PROJECT_NAME}.service"; then
                systemctl --user restart "${PROJECT_NAME}.service"
            else
                systemctl --user start "${PROJECT_NAME}.service"
            fi
            # Enable lingering so user services run at boot and after logout.
            local service_account
            service_account=$(id -un)
            if ! loginctl enable-linger "$service_account"; then
                if command -v sudo &>/dev/null; then
                    sudo loginctl enable-linger "$service_account"
                else
                    echo -e "${RED}Error: failed to enable lingering for ${service_account}; rootless boot startup is not configured.${NC}" >&2
                    return 1
                fi
            fi
            echo -e "${GREEN}User service enabled and started.${NC}"
            echo -e "  Check status: ${CYAN}systemctl --user status ${PROJECT_NAME}${NC}"
            echo -e "  View logs:    ${CYAN}journalctl --user -u ${PROJECT_NAME} -f${NC}"
        fi
    else
        echo -e "${YELLOW}Service file created but not enabled.${NC}"
        if [ "$SERVICE_TYPE" = "system" ]; then
            echo "  Safe activation commands:"
            if [ "$conflict_scope" = "user" ]; then
                echo -e "    ${CYAN}${user_systemctl_display} disable --now ${PROJECT_NAME}.service${NC}"
            fi
            echo -e "    ${CYAN}${systemctl_display} daemon-reload${NC}"
            echo -e "    ${CYAN}${systemctl_display} enable --now ${PROJECT_NAME}.service${NC}"
        else
            echo "  Safe activation commands:"
            if [ "$conflict_scope" = "system" ]; then
                echo -e "    ${CYAN}${systemctl_display} disable --now ${PROJECT_NAME}.service${NC}"
            fi
            echo -e "    ${CYAN}loginctl enable-linger $(id -un)${NC}"
            echo -e "    ${CYAN}systemctl --user daemon-reload${NC}"
            echo -e "    ${CYAN}systemctl --user enable --now ${PROJECT_NAME}.service${NC}"
        fi
    fi
}

# --- Main ---
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

echo -e "${CYAN}=== n8n-autoscaling systemd service generator ===${NC}"
echo ""

detect_runtime
echo ""
echo "Building compose file list..."
build_compose_files
echo ""
generate_service
install_service

echo ""
echo -e "${GREEN}Done!${NC}"
