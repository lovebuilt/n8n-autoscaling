#!/bin/bash
# n8n-autoscaling setup wizard
# Interactive setup for the n8n autoscaling stack.
# Adapted from pie-rs/n8n-autoscaling fork.

set -e

# Colors
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Build compose file list based on detected configuration
build_compose_files() {
    local runtime="$1"
    local files="-f docker-compose.yml"
    if [ -f .env ] && grep -q "^ENABLE_CLOUDFLARE_OVERRIDE=true" .env 2>/dev/null; then
        [ -f docker-compose.cloudflare.yml ] && files="$files -f docker-compose.cloudflare.yml"
    fi
    [ "$runtime" = "podman" ] && [ -f docker-compose.podman.yml ] && files="$files -f docker-compose.podman.yml"
    echo "$files"
}

# ============================================================
# Container Lifecycle
# ============================================================

stop_all_containers_force() {
    echo "${BLUE}Stopping all containers...${NC}"
    docker compose down -v 2>/dev/null || true
    podman compose down 2>/dev/null || true
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

if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    if podman info --format "{{.Host.Security.Rootless}}" 2>/dev/null | grep -q "true"; then
        CONTAINER_RUNTIME="podman"; RUNTIME_MODE="rootless"
    else
        CONTAINER_RUNTIME="podman"; RUNTIME_MODE="rootful"
    fi
elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    if docker info 2>/dev/null | grep -q "rootless"; then
        CONTAINER_RUNTIME="docker"; RUNTIME_MODE="rootless"
    else
        CONTAINER_RUNTIME="docker"; RUNTIME_MODE="rootful"
    fi
else
    echo "${RED}No container runtime found. Please install Docker or Podman.${NC}"
    exit 1
fi

echo "${BLUE}Detected: $CONTAINER_RUNTIME ($RUNTIME_MODE mode)${NC}"

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

# Update Docker socket path for rootless
if [ "$RUNTIME_MODE" = "rootless" ] && [ "$CONTAINER_RUNTIME" = "docker" ]; then
    DOCKER_SOCK="/run/user/$(id -u)/docker.sock"
    sed -i.bak "s|^#DOCKER_SOCK=.*|DOCKER_SOCK=$DOCKER_SOCK|" .env
    sed -i.bak "s|^DOCKER_SOCK=.*|DOCKER_SOCK=$DOCKER_SOCK|" .env
    echo "${BLUE}Docker socket set to: $DOCKER_SOCK${NC}"
fi

# ============================================================
# Step 10: Create External Network
# ============================================================

echo ""
echo "${BLUE}Step 10: Docker Network${NC}"
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
# Step 11: Start Services
# ============================================================

echo ""
echo "${BLUE}Step 11: Start Services${NC}"
echo "-----------------------"

echo -n "Start all services now? [Y/n]: "
read -r r
if [[ -z "$r" || "$r" =~ ^[Yy] ]]; then
    COMPOSE_FILES=$(build_compose_files "$CONTAINER_RUNTIME")

    echo "${BLUE}Starting with: $COMPOSE_CMD $COMPOSE_FILES${NC}"
    $COMPOSE_CMD $COMPOSE_FILES up -d

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

    # Show running containers
    echo ""
    RUNNING=$($COMPOSE_CMD $COMPOSE_FILES ps --services --filter "status=running" 2>/dev/null | wc -l | tr -d ' ')
    TOTAL=$($COMPOSE_CMD $COMPOSE_FILES ps --services 2>/dev/null | wc -l | tr -d ' ')
    echo "${BLUE}Running containers: $RUNNING/$TOTAL${NC}"

    N8N_HOST_FINAL=$(get_existing_value "N8N_HOST" "localhost")
    echo ""
    echo "${BLUE}Access URLs:${NC}"
    echo "  n8n:      https://$N8N_HOST_FINAL"
    echo "  Local:    http://localhost:5678"
else
    echo "${BLUE}Services not started. Start manually with:${NC}"
    echo "  $COMPOSE_CMD up -d"
fi

# ============================================================
# Finalize
# ============================================================

echo ""

# Add setup completion flag (idempotent)
if ! grep -q "^SETUP_COMPLETED=true" .env 2>/dev/null; then
    echo "" >> .env
    echo "# Setup completion flag" >> .env
    echo "SETUP_COMPLETED=true" >> .env
fi

# Clean up sed backup files
rm -f .env.bak

echo "${GREEN}Setup completed!${NC}"
echo ""
echo "${BLUE}Summary:${NC}"
echo "  Runtime:   $CONTAINER_RUNTIME ($RUNTIME_MODE)"
echo "  n8n URL:   https://$(get_existing_value 'N8N_HOST' 'n8n.domain.com')"
echo "  Webhook:   https://$(get_existing_value 'N8N_WEBHOOK' 'webhook.domain.com')"
echo "  Workers:   $(get_existing_value 'MIN_REPLICAS' '1')-$(get_existing_value 'MAX_REPLICAS' '5')"
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
