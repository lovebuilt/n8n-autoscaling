#!/bin/bash
# n8n-autoscaling setup wizard
# Interactive setup for the n8n autoscaling stack.
# Adapted from pie-rs/n8n-autoscaling fork.

set -e

# Colors
if command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# ============================================================
# Utility Functions
# ============================================================

get_existing_value() {
    local key="$1" default="$2"
    if [ -f .env ]; then
        local value
        value=$(grep "^$key=" .env 2>/dev/null | cut -d'=' -f2- | sed 's/#.*//' | xargs) || true
        if [ -n "$value" ]; then echo "$value"; else echo "$default"; fi
    else
        echo "$default"
    fi
}

set_env_value() {
    local key="$1" value="$2" escaped
    escaped=${value//\\/\\\\}
    escaped=${escaped//&/\\&}
    escaped=${escaped//|/\\|}

    if grep -q "^${key}=" .env 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" .env
    elif grep -q "^#${key}=" .env 2>/dev/null; then
        sed -i.bak "s|^#${key}=.*|${key}=${escaped}|" .env
    else
        printf '\n%s=%s\n' "$key" "$value" >> .env
    fi
}

unset_env_value() {
    local key="$1"
    if grep -q "^${key}=" .env 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|#${key}=|" .env
    fi
}

secret_is_usable() {
    local value="$1"
    [ -n "$value" ] && [[ ! "$value" =~ ^(YOUR|REPLACE|GENERATE|change-me) ]] && \
        [ "$value" != "changeme" ] && [ "$value" != "password" ] && \
        [ "$value" != "secret" ] && [ "$value" != "test" ] && [ "$value" != "123456" ]
}

ensure_secret_pair() {
    local first_key="$1" second_key="$2" first_value second_value value
    first_value=$(get_existing_value "$first_key" "")
    second_value=$(get_existing_value "$second_key" "")

    if secret_is_usable "$first_value"; then
        value="$first_value"
    elif secret_is_usable "$second_value"; then
        value="$second_value"
    else
        value=$(openssl rand -hex 32)
    fi

    if [ "${#value}" -lt 32 ]; then
        echo "${YELLOW}Warning: preserving an existing short value for $first_key/$second_key; rotate it when practical.${NC}" >&2
    fi

    set_env_value "$first_key" "$value"
    set_env_value "$second_key" "$value"
}

# Keep a single client key valid against a server's comma-separated accepted
# key list. This preserves overlap during rotations instead of copying the
# entire list into a client key field.
ensure_client_key_in_list() {
    local list_key="$1" client_key="$2" list_value client_value selected_value=""
    local item new_list=""
    local -a list_items
    list_value=$(get_existing_value "$list_key" "")
    client_value=$(get_existing_value "$client_key" "")

    if secret_is_usable "$client_value" && [[ "$client_value" != *,* ]]; then
        selected_value="$client_value"
    else
        local IFS=','
        read -ra list_items <<< "$list_value"
        for item in "${list_items[@]}"; do
            item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if secret_is_usable "$item"; then
                selected_value="$item"
            fi
        done
    fi

    if [ -z "$selected_value" ]; then
        selected_value=$(openssl rand -hex 32)
    fi

    if [ "${#selected_value}" -lt 32 ]; then
        echo "${YELLOW}Warning: preserving an existing short client key for $list_key; rotate it when practical.${NC}" >&2
    fi

    local IFS=','
    read -ra list_items <<< "$list_value"
    local selected_present=false
    for item in "${list_items[@]}"; do
        item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if secret_is_usable "$item"; then
            [ -n "$new_list" ] && new_list+=","
            new_list+="$item"
            [ "$item" = "$selected_value" ] && selected_present=true
        fi
    done
    if [ "$selected_present" = "false" ]; then
        [ -n "$new_list" ] && new_list+=","
        new_list+="$selected_value"
    fi

    set_env_value "$list_key" "$new_list"
    set_env_value "$client_key" "$selected_value"
}

ensure_secret() {
    local key="$1" value
    value=$(get_existing_value "$key" "")
    if ! secret_is_usable "$value"; then
        value=$(openssl rand -hex 32)
        set_env_value "$key" "$value"
    elif [ "${#value}" -lt 32 ]; then
        echo "${YELLOW}Warning: preserving an existing short value for $key; rotate it when practical.${NC}" >&2
    fi
}

ensure_default_value() {
    local key="$1" default_value="$2"
    if [ -z "$(get_existing_value "$key" "")" ]; then
        set_env_value "$key" "$default_value"
    fi
}

ensure_csv_value() {
    local key="$1" required_value="$2" current_value
    current_value=$(get_existing_value "$key" "")
    if [ -z "$current_value" ]; then
        set_env_value "$key" "$required_value"
    elif [[ ",$current_value," != *",$required_value,"* ]]; then
        set_env_value "$key" "${current_value},${required_value}"
    fi
}

remove_csv_value() {
    local key="$1" removed_value="$2" current_value item joined=""
    local -a current_items
    current_value=$(get_existing_value "$key" "")
    local IFS=','
    read -ra current_items <<< "$current_value"
    for item in "${current_items[@]}"; do
        item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$item" ] && continue
        [ "$item" = "$removed_value" ] && continue
        [ -n "$joined" ] && joined+=","
        joined+="$item"
    done
    set_env_value "$key" "$joined"
}

infer_runtime_mode_from_socket() {
    case "${1:-}" in
        /run/user/*) echo "rootless" ;;
        /var/run/docker.sock|/run/docker.sock|/run/podman/podman.sock) echo "rootful" ;;
        *) echo "" ;;
    esac
}

runtime_identity_changed() {
    [ "$1" != "$4" ] || [ "$2" != "$5" ] || [ "$3" != "$6" ]
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

detect_timezone() {
    if [ -f /etc/timezone ]; then
        cat /etc/timezone
    elif [ -L /etc/localtime ]; then
        readlink /etc/localtime | sed 's|.*/zoneinfo/||'
    elif command -v timedatectl &>/dev/null; then
        timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC"
    else
        echo "UTC"
    fi
}

validate_url() {
    local url="$1"
    if [ -z "$url" ]; then
        echo "${RED}URL cannot be empty${NC}"; return 1
    fi
    if [[ "$url" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        echo "${RED}Invalid domain format. Use: example.com or subdomain.example.com (no https://)${NC}"; return 1
    fi
}

validate_ip_address() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        echo "${RED}Invalid IP format. Use: 192.168.1.100${NC}"; return 1
    fi
}

validate_timezone() {
    local tz="$1"
    if [ -z "$tz" ]; then echo "${RED}Timezone cannot be empty${NC}"; return 1; fi
    if [ "$tz" = "UTC" ] || [ "$tz" = "GMT" ]; then return 0; fi
    if [[ "$tz" =~ ^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]; then
        return 0
    fi
    echo "${RED}Invalid timezone. Use: UTC, America/New_York, Europe/London, etc.${NC}"; return 1
}

# Return the ordered Compose file list managed by this wizard, preserving any
# user-supplied custom overrides after the managed files.
compose_file_list() {
    local runtime="$1" separator current_file base_name provider isolation
    local -a files custom_files
    separator=$(get_existing_value "COMPOSE_PATH_SEPARATOR" ":")
    files=("docker-compose.yml")

    if [ -f .env ] && grep -q "^ENABLE_CLOUDFLARE_OVERRIDE=true" .env 2>/dev/null; then
        [ -f docker-compose.cloudflare.yml ] && files+=("docker-compose.cloudflare.yml")
    fi

    if [ "$(get_existing_value "ENABLE_AI_ASSISTANT" "false")" = "true" ]; then
        files+=("docker-compose.instance-ai.yml")
        provider=$(get_existing_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "n8n-sandbox")
        if [ "$provider" = "n8n-sandbox" ]; then
            files+=("docker-compose.ai-sandbox.yml")
            isolation=$(get_existing_value "N8N_SANDBOX_ISOLATION" "sysbox")
            if [ "$isolation" = "privileged" ]; then
                files+=("docker-compose.ai-sandbox.privileged.yml")
            else
                files+=("docker-compose.ai-sandbox.sysbox.yml")
            fi
        elif [ "$provider" = "daytona" ]; then
            files+=("docker-compose.ai-daytona.yml")
        fi
    fi

    [ "$runtime" = "podman" ] && [ -f docker-compose.podman.yml ] && files+=("docker-compose.podman.yml")

    # Setting COMPOSE_FILE disables Compose's implicit override discovery, so
    # retain both explicit custom files and the conventional override file.
    current_file=$(get_existing_value "COMPOSE_FILE" "")
    if [ -n "$current_file" ]; then
        local IFS="$separator"
        read -ra configured_files <<< "$current_file"
        for current_file in "${configured_files[@]}"; do
            [ -z "$current_file" ] && continue
            base_name=${current_file##*/}
            case "$base_name" in
                docker-compose.yml|docker-compose.cloudflare.yml|docker-compose.instance-ai.yml|docker-compose.ai-daytona.yml|docker-compose.ai-sandbox.yml|docker-compose.ai-sandbox.sysbox.yml|docker-compose.ai-sandbox.privileged.yml|docker-compose.podman.yml)
                    ;;
                *) custom_files+=("$current_file") ;;
            esac
        done
    fi
    if [ -f docker-compose.override.yml ]; then
        local found_override=false
        for current_file in "${custom_files[@]}"; do
            [ "$current_file" = "docker-compose.override.yml" ] && found_override=true
        done
        [ "$found_override" = "false" ] && custom_files+=("docker-compose.override.yml")
    fi
    files+=("${custom_files[@]}")

    local joined=""
    for current_file in "${files[@]}"; do
        [ -n "$joined" ] && joined+="$separator"
        joined+="$current_file"
    done
    echo "$joined"
}

sync_compose_file_env() {
    local runtime="$1"
    set_env_value "COMPOSE_FILE" "$(compose_file_list "$runtime")"
}

# Build command-line flags from the same list used by plain `docker compose`.
build_compose_files() {
    local runtime="$1" separator compose_files compose_file flags=""
    separator=$(get_existing_value "COMPOSE_PATH_SEPARATOR" ":")
    compose_files=$(compose_file_list "$runtime")
    local IFS="$separator"
    read -ra configured_files <<< "$compose_files"
    for compose_file in "${configured_files[@]}"; do
        [ -n "$compose_file" ] && flags="$flags -f $compose_file"
    done
    echo "${flags# }"
}

# ============================================================
# Container Lifecycle
# ============================================================

stop_all_containers_force() {
    echo "${BLUE}Stopping all containers...${NC}"
    local configured_runtime compose_files
    configured_runtime=$(get_existing_value "CONTAINER_RUNTIME" "docker")
    compose_files=$(build_compose_files "$configured_runtime")
    docker compose $compose_files down -v --remove-orphans 2>/dev/null || true
    podman compose $compose_files down -v --remove-orphans 2>/dev/null || true
    docker ps -a --filter "name=n8n" -q 2>/dev/null | xargs -r docker stop 2>/dev/null || true
    docker ps -a --filter "name=n8n" -q 2>/dev/null | xargs -r docker rm 2>/dev/null || true
    podman ps -a --filter "name=n8n" -q 2>/dev/null | xargs -r podman stop 2>/dev/null || true
    podman ps -a --filter "name=n8n" -q 2>/dev/null | xargs -r podman rm 2>/dev/null || true
}

remove_rootless_directory() {
    local dir="$1"
    if rm -rf "$dir" 2>/dev/null; then return 0; fi
    echo "${BLUE}Handling rootless permissions for $dir...${NC}"
    if [ -d "$dir" ]; then
        if command -v podman &>/dev/null; then
            podman run --rm -v "$(pwd)/$dir:/data:Z" alpine:latest sh -c "rm -rf /data/*" 2>/dev/null || true
        elif command -v docker &>/dev/null; then
            docker run --rm -v "$(pwd)/$dir:/data" alpine:latest sh -c "rm -rf /data/*" 2>/dev/null || true
        fi
        rmdir "$dir" 2>/dev/null || true
        if [ -d "$dir" ] && command -v sudo &>/dev/null; then
            echo "${YELLOW}Directory $dir still exists. Use sudo to remove? [y/N]: ${NC}"
            read -r use_sudo
            [[ "$use_sudo" =~ ^[Yy] ]] && sudo rm -rf "$dir" 2>/dev/null || true
        fi
    fi
}

reset_environment() {
    echo "${YELLOW}WARNING: This will delete all data and configuration!${NC}"
    echo ""
    echo "What would you like to reset?"
    echo "1. Everything (recommended for clean start)"
    echo "2. Just Docker volumes (keep .env file)"
    echo "3. Just .env file (keep volumes)"
    echo "4. Cancel"
    echo -n "Enter your choice [1-4]: "
    read -r reset_choice
    case "$reset_choice" in
        1)
            stop_all_containers_force
            echo "${BLUE}Pruning volumes...${NC}"
            docker volume prune -f 2>/dev/null || true
            podman volume prune -f 2>/dev/null || true
            rm -f .env .env.bak
            echo "${GREEN}Environment reset complete${NC}"
            echo -n "Run the setup wizard now? [Y/n]: "
            read -r r; [[ -z "$r" || "$r" =~ ^[Yy] ]] && return 0 || exit 0
            ;;
        2)
            stop_all_containers_force
            docker volume prune -f 2>/dev/null || true
            podman volume prune -f 2>/dev/null || true
            echo "${GREEN}Volumes reset complete${NC}"; exit 0
            ;;
        3)
            rm -f .env .env.bak
            echo "${GREEN}.env file removed${NC}"
            echo "${YELLOW}Note: Existing data won't work with new passwords!${NC}"
            return 0
            ;;
        *) echo "${BLUE}Cancelled${NC}"; exit 0 ;;
    esac
}

# ============================================================
# Main Menu
# ============================================================

# Allow the helper functions above to be sourced by tests and maintenance
# tooling without launching the interactive wizard.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

echo "${CYAN}n8n-autoscaling Setup Wizard${NC}"
echo "============================"
echo ""

# Check for existing setup
if [ -f .env ]; then
    SETUP_COMPLETE=$(grep "^SETUP_COMPLETED=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ "$SETUP_COMPLETE" = "true" ]; then
        echo "${GREEN}Setup has been completed previously.${NC}"
        echo ""
        echo "What would you like to do?"
        echo "1. Run full setup wizard"
        echo "2. Reset environment (clean start)"
        echo "3. Set up systemd services"
        echo "4. Exit"
        echo -n "Enter your choice [1-4]: "
        read -r choice
        case "$choice" in
            1) echo "${BLUE}Running setup wizard...${NC}"; echo "" ;;
            2) reset_environment ;;
            3) ./generate-systemd.sh; exit 0 ;;
            *) exit 0 ;;
        esac
    else
        echo "${YELLOW}Found partial setup (.env exists but setup not completed)${NC}"
        echo ""
        echo "1. Run full setup wizard"
        echo "2. Reset environment"
        echo "3. Exit"
        echo -n "Enter your choice [1-3]: "
        read -r choice
        case "$choice" in
            1) echo "" ;;
            2) reset_environment ;;
            *) exit 0 ;;
        esac
    fi
fi

# ============================================================
# Step 1: Create .env from template
# ============================================================

echo "${BLUE}Step 1: Environment File${NC}"
echo "------------------------"

PRESERVE_EXISTING=false
if [ -f .env ]; then
    echo "${YELLOW}.env file already exists.${NC}"
    echo -n "Overwrite it? [y/N]: "
    read -r r
    if [[ "$r" =~ ^[Yy] ]]; then
        rm -f .env
    else
        echo "${BLUE}Using existing .env file.${NC}"
        PRESERVE_EXISTING=true
    fi
fi

if [ ! -f .env ]; then
    cp .env.example .env
    echo "${GREEN}Created .env file from .env.example${NC}"
fi

# Protect existing credentials immediately. The wizard may exit before the
# final cleanup step, so do not wait until setup completes to restrict access.
chmod 600 .env

# Record the tested server/runner pair so a future repository default cannot
# silently upgrade an existing installation when the wizard is rerun.
ensure_default_value "N8N_VERSION" "2.36.8"

# ============================================================
# Step 2: Secret Generation
# ============================================================

echo ""
echo "${BLUE}Step 2: Secret Generation${NC}"
echo "-------------------------"

SKIP_SECRETS=false
if [ "$PRESERVE_EXISTING" = "true" ]; then
    EXISTING_REDIS_PW=$(get_existing_value "REDIS_PASSWORD" "")
    EXISTING_PG_PW=$(get_existing_value "POSTGRES_PASSWORD" "")
    EXISTING_ENC_KEY=$(get_existing_value "N8N_ENCRYPTION_KEY" "")

    INSECURE_DEFAULTS="YOURPASSWORD YOURKEY YOURREDISPASSWORD YOURADMINPASSWORD YOURAPPPASSWORD changeme password 123456"
    SECRETS_SECURE=true
    for d in $INSECURE_DEFAULTS; do
        if [ "$EXISTING_REDIS_PW" = "$d" ] || [ "$EXISTING_PG_PW" = "$d" ] || [ "$EXISTING_ENC_KEY" = "$d" ]; then
            SECRETS_SECURE=false; break
        fi
    done

    if [ "$SECRETS_SECURE" = "true" ] && [ -n "$EXISTING_REDIS_PW" ] && [ -n "$EXISTING_PG_PW" ] && [ -n "$EXISTING_ENC_KEY" ]; then
        echo "${GREEN}Found existing secure passwords.${NC}"
        echo -n "Keep existing passwords? [Y/n]: "
        read -r r
        [[ -z "$r" || "$r" =~ ^[Yy] ]] && SKIP_SECRETS=true
    else
        echo "${YELLOW}Existing passwords appear insecure or incomplete.${NC}"
    fi
fi

if [ "$SKIP_SECRETS" != "true" ]; then
    echo -n "Generate secure random secrets? [Y/n]: "
    read -r r
    if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
        echo -n "Enter a salt for secret generation [press Enter for random]: "
        read -r SALT
        [ -z "$SALT" ] && SALT=$(openssl rand -hex 16)

        echo "${BLUE}Generating secrets...${NC}"
        REDIS_PASSWORD=$(echo -n "${SALT}redis$(date +%s)" | sha256sum | cut -c1-32)
        POSTGRES_ADMIN_PASSWORD=$(echo -n "${SALT}pgadmin$(date +%s)" | sha256sum | cut -c1-32)
        POSTGRES_APP_PASSWORD=$(echo -n "${SALT}pgapp$(date +%s)" | sha256sum | cut -c1-32)
        N8N_ENCRYPTION_KEY=$(echo -n "${SALT}encrypt$(date +%s)" | sha256sum | cut -c1-64)
        N8N_JWT_SECRET=$(echo -n "${SALT}jwt$(date +%s)" | sha256sum | cut -c1-64)
        N8N_RUNNERS_AUTH=$(echo -n "${SALT}runners$(date +%s)" | sha256sum | cut -c1-32)

        sed -i.bak "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" .env
        sed -i.bak "s/^POSTGRES_ADMIN_PASSWORD=.*/POSTGRES_ADMIN_PASSWORD=$POSTGRES_ADMIN_PASSWORD/" .env
        sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$POSTGRES_APP_PASSWORD/" .env
        sed -i.bak "s/^POSTGRES_APP_PASSWORD=.*/POSTGRES_APP_PASSWORD=$POSTGRES_APP_PASSWORD/" .env
        sed -i.bak "s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY/" .env
        sed -i.bak "s/^N8N_USER_MANAGEMENT_JWT_SECRET=.*/N8N_USER_MANAGEMENT_JWT_SECRET=$N8N_JWT_SECRET/" .env
        sed -i.bak "s/^N8N_RUNNERS_AUTH_TOKEN=.*/N8N_RUNNERS_AUTH_TOKEN=$N8N_RUNNERS_AUTH/" .env

        echo "${GREEN}Secrets generated and saved to .env${NC}"
    else
        echo "${YELLOW}You'll need to manually update passwords in .env${NC}"
    fi
fi

# ============================================================
# Step 3: Timezone
# ============================================================

echo ""
echo "${BLUE}Step 3: Timezone${NC}"
echo "----------------"

DETECTED_TZ=$(detect_timezone)
CURRENT_TZ=$(get_existing_value "GENERIC_TIMEZONE" "$DETECTED_TZ")
echo "${BLUE}System timezone: $DETECTED_TZ | Current in .env: $CURRENT_TZ${NC}"

# Build timezone list from system zoneinfo
TIMEZONE_LIST=()
if [ -d /usr/share/zoneinfo ]; then
    while IFS= read -r tz; do
        TIMEZONE_LIST+=("$tz")
    done < <(find /usr/share/zoneinfo/posix -type f 2>/dev/null \
        | sed 's|.*/zoneinfo/posix/||' \
        | grep -E '^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/' \
        | sort)
fi

# Fallback if zoneinfo not available
if [ ${#TIMEZONE_LIST[@]} -eq 0 ]; then
    TIMEZONE_LIST=(
        "UTC"
        "America/New_York" "America/Chicago" "America/Denver" "America/Los_Angeles"
        "America/Anchorage" "America/Phoenix" "America/Toronto" "America/Vancouver"
        "America/Mexico_City" "America/Sao_Paulo" "America/Argentina/Buenos_Aires"
        "Europe/London" "Europe/Paris" "Europe/Berlin" "Europe/Madrid" "Europe/Rome"
        "Europe/Amsterdam" "Europe/Stockholm" "Europe/Moscow" "Europe/Istanbul"
        "Asia/Tokyo" "Asia/Shanghai" "Asia/Hong_Kong" "Asia/Singapore" "Asia/Seoul"
        "Asia/Kolkata" "Asia/Dubai" "Asia/Bangkok" "Asia/Taipei" "Asia/Jakarta"
        "Australia/Sydney" "Australia/Melbourne" "Australia/Perth" "Australia/Brisbane"
        "Pacific/Auckland" "Pacific/Honolulu" "Pacific/Fiji"
        "Africa/Cairo" "Africa/Lagos" "Africa/Johannesburg" "Africa/Nairobi"
    )
fi

# Get unique regions for the first selection
REGIONS=()
for tz in "${TIMEZONE_LIST[@]}"; do
    region="${tz%%/*}"
    if [[ ! " ${REGIONS[*]} " =~ " $region " ]]; then
        REGIONS+=("$region")
    fi
done

while true; do
    echo ""
    echo "Select a region:"
    for i in "${!REGIONS[@]}"; do
        # Mark the detected region
        marker=""
        if [[ "$DETECTED_TZ" == "${REGIONS[$i]}"/* ]] || [ "$DETECTED_TZ" = "${REGIONS[$i]}" ]; then
            marker=" ${CYAN}(detected)${NC}"
        fi
        echo -e "  $((i+1)). ${REGIONS[$i]}$marker"
    done
    echo ""
    echo -n "Region [1-${#REGIONS[@]}]: "
    read -r region_choice

    if ! [[ "$region_choice" =~ ^[0-9]+$ ]] || [ "$region_choice" -lt 1 ] || [ "$region_choice" -gt ${#REGIONS[@]} ]; then
        echo "${RED}Invalid choice${NC}"; continue
    fi

    SELECTED_REGION="${REGIONS[$((region_choice-1))]}"

    # Filter timezones for selected region
    REGION_TZS=()
    for tz in "${TIMEZONE_LIST[@]}"; do
        if [[ "$tz" == "$SELECTED_REGION"/* ]] || [ "$tz" = "$SELECTED_REGION" ]; then
            REGION_TZS+=("$tz")
        fi
    done

    # Handle UTC/single-entry regions
    if [ ${#REGION_TZS[@]} -eq 0 ]; then
        REGION_TZS=("$SELECTED_REGION")
    fi

    # Display cities in pages of 20
    PAGE_SIZE=20
    TOTAL=${#REGION_TZS[@]}
    PAGE=0

    while true; do
        START=$((PAGE * PAGE_SIZE))
        END=$((START + PAGE_SIZE))
        [ "$END" -gt "$TOTAL" ] && END=$TOTAL

        echo ""
        echo "Select a timezone in ${CYAN}$SELECTED_REGION${NC} (showing $((START+1))-$END of $TOTAL):"
        for ((i=START; i<END; i++)); do
            city="${REGION_TZS[$i]#*/}"
            marker=""
            if [ "${REGION_TZS[$i]}" = "$DETECTED_TZ" ]; then
                marker=" ${CYAN}(detected)${NC}"
            fi
            echo -e "  $((i+1)). ${city//_/ }$marker"
        done

        echo ""
        if [ "$END" -lt "$TOTAL" ]; then
            echo "  n. Next page | b. Back to regions"
        else
            echo "  b. Back to regions"
        fi
        echo -n "Choice [1-$TOTAL]: "
        read -r tz_choice

        if [ "$tz_choice" = "n" ] && [ "$END" -lt "$TOTAL" ]; then
            PAGE=$((PAGE + 1)); continue
        elif [ "$tz_choice" = "b" ]; then
            break
        elif [[ "$tz_choice" =~ ^[0-9]+$ ]] && [ "$tz_choice" -ge 1 ] && [ "$tz_choice" -le "$TOTAL" ]; then
            SELECTED_TZ="${REGION_TZS[$((tz_choice-1))]}"
            sed -i.bak "s|^GENERIC_TIMEZONE=.*|GENERIC_TIMEZONE=$SELECTED_TZ|" .env
            echo "${GREEN}Timezone set to: $SELECTED_TZ${NC}"
            break 2
        else
            echo "${RED}Invalid choice${NC}"
        fi
    done
done

# ============================================================
# Step 4: URL Configuration
# ============================================================

echo ""
echo "${BLUE}Step 4: URL Configuration${NC}"
echo "-------------------------"

CURRENT_HOST=$(get_existing_value "N8N_HOST" "n8n.domain.com")
CURRENT_WEBHOOK=$(get_existing_value "N8N_WEBHOOK" "webhook.domain.com")

# n8n host
while true; do
    echo -n "n8n domain (without https://) [$CURRENT_HOST]: "
    read -r host_input
    [ -z "$host_input" ] && host_input="$CURRENT_HOST"
    if validate_url "$host_input"; then
        N8N_HOST="$host_input"; break
    fi
done

# Webhook host
while true; do
    echo -n "Webhook domain (without https://) [$CURRENT_WEBHOOK]: "
    read -r webhook_input
    [ -z "$webhook_input" ] && webhook_input="$CURRENT_WEBHOOK"
    if validate_url "$webhook_input"; then
        N8N_WEBHOOK="$webhook_input"; break
    fi
done

sed -i.bak "s|^N8N_HOST=.*|N8N_HOST=$N8N_HOST|" .env
sed -i.bak "s|^N8N_WEBHOOK=.*|N8N_WEBHOOK=$N8N_WEBHOOK|" .env
sed -i.bak "s|^N8N_WEBHOOK_URL=.*|N8N_WEBHOOK_URL=https://$N8N_WEBHOOK|" .env
sed -i.bak "s|^WEBHOOK_URL=.*|WEBHOOK_URL=https://$N8N_WEBHOOK|" .env
sed -i.bak "s|^N8N_EDITOR_BASE_URL=.*|N8N_EDITOR_BASE_URL=https://$N8N_HOST|" .env
echo "${GREEN}URLs configured: https://$N8N_HOST and https://$N8N_WEBHOOK${NC}"

# ============================================================
# Step 5: Cloudflare Tunnel
# ============================================================

echo ""
echo "${BLUE}Step 5: Cloudflare Tunnel${NC}"
echo "-------------------------"

CURRENT_CF_TOKEN=$(get_existing_value "CLOUDFLARE_TUNNEL_TOKEN" "YOURTOKEN")
if [ "$CURRENT_CF_TOKEN" != "YOURTOKEN" ] && [ -n "$CURRENT_CF_TOKEN" ]; then
    echo "${BLUE}Cloudflare token already configured.${NC}"
    echo -n "Keep current token? [Y/n]: "
    read -r r
    if [[ "$r" =~ ^[Nn] ]]; then
        echo -n "Enter Cloudflare tunnel token: "
        read -r cf_token
        [ -n "$cf_token" ] && sed -i.bak "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$cf_token|" .env
    fi
else
    echo "Get your token from: https://dash.cloudflare.com -> Zero Trust -> Access -> Tunnels"
    echo -n "Enter Cloudflare tunnel token (or press Enter to skip): "
    read -r cf_token
    if [ -n "$cf_token" ]; then
        sed -i.bak "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$cf_token|" .env
        echo "${GREEN}Cloudflare tunnel configured${NC}"
    else
        echo "${YELLOW}Cloudflare tunnel skipped - you'll need to configure access another way${NC}"
    fi
fi

# ============================================================
# Step 6: Tailscale (Optional)
# ============================================================

echo ""
echo "${BLUE}Step 6: Tailscale (Optional)${NC}"
echo "----------------------------"
echo "Binds PostgreSQL and Redis ports to your Tailscale IP for private access."
echo "When not set, ports default to 127.0.0.1 (localhost only)."

CURRENT_TS_IP=$(get_existing_value "TAILSCALE_IP" "")

# Auto-detect Tailscale IP if available
DETECTED_TS_IP=""
if command -v tailscale &>/dev/null; then
    DETECTED_TS_IP=$(tailscale ip -4 2>/dev/null || true)
fi

# Determine the default to show
TS_DEFAULT="${CURRENT_TS_IP:-$DETECTED_TS_IP}"

if [ -n "$DETECTED_TS_IP" ]; then
    echo "${GREEN}Detected Tailscale IP: $DETECTED_TS_IP${NC}"
elif [ -n "$CURRENT_TS_IP" ]; then
    echo "${BLUE}Current Tailscale IP: $CURRENT_TS_IP${NC}"
fi

if [ -n "$TS_DEFAULT" ]; then
    echo -n "Tailscale IP [$TS_DEFAULT] (enter 'none' to disable): "
    read -r ts_input
    if [ "$ts_input" = "none" ]; then
        sed -i.bak "s|^TAILSCALE_IP=.*|TAILSCALE_IP=|" .env
        echo "${BLUE}Tailscale disabled - ports will bind to 127.0.0.1${NC}"
    else
        [ -z "$ts_input" ] && ts_input="$TS_DEFAULT"
        if validate_ip_address "$ts_input"; then
            sed -i.bak "s|^TAILSCALE_IP=.*|TAILSCALE_IP=$ts_input|" .env
            echo "${GREEN}Tailscale IP set to: $ts_input${NC}"
        fi
    fi
else
    echo "No Tailscale detected. Enter your Tailscale IP or press Enter to skip."
    echo -n "Tailscale IP (find with: tailscale ip -4): "
    read -r ts_input
    if [ -n "$ts_input" ]; then
        if validate_ip_address "$ts_input"; then
            sed -i.bak "s|^TAILSCALE_IP=.*|TAILSCALE_IP=$ts_input|" .env
            echo "${GREEN}Tailscale IP set to: $ts_input${NC}"
        fi
    else
        echo "${BLUE}Tailscale skipped - ports will bind to 127.0.0.1${NC}"
    fi
fi

# ============================================================
# Step 7: Autoscaling Parameters
# ============================================================

echo ""
echo "${BLUE}Step 7: Autoscaling Parameters${NC}"
echo "------------------------------"

MIN_R=$(get_existing_value "MIN_REPLICAS" "1")
MAX_R=$(get_existing_value "MAX_REPLICAS" "5")
UP_T=$(get_existing_value "SCALE_UP_QUEUE_THRESHOLD" "5")
DOWN_T=$(get_existing_value "SCALE_DOWN_QUEUE_THRESHOLD" "1")

echo "Current: MIN=$MIN_R, MAX=$MAX_R, Scale up at >$UP_T jobs, Scale down at <$DOWN_T job"
echo -n "Customize autoscaling parameters? [y/N]: "
read -r r
if [[ "$r" =~ ^[Yy] ]]; then
    echo -n "Min replicas [$MIN_R]: "; read -r v; [ -n "$v" ] && sed -i.bak "s/^MIN_REPLICAS=.*/MIN_REPLICAS=$v/" .env
    echo -n "Max replicas [$MAX_R]: "; read -r v; [ -n "$v" ] && sed -i.bak "s/^MAX_REPLICAS=.*/MAX_REPLICAS=$v/" .env
    echo -n "Scale up threshold [$UP_T]: "; read -r v; [ -n "$v" ] && sed -i.bak "s/^SCALE_UP_QUEUE_THRESHOLD=.*/SCALE_UP_QUEUE_THRESHOLD=$v/" .env
    echo -n "Scale down threshold [$DOWN_T]: "; read -r v; [ -n "$v" ] && sed -i.bak "s/^SCALE_DOWN_QUEUE_THRESHOLD=.*/SCALE_DOWN_QUEUE_THRESHOLD=$v/" .env
    echo "${GREEN}Autoscaling parameters updated${NC}"
else
    echo "${BLUE}Using current autoscaling settings${NC}"
fi

# ============================================================
# Step 8: Backup Configuration (Optional)
# ============================================================

echo ""
echo "${BLUE}Step 8: Backup Configuration (Optional)${NC}"
echo "----------------------------------------"
echo "Automated backups include PostgreSQL dumps and Redis snapshots."
echo "Backups can be encrypted and uploaded to cloud storage via rclone."

CURRENT_PROFILES=$(get_existing_value "COMPOSE_PROFILES" "")
BACKUP_ENABLED=false
if [[ "$CURRENT_PROFILES" == *"backup"* ]]; then
    BACKUP_ENABLED=true
    echo "${GREEN}Backups are currently enabled.${NC}"
    echo -n "Keep backups enabled? [Y/n]: "
    read -r r
    if [[ "$r" =~ ^[Nn] ]]; then
        sed -i.bak "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=/" .env
        BACKUP_ENABLED=false
        echo "${BLUE}Backups disabled${NC}"
    fi
else
    echo -n "Enable automated backups? [y/N]: "
    read -r r
    if [[ "$r" =~ ^[Yy] ]]; then
        if grep -q "^COMPOSE_PROFILES=" .env 2>/dev/null; then
            sed -i.bak "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=backup/" .env
        elif grep -q "^#COMPOSE_PROFILES=" .env 2>/dev/null; then
            sed -i.bak "s/^#COMPOSE_PROFILES=.*/COMPOSE_PROFILES=backup/" .env
        else
            echo "COMPOSE_PROFILES=backup" >> .env
        fi
        BACKUP_ENABLED=true
        echo "${GREEN}Backups enabled${NC}"
    else
        echo "${BLUE}Backups skipped - enable later by adding COMPOSE_PROFILES=backup to .env${NC}"
    fi
fi

if [ "$BACKUP_ENABLED" = "true" ]; then
    # Schedule
    CURRENT_SCHEDULE=$(get_existing_value "BACKUP_SCHEDULE" "0 2 * * *")
    echo ""
    echo "Backup schedule (cron format):"
    echo "  1. Daily at 2 AM (default)"
    echo "  2. Every 12 hours"
    echo "  3. Every 6 hours"
    echo "  4. Custom cron expression"
    echo -n "Choice [1-4, default 1]: "
    read -r sched_choice
    case "$sched_choice" in
        2) BACKUP_SCHED="0 */12 * * *" ;;
        3) BACKUP_SCHED="0 */6 * * *" ;;
        4)
            echo -n "Enter cron expression [$CURRENT_SCHEDULE]: "
            read -r custom_sched
            BACKUP_SCHED="${custom_sched:-$CURRENT_SCHEDULE}"
            ;;
        *) BACKUP_SCHED="0 2 * * *" ;;
    esac
    sed -i.bak "s|^BACKUP_SCHEDULE=.*|BACKUP_SCHEDULE=$BACKUP_SCHED|" .env
    echo "${GREEN}Schedule: $BACKUP_SCHED${NC}"

    # Retention
    CURRENT_RETENTION=$(get_existing_value "BACKUP_RETENTION_DAYS" "30")
    echo ""
    echo -n "Backup retention in days [$CURRENT_RETENTION]: "
    read -r ret_input
    [ -n "$ret_input" ] && sed -i.bak "s/^BACKUP_RETENTION_DAYS=.*/BACKUP_RETENTION_DAYS=$ret_input/" .env

    # Encryption
    CURRENT_ENC_KEY=$(get_existing_value "BACKUP_ENCRYPTION_KEY" "")
    echo ""
    if [ -n "$CURRENT_ENC_KEY" ]; then
        echo "${GREEN}Backup encryption is configured.${NC}"
        echo -n "Keep current encryption key? [Y/n]: "
        read -r r
        if [[ "$r" =~ ^[Nn] ]]; then
            echo -n "Generate new encryption key? [Y/n]: "
            read -r r
            if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
                NEW_ENC=$(openssl rand -hex 32)
                sed -i.bak "s|^BACKUP_ENCRYPTION_KEY=.*|BACKUP_ENCRYPTION_KEY=$NEW_ENC|" .env
                echo "${GREEN}New encryption key generated${NC}"
            else
                echo -n "Enter encryption key (leave empty to disable): "
                read -r enc_input
                sed -i.bak "s|^BACKUP_ENCRYPTION_KEY=.*|BACKUP_ENCRYPTION_KEY=$enc_input|" .env
            fi
        fi
    else
        echo -n "Enable backup encryption? [y/N]: "
        read -r r
        if [[ "$r" =~ ^[Yy] ]]; then
            NEW_ENC=$(openssl rand -hex 32)
            sed -i.bak "s|^BACKUP_ENCRYPTION_KEY=.*|BACKUP_ENCRYPTION_KEY=$NEW_ENC|" .env
            echo "${GREEN}Encryption key generated and saved${NC}"
            echo "${YELLOW}Keep this key safe - you'll need it to restore backups!${NC}"
        else
            echo "${BLUE}Encryption disabled - backups will be stored unencrypted${NC}"
        fi
    fi

    # Rclone destinations
    CURRENT_RCLONE=$(get_existing_value "BACKUP_RCLONE_DESTINATIONS" "")
    echo ""
    echo "Cloud storage destinations (requires rclone configuration)."
    echo "  Format: remote:bucket/path (comma-separated for multiple)"
    echo "  Example: r2:my-bucket/n8n-backups,s3:backup-bucket/n8n"
    if [ -n "$CURRENT_RCLONE" ]; then
        echo "${BLUE}Current: $CURRENT_RCLONE${NC}"
        echo -n "Keep current destinations? [Y/n]: "
        read -r r
        if [[ "$r" =~ ^[Nn] ]]; then
            echo -n "Enter rclone destinations (or leave empty for local only): "
            read -r rclone_input
            sed -i.bak "s|^BACKUP_RCLONE_DESTINATIONS=.*|BACKUP_RCLONE_DESTINATIONS=$rclone_input|" .env
        fi
    else
        echo -n "Enter rclone destinations (or press Enter for local only): "
        read -r rclone_input
        if [ -n "$rclone_input" ]; then
            sed -i.bak "s|^BACKUP_RCLONE_DESTINATIONS=.*|BACKUP_RCLONE_DESTINATIONS=$rclone_input|" .env
            echo "${GREEN}Destinations: $rclone_input${NC}"
            if [ ! -f backup/rclone.conf ]; then
                echo "${YELLOW}Don't forget to configure backup/rclone.conf (see backup/rclone.conf.example)${NC}"
            fi
        else
            echo "${BLUE}Local-only backups (no cloud upload)${NC}"
        fi
    fi

    # Delete local after upload
    if [ -n "$rclone_input" ] || [ -n "$CURRENT_RCLONE" ]; then
        CURRENT_DELETE=$(get_existing_value "BACKUP_DELETE_LOCAL_AFTER_UPLOAD" "false")
        echo ""
        echo -n "Delete local backups after successful upload? [y/N]: "
        read -r r
        if [[ "$r" =~ ^[Yy] ]]; then
            sed -i.bak "s/^BACKUP_DELETE_LOCAL_AFTER_UPLOAD=.*/BACKUP_DELETE_LOCAL_AFTER_UPLOAD=true/" .env
        else
            sed -i.bak "s/^BACKUP_DELETE_LOCAL_AFTER_UPLOAD=.*/BACKUP_DELETE_LOCAL_AFTER_UPLOAD=false/" .env
        fi
    fi

    # Email notifications
    CURRENT_SMTP=$(get_existing_value "SMTP_HOST" "")
    echo ""
    echo -n "Configure email notifications for backups? [y/N]: "
    read -r r
    if [[ "$r" =~ ^[Yy] ]]; then
        echo -n "SMTP host [$CURRENT_SMTP]: "; read -r v
        [ -n "$v" ] && sed -i.bak "s|^SMTP_HOST=.*|SMTP_HOST=$v|" .env

        CURRENT_SMTP_PORT=$(get_existing_value "SMTP_PORT" "587")
        echo -n "SMTP port [$CURRENT_SMTP_PORT]: "; read -r v
        [ -n "$v" ] && sed -i.bak "s/^SMTP_PORT=.*/SMTP_PORT=$v/" .env

        CURRENT_SMTP_USER=$(get_existing_value "SMTP_USER" "")
        echo -n "SMTP user [$CURRENT_SMTP_USER]: "; read -r v
        [ -n "$v" ] && sed -i.bak "s|^SMTP_USER=.*|SMTP_USER=$v|" .env

        echo -n "SMTP password: "; read -rs v; echo ""
        [ -n "$v" ] && sed -i.bak "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=$v|" .env

        CURRENT_SMTP_TO=$(get_existing_value "SMTP_TO" "")
        echo -n "Notification email [$CURRENT_SMTP_TO]: "; read -r v
        [ -n "$v" ] && sed -i.bak "s|^SMTP_TO=.*|SMTP_TO=$v|" .env

        echo "${GREEN}Email notifications configured${NC}"
    fi

    # Webhook notifications
    CURRENT_WEBHOOK_URL=$(get_existing_value "BACKUP_WEBHOOK_URL" "")
    echo ""
    echo -n "Configure webhook notifications? [y/N]: "
    read -r r
    if [[ "$r" =~ ^[Yy] ]]; then
        echo -n "Webhook URL [$CURRENT_WEBHOOK_URL]: "; read -r v
        [ -n "$v" ] && sed -i.bak "s|^BACKUP_WEBHOOK_URL=.*|BACKUP_WEBHOOK_URL=$v|" .env
        echo "${GREEN}Webhook notification configured${NC}"
    fi

    echo ""
    echo "${GREEN}Backup configuration complete${NC}"
fi

# ============================================================
# Step 9: Container Runtime Detection
# ============================================================

echo ""
echo "${BLUE}Step 9: Container Runtime${NC}"
echo "-------------------------"

CONTAINER_RUNTIME=""
RUNTIME_MODE=""
DOCKER_AVAILABLE=false
PODMAN_AVAILABLE=false
PREVIOUS_CONTAINER_RUNTIME=$(get_existing_value "CONTAINER_RUNTIME" "")
PREVIOUS_RUNTIME_MODE=$(get_existing_value "CONTAINER_RUNTIME_MODE" "")
PREVIOUS_RUNTIME_SOCKET=$(get_existing_value "DOCKER_SOCK" "")
PREVIOUS_RUNTIME_SOCKET=${PREVIOUS_RUNTIME_SOCKET#unix://}
SETUP_WAS_COMPLETED=$(get_existing_value "SETUP_COMPLETED" "false")

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
fi
if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    PODMAN_AVAILABLE=true
fi

COMPOSE_PROJECT=$(get_existing_value "COMPOSE_PROJECT_NAME" "n8n-autoscaling")
DOCKER_PROJECT_HAS_DATA=false
PODMAN_PROJECT_HAS_DATA=false
if [ "$DOCKER_AVAILABLE" = "true" ]; then
    if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null)" ] || \
       docker volume inspect "${COMPOSE_PROJECT}_postgres_data" &>/dev/null || \
       docker volume inspect "${COMPOSE_PROJECT}_n8n_main" &>/dev/null; then
        DOCKER_PROJECT_HAS_DATA=true
    fi
fi
if [ "$PODMAN_AVAILABLE" = "true" ]; then
    if [ -n "$(podman ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null)" ] || \
       podman volume inspect "${COMPOSE_PROJECT}_postgres_data" &>/dev/null || \
       podman volume inspect "${COMPOSE_PROJECT}_n8n_main" &>/dev/null; then
        PODMAN_PROJECT_HAS_DATA=true
    fi
fi

if [ -z "$PREVIOUS_CONTAINER_RUNTIME" ]; then
    if [ "$DOCKER_PROJECT_HAS_DATA" = "true" ] && [ "$PODMAN_PROJECT_HAS_DATA" = "true" ]; then
        echo "${RED}Existing $COMPOSE_PROJECT data was found in both Docker and Podman.${NC}"
        echo "Resolve which engine owns the authoritative deployment before rerunning the wizard."
        exit 1
    elif [ "$DOCKER_PROJECT_HAS_DATA" = "true" ]; then
        PREVIOUS_CONTAINER_RUNTIME="docker"
        echo "${YELLOW}Legacy configuration: inferred Docker from existing project containers/volumes.${NC}"
    elif [ "$PODMAN_PROJECT_HAS_DATA" = "true" ]; then
        PREVIOUS_CONTAINER_RUNTIME="podman"
        echo "${YELLOW}Legacy configuration: inferred Podman from existing project containers/volumes.${NC}"
    fi
    if [ -z "$PREVIOUS_CONTAINER_RUNTIME" ] && [ "$(get_existing_value "SETUP_COMPLETED" "false")" = "true" ]; then
        echo "${RED}Legacy setup has no recorded runtime and no engine-local project data could be identified.${NC}"
        echo "Restore access to the previous engine or set CONTAINER_RUNTIME only after verifying where the data lives."
        exit 1
    fi
fi

if [ "$DOCKER_AVAILABLE" = "true" ] && [ "$PODMAN_AVAILABLE" = "true" ]; then
    CURRENT_RUNTIME="$PREVIOUS_CONTAINER_RUNTIME"
    echo "Both Docker and Podman are available:"
    echo "  1. Docker (required for the self-hosted n8n Sandbox)"
    echo "  2. Podman"
    if [ "$CURRENT_RUNTIME" = "podman" ]; then
        RUNTIME_DEFAULT=2
    elif [ "$CURRENT_RUNTIME" = "docker" ]; then
        RUNTIME_DEFAULT=1
    else
        RUNTIME_DEFAULT=""
        echo "No previous runtime is recorded; choose explicitly because Docker and Podman use separate data volumes."
    fi
    while true; do
        if [ -n "$RUNTIME_DEFAULT" ]; then
            echo -n "Runtime [1-2, default $RUNTIME_DEFAULT]: "
        else
            echo -n "Runtime [1-2]: "
        fi
        read -r runtime_choice
        runtime_choice=${runtime_choice:-$RUNTIME_DEFAULT}
        [[ "$runtime_choice" =~ ^[12]$ ]] && break
        echo "${RED}Choose 1 or 2.${NC}"
    done
    if [ "$runtime_choice" = "2" ]; then
        CONTAINER_RUNTIME="podman"
    else
        CONTAINER_RUNTIME="docker"
    fi
elif [ "$DOCKER_AVAILABLE" = "true" ]; then
    CONTAINER_RUNTIME="docker"
elif [ "$PODMAN_AVAILABLE" = "true" ]; then
    CONTAINER_RUNTIME="podman"
else
    echo "${RED}No container runtime found. Please install Docker or Podman.${NC}"
    exit 1
fi

if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    if podman info --format "{{.Host.Security.Rootless}}" 2>/dev/null | grep -q "true"; then
        RUNTIME_MODE="rootless"
    else
        RUNTIME_MODE="rootful"
    fi
elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    if docker info 2>/dev/null | grep -q "rootless"; then
        RUNTIME_MODE="rootless"
    else
        RUNTIME_MODE="rootful"
    fi
fi

if [ "$CONTAINER_RUNTIME" = "docker" ]; then
    if ! DOCKER_SOCK=$(detect_docker_socket_path "$RUNTIME_MODE"); then
        echo "${RED}The selected Docker context is remote or does not expose a local Unix socket.${NC}"
        echo "Select a local Docker context; the autoscaler must bind-mount its API socket."
        exit 1
    fi
else
    if [ "$(podman info --format '{{.Host.ServiceIsRemote}}' 2>/dev/null)" = "true" ]; then
        echo "${RED}Remote Podman connections cannot be bind-mounted into the autoscaler.${NC}"
        echo "Use a local Podman Unix socket, or select local Docker."
        exit 1
    fi
    DOCKER_SOCK=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
    DOCKER_SOCK=${DOCKER_SOCK#unix://}
    if [ -z "$DOCKER_SOCK" ]; then
        if [ "$RUNTIME_MODE" = "rootless" ]; then
            DOCKER_SOCK="/run/user/$(id -u)/podman/podman.sock"
        else
            DOCKER_SOCK="/run/podman/podman.sock"
        fi
    fi
    if [[ "$DOCKER_SOCK" != /* ]]; then
        echo "${RED}Podman reported a non-local socket path: $DOCKER_SOCK${NC}"
        exit 1
    fi
fi

echo "${BLUE}Detected: $CONTAINER_RUNTIME ($RUNTIME_MODE mode)${NC}"

if [ -n "$PREVIOUS_CONTAINER_RUNTIME" ]; then
    if [ -z "$PREVIOUS_RUNTIME_MODE" ]; then
        PREVIOUS_RUNTIME_MODE=$(infer_runtime_mode_from_socket "$PREVIOUS_RUNTIME_SOCKET")
        SELECTED_PROJECT_HAS_DATA=false
        [ "$CONTAINER_RUNTIME" = "docker" ] && SELECTED_PROJECT_HAS_DATA="$DOCKER_PROJECT_HAS_DATA"
        [ "$CONTAINER_RUNTIME" = "podman" ] && SELECTED_PROJECT_HAS_DATA="$PODMAN_PROJECT_HAS_DATA"
        if [ -z "$PREVIOUS_RUNTIME_MODE" ] && \
           [ "$PREVIOUS_CONTAINER_RUNTIME" = "$CONTAINER_RUNTIME" ] && \
           [ "$SELECTED_PROJECT_HAS_DATA" = "true" ]; then
            PREVIOUS_RUNTIME_MODE="$RUNTIME_MODE"
            echo "${YELLOW}Legacy configuration: inferred $RUNTIME_MODE mode from existing project data.${NC}"
        fi
    fi
    if [ -z "$PREVIOUS_RUNTIME_SOCKET" ] && \
       [ "$PREVIOUS_CONTAINER_RUNTIME" = "$CONTAINER_RUNTIME" ] && \
       [ "$PREVIOUS_RUNTIME_MODE" = "$RUNTIME_MODE" ]; then
        SELECTED_PROJECT_HAS_DATA=false
        [ "$CONTAINER_RUNTIME" = "docker" ] && SELECTED_PROJECT_HAS_DATA="$DOCKER_PROJECT_HAS_DATA"
        [ "$CONTAINER_RUNTIME" = "podman" ] && SELECTED_PROJECT_HAS_DATA="$PODMAN_PROJECT_HAS_DATA"
        if [ "$SELECTED_PROJECT_HAS_DATA" = "true" ]; then
            PREVIOUS_RUNTIME_SOCKET="$DOCKER_SOCK"
            echo "${YELLOW}Legacy configuration: inferred the container socket from existing project data.${NC}"
        fi
    fi

    if [ "$SETUP_WAS_COMPLETED" = "true" ] && \
       { [ -z "$PREVIOUS_RUNTIME_MODE" ] || [ -z "$PREVIOUS_RUNTIME_SOCKET" ]; }; then
        echo "${RED}Legacy setup has no complete container-daemon identity.${NC}"
        echo "Verify which daemon owns the database volumes, then set CONTAINER_RUNTIME, CONTAINER_RUNTIME_MODE, and DOCKER_SOCK in .env before rerunning."
        exit 1
    fi

    # An interrupted setup with no known data can safely adopt the currently
    # selected identity. Completed/identified deployments must never cross it
    # implicitly because engine, privilege mode, and socket each select a
    # potentially different named-volume store.
    [ -z "$PREVIOUS_RUNTIME_MODE" ] && PREVIOUS_RUNTIME_MODE="$RUNTIME_MODE"
    [ -z "$PREVIOUS_RUNTIME_SOCKET" ] && PREVIOUS_RUNTIME_SOCKET="$DOCKER_SOCK"

    if runtime_identity_changed \
        "$PREVIOUS_CONTAINER_RUNTIME" "$PREVIOUS_RUNTIME_MODE" "$PREVIOUS_RUNTIME_SOCKET" \
        "$CONTAINER_RUNTIME" "$RUNTIME_MODE" "$DOCKER_SOCK"; then
        echo "${RED}Automatic container-daemon identity switch blocked: named volumes are daemon-local.${NC}"
        echo "Recorded: $PREVIOUS_CONTAINER_RUNTIME/$PREVIOUS_RUNTIME_MODE at $PREVIOUS_RUNTIME_SOCKET"
        echo "Selected: $CONTAINER_RUNTIME/$RUNTIME_MODE at $DOCKER_SOCK"
        echo "Perform a manual cutover: back up and stop the recorded daemon, restore and verify the data on the selected daemon,"
        echo "then set CONTAINER_RUNTIME=$CONTAINER_RUNTIME, CONTAINER_RUNTIME_MODE=$RUNTIME_MODE, and DOCKER_SOCK=$DOCKER_SOCK in .env before rerunning."
        echo "If the recorded identity came only from an interrupted empty setup, clear those three values and rerun instead."
        exit 1
    fi
fi

if [ "$RUNTIME_MODE" = "rootless" ] && [ -f "/etc/systemd/system/n8n-autoscaling.service" ] && command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet n8n-autoscaling.service || systemctl is-enabled --quiet n8n-autoscaling.service; then
        echo "${YELLOW}A system-scoped n8n-autoscaling unit cannot manage the selected rootless runtime.${NC}"
        echo -n "Disable and stop the old system unit now? [Y/n]: "
        read -r disable_system_unit
        if [[ -z "$disable_system_unit" || "$disable_system_unit" =~ ^[Yy] ]]; then
            if [ "$EUID" -eq 0 ]; then
                systemctl disable --now n8n-autoscaling.service
            elif command -v sudo &>/dev/null; then
                sudo systemctl disable --now n8n-autoscaling.service
            else
                echo "${RED}sudo is required to disable the stale system unit.${NC}"
                exit 1
            fi
        else
            echo "${RED}Runtime switch aborted to prevent both system and user units from managing the stack.${NC}"
            exit 1
        fi
    fi
fi

if [ "$RUNTIME_MODE" = "rootful" ] && command -v systemctl &>/dev/null; then
    OLD_USER_HOME="$HOME"
    OLD_USER_NAME="${SUDO_USER:-}"
    OLD_USER_SYSTEMCTL=(systemctl --user)
    if [ "$EUID" -eq 0 ] && [ -n "$OLD_USER_NAME" ] && [ "$OLD_USER_NAME" != "root" ]; then
        OLD_USER_HOME=$(getent passwd "$OLD_USER_NAME" 2>/dev/null | cut -d: -f6) || true
        [ -z "$OLD_USER_HOME" ] && OLD_USER_HOME="/home/${OLD_USER_NAME}"
        OLD_USER_UID=$(id -u "$OLD_USER_NAME")
        OLD_USER_SYSTEMCTL=(sudo -u "$OLD_USER_NAME" env "XDG_RUNTIME_DIR=/run/user/${OLD_USER_UID}" systemctl --user)
    fi
    if [ -f "${OLD_USER_HOME}/.config/systemd/user/n8n-autoscaling.service" ] && \
       { "${OLD_USER_SYSTEMCTL[@]}" is-active --quiet n8n-autoscaling.service || \
         "${OLD_USER_SYSTEMCTL[@]}" is-enabled --quiet n8n-autoscaling.service; }; then
        echo "${YELLOW}A user-scoped n8n-autoscaling unit cannot safely manage the selected rootful runtime.${NC}"
        echo -n "Disable and stop the old user unit now? [Y/n]: "
        read -r disable_user_unit
        if [[ -z "$disable_user_unit" || "$disable_user_unit" =~ ^[Yy] ]]; then
            "${OLD_USER_SYSTEMCTL[@]}" disable --now n8n-autoscaling.service
        else
            echo "${RED}Runtime switch aborted to prevent both system and user units from managing the stack.${NC}"
            exit 1
        fi
    fi
fi

if [ "$RUNTIME_MODE" = "rootless" ]; then
    echo "${GREEN}Running in rootless mode.${NC}"
fi

# Detect compose command
if [ "$CONTAINER_RUNTIME" = "docker" ]; then
    if docker compose version &>/dev/null; then COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then COMPOSE_CMD="docker-compose"
    else echo "${RED}No compose tool found for Docker${NC}"; exit 1; fi
elif [ "$CONTAINER_RUNTIME" = "podman" ]; then
    if command -v podman-compose &>/dev/null; then COMPOSE_CMD="podman-compose"
    elif podman compose version &>/dev/null; then COMPOSE_CMD="podman compose"
    else echo "${RED}No compose tool found for Podman${NC}"; exit 1; fi
fi

echo "${GREEN}Using: $COMPOSE_CMD${NC}"

# Keep the selected local API socket active for the autoscaler. The exact path
# was resolved and identity-checked before any .env runtime fields were changed.
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    if [ "$RUNTIME_MODE" = "rootless" ] && command -v systemctl &>/dev/null; then
        systemctl --user enable --now podman.socket 2>/dev/null || true
    elif [ "$EUID" -eq 0 ] && command -v systemctl &>/dev/null; then
        systemctl enable --now podman.socket 2>/dev/null || true
    elif command -v sudo &>/dev/null && command -v systemctl &>/dev/null && \
         { [ ! -S "$DOCKER_SOCK" ] || ! systemctl is-enabled --quiet podman.socket; }; then
        echo -n "Enable and start the rootful Podman API socket with sudo? [Y/n]: "
        read -r start_podman_socket
        if [[ -z "$start_podman_socket" || "$start_podman_socket" =~ ^[Yy] ]]; then
            sudo systemctl enable --now podman.socket || true
        fi
    fi
    if [ ! -S "$DOCKER_SOCK" ]; then
        echo "${RED}Podman API socket is unavailable at $DOCKER_SOCK.${NC}"
        echo "Enable podman.socket, then rerun the wizard. Never make the socket world-writable."
        exit 1
    fi
    if command -v systemctl &>/dev/null; then
        if [ "$RUNTIME_MODE" = "rootless" ] && ! systemctl --user is-enabled --quiet podman.socket; then
            echo "${RED}Rootless podman.socket is active but not enabled for reboot.${NC}"
            exit 1
        elif [ "$RUNTIME_MODE" = "rootful" ] && ! systemctl is-enabled --quiet podman.socket; then
            echo "${RED}Rootful podman.socket is active but not enabled for reboot.${NC}"
            exit 1
        fi
    fi
fi
set_env_value "CONTAINER_RUNTIME" "$CONTAINER_RUNTIME"
set_env_value "CONTAINER_RUNTIME_MODE" "$RUNTIME_MODE"
set_env_value "DOCKER_SOCK" "$DOCKER_SOCK"
echo "${BLUE}Container API socket set to: $DOCKER_SOCK${NC}"

# ============================================================
# Step 10: n8n Instance AI Sandbox
# ============================================================

echo ""
echo "${BLUE}Step 10: n8n Instance AI Sandbox${NC}"
echo "---------------------------------"
echo "Choose where Instance AI should execute code:"
echo "  1. Self-hosted n8n Sandbox (automatic services + bundled SearXNG)"
echo "  2. Daytona (managed sandbox provider)"
echo "  3. Disable Instance AI"

CURRENT_AI_ENABLED=$(get_existing_value "ENABLE_AI_ASSISTANT" "false")
CURRENT_AI_PROVIDER=$(get_existing_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "n8n-sandbox")
PREVIOUS_AI_ENABLED="$CURRENT_AI_ENABLED"
PREVIOUS_AI_PROVIDER="$CURRENT_AI_PROVIDER"
if [ "$CURRENT_AI_ENABLED" != "true" ]; then
    AI_DEFAULT=3
elif [ "$CURRENT_AI_PROVIDER" = "daytona" ]; then
    AI_DEFAULT=2
else
    AI_DEFAULT=1
fi

AI_SELECTION="Disabled"
while true; do
    echo -n "Sandbox option [1-3, default $AI_DEFAULT]: "
    read -r ai_choice
    ai_choice=${ai_choice:-$AI_DEFAULT}

    case "$ai_choice" in
        1)
            if [ "$CONTAINER_RUNTIME" != "docker" ] || [ "$RUNTIME_MODE" != "rootful" ]; then
                echo "${RED}The self-hosted sandbox requires rootful Docker 24 or newer.${NC}"
                echo "${YELLOW}Podman and rootless Docker are not supported by the upstream sandbox service.${NC}"
                echo "Choose Daytona or disable the sandbox, or rerun the wizard with rootful Docker."
                continue
            fi

            if ! docker compose version &>/dev/null; then
                echo "${RED}The self-hosted sandbox requires the Docker Compose v2 plugin ('docker compose').${NC}"
                echo "Install Compose v2, or choose Daytona or disabled."
                continue
            fi

            SANDBOX_ARCH=$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)
            case "$SANDBOX_ARCH" in
                x86_64|amd64|aarch64|arm64) ;;
                *)
                    echo "${RED}No pinned sandbox images are published for architecture '$SANDBOX_ARCH'.${NC}"
                    echo "The self-hosted option currently supports amd64 and arm64 hosts."
                    continue
                    ;;
            esac

            DOCKER_SERVER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
            DOCKER_SERVER_MAJOR=${DOCKER_SERVER_VERSION%%.*}
            if ! [[ "$DOCKER_SERVER_MAJOR" =~ ^[0-9]+$ ]]; then
                echo "${RED}Could not determine the Docker server version; Docker 24 or newer is required.${NC}"
                continue
            fi
            if [ "$DOCKER_SERVER_MAJOR" -lt 24 ]; then
                echo "${RED}Docker $DOCKER_SERVER_VERSION is too old; the self-hosted sandbox requires Docker 24 or newer.${NC}"
                continue
            fi

            SYSBOX_AVAILABLE=false
            if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'sysbox-runc'; then
                SYSBOX_AVAILABLE=true
            fi

            if [ "$SYSBOX_AVAILABLE" = "true" ]; then
                if [ "$(uname -s)" != "Linux" ]; then
                    echo "${RED}Sysbox production isolation is supported only on Linux.${NC}"
                    continue
                fi
                KERNEL_RELEASE=$(docker info --format '{{.KernelVersion}}' 2>/dev/null || uname -r)
                KERNEL_MAJOR=${KERNEL_RELEASE%%.*}
                KERNEL_REMAINDER=${KERNEL_RELEASE#*.}
                KERNEL_MINOR=${KERNEL_REMAINDER%%.*}
                if ! [[ "$KERNEL_MAJOR" =~ ^[0-9]+$ && "$KERNEL_MINOR" =~ ^[0-9]+$ ]] || \
                   [ "$KERNEL_MAJOR" -lt 5 ] || { [ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -le 19 ]; }; then
                    echo "${RED}Sysbox requires a Linux kernel newer than 5.19; detected $KERNEL_RELEASE.${NC}"
                    continue
                fi
                set_env_value "N8N_SANDBOX_ISOLATION" "sysbox"
                echo "${GREEN}Sysbox detected; using production isolation.${NC}"
                AI_SELECTION="Self-hosted n8n Sandbox (Sysbox)"
            else
                echo "${YELLOW}Sysbox was not detected.${NC}"
                if [ "$(uname -s)" = "Linux" ]; then
                    echo "Production Linux hosts should install sysbox-runc first:"
                    echo "  https://github.com/n8n-io/n8n-sandbox-service/blob/main/docs/quickstart-linux.md"
                fi
                echo "Privileged Docker-in-Docker is host-root-equivalent and is intended only for local/test use."
                echo -n "Use the privileged local/test fallback? [y/N]: "
                read -r privileged_choice
                if [[ ! "$privileged_choice" =~ ^[Yy] ]]; then
                    echo "${BLUE}Self-hosted setup paused; choose another option or install Sysbox and rerun.${NC}"
                    continue
                fi
                set_env_value "N8N_SANDBOX_ISOLATION" "privileged"
                AI_SELECTION="Self-hosted n8n Sandbox (privileged local/test)"
            fi

            set_env_value "ENABLE_AI_ASSISTANT" "true"
            ensure_csv_value "N8N_ENABLED_MODULES" "instance-ai"
            remove_csv_value "N8N_DISABLED_MODULES" "instance-ai"
            set_env_value "N8N_INSTANCE_AI_SANDBOX_ENABLED" "true"
            set_env_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "n8n-sandbox"
            set_env_value "N8N_SANDBOX_SERVICE_URL" "http://sandbox-api:8080"
            set_env_value "N8N_INSTANCE_AI_SEARXNG_URL" "http://searxng:8080"

            ensure_client_key_in_list "SANDBOX_API_KEYS" "N8N_SANDBOX_SERVICE_API_KEY"
            ensure_secret_pair "SANDBOX_API_RUNNER_REGISTRATION_TOKEN" "SANDBOX_RUNNER_REGISTRATION_TOKEN"
            ensure_client_key_in_list "SANDBOX_RUNNER_API_KEYS" "SANDBOX_API_RUNNER_API_KEY"
            ensure_secret "SEARXNG_SECRET"

            ensure_default_value "N8N_SANDBOX_SERVICE_VERSION" "1.1.1"
            ensure_default_value "N8N_SANDBOX_IMAGE_VERSION" "1.1.0"
            ensure_default_value "SEARXNG_VERSION" "2026.8.28-a30b2d474"

            CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
            MEMORY_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
            if { [ "$CPU_COUNT" -gt 0 ] && [ "$CPU_COUNT" -lt 2 ]; } || { [ "$MEMORY_KB" -gt 0 ] && [ "$MEMORY_KB" -lt 4194304 ]; }; then
                echo "${YELLOW}Warning: n8n recommends at least 2 CPUs and 4 GB RAM for the sandbox stack.${NC}"
            fi
            echo "${GREEN}Self-hosted sandbox secrets and services configured.${NC}"
            break
            ;;
        2)
            daytona_key=""
            CURRENT_DAYTONA_URL=$(get_existing_value "DAYTONA_API_URL" "https://app.daytona.io/api")
            echo -n "Daytona API URL [$CURRENT_DAYTONA_URL]: "
            read -r daytona_url
            daytona_url=${daytona_url:-$CURRENT_DAYTONA_URL}

            CURRENT_DAYTONA_KEY=$(get_existing_value "DAYTONA_API_KEY" "")
            if [ -n "$CURRENT_DAYTONA_KEY" ] && [[ ! "$CURRENT_DAYTONA_KEY" =~ ^YOUR ]]; then
                echo -n "Keep the existing Daytona API key? [Y/n]: "
                read -r keep_daytona_key
                if [[ -z "$keep_daytona_key" || "$keep_daytona_key" =~ ^[Yy] ]]; then
                    daytona_key="$CURRENT_DAYTONA_KEY"
                fi
            fi
            while [ -z "$daytona_key" ]; do
                echo -n "Daytona API key: "
                read -rs daytona_key
                echo ""
                [ -z "$daytona_key" ] && echo "${RED}A Daytona API key is required for this option.${NC}"
            done

            set_env_value "ENABLE_AI_ASSISTANT" "true"
            ensure_csv_value "N8N_ENABLED_MODULES" "instance-ai"
            remove_csv_value "N8N_DISABLED_MODULES" "instance-ai"
            set_env_value "N8N_INSTANCE_AI_SANDBOX_ENABLED" "true"
            set_env_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "daytona"
            set_env_value "N8N_INSTANCE_AI_SEARXNG_URL" ""
            set_env_value "DAYTONA_API_URL" "$daytona_url"
            set_env_value "DAYTONA_API_KEY" "$daytona_key"
            [ -z "$(get_existing_value "N8N_INSTANCE_AI_SANDBOX_IMAGE" "")" ] && set_env_value "N8N_INSTANCE_AI_SANDBOX_IMAGE" "daytonaio/sandbox:0.5.3-slim"
            AI_SELECTION="Daytona"
            echo "${GREEN}Daytona sandbox configured.${NC}"
            break
            ;;
        3)
            set_env_value "ENABLE_AI_ASSISTANT" "false"
            set_env_value "N8N_INSTANCE_AI_SANDBOX_ENABLED" "false"
            remove_csv_value "N8N_ENABLED_MODULES" "instance-ai"
            ensure_csv_value "N8N_DISABLED_MODULES" "instance-ai"
            AI_SELECTION="Disabled"
            echo "${BLUE}Instance AI disabled through N8N_DISABLED_MODULES.${NC}"
            break
            ;;
        *)
            echo "${RED}Invalid choice${NC}"
            ;;
    esac
done

if [ "$(get_existing_value "ENABLE_AI_ASSISTANT" "false")" = "true" ]; then
    SELECTED_AI_PROVIDER=$(get_existing_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "")
    if [ "$PREVIOUS_AI_ENABLED" = "true" ] && [ "$PREVIOUS_AI_PROVIDER" != "$SELECTED_AI_PROVIDER" ]; then
        echo "${YELLOW}Provider changed from $PREVIOUS_AI_PROVIDER to $SELECTED_AI_PROVIDER.${NC}"
        echo "After startup, verify the selected provider in AI Assistant settings and remove the old saved sandbox connection if it is still selected."
    fi
    echo "${YELLOW}On an existing n8n database, the saved AI Settings on/off state overrides the environment default.${NC}"
    echo "After startup, verify that AI Assistant and Sandbox are enabled and that the selected provider matches $SELECTED_AI_PROVIDER."
    echo "Disconnect any mismatched saved sandbox connection. The wizard does not directly edit n8n's database-backed settings."
fi

if [ "$(get_existing_value "ENABLE_AI_ASSISTANT" "false")" = "true" ]; then
    CURRENT_MODEL_KEY=$(get_existing_value "N8N_INSTANCE_AI_MODEL_API_KEY" "")
    CURRENT_MODEL_URL=$(get_existing_value "N8N_INSTANCE_AI_MODEL_URL" "")
    if [ -n "$CURRENT_MODEL_KEY" ] || [ -n "$CURRENT_MODEL_URL" ]; then
        CURRENT_MODEL=$(get_existing_value "N8N_INSTANCE_AI_MODEL" "")
        if [ -z "$CURRENT_MODEL" ]; then
            CURRENT_MODEL="anthropic/claude-opus-4-8"
            echo "A model API key/URL exists but no model name is configured."
            echo -n "Model in provider/model format [$CURRENT_MODEL]: "
            read -r model_name
            model_name=${model_name:-$CURRENT_MODEL}
            set_env_value "N8N_INSTANCE_AI_MODEL" "$model_name"
        fi
        echo "${GREEN}Existing Instance AI model credentials preserved.${NC}"
    else
        echo "A model credential is also required before the assistant can answer."
        echo -n "Configure a model API key now? [y/N]: "
        read -r configure_model
        if [[ "$configure_model" =~ ^[Yy] ]]; then
            CURRENT_MODEL=$(get_existing_value "N8N_INSTANCE_AI_MODEL" "anthropic/claude-opus-4-8")
            echo -n "Model in provider/model format [$CURRENT_MODEL]: "
            read -r model_name
            model_name=${model_name:-$CURRENT_MODEL}
            echo -n "Model API key (leave empty only for a keyless local endpoint): "
            read -rs model_key
            echo ""
            echo -n "OpenAI-compatible base URL (optional): "
            read -r model_url
            set_env_value "N8N_INSTANCE_AI_MODEL" "$model_name"
            set_env_value "N8N_INSTANCE_AI_MODEL_API_KEY" "$model_key"
            set_env_value "N8N_INSTANCE_AI_MODEL_URL" "$model_url"
            if [ -n "$model_key" ] || [ -n "$model_url" ]; then
                echo "${GREEN}Model configuration saved.${NC}"
            else
                echo "${YELLOW}No key or local endpoint was entered; configure the model later.${NC}"
            fi
        else
            unset_env_value "N8N_INSTANCE_AI_MODEL"
            unset_env_value "N8N_INSTANCE_AI_MODEL_API_KEY"
            unset_env_value "N8N_INSTANCE_AI_MODEL_URL"
            echo "${YELLOW}Configure the model later in n8n's AI settings or in .env.${NC}"
        fi
    fi
fi

sync_compose_file_env "$CONTAINER_RUNTIME"
chmod 600 .env
echo "${BLUE}Compose stack: $(get_existing_value "COMPOSE_FILE" "docker-compose.yml")${NC}"

SYSTEMD_REFRESH_REQUIRED=false
for installed_unit in "/etc/systemd/system/n8n-autoscaling.service" "${HOME}/.config/systemd/user/n8n-autoscaling.service"; do
    if [ -f "$installed_unit" ] && \
       { ! grep -q '/compose-stack.sh up$' "$installed_unit" 2>/dev/null || \
         ! grep -q '^After=.*docker\.service.*podman\.socket' "$installed_unit" 2>/dev/null; }; then
        SYSTEMD_REFRESH_REQUIRED=true
        echo "${YELLOW}Existing systemd unit needs the current runtime/provider and engine-ordering support: $installed_unit${NC}"
    fi
done
if [ "$RUNTIME_MODE" = "rootless" ] && [ -f "/etc/systemd/system/n8n-autoscaling.service" ]; then
    SYSTEMD_REFRESH_REQUIRED=true
    echo "${YELLOW}Rootless runtimes need a user service; regenerate systemd without sudo.${NC}"
fi
if [ "$RUNTIME_MODE" = "rootful" ] && [ -f "${HOME}/.config/systemd/user/n8n-autoscaling.service" ]; then
    SYSTEMD_REFRESH_REQUIRED=true
    echo "${YELLOW}Rootful runtimes need a system service for clean engine shutdown ordering; regenerate systemd.${NC}"
fi
if [ "$SYSTEMD_REFRESH_REQUIRED" = "true" ]; then
    echo "Run ./generate-systemd.sh after this wizard to make future boots follow the selected provider."
fi

# ============================================================
# Step 11: Create External Network
# ============================================================

echo ""
echo "${BLUE}Step 11: Docker Network${NC}"
echo "-----------------------"

echo "The 'shark' external network is used for inter-service communication."
NETWORK_NAME="shark"
if [ "$CONTAINER_RUNTIME" = "docker" ]; then
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
        echo -n "Create external network '$NETWORK_NAME'? [Y/n]: "
        read -r r
        if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
            docker network create "$NETWORK_NAME"
            echo "${GREEN}Network '$NETWORK_NAME' created${NC}"
        else
            echo "${YELLOW}Skipped - you'll need to create it manually before starting${NC}"
        fi
    else
        echo "${GREEN}Network '$NETWORK_NAME' already exists${NC}"
    fi
elif [ "$CONTAINER_RUNTIME" = "podman" ]; then
    if ! podman network inspect "$NETWORK_NAME" &>/dev/null 2>&1; then
        echo -n "Create external network '$NETWORK_NAME'? [Y/n]: "
        read -r r
        if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
            podman network create "$NETWORK_NAME"
            echo "${GREEN}Network '$NETWORK_NAME' created${NC}"
        fi
    else
        echo "${GREEN}Network '$NETWORK_NAME' already exists${NC}"
    fi
fi

# ============================================================
# Step 12: Start Services
# ============================================================

echo ""
echo "${BLUE}Step 12: Start Services${NC}"
echo "-----------------------"

echo -n "Start all services now? [Y/n]: "
read -r r
if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
    COMPOSE_FILES=$(build_compose_files "$CONTAINER_RUNTIME")

    echo "${BLUE}Starting with: $COMPOSE_CMD $COMPOSE_FILES${NC}"
    $COMPOSE_CMD $COMPOSE_FILES up -d --build --remove-orphans

    echo "${BLUE}Waiting for services to start (30s)...${NC}"
    sleep 30

    echo ""
    echo "${BLUE}Health checks:${NC}"

    # Check Redis
    REDIS_PW=$(get_existing_value "REDIS_PASSWORD" "")
    if $COMPOSE_CMD $COMPOSE_FILES exec -T redis redis-cli --no-auth-warning -a "$REDIS_PW" ping 2>/dev/null | grep -q "PONG"; then
        echo "  ${GREEN}Redis: OK${NC}"
    else
        echo "  ${RED}Redis: FAILED${NC}"
    fi

    # Check PostgreSQL
    PG_ADMIN=$(get_existing_value "POSTGRES_ADMIN_USER" "postgres")
    if $COMPOSE_CMD $COMPOSE_FILES exec -T postgres pg_isready -U "$PG_ADMIN" 2>/dev/null; then
        echo "  ${GREEN}PostgreSQL: OK${NC}"
    else
        echo "  ${RED}PostgreSQL: FAILED${NC}"
    fi

    # Check the local sandbox API and runner when selected. The certificate
    # bootstrap service exits successfully by design and is not a long-running
    # health target.
    if [ "$(get_existing_value "ENABLE_AI_ASSISTANT" "false")" = "true" ] && \
       [ "$(get_existing_value "N8N_INSTANCE_AI_SANDBOX_PROVIDER" "")" = "n8n-sandbox" ]; then
        if $COMPOSE_CMD $COMPOSE_FILES exec -T sandbox-api wget -q -O /dev/null http://localhost:8080/healthz 2>/dev/null; then
            echo "  ${GREEN}Sandbox API: OK${NC}"
        else
            echo "  ${RED}Sandbox API: FAILED${NC}"
        fi
        if $COMPOSE_CMD $COMPOSE_FILES exec -T sandbox-runner-1 wget -q -O /dev/null http://localhost:8080/readyz 2>/dev/null; then
            echo "  ${GREEN}Sandbox runner runtime: OK${NC}"
            echo "    Verify runner registration in sandbox-api/sandbox-runner-1 logs."
        else
            echo "  ${RED}Sandbox runner runtime: FAILED${NC}"
        fi
    fi

    # Show running containers
    echo ""
    RUNNING=$($COMPOSE_CMD $COMPOSE_FILES ps --services --filter "status=running" 2>/dev/null | wc -l | tr -d ' ')
    TOTAL=$($COMPOSE_CMD $COMPOSE_FILES config --services 2>/dev/null | grep -v '^sandbox-certs$' | wc -l | tr -d ' ')
    echo "${BLUE}Running containers: $RUNNING/$TOTAL${NC}"

    N8N_HOST_FINAL=$(get_existing_value "N8N_HOST" "localhost")
    echo ""
    echo "${BLUE}Access URLs:${NC}"
    echo "  n8n:      https://$N8N_HOST_FINAL"
    echo "  Local:    http://localhost:5678"
else
    echo "${BLUE}Services not started. Start manually with:${NC}"
    echo "  $COMPOSE_CMD up -d --build --remove-orphans"
fi

# ============================================================
# Finalize
# ============================================================

echo ""

# Add setup completion flag (idempotent)
set_env_value "SETUP_COMPLETED" "true"
chmod 600 .env

# Clean up sed backup files
rm -f .env.bak

echo "${GREEN}Setup completed!${NC}"
echo ""
echo "${BLUE}Summary:${NC}"
echo "  Runtime:   $CONTAINER_RUNTIME ($RUNTIME_MODE)"
echo "  n8n URL:   https://$(get_existing_value 'N8N_HOST' 'n8n.domain.com')"
echo "  Webhook:   https://$(get_existing_value 'N8N_WEBHOOK' 'webhook.domain.com')"
echo "  Workers:   $(get_existing_value 'MIN_REPLICAS' '1')-$(get_existing_value 'MAX_REPLICAS' '5')"
echo "  AI Sandbox: $AI_SELECTION"
if [ "$SYSTEMD_REFRESH_REQUIRED" = "true" ]; then
    echo "  systemd:    Regenerate with ./generate-systemd.sh"
fi
if [ "$(get_existing_value 'ENABLE_AI_ASSISTANT' 'false')" = "true" ]; then
    if [ -n "$(get_existing_value 'N8N_INSTANCE_AI_MODEL_API_KEY' '')" ] || [ -n "$(get_existing_value 'N8N_INSTANCE_AI_MODEL_URL' '')" ]; then
        echo "  AI Model:   Configured"
    else
        echo "  AI Model:   Needs configuration in n8n AI settings or .env"
    fi
fi
FINAL_PROFILES=$(get_existing_value 'COMPOSE_PROFILES' '')
if [[ "$FINAL_PROFILES" == *"backup"* ]]; then
    echo "  Backups:   Enabled ($(get_existing_value 'BACKUP_SCHEDULE' '0 2 * * *'))"
else
    echo "  Backups:   Disabled"
fi
echo ""
echo "${BLUE}Next steps:${NC}"
echo "  1. Verify services are running: $COMPOSE_CMD ps"
echo "  2. Set up systemd (optional): ./generate-systemd.sh"
echo "  3. Access n8n at: https://$(get_existing_value 'N8N_HOST' 'n8n.domain.com')"
