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

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="n8n-autoscaling"

# --- Detect container runtime ---
detect_runtime() {
    if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        RUNTIME="podman"
        COMPOSE_CMD="podman compose"
        # Check if rootless
        if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
            ROOTLESS=true
        else
            ROOTLESS=false
        fi
    elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        RUNTIME="docker"
        COMPOSE_CMD="docker compose"
        # Check if rootless
        if docker info 2>/dev/null | grep -q "rootless"; then
            ROOTLESS=true
        else
            ROOTLESS=false
        fi
    else
        echo -e "${RED}Error: Neither Docker nor Podman found or accessible.${NC}"
        exit 1
    fi
    echo -e "${CYAN}Detected runtime:${NC} ${RUNTIME} (rootless: ${ROOTLESS})"
}

# --- Build compose file list ---
build_compose_files() {
    COMPOSE_FILES="-f ${PROJECT_DIR}/docker-compose.yml"

    # Check .env for enabled features
    if [ -f "${PROJECT_DIR}/.env" ]; then
        # Cloudflare override
        if grep -q "^ENABLE_CLOUDFLARE_OVERRIDE=true" "${PROJECT_DIR}/.env" 2>/dev/null; then
            if [ -f "${PROJECT_DIR}/docker-compose.cloudflare.yml" ]; then
                COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_DIR}/docker-compose.cloudflare.yml"
                echo -e "  ${GREEN}+${NC} Cloudflare tunnel override"
            fi
        fi
    fi

    # Podman override (auto-detected)
    if [ "$RUNTIME" = "podman" ]; then
        if [ -f "${PROJECT_DIR}/docker-compose.podman.yml" ]; then
            COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_DIR}/docker-compose.podman.yml"
            echo -e "  ${GREEN}+${NC} Podman rootless override"
        fi
    fi

    echo -e "${CYAN}Compose files:${NC} ${COMPOSE_FILES}"
}

# --- Generate service file ---
generate_service() {
    local service_name="${PROJECT_NAME}"
    local service_file

    # Determine if system or user service
    if [ "$EUID" -eq 0 ] && [ "$ROOTLESS" = false ]; then
        SERVICE_TYPE="system"
        service_file="/etc/systemd/system/${service_name}.service"
    else
        SERVICE_TYPE="user"
        local user_dir="${HOME}/.config/systemd/user"
        mkdir -p "$user_dir"
        service_file="${user_dir}/${service_name}.service"
    fi

    echo -e "${CYAN}Generating ${SERVICE_TYPE} service:${NC} ${service_file}"

    local working_dir="${PROJECT_DIR}"
    local exec_start="${COMPOSE_CMD} ${COMPOSE_FILES} up -d --remove-orphans"
    local exec_stop="${COMPOSE_CMD} ${COMPOSE_FILES} down"

    cat > "$service_file" <<EOF
[Unit]
Description=n8n Autoscaling Stack
After=network-online.target
Wants=network-online.target
$([ "$RUNTIME" = "docker" ] && echo "Requires=docker.service" || echo "# Podman - no service dependency needed for rootless")

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${working_dir}
$([ "$ROOTLESS" = true ] && echo "Environment=XDG_RUNTIME_DIR=/run/user/$(id -u)" || true)
ExecStartPre=${COMPOSE_CMD} ${COMPOSE_FILES} pull --ignore-pull-failures
ExecStart=${exec_start}
ExecStop=${exec_stop}
ExecReload=${COMPOSE_CMD} ${COMPOSE_FILES} up -d --remove-orphans
TimeoutStartSec=300
TimeoutStopSec=300
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600

[Install]
$([ "$SERVICE_TYPE" = "system" ] && echo "WantedBy=multi-user.target" || echo "WantedBy=default.target")
EOF

    echo -e "${GREEN}Service file created:${NC} ${service_file}"
}

# --- Install and enable ---
install_service() {
    echo ""
    read -p "Enable and start the service now? [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ "$SERVICE_TYPE" = "system" ]; then
            systemctl daemon-reload
            systemctl enable "${PROJECT_NAME}.service"
            systemctl start "${PROJECT_NAME}.service"
            echo -e "${GREEN}Service enabled and started.${NC}"
            echo -e "  Check status: ${CYAN}systemctl status ${PROJECT_NAME}${NC}"
            echo -e "  View logs:    ${CYAN}journalctl -u ${PROJECT_NAME} -f${NC}"
        else
            systemctl --user daemon-reload
            systemctl --user enable "${PROJECT_NAME}.service"
            systemctl --user start "${PROJECT_NAME}.service"
            # Enable lingering so user services run after logout
            loginctl enable-linger "$(whoami)" 2>/dev/null || true
            echo -e "${GREEN}User service enabled and started.${NC}"
            echo -e "  Check status: ${CYAN}systemctl --user status ${PROJECT_NAME}${NC}"
            echo -e "  View logs:    ${CYAN}journalctl --user -u ${PROJECT_NAME} -f${NC}"
        fi
    else
        echo -e "${YELLOW}Service file created but not enabled.${NC}"
        if [ "$SERVICE_TYPE" = "system" ]; then
            echo -e "  Enable:  ${CYAN}systemctl enable --now ${PROJECT_NAME}${NC}"
        else
            echo -e "  Enable:  ${CYAN}systemctl --user enable --now ${PROJECT_NAME}${NC}"
        fi
    fi
}

# --- Main ---
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
