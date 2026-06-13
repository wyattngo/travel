#!/usr/bin/env bash
#
# server-setup.sh — turnkey setup & operations for ToursTravel Kenya (Docker).
#
# On a FRESH server, one command does everything:
#     ./server-setup.sh bootstrap
#   (installs Docker → generates secrets → builds image → starts app + MySQL
#    → runs migrations/seed → smoke-tests the homepage)
#
# Run `./server-setup.sh help` for all commands.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env.docker"
ENV_EXAMPLE=".env.docker.example"
CADDY_OVERRIDE="docker-compose.caddy.yml"

# If HTTPS/Caddy has been enabled, make every compose command include the override.
if [ -f "$CADDY_OVERRIDE" ]; then
    export COMPOSE_FILE="docker-compose.yml:${CADDY_OVERRIDE}"
fi

ASSUME_YES="${ASSUME_YES:-false}"

# ---------------------------------------------------------------- logging ----
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
log()  { printf '%s▶ %s%s\n' "$c_blue" "$*" "$c_rst"; }
ok()   { printf '%s✔ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s! %s%s\n' "$c_yel" "$*" "$c_rst"; }
die()  { printf '%s✘ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" = "true" ] && return 0
    printf '%s? %s [y/N] %s' "$c_yel" "$1" "$c_rst"
    read -r ans || true
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------ docker access ---
SUDO=""
DK="docker"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "This step needs root. Re-run as root or install sudo."
        SUDO="sudo"
    fi
}

ensure_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker not installed. Run: $0 install-docker"
    if docker info >/dev/null 2>&1; then
        DK="docker"
    elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        DK="sudo docker"
        warn "Using 'sudo docker' (current user not in the docker group yet — log out/in to fix)."
    else
        die "Cannot talk to the Docker daemon. Is it running? (sudo systemctl start docker)"
    fi
}

compose() {
    if $DK compose version >/dev/null 2>&1; then
        $DK compose "$@"
    else
        die "The Docker Compose v2 plugin is required ('docker compose'). Run: $0 install-docker"
    fi
}

# ------------------------------------------------------------------ secrets --
gen_key() {
    if command -v openssl >/dev/null 2>&1; then echo "base64:$(openssl rand -base64 32)"
    else echo "base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"; fi
}
gen_pw() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
    else head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# set_env KEY VALUE — replace (or append) KEY=VALUE in $ENV_FILE, value inserted literally.
set_env() {
    local k="$1" v="$2" tmp
    if grep -qE "^${k}=" "$ENV_FILE"; then
        tmp="$(mktemp)"
        awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k"="v; next} {print}' "$ENV_FILE" >"$tmp"
        mv "$tmp" "$ENV_FILE"
    else
        printf '%s=%s\n' "$k" "$v" >>"$ENV_FILE"
    fi
}
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'; }
app_port() { local p; p="$(get_env APP_PORT)"; echo "${p:-8000}"; }

# ============================================================= commands ======

cmd_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "Docker already installed: $(docker --version)"
        return
    fi
    need_root
    log "Installing Docker Engine + Compose plugin via get.docker.com…"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | $SUDO sh
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://get.docker.com | $SUDO sh
    else
        die "Need curl or wget to install Docker."
    fi
    $SUDO systemctl enable --now docker 2>/dev/null || true
    local u="${SUDO_USER:-$USER}"
    if [ -n "$u" ] && [ "$u" != "root" ]; then
        $SUDO usermod -aG docker "$u" 2>/dev/null || true
        warn "Added '$u' to the docker group — log out/in (or run 'newgrp docker') to use docker without sudo."
    fi
    ok "Docker installed: $(docker --version 2>/dev/null || echo unknown)"
}

cmd_env() {
    if [ -f "$ENV_FILE" ]; then
        ok "$ENV_FILE already exists — leaving it untouched (use 'regen-secrets' to rotate)."
        return
    fi
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found."
    log "Creating $ENV_FILE with freshly generated secrets…"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    local key pw; key="$(gen_key)"; pw="$(gen_pw)"
    set_env APP_KEY "$key"
    set_env DB_PASSWORD "$pw"
    set_env MYSQL_ROOT_PASSWORD "$pw"
    [ -n "${DOMAIN:-}" ]   && set_env APP_URL "$DOMAIN"
    [ -n "${APP_PORT:-}" ] && set_env APP_PORT "$APP_PORT"
    chmod 600 "$ENV_FILE"
    ok "Wrote $ENV_FILE (APP_KEY + DB password generated, file mode 600)."
}

cmd_regen_secrets() {
    [ -f "$ENV_FILE" ] || die "$ENV_FILE not found — run '$0 env' first."
    warn "Rotating APP_KEY and DB password will INVALIDATE existing sessions and the current DB password."
    confirm "Continue?" || { warn "Aborted."; return 1; }
    local key pw; key="$(gen_key)"; pw="$(gen_pw)"
    set_env APP_KEY "$key"; set_env DB_PASSWORD "$pw"; set_env MYSQL_ROOT_PASSWORD "$pw"
    ok "Secrets rotated. Re-run '$0 deploy' (a fresh DB volume may be needed if MySQL was already initialised)."
}

cmd_deploy() {
    ensure_docker
    [ -f "$ENV_FILE" ] || cmd_env
    log "Building image and starting containers…"
    compose up -d --build
    smoke_test || true
    cmd_status
}

smoke_test() {
    local port code i=0; port="$(app_port)"
    command -v curl >/dev/null 2>&1 || { warn "curl not available — skipping smoke test."; return 0; }
    log "Waiting for the app to answer on http://localhost:${port}/ …"
    until code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null)"; \
          [ "$code" = "200" ] || [ "$code" = "302" ]; do
        i=$((i + 1))
        if [ "$i" -ge 40 ]; then
            warn "App not healthy yet (last HTTP: ${code:-none}). Inspect with: $0 logs app"
            return 1
        fi
        sleep 3
    done
    ok "App is up (HTTP $code) on port ${port}."
}

cmd_update() {
    ensure_docker
    if [ -d .git ]; then
        log "Pulling latest code…"; git pull --ff-only || warn "git pull skipped/failed — continuing with current code."
    fi
    log "Rebuilding and restarting…"
    compose up -d --build
    smoke_test || true
    $DK image prune -f >/dev/null 2>&1 || true
    ok "Update complete."
}

cmd_backup() {
    ensure_docker
    mkdir -p backups
    local ts file db pw
    ts="$(date +%Y%m%d-%H%M%S)"; file="backups/db-${ts}.sql.gz"
    db="$(get_env DB_DATABASE)"; pw="$(get_env MYSQL_ROOT_PASSWORD)"
    [ -n "$db" ] && [ -n "$pw" ] || die "Could not read DB settings from $ENV_FILE."
    log "Dumping database '$db' → $file …"
    compose exec -T -e MYSQL_PWD="$pw" db mysqldump -uroot --single-transaction --quick "$db" | gzip >"$file"
    ok "Backup written: $file ($(du -h "$file" | cut -f1))"
}

cmd_restore() {
    ensure_docker
    local file="${1:-}"
    [ -n "$file" ] || die "Usage: $0 restore <backup.sql.gz|backup.sql>"
    [ -f "$file" ] || die "File not found: $file"
    local db pw; db="$(get_env DB_DATABASE)"; pw="$(get_env MYSQL_ROOT_PASSWORD)"
    warn "This OVERWRITES the current '$db' database with $file."
    confirm "Continue?" || { warn "Aborted."; return 1; }
    log "Restoring…"
    if printf '%s' "$file" | grep -q '\.gz$'; then gunzip -c "$file"; else cat "$file"; fi \
        | compose exec -T -e MYSQL_PWD="$pw" db mysql -uroot "$db"
    ok "Restore complete."
}

cmd_enable_https() {
    ensure_docker
    local domain="${1:-}" email="${2:-}"
    [ -n "$domain" ] || die "Usage: $0 enable-https <domain> [acme-email]"
    [ -f "$ENV_FILE" ] || cmd_env
    log "Setting up automatic HTTPS (Caddy + Let's Encrypt) for ${domain}…"

    {
        if [ -n "$email" ]; then printf '{\n    email %s\n}\n\n' "$email"; fi
        printf '%s {\n    reverse_proxy app:80\n    encode gzip\n}\n' "$domain"
    } >Caddyfile

    cat >"$CADDY_OVERRIDE" <<'YAML'
# HTTPS reverse proxy (Caddy, automatic certificates). Applied as a compose
# override on top of docker-compose.yml. Managed by server-setup.sh.
services:
  app:
    # Behind Caddy the app is only reachable on the internal network.
    ports: !reset []
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on:
      - app
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
volumes:
  caddy-data:
  caddy-config:
YAML

    set_env APP_URL "https://${domain}"
    export COMPOSE_FILE="docker-compose.yml:${CADDY_OVERRIDE}"
    log "Rebuilding behind Caddy…"
    compose up -d --build
    ok "HTTPS configured for https://${domain}"
    warn "Make sure DNS A/AAAA records for ${domain} point at this server — Caddy issues certs on first request."
}

cmd_disable_https() {
    ensure_docker
    [ -f "$CADDY_OVERRIDE" ] || { ok "HTTPS/Caddy not enabled."; return; }
    log "Removing Caddy and returning to direct HTTP on APP_PORT…"
    compose down || true
    rm -f "$CADDY_OVERRIDE" Caddyfile
    unset COMPOSE_FILE
    compose up -d --build
    ok "HTTPS disabled. App published directly on port $(app_port)."
}

cmd_status()  { ensure_docker; compose ps; }
cmd_logs()    { ensure_docker; compose logs -f "${@}"; }
cmd_stop()    { ensure_docker; log "Stopping containers…"; compose down; ok "Stopped (data volumes kept)."; }
cmd_restart() { ensure_docker; compose restart "${@}"; ok "Restarted."; }

cmd_destroy() {
    ensure_docker
    warn "This removes containers, the built image, AND the database volume (ALL DATA LOST)."
    confirm "Really destroy everything?" || { warn "Aborted."; return 1; }
    compose down -v --rmi local || true
    ok "Tore down containers, volumes and local image."
}

cmd_bootstrap() {
    log "=== Bootstrapping ToursTravel Kenya on this server ==="
    cmd_install_docker
    cmd_env
    cmd_deploy
    echo
    ok "Bootstrap finished. App: http://localhost:$(app_port)/  (set a domain with: $0 enable-https <domain> <email>)"
}

usage() {
    cat <<EOF
ToursTravel Kenya — server setup & operations

Usage: $0 <command> [args]

Fresh server (does everything):
  bootstrap                 install Docker, generate secrets, build, deploy, smoke-test

Setup steps:
  install-docker            install Docker Engine + Compose plugin (needs root/sudo)
  env                       create .env.docker from the template with fresh secrets
  regen-secrets             rotate APP_KEY + DB password in .env.docker

Run / operate:
  deploy                    build image and start app + MySQL (default if no command)
  update                    git pull (if a repo) + rebuild + restart + prune
  status                    show container status
  logs [service]            follow logs (e.g. '$0 logs app')
  restart [service]         restart containers
  stop                      stop containers (keeps data)
  destroy                   remove containers, image AND data volumes

HTTPS (real domain):
  enable-https <domain> [email]   put Caddy in front with automatic TLS
  disable-https                   remove Caddy, serve plain HTTP again

Backup / restore:
  backup                    dump the database to ./backups/db-<timestamp>.sql.gz
  restore <file>            restore a dump into the database

Options:
  ASSUME_YES=true           skip confirmation prompts (for automation)
  DOMAIN=https://...        used by 'env' to preset APP_URL
  APP_PORT=8080             used by 'env' to preset the published port

Examples:
  ./server-setup.sh bootstrap
  ./server-setup.sh enable-https tours.example.com you@example.com
  ASSUME_YES=true ./server-setup.sh update
EOF
}

main() {
    local cmd="${1:-deploy}"; shift || true
    case "$cmd" in
        bootstrap)       cmd_bootstrap "$@" ;;
        install-docker)  cmd_install_docker "$@" ;;
        env)             cmd_env "$@" ;;
        regen-secrets)   cmd_regen_secrets "$@" ;;
        deploy|up)       cmd_deploy "$@" ;;
        update)          cmd_update "$@" ;;
        status|ps)       cmd_status "$@" ;;
        logs)            cmd_logs "$@" ;;
        restart)         cmd_restart "$@" ;;
        stop|down)       cmd_stop "$@" ;;
        destroy)         cmd_destroy "$@" ;;
        enable-https)    cmd_enable_https "$@" ;;
        disable-https)   cmd_disable_https "$@" ;;
        backup)          cmd_backup "$@" ;;
        restore)         cmd_restore "$@" ;;
        help|-h|--help)  usage ;;
        *)               warn "Unknown command: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"
