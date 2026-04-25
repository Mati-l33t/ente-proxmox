#!/usr/bin/env bash

# Copyright (c) 2025-2026 proxmox-scripts.com
# Author: Mati-l33t
# License: MIT | https://github.com/Mati-l33t/ente-proxmox/raw/main/LICENSE
# Source: https://ente.io | Github: https://github.com/ente-io/ente

if [ -f /etc/pve/version ]; then
  echo "ERROR: This script must run inside an LXC container, not on the Proxmox host!"
  exit 1
fi

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

YW="\033[33m"; CM="\033[0;92m"; RD="\033[01;31m"; CL="\033[m"; TAB="  "
msg_info()  { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()    { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error() { echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

[[ $EUID -ne 0 ]] && msg_error "Run as root"

check_os() {
  [[ ! -f /etc/os-release ]] && msg_error "Cannot detect OS"
  # shellcheck source=/dev/null
  source /etc/os-release
  case "$ID" in
    debian)
      case "$VERSION_ID" in
        12|13) msg_ok "Detected: $PRETTY_NAME" ;;
        *) msg_error "Unsupported Debian version ${VERSION_ID} — requires Debian 12 or 13" ;;
      esac
      ;;
    ubuntu) msg_ok "Detected: $PRETTY_NAME" ;;
    *) msg_error "Unsupported OS '$PRETTY_NAME' — Debian 12/13 or Ubuntu required" ;;
  esac
  CODENAME="${VERSION_CODENAME}"
}

gen_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 28 || true
}

# ── Gather config (all user prompts run first, before any installation) ───────
# SERVER_HOST and STORAGE_* can be injected by the ct script via env vars.

if [ -z "${SERVER_HOST:-}" ]; then
  DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  echo -e "  ${YW}Ente Setup — Configuration${CL}"
  echo ""
  echo -e "  Enter the IP or hostname that clients (browser/mobile app) will"
  echo -e "  use to reach this server. For a LAN install, use the LXC IP."
  read -rp "  Server IP or hostname [${DEFAULT_IP}]: " SERVER_HOST
  SERVER_HOST="${SERVER_HOST:-${DEFAULT_IP}}"
fi

if [ -z "${STORAGE_TYPE:-}" ]; then
  echo ""
  echo -e "  ${YW}Photo Storage${CL}"
  echo ""
  echo -e "  1) Default  — /var/lib/minio (inside this container)"
  echo -e "  2) Custom   — a path that is already mounted (NAS, bind mount, etc.)"
  echo ""
  read -rp "  Choice [1]: " _sc
  case "${_sc:-1}" in
    2|custom)
      read -rp "  Storage path: " STORAGE_PATH
      [ -z "${STORAGE_PATH:-}" ] && msg_error "Storage path cannot be empty"
      STORAGE_TYPE="custom"
      ;;
    *)
      STORAGE_PATH="/var/lib/minio"
      STORAGE_TYPE="local"
      ;;
  esac
fi
: "${STORAGE_PATH:=/var/lib/minio}"
: "${STORAGE_TYPE:=local}"

# Generate all secrets before touching the system
DB_NAME="ente_db"
DB_USER="ente"
DB_PASS=$(gen_password)

MINIO_KEY="ente$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 10 || true)"
MINIO_SECRET=$(gen_password)

ENC_KEY=$(openssl rand -base64 32)
HASH_KEY=$(openssl rand -base64 64 | tr -d '\n')
JWT_SECRET=$(openssl rand -base64 32 | tr '+/' '-_')

# ── Auto-login for Proxmox console (only when no root password was set) ───────
if [ "${ENTE_AUTOLOGIN:-1}" = "1" ]; then
  mkdir -p /etc/systemd/system/container-getty@1.service.d
  cat > /etc/systemd/system/container-getty@1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF
  systemctl daemon-reload
fi

# ── Disable IPv6 (prevents apt IPv6 hangs in some LXC setups) ────────────────
cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p -q 2>/dev/null || true

check_os

# ── Fix locale (prevents perl warnings that break set -e) ────────────────────
msg_info "Fixing locale"
apt-get update -qq
apt-get install -y -qq locales >/dev/null 2>&1
sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
locale-gen >/dev/null 2>&1
export LANG=en_US.UTF-8
msg_ok "Locale fixed"

# ── APT sources (clean slate to avoid duplicates) ─────────────────────────────
> /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources << EOF
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${CODENAME} ${CODENAME}-updates
Components: main

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: ${CODENAME}-security
Components: main
EOF

# ── System update ─────────────────────────────────────────────────────────────
msg_info "Updating container OS"
apt-get update -qq
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
msg_ok "Container OS updated"

# ── Base dependencies ─────────────────────────────────────────────────────────
msg_info "Installing base dependencies"
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential pkg-config \
  libsodium-dev \
  postgresql postgresql-client \
  openssl \
  apt-transport-https \
  debian-keyring debian-archive-keyring >/dev/null 2>&1
msg_ok "Base dependencies installed"

# ── Go ────────────────────────────────────────────────────────────────────────
msg_info "Installing Go"
GO_VER=$(curl -fsSL "https://go.dev/dl/?mode=json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['version'])" 2>/dev/null \
  || echo "go1.23.0")
if [ ! -d /usr/local/go ]; then
  curl -fsSL "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
fi
export PATH="$PATH:/usr/local/go/bin"
echo 'export PATH="$PATH:/usr/local/go/bin"' >> /etc/profile.d/go.sh
chmod +x /etc/profile.d/go.sh
msg_ok "Go $(go version | awk '{print $3}') installed"

# ── Node.js 22 LTS ────────────────────────────────────────────────────────────
msg_info "Installing Node.js 22"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs >/dev/null 2>&1
msg_ok "Node.js $(node --version) installed"

# ── Yarn Classic (Ente web specifies yarn@1.22.22) ────────────────────────────
msg_info "Installing Yarn"
npm install -g yarn >/dev/null 2>&1
msg_ok "Yarn $(yarn --version 2>/dev/null || echo installed) installed"

# ── Rust + wasm-pack (required for Ente's WebAssembly module) ────────────────
msg_info "Installing Rust and wasm-pack"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --no-modify-path >/dev/null 2>&1
[ -f "$HOME/.cargo/bin/rustup" ] || msg_error "Rust installation failed"
export PATH="$HOME/.cargo/bin:$PATH"
echo 'export PATH="$HOME/.cargo/bin:$PATH"' > /etc/profile.d/rust.sh
chmod +x /etc/profile.d/rust.sh
rustup target add wasm32-unknown-unknown >/dev/null 2>&1
WPACK_VER=$(curl -fsSL https://api.github.com/repos/rustwasm/wasm-pack/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/' 2>/dev/null || true)
WPACK_VER="${WPACK_VER:-0.13.1}"
WPACK_TMP=$(mktemp -d)
curl -fsSL "https://github.com/rustwasm/wasm-pack/releases/download/v${WPACK_VER}/wasm-pack-v${WPACK_VER}-x86_64-unknown-linux-musl.tar.gz" \
  | tar -xzC "${WPACK_TMP}"
find "${WPACK_TMP}" -name "wasm-pack" -type f | head -1 | xargs -I{} mv {} /usr/local/bin/wasm-pack
rm -rf "${WPACK_TMP}"
chmod +x /usr/local/bin/wasm-pack
[ -x /usr/local/bin/wasm-pack ] || msg_error "wasm-pack installation failed"
msg_ok "Rust $(rustc --version 2>/dev/null | awk '{print $2}') and wasm-pack ${WPACK_VER} installed"

# ── Caddy ─────────────────────────────────────────────────────────────────────
msg_info "Installing Caddy"
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt-get update -qq
apt-get install -y -qq caddy >/dev/null 2>&1
msg_ok "Caddy $(caddy version 2>/dev/null | head -1 || echo installed) installed"

# ── MinIO server ──────────────────────────────────────────────────────────────
msg_info "Installing MinIO"
curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio \
  -o /usr/local/bin/minio
chmod +x /usr/local/bin/minio
curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
  -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc
ln -sf /usr/local/bin/mc /usr/bin/mc
msg_ok "MinIO installed"

# ── PostgreSQL ────────────────────────────────────────────────────────────────
msg_info "Configuring PostgreSQL"
systemctl enable --now postgresql >/dev/null 2>&1
# Wait until PostgreSQL is ready
for i in $(seq 1 12); do
  pg_isready -q 2>/dev/null && break
  sleep 2
done
pg_isready -q || msg_error "PostgreSQL did not become ready"

runuser -u postgres -- psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
  | grep -q 1 || \
  runuser -u postgres -- psql -c "CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}'" \
  >/dev/null 2>&1
runuser -u postgres -- psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
  | grep -q 1 || \
  runuser -u postgres -- psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}" \
  >/dev/null 2>&1
runuser -u postgres -- psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER}" \
  >/dev/null 2>&1
msg_ok "PostgreSQL configured (db: ${DB_NAME}, user: ${DB_USER})"

# ── Museum systemd service (created early so it exists even if later steps fail)
cat > /etc/systemd/system/museum.service << 'SVCEOF'
[Unit]
Description=Ente Museum API Server
After=network.target postgresql.service minio.service
Requires=postgresql.service minio.service

[Service]
Type=simple
WorkingDirectory=/opt/ente/server
ExecStart=/opt/ente/server/museum
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable museum >/dev/null 2>&1

# ── MinIO service ─────────────────────────────────────────────────────────────
msg_info "Configuring MinIO"

if [ "${STORAGE_TYPE}" = "local" ]; then
  # Local storage: dedicated user, standard network dependency
  useradd -r -s /sbin/nologin minio-user 2>/dev/null || true
  mkdir -p "${STORAGE_PATH}"
  chown minio-user:minio-user "${STORAGE_PATH}"
  MINIO_SVC_USER="User=minio-user"$'\n'"Group=minio-user"
  MINIO_SVC_AFTER="After=network.target"
  MINIO_SVC_REQUIRES=""
else
  # Custom/NAS storage: run as root to avoid bind-mount UID issues,
  # wait for network and require the mount to be present before starting
  mkdir -p "${STORAGE_PATH}"
  touch "${STORAGE_PATH}/.ente-write-test" 2>/dev/null \
    || msg_error "Storage path ${STORAGE_PATH} is not writable — check mount and permissions"
  rm -f "${STORAGE_PATH}/.ente-write-test"
  MINIO_SVC_USER=""
  MINIO_SVC_AFTER="After=network-online.target"
  MINIO_SVC_REQUIRES="RequiresMountsFor=${STORAGE_PATH}"
  msg_ok "Custom storage path verified: ${STORAGE_PATH}"
fi

cat > /etc/default/minio << EOF
MINIO_ROOT_USER=${MINIO_KEY}
MINIO_ROOT_PASSWORD=${MINIO_SECRET}
MINIO_VOLUMES=${STORAGE_PATH}
MINIO_ADDRESS=:3200
MINIO_CONSOLE_ADDRESS=:3201
EOF
chmod 600 /etc/default/minio

cat > /etc/systemd/system/minio.service << EOF
[Unit]
Description=MinIO Object Storage
${MINIO_SVC_AFTER}
${MINIO_SVC_REQUIRES}

[Service]
Type=simple
WorkingDirectory=${STORAGE_PATH}
${MINIO_SVC_USER}
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server ${STORAGE_PATH}
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio >/dev/null 2>&1
systemctl start minio
sleep 3
if ! systemctl is-active --quiet minio; then
  journalctl -u minio -n 30 --no-pager >&2 || true
  msg_error "MinIO failed to start — see logs above"
fi

# Wait for MinIO API to be ready, then create buckets
msg_info "Waiting for MinIO and creating buckets"
for i in $(seq 1 40); do
  mc alias set ente http://localhost:3200 "${MINIO_KEY}" "${MINIO_SECRET}" >/dev/null 2>&1 && break
  sleep 5
done
if ! mc alias set ente http://localhost:3200 "${MINIO_KEY}" "${MINIO_SECRET}" >/dev/null 2>&1; then
  journalctl -u minio -n 30 --no-pager >&2 || true
  msg_error "MinIO did not become ready after 200s — see logs above"
fi

mc mb --ignore-existing ente/b2-eu-cen >/dev/null 2>&1
mc mb --ignore-existing ente/wasabi-eu-central-2-v3 >/dev/null 2>&1
mc mb --ignore-existing ente/scw-eu-fr-v3 >/dev/null 2>&1
msg_ok "MinIO running and buckets created (API :3200, Console :3201)"

# ── Clone Ente ────────────────────────────────────────────────────────────────
msg_info "Cloning Ente repository"
if [ -d /opt/ente/.git ]; then
  git -C /opt/ente pull -q
else
  git clone --depth 1 -q https://github.com/ente-io/ente.git /opt/ente
fi
msg_ok "Ente cloned"

# Write .env.local so the update utility can always find the correct server URL
cat > /opt/ente/web/.env.local << EOF
NEXT_PUBLIC_ENTE_ENDPOINT=http://${SERVER_HOST}:8080
NEXT_PUBLIC_ENTE_ALBUMS_ENDPOINT=http://${SERVER_HOST}:3002
EOF

# ── Museum config (museum.yaml) ───────────────────────────────────────────────
msg_info "Writing museum.yaml"
cat > /opt/ente/server/museum.yaml << EOF
db:
    host: localhost
    port: 5432
    name: ${DB_NAME}
    user: ${DB_USER}
    password: ${DB_PASS}

s3:
    are_local_buckets: true
    use_path_style_urls: true
    b2-eu-cen:
      key: ${MINIO_KEY}
      secret: ${MINIO_SECRET}
      endpoint: ${SERVER_HOST}:3200
      region: eu-central-2
      bucket: b2-eu-cen
    wasabi-eu-central-2-v3:
      key: ${MINIO_KEY}
      secret: ${MINIO_SECRET}
      endpoint: ${SERVER_HOST}:3200
      region: eu-central-2
      bucket: wasabi-eu-central-2-v3
      compliance: false
    scw-eu-fr-v3:
      key: ${MINIO_KEY}
      secret: ${MINIO_SECRET}
      endpoint: ${SERVER_HOST}:3200
      region: eu-central-2
      bucket: scw-eu-fr-v3

apps:
    public-albums: http://${SERVER_HOST}:3002
    public-locker: http://${SERVER_HOST}:3005
    cast: http://${SERVER_HOST}:3004
    accounts: http://${SERVER_HOST}:3001

key:
    encryption: ${ENC_KEY}
    hash: ${HASH_KEY}
jwt:
    secret: ${JWT_SECRET}
EOF
chmod 600 /opt/ente/server/museum.yaml
msg_ok "museum.yaml written"

# ── Build Museum (Go server) ──────────────────────────────────────────────────
msg_info "Building Museum server (Go, takes 2-5 minutes)"
cd /opt/ente/server
/usr/local/go/bin/go mod tidy -q 2>/dev/null || true
export CGO_ENABLED=1
export CGO_CFLAGS="$(pkg-config --cflags libsodium 2>/dev/null || echo '-I/usr/include')"
export CGO_LDFLAGS="$(pkg-config --libs libsodium 2>/dev/null || echo '-lsodium')"
/usr/local/go/bin/go build -o museum cmd/museum/main.go 2>&1 | tail -3 || true
[ -f /opt/ente/server/museum ] || msg_error "Museum build failed — binary not found"
msg_ok "Museum built"

# ── Web apps (yarn build) ─────────────────────────────────────────────────────
msg_info "Installing web dependencies (yarn, takes a few minutes)"
cd /opt/ente/web
yarn install 2>&1 | tail -3
msg_ok "Web dependencies installed"

msg_info "Building WebAssembly module"
yarn build:wasm 2>&1 | tail -5 || msg_error "WebAssembly build failed"
msg_ok "WebAssembly built"

API_URL="http://${SERVER_HOST}:8080"
ALBUMS_URL="http://${SERVER_HOST}:3002"
mkdir -p /var/www/ente/apps

build_app() {
  local name="$1"   # workspace name
  local label="$2"  # display name
  local out_dir="$3"  # /var/www/ente/apps/<dest>
  local extra_env="${4:-}"

  msg_info "Building ${label} app (this takes several minutes)"
  cd /opt/ente/web
  env NEXT_PUBLIC_ENTE_ENDPOINT="${API_URL}" \
    NEXT_PUBLIC_ENTE_ALBUMS_ENDPOINT="${ALBUMS_URL}" \
    ${extra_env} \
    yarn workspace "${name}" next build 2>&1 | tail -5 || {
      echo -e "${TAB}${YW}  ⚠ ${label} build had warnings — checking output${CL}"
    }
  if [ -d "/opt/ente/web/apps/${name}/out" ]; then
    mkdir -p "${out_dir}"
    cp -r "/opt/ente/web/apps/${name}/out/." "${out_dir}/"
    msg_ok "${label} app built → ${out_dir}"
  else
    echo -e "${TAB}${YW}  ⚠ ${label} out/ not found, skipping${CL}"
  fi
}

build_app "photos"   "Photos"   "/var/www/ente/apps/photos"
build_app "accounts" "Accounts" "/var/www/ente/apps/accounts"
build_app "albums"   "Albums"   "/var/www/ente/apps/albums"
build_app "auth"     "Auth"     "/var/www/ente/apps/auth"
build_app "cast"     "Cast"     "/var/www/ente/apps/cast"
build_app "locker"   "Locker"   "/var/www/ente/apps/locker"

# ── Caddy configuration ───────────────────────────────────────────────────────
msg_info "Configuring Caddy"
systemctl stop caddy 2>/dev/null || true

cat > /etc/caddy/Caddyfile << 'CADDY'
:3000 {
    root * /var/www/ente/apps/photos
    file_server
    try_files {path} /index.html
}

:3001 {
    root * /var/www/ente/apps/accounts
    file_server
    try_files {path} /index.html
}

:3002 {
    root * /var/www/ente/apps/albums
    file_server
    try_files {path} /index.html
}

:3003 {
    root * /var/www/ente/apps/auth
    file_server
    try_files {path} /index.html
}

:3004 {
    root * /var/www/ente/apps/cast
    file_server
    try_files {path} /index.html
}

:3005 {
    root * /var/www/ente/apps/locker
    file_server
    try_files {path} /index.html
}
CADDY

systemctl enable --now caddy >/dev/null 2>&1
msg_ok "Caddy started"

# ── Credentials file ──────────────────────────────────────────────────────────
CREDS_FILE="/root/ente-credentials.txt"
cat > "${CREDS_FILE}" << EOF
Ente Installation — Generated Credentials
==========================================
Date: $(date)

Museum API:    http://${SERVER_HOST}:8080
Photos:        http://${SERVER_HOST}:3000
Accounts:      http://${SERVER_HOST}:3001
Albums:        http://${SERVER_HOST}:3002
Auth:          http://${SERVER_HOST}:3003
Cast:          http://${SERVER_HOST}:3004
Locker:        http://${SERVER_HOST}:3005
MinIO Console: http://$(hostname -I | awk '{print $1}'):3201

PostgreSQL
  host:     localhost
  db:       ${DB_NAME}
  user:     ${DB_USER}
  password: ${DB_PASS}

MinIO
  access key:   ${MINIO_KEY}
  secret key:   ${MINIO_SECRET}
  endpoint:     http://localhost:3200
  storage path: ${STORAGE_PATH}

Museum Config: /opt/ente/server/museum.yaml
Caddy Config:  /etc/caddy/Caddyfile
Verification code (no SMTP configured)
  Run 'journalctl -u museum -f' BEFORE requesting a code in the app.
  The code appears in the log: "Skipping sending email ... Verification code: XXXXXX"

Logs:          journalctl -u museum -f
               journalctl -u minio -f
               journalctl -u caddy -f
Update:        run 'update'
EOF
chmod 600 "${CREDS_FILE}"
msg_ok "Credentials saved to ${CREDS_FILE}"

msg_info "Starting Museum"
systemctl start museum
sleep 3
if ! systemctl is-active --quiet museum; then
  journalctl -u museum -n 30 --no-pager >&2 || true
  msg_error "Museum failed to start — see logs above"
fi

# ── Wait for Museum API to accept connections ─────────────────────────────────
msg_info "Waiting for Museum API to accept connections"
for i in $(seq 1 24); do
  curl -fsSL http://localhost:8080/ping >/dev/null 2>&1 && break
  sleep 5
done
curl -fsSL http://localhost:8080/ping >/dev/null 2>&1 \
  || echo -e "${TAB}${YW}  ⚠ Museum not yet responding — check: journalctl -u museum -f${CL}"

# ── Update utility ────────────────────────────────────────────────────────────
msg_info "Setting up update utility"
cat > /usr/bin/update << 'UPDATEEOF'
#!/usr/bin/env bash
# Safe update: backs up DB before anything changes, keeps old Museum binary as
# fallback, builds web apps to a temp dir before swapping live files.
# Photos (MinIO /var/lib/minio) and museum.yaml are never touched.

set -euo pipefail
export PATH="$PATH:/usr/local/go/bin:/root/.cargo/bin"

YW="\033[33m"; CM="\033[0;92m"; RD="\033[01;31m"; CL="\033[m"; TAB="  "
msg_info() { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()   { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_warn() { echo -e "${TAB}${YW}  ⚠  ${1}${CL}"; }
msg_error(){ echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

[[ $EUID -ne 0 ]] && msg_error "Run as root"

# ── Check disk space (web build needs ~3GB free) ──────────────────────────────
FREE_KB=$(df /opt --output=avail 2>/dev/null | tail -1)
if [ "${FREE_KB:-0}" -lt 3145728 ]; then
  msg_warn "Less than 3GB free on /opt — build may fail"
  read -rp "  Continue anyway? (y/N): " ok
  [[ "${ok,,}" != "y" ]] && { echo "  Aborted."; exit 0; }
fi

# ── Version check ─────────────────────────────────────────────────────────────
CURRENT=$(git -C /opt/ente rev-parse --short HEAD 2>/dev/null || echo "unknown")
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/ente-io/ente/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null || true)

echo -e "\n  Current commit: ${CURRENT}"
echo -e "  Latest release: ${LATEST_TAG:-unknown}\n"

# ── Backup database (always, before any changes) ──────────────────────────────
msg_info "Backing up database"
BACKUP_DIR="/root/ente-backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/ente-db-$(date +%Y%m%d-%H%M%S).sql.gz"
if runuser -u postgres -- bash -c "pg_dump ente_db | gzip > '${BACKUP_FILE}'" 2>/dev/null; then
  msg_ok "Database backed up → ${BACKUP_FILE}"
  # Keep only the 5 most recent backups
  ls -t "${BACKUP_DIR}"/ente-db-*.sql.gz 2>/dev/null | tail -n +6 | xargs rm -f || true
else
  msg_warn "Database backup failed — proceeding anyway (check PostgreSQL is running)"
fi

# ── Pull latest source ────────────────────────────────────────────────────────
msg_info "Pulling latest Ente source"
# museum.yaml is gitignored — git pull will never touch it
git -C /opt/ente pull -q
msg_ok "Source updated"

# ── Rebuild Museum binary (keep old binary as fallback) ───────────────────────
msg_info "Rebuilding Museum server"
cd /opt/ente/server
[ -f museum ] && cp museum museum.bak
go mod tidy -q 2>/dev/null || true
export CGO_ENABLED=1
export CGO_CFLAGS="$(pkg-config --cflags libsodium 2>/dev/null || echo '-I/usr/include')"
export CGO_LDFLAGS="$(pkg-config --libs libsodium 2>/dev/null || echo '-lsodium')"
if go build -o museum.new cmd/museum/main.go 2>&1 | tail -3; then
  mv museum.new museum
  rm -f museum.bak
  msg_ok "Museum rebuilt"
else
  rm -f museum.new
  if [ -f museum.bak ]; then
    mv museum.bak museum
    msg_error "Museum build failed — previous binary restored, no changes applied"
  else
    msg_error "Museum build failed and no previous binary exists"
  fi
fi

# ── Rebuild web apps (build to temp dir, swap only on success) ────────────────
msg_info "Rebuilding web apps (takes several minutes)"
cd /opt/ente/web

# Read the API URL from the live Caddyfile or fall back to localhost
API_URL=$(grep -oP 'NEXT_PUBLIC_ENTE_ENDPOINT=\K\S+' /opt/ente/web/.env.local 2>/dev/null \
  || grep -oP 'http://\S+:8080' /etc/caddy/Caddyfile 2>/dev/null | head -1 \
  || echo "http://localhost:8080")
ALBUMS_URL="${API_URL%:8080}:3002"

yarn install 2>&1 | tail -3
yarn build:wasm 2>&1 | tail -3

BUILD_FAILED=()
for app in photos accounts albums auth cast locker; do
  if yarn workspace "$app" next build 2>&1 | tail -3; then
    if [ -d "/opt/ente/web/apps/${app}/out" ]; then
      # Swap atomically: move old aside, copy new, remove old
      LIVE="/var/www/ente/apps/${app}"
      OLD="${LIVE}.old"
      rm -rf "$OLD"
      [ -d "$LIVE" ] && mv "$LIVE" "$OLD"
      cp -r "/opt/ente/web/apps/${app}/out" "$LIVE"
      rm -rf "$OLD"
      msg_ok "${app} updated"
    else
      msg_warn "${app} built but no out/ dir found — skipping"
      BUILD_FAILED+=("$app")
    fi
  else
    msg_warn "${app} build failed — keeping existing live files"
    BUILD_FAILED+=("$app")
  fi
done

[ ${#BUILD_FAILED[@]} -gt 0 ] && \
  msg_warn "Some apps failed to build: ${BUILD_FAILED[*]} — live files unchanged for those"

# ── Restart services ──────────────────────────────────────────────────────────
msg_info "Restarting services"
systemctl restart museum caddy
msg_ok "Services restarted"

echo ""
msg_ok "Update complete"
echo -e "  ${YW}Photos and database untouched. Backup: ${BACKUP_FILE}${CL}"
[ ${#BUILD_FAILED[@]} -gt 0 ] && \
  echo -e "  ${YW}Check logs for failed apps: journalctl -u museum -f${CL}"
echo ""
UPDATEEOF
chmod +x /usr/bin/update
msg_ok "Update utility ready (run: update)"

# ── set-storage utility ───────────────────────────────────────────────────────
msg_info "Setting up set-storage utility"
cat > /usr/bin/set-storage << 'STOREOF'
#!/usr/bin/env bash
set -euo pipefail

YW="\033[33m"; CM="\033[0;92m"; RD="\033[01;31m"; CL="\033[m"; TAB="  "
msg_ok()    { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error() { echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

[[ $EUID -ne 0 ]] && msg_error "Run as root"

COUNT=$(runuser -u postgres -- psql ente_db -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')
[[ "$COUNT" == "0" ]] && { echo "  No users found — register an account first."; exit 0; }

runuser -u postgres -- psql ente_db -q << 'SQL'
DO $$
DECLARE
  uid BIGINT;
BEGIN
  FOR uid IN SELECT user_id FROM users LOOP
    IF EXISTS (SELECT 1 FROM subscriptions WHERE user_id = uid) THEN
      UPDATE subscriptions
        SET storage = 1099511627776000, expiry_time = 9999999999000000
        WHERE user_id = uid;
    ELSE
      INSERT INTO subscriptions
        (user_id, storage, expiry_time, product_id, payment_provider, original_transaction_id)
        VALUES (uid, 1099511627776000, 9999999999000000, 'self_hosted', 'stripe', 'self_hosted');
    END IF;
  END LOOP;
END;
$$;
SQL

msg_ok "Storage quota set to unlimited for all ${COUNT} user(s)"
STOREOF
chmod +x /usr/bin/set-storage
msg_ok "set-storage utility ready (run: set-storage)"

# ── MOTD ──────────────────────────────────────────────────────────────────────
msg_info "Setting up MOTD"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
> /etc/motd
find /etc/update-motd.d/ -type f -exec chmod -x {} \; 2>/dev/null || true
cat > /etc/profile.d/ente-motd.sh << 'MOTDEOF'
#!/usr/bin/env bash
. /etc/os-release
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "  Ente Photos LXC"
echo ""
echo "    🌐   Provided by: Mati-l33t | Website: https://proxmox-scripts.com | GitHub: https://github.com/Mati-l33t/ente-proxmox"
echo ""
echo "    🖥️   OS: ${PRETTY_NAME}"
echo "    🏠   Hostname: $(hostname)"
echo "    💡   IP Address: ${IP}"
echo ""
MOTDEOF
chmod +x /etc/profile.d/ente-motd.sh
msg_ok "MOTD configured"

# ── Cleanup ───────────────────────────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y -qq
apt-get autoclean -qq
rm -f /tmp/ente-install.sh
# Remove build artifacts that are no longer needed (saves ~3-4 GB)
rm -rf /opt/ente/web/apps/*/.next
rm -rf /opt/ente/web/apps/*/out
rm -rf /root/.cache/go-build
rm -rf /root/go/pkg/mod
yarn cache clean --all 2>/dev/null || true
systemctl daemon-reload
systemctl restart container-getty@1 2>/dev/null || true
msg_ok "Cleaned up"

# ── Done ──────────────────────────────────────────────────────────────────────
if [ "${ENTE_QUIET_FINISH:-0}" != "1" ]; then
  echo ""
  msg_ok "Ente installation complete!"
  echo ""
  echo -e "  ${CM}Photos:${CL}        http://${SERVER_HOST}:3000"
  echo -e "  ${CM}Accounts:${CL}      http://${SERVER_HOST}:3001"
  echo -e "  ${CM}Albums:${CL}        http://${SERVER_HOST}:3002"
  echo -e "  ${CM}Museum API:${CL}    http://${SERVER_HOST}:8080"
  echo -e "  ${CM}MinIO Console:${CL} http://${IP}:3201"
  echo ""
  echo -e "  ${YW}Credentials saved to: /root/ente-credentials.txt${CL}"
  echo -e "  ${YW}Register the first account in the Photos app — it becomes admin.${CL}"
  echo ""
fi

