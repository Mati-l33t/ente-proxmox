#!/usr/bin/env bash

# Copyright (c) 2025-2026 Mati-l33t
# Author: Mati-l33t
# License: MIT | https://github.com/Mati-l33t/ente-proxmox/raw/main/LICENSE
# Source: https://ente.io | Github: https://github.com/ente-io/ente

set -euo pipefail

INSTALL_SCRIPT="https://raw.githubusercontent.com/Mati-l33t/ente-proxmox/main/install/ente-install.sh"

YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
BL="\033[36m"
CM="\033[0;92m"
CL="\033[m"
BOLD="\033[1m"
TAB="  "

APP="Ente"
NSAPP="ente"
var_cpu="4"
var_ram="6144"
var_disk="30"
var_unprivileged="1"

msg_info()  { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()    { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error() { echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

header_info() {
  clear
  cat << 'EOF'
    ______      __
   / ____/___  / /____
  / __/ / __ \/ __/ _ \
 / /___/ / / / /_/  __/
/_____/_/ /_/\__/\___/
EOF
  echo -e "${TAB}${BOLD}${BL}Ente Photos LXC Installer${CL}"
  echo -e "${TAB}${YW}Provided by: Mati-l33t${CL}"
  echo -e "${TAB}${YW}GitHub: https://github.com/Mati-l33t/ente-proxmox${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Storage helpers
# ─────────────────────────────────────────────
select_storage() {
  local type="$1"
  local content="rootdir"
  [ "$type" = "template" ] && content="vztmpl"

  local names=()
  while IFS= read -r name; do
    names+=("$name" " ")
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 {print $1}')

  local count=$(( ${#names[@]} / 2 ))
  [ "$count" -eq 0 ] && msg_error "No suitable ${type} storage found"
  [ "$count" -eq 1 ] && { echo "${names[0]}"; return; }

  whiptail --backtitle "Ente Installer" \
    --title "$([ "$type" = "template" ] && echo "TEMPLATE STORAGE" || echo "CONTAINER STORAGE")" \
    --menu "\nWhere to store the ${type}?" 16 58 8 \
    "${names[@]}" \
    3>&1 1>&2 2>&3
}

get_template() {
  local storage="$1"

  pveam update >/dev/null 2>&1

  # Prefer Debian 13 (Trixie), fall back to Debian 12 (Bookworm)
  local TEMPLATE_NAME=""
  for prefix in "debian-13-standard" "debian-12-standard"; do
    local existing
    existing=$(pveam list "$storage" 2>/dev/null | awk '{print $1}' | grep -F "$prefix" | sort -V | tail -1)
    if [ -n "$existing" ]; then
      TEMPLATE_NAME="$existing"
      break
    fi
    local available
    available=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -F "$prefix" | sort -V | tail -1)
    if [ -n "$available" ]; then
      msg_info "Downloading ${available}"
      pveam download "$storage" "$available" >/dev/null 2>&1 \
        && { TEMPLATE_NAME="${storage}:vztmpl/${available}"; break; }
    fi
  done

  [ -z "$TEMPLATE_NAME" ] && msg_error "No Debian 13 or 12 template found — run: pveam update"
  echo "$TEMPLATE_NAME"
}

# ─────────────────────────────────────────────
# Settings
# ─────────────────────────────────────────────
default_settings() {
  CTID=$(pvesh get /cluster/nextid)
  HN="${NSAPP}"
  CORE_COUNT="${var_cpu}"
  RAM_SIZE="${var_ram}"
  DISK_SIZE="${var_disk}"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  VLAN_TAG=""
  PW=""
  SSH="no"
  UNPRIVILEGED="${var_unprivileged}"
  VERB="no"

  echo -e "${TAB}${BOLD}Using Default Settings${CL}"
  echo -e "${TAB}🆔  Container ID:  ${BL}${CTID}${CL}"
  echo -e "${TAB}🏠  Hostname:      ${BL}${HN}${CL}"
  echo -e "${TAB}💾  Disk:          ${BL}${DISK_SIZE}GB${CL}"
  echo -e "${TAB}🧠  CPU Cores:     ${BL}${CORE_COUNT}${CL}"
  echo -e "${TAB}🛠️  RAM:           ${BL}${RAM_SIZE}MiB${CL}"
  echo -e "${TAB}🌉  Bridge:        ${BL}${BRG}${CL}"
  echo -e "${TAB}📡  IP:            ${BL}${NET}${CL}"
  echo ""
}

advanced_settings() {
  CTID=$(whiptail --backtitle "Ente Installer" --title "CONTAINER ID" \
    --inputbox "\nSet Container ID:" 8 58 "$(pvesh get /cluster/nextid)" \
    3>&1 1>&2 2>&3) || exit

  HN=$(whiptail --backtitle "Ente Installer" --title "HOSTNAME" \
    --inputbox "\nSet Hostname:" 8 58 "${NSAPP}" \
    3>&1 1>&2 2>&3) || exit

  DISK_SIZE=$(whiptail --backtitle "Ente Installer" --title "DISK SIZE" \
    --inputbox "\nSet Disk Size in GB:\n(30GB minimum — more for photo storage)" 10 58 "${var_disk}" \
    3>&1 1>&2 2>&3) || exit

  CORE_COUNT=$(whiptail --backtitle "Ente Installer" --title "CPU CORES" \
    --inputbox "\nSet CPU Cores:\n(4 recommended — build takes longer with fewer)" 10 58 "${var_cpu}" \
    3>&1 1>&2 2>&3) || exit

  RAM_SIZE=$(whiptail --backtitle "Ente Installer" --title "RAM (MiB)" \
    --inputbox "\nSet RAM in MiB:\n(6144 recommended — Go+Node build is memory-intensive)" 10 58 "${var_ram}" \
    3>&1 1>&2 2>&3) || exit

  local bridge_opts=()
  while IFS= read -r br; do
    bridge_opts+=("$br" " ")
  done < <(ip link show | grep -oP 'vmbr\d+' | sort -u)
  [ "${#bridge_opts[@]}" -gt 2 ] && \
    BRG=$(whiptail --backtitle "Ente Installer" --title "NETWORK BRIDGE" \
      --menu "\nSelect network bridge:" 16 58 6 "${bridge_opts[@]}" 3>&1 1>&2 2>&3) || BRG="vmbr0"

  local ip_choice
  ip_choice=$(whiptail --backtitle "Ente Installer" --title "IP CONFIGURATION" \
    --menu "\nSelect IP configuration:" 12 58 2 \
    "dhcp"   "Automatic (DHCP)" \
    "static" "Static IP" \
    3>&1 1>&2 2>&3) || exit

  if [ "$ip_choice" = "static" ]; then
    NET=$(whiptail --backtitle "Ente Installer" --title "STATIC IP" \
      --inputbox "\nEnter Static IP with CIDR:\n(e.g. 192.168.1.100/24)" 10 58 "" \
      3>&1 1>&2 2>&3) || exit
    local gw
    gw=$(whiptail --backtitle "Ente Installer" --title "GATEWAY" \
      --inputbox "\nEnter Gateway IP:" 10 58 "" \
      3>&1 1>&2 2>&3) || exit
    GATE=",gw=${gw}"
  else
    NET="dhcp"
    GATE=""
  fi

  local vlan_input
  vlan_input=$(whiptail --backtitle "Ente Installer" --title "VLAN TAG" \
    --inputbox "\nSet VLAN Tag (leave blank for none):" 8 58 "" \
    3>&1 1>&2 2>&3) || exit
  [ -n "$vlan_input" ] && VLAN_TAG=",tag=${vlan_input}" || VLAN_TAG=""

  local pw1 pw2
  pw1=$(whiptail --backtitle "Ente Installer" --title "ROOT PASSWORD" \
    --passwordbox "\nSet Root Password\n(leave blank for autologin):" 10 58 \
    3>&1 1>&2 2>&3) || exit
  if [ -n "$pw1" ]; then
    pw2=$(whiptail --backtitle "Ente Installer" --title "CONFIRM PASSWORD" \
      --passwordbox "\nConfirm Root Password:" 10 58 \
      3>&1 1>&2 2>&3) || exit
    [ "$pw1" != "$pw2" ] && msg_error "Passwords do not match"
    PW="--password ${pw1}"
  else
    PW=""
  fi

  SSH=$(whiptail --backtitle "Ente Installer" --title "SSH ACCESS" \
    --radiolist "\nAllow root SSH access?" 10 58 2 \
    "no"  "No (recommended)" ON \
    "yes" "Yes" OFF \
    3>&1 1>&2 2>&3) || exit

  UNPRIVILEGED=$(whiptail --backtitle "Ente Installer" --title "CONTAINER TYPE" \
    --radiolist "\nSelect container type:" 10 58 2 \
    "1" "Unprivileged (recommended)" ON \
    "0" "Privileged" OFF \
    3>&1 1>&2 2>&3) || exit

  VERB=$(whiptail --backtitle "Ente Installer" --title "VERBOSE MODE" \
    --radiolist "\nEnable verbose install output?" 10 58 2 \
    "no"  "No" ON \
    "yes" "Yes" OFF \
    3>&1 1>&2 2>&3) || exit

  echo -e "${TAB}${BOLD}Using Advanced Settings${CL}"
  echo -e "${TAB}🆔  Container ID:  ${BL}${CTID}${CL}"
  echo -e "${TAB}🏠  Hostname:      ${BL}${HN}${CL}"
  echo -e "${TAB}📦  Type:          ${BL}$([ "$UNPRIVILEGED" = "1" ] && echo Unprivileged || echo Privileged)${CL}"
  echo -e "${TAB}💾  Disk:          ${BL}${DISK_SIZE}GB${CL}"
  echo -e "${TAB}🧠  CPU Cores:     ${BL}${CORE_COUNT}${CL}"
  echo -e "${TAB}🛠️  RAM:           ${BL}${RAM_SIZE}MiB${CL}"
  echo -e "${TAB}🌉  Bridge:        ${BL}${BRG}${CL}"
  echo -e "${TAB}📡  IP:            ${BL}${NET}${CL}"
  echo -e "${TAB}🔑  SSH:           ${BL}${SSH}${CL}"
  echo -e "${TAB}🔊  Verbose:       ${BL}${VERB}${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Ask server address (before container creation)
# ─────────────────────────────────────────────
ask_server_host() {
  SERVER_HOST=$(whiptail --backtitle "Ente Installer" --title "SERVER ADDRESS" \
    --inputbox "\nEnter the IP or domain clients will use to reach Ente.\n\nFor DHCP, leave blank — the container's IP will be auto-detected.\nFor static IP, enter it here (e.g. 192.168.1.50).\n\nThis gets baked into the web app build." 16 62 "" \
    3>&1 1>&2 2>&3) || exit
  # Blank is fine — install script auto-detects inside the container
  echo -e "${TAB}${YW}Server address: ${BL}${SERVER_HOST:-auto-detect}${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Build container
# ─────────────────────────────────────────────
build_container() {
  msg_info "Selecting storage"
  TEMPLATE_STORAGE=$(select_storage template)
  CONTAINER_STORAGE=$(select_storage container)
  msg_ok "Storage selected"

  TEMPLATE=$(get_template "$TEMPLATE_STORAGE")
  msg_ok "Template ready"

  local tz
  tz=$(timedatectl show --value --property=Timezone 2>/dev/null || echo "UTC")
  [[ "$tz" == Etc/* ]] && tz="UTC"

  msg_info "Creating LXC container ${CTID}"
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HN" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_SIZE" \
    --rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRG},ip=${NET}${GATE}${VLAN_TAG}" \
    --features "nesting=1" \
    --unprivileged "$UNPRIVILEGED" \
    --tags "ente" \
    --onboot 1 \
    --timezone "$tz" \
    $PW \
    >/dev/null 2>&1
  msg_ok "LXC container ${CTID} created"

  msg_info "Starting container"
  pct start "$CTID"
  sleep 8
  msg_ok "Container started"

  msg_info "Waiting for network"
  local tries=0
  while ! pct exec "$CTID" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
    sleep 3
    tries=$((tries + 1))
    [ $tries -gt 15 ] && msg_error "Network not reachable inside container"
  done
  msg_ok "Network connected"

  IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
  # If no server host was given, use the container's IP
  [ -z "${SERVER_HOST:-}" ] && SERVER_HOST="$IP"
}

# ─────────────────────────────────────────────
# Run install inside container
# ─────────────────────────────────────────────
run_install() {
  msg_info "Downloading install script"
  curl -fsSL "$INSTALL_SCRIPT" -o /tmp/ente-install.sh
  msg_ok "Install script downloaded"

  msg_info "Pushing install script into container"
  pct push "$CTID" /tmp/ente-install.sh /tmp/ente-install.sh --perms 0755
  rm -f /tmp/ente-install.sh
  msg_ok "Install script ready"

  # Build can take 30-90 minutes on older CPUs — warn the user
  echo ""
  echo -e "  ${YW}${BOLD}Installation starting — this takes 30-90 minutes on older hardware.${CL}"
  echo -e "  ${YW}The Go and Node.js builds are CPU and memory intensive.${CL}"
  echo ""

  if [ "$VERB" = "yes" ]; then
    pct exec "$CTID" -- bash -c "SERVER_HOST='${SERVER_HOST}' bash /tmp/ente-install.sh"
  else
    pct exec "$CTID" -- bash -c "SERVER_HOST='${SERVER_HOST}' bash /tmp/ente-install.sh" \
      2>&1 | grep -E "✔️|✖️|⏳|ERROR" || true
  fi

  sleep 5
  if pct exec "$CTID" -- systemctl is-active museum >/dev/null 2>&1; then
    msg_ok "Ente installer finished"
  else
    msg_error "Museum service failed to start — enter container ${CTID} to debug: pct enter ${CTID}"
  fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
header_info

if whiptail --backtitle "Ente Installer" --title "INSTALL MODE" \
  --yesno "\nWould you like to use Default Settings?\n\nDefaults:\n  CPU: 4 cores\n  RAM: 6144 MiB\n  Disk: 30 GB\n  IP: DHCP\n  Type: Unprivileged" 16 58; then
  default_settings
else
  advanced_settings
fi

ask_server_host
build_container
run_install

echo ""
msg_ok "Ente installation complete!"
echo ""
echo -e "${TAB}${GN}📷 Photos:${CL}        ${BL}http://${SERVER_HOST}:3000${CL}"
echo -e "${TAB}${GN}👤 Accounts:${CL}      ${BL}http://${SERVER_HOST}:3001${CL}"
echo -e "${TAB}${GN}🖼️  Albums:${CL}         ${BL}http://${SERVER_HOST}:3002${CL}"
echo -e "${TAB}${GN}🔐 Museum API:${CL}    ${BL}http://${SERVER_HOST}:8080${CL}"
echo -e "${TAB}${GN}🪣 MinIO Console:${CL} ${BL}http://${IP}:3201${CL}"
echo ""
echo -e "${TAB}${YW}Credentials:${CL} cat /root/ente-credentials.txt  (inside container)"
echo -e "${TAB}${YW}Enter container:${CL} pct enter ${CTID}"
echo -e "${TAB}${YW}Register first account in Photos app — it becomes admin.${CL}"
echo ""
