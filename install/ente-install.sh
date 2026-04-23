#!/usr/bin/env bash

# Copyright (c) 2025-2026 Mati-l33t
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
    debian|ubuntu) msg_ok "Detected: $PRETTY_NAME" ;;
    *) msg_error "Unsupported OS '$PRETTY_NAME' — Debian or Ubuntu required" ;;
  esac
}

gen_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 28 || true
}

# ── Gather config (all user prompts run first, before any installation) ───────
# SERVER_HOST can be injected by the ct script via env var. If not set, prompt.
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

# Generate all secrets before touching the system
DB_NAME="ente_db"
DB_USER="ente"
DB_PASS=$(gen_password)

MINIO_KEY="ente$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 10)"
MINIO_SECRET=$(gen_password)

ENC_KEY=$(openssl rand -base64 32)
HASH_KEY=$(openssl rand -base64 64 | tr -d '\n')
JWT_SECRET=$(openssl rand -base64 32)

# ── Auto-login for Proxmox console ────────────────────────────────────────────
mkdir -p /etc/systemd/system/container-getty@1.service.d
cat > /etc/systemd/system/container-getty@1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF
systemctl daemon-reload

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
cat > /etc/apt/sources.list.d/debian.sources << 'SOURCES'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main
SOURCES

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

# ── Yarn (via corepack) ───────────────────────────────────────────────────────
msg_info "Installing Yarn"
corepack enable >/dev/null 2>&1
corepack prepare yarn@stable --activate >/dev/null 2>&1 || npm install -g yarn >/dev/null 2>&1
msg_ok "Yarn $(yarn --version 2>/dev/null || echo installed) installed"

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

su -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" postgres \
  | grep -q 1 || \
  su -c "psql -c \"CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}'\"" postgres \
  >/dev/null 2>&1
su -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" postgres \
  | grep -q 1 || \
  su -c "psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}\"" postgres \
  >/dev/null 2>&1
su -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER}\"" postgres \
  >/dev/null 2>&1
msg_ok "PostgreSQL configured (db: ${DB_NAME}, user: ${DB_USER})"

# ── MinIO service ─────────────────────────────────────────────────────────────
msg_info "Configuring MinIO"
useradd -r -s /sbin/nologin minio-user 2>/dev/null || true
mkdir -p /var/lib/minio
chown minio-user:minio-user /var/lib/minio

cat > /etc/default/minio << EOF
MINIO_ROOT_USER=${MINIO_KEY}
MINIO_ROOT_PASSWORD=${MINIO_SECRET}
MINIO_VOLUMES=/var/lib/minio
MINIO_OPTS="--address :3200 --console-address :3201"
EOF
chmod 600 /etc/default/minio

cat > /etc/systemd/system/minio.service << 'SVCEOF'
[Unit]
Description=MinIO Object Storage
After=network.target

[Service]
Type=notify
WorkingDirectory=/var/lib/minio
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_VOLUMES $MINIO_OPTS
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now minio >/dev/null 2>&1

# Wait for MinIO API to be ready, then create buckets
msg_info "Waiting for MinIO and creating buckets"
for i in $(seq 1 20); do
  mc alias set ente http://localhost:3200 "${MINIO_KEY}" "${MINIO_SECRET}" >/dev/null 2>&1 && break
  sleep 3
done
mc alias set ente http://localhost:3200 "${MINIO_KEY}" "${MINIO_SECRET}" >/dev/null 2>&1 \
  || msg_error "MinIO did not become ready"

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
      endpoint: localhost:3200
      region: eu-central-2
      bucket: b2-eu-cen
    wasabi-eu-central-2-v3:
      key: ${MINIO_KEY}
      secret: ${MINIO_SECRET}
      endpoint: localhost:3200
      region: eu-central-2
      bucket: wasabi-eu-central-2-v3
      compliance: false
    scw-eu-fr-v3:
      key: ${MINIO_KEY}
      secret: ${MINIO_SECRET}
      endpoint: localhost:3200
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
/usr/local/go/bin/go mod tidy -q 2>/dev/null
/usr/local/go/bin/go build -o museum cmd/museum/main.go 2>&1 | tail -3 || true
[ -f /opt/ente/server/museum ] || msg_error "Museum build failed — binary not found"
msg_ok "Museum built"

# ── Museum systemd service ────────────────────────────────────────────────────
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

# ── Web apps (yarn build) ─────────────────────────────────────────────────────
msg_info "Installing web dependencies (yarn, takes a few minutes)"
cd /opt/ente/web
yarn install --frozen-lockfile 2>&1 | tail -3
msg_ok "Web dependencies installed"

msg_info "Building WebAssembly module"
yarn build:wasm 2>&1 | tail -3
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
systemctl start museum >/dev/null 2>&1
msg_ok "Caddy and Museum started"

# ── Wait for Museum to be ready ───────────────────────────────────────────────
msg_info "Waiting for Museum API to accept connections"
for i in $(seq 1 24); do
  curl -fsSL http://localhost:8080/ping >/dev/null 2>&1 && break
  sleep 5
done
curl -fsSL http://localhost:8080/ping >/dev/null 2>&1 \
  || echo -e "${TAB}${YW}  ⚠ Museum not yet responding — check: journalctl -u museum -f${CL}"

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
  access key: ${MINIO_KEY}
  secret key: ${MINIO_SECRET}
  endpoint:   http://localhost:3200

Museum Config: /opt/ente/server/museum.yaml
Caddy Config:  /etc/caddy/Caddyfile
Logs:          journalctl -u museum -f
               journalctl -u minio -f
               journalctl -u caddy -f
Update:        run 'update'
EOF
chmod 600 "${CREDS_FILE}"
msg_ok "Credentials saved to ${CREDS_FILE}"

# ── Update utility ────────────────────────────────────────────────────────────
msg_info "Setting up update utility"
cat > /usr/bin/update << 'UPDATEEOF'
#!/usr/bin/env bash
YW="\033[33m"; CM="\033[0;92m"; RD="\033[01;31m"; CL="\033[m"; TAB="  "
msg_info() { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()   { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error(){ echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

export PATH="$PATH:/usr/local/go/bin"

CURRENT=$(cd /opt/ente && git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
LATEST=$(curl -fsSL https://api.github.com/repos/ente-io/ente/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

echo -e "\n  Current: ${CURRENT}\n  Latest:  ${LATEST}\n"
[ "$CURRENT" = "$LATEST" ] && { msg_ok "Already on latest"; exit 0; }

msg_info "Stopping services"
systemctl stop museum caddy
msg_ok "Services stopped"

msg_info "Pulling latest Ente"
git -C /opt/ente pull -q
msg_ok "Ente updated"

msg_info "Rebuilding Museum"
cd /opt/ente/server
go mod tidy -q 2>/dev/null
go build -o museum cmd/museum/main.go
msg_ok "Museum rebuilt"

msg_info "Rebuilding web apps (takes several minutes)"
cd /opt/ente/web
API_URL=$(grep -oP 'NEXT_PUBLIC_ENTE_ENDPOINT=\K[^ ]+' /opt/ente/web/.env.local 2>/dev/null || echo "http://localhost:8080")
yarn install --frozen-lockfile 2>&1 | tail -3
yarn build:wasm 2>&1 | tail -3
for app in photos accounts albums auth cast locker; do
  yarn workspace "$app" next build 2>&1 | tail -3 || true
  [ -d "/opt/ente/web/apps/${app}/out" ] && cp -r "/opt/ente/web/apps/${app}/out/." "/var/www/ente/apps/${app}/"
done
msg_ok "Web apps rebuilt"

msg_info "Starting services"
systemctl start museum caddy
msg_ok "Ente updated to ${LATEST}"
UPDATEEOF
chmod +x /usr/bin/update
msg_ok "Update utility ready (run: update)"

# ── MOTD ──────────────────────────────────────────────────────────────────────
msg_info "Setting up MOTD"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat > /etc/motd << MOTDEOF

  Ente Photos LXC
  Provided by: Mati-l33t
  GitHub: https://github.com/Mati-l33t/ente-proxmox

  OS:       $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
  Hostname: $(hostname)
  IP:       ${IP}

  Photos:        http://${SERVER_HOST}:3000
  Accounts:      http://${SERVER_HOST}:3001
  Albums:        http://${SERVER_HOST}:3002
  Museum API:    http://${SERVER_HOST}:8080
  MinIO Console: http://${IP}:3201

  Credentials: /root/ente-credentials.txt
  Config:      /opt/ente/server/museum.yaml
  Caddy:       /etc/caddy/Caddyfile
  Update:      run 'update'

MOTDEOF
msg_ok "MOTD configured"

# ── Cleanup ───────────────────────────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y -qq
apt-get autoclean -qq
rm -f /tmp/ente-install.sh
systemctl daemon-reload
systemctl restart container-getty@1 2>/dev/null || true
msg_ok "Cleaned up"

# ── Done ──────────────────────────────────────────────────────────────────────
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
