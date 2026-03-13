#!/usr/bin/env bash
# =============================================================================
# iPXE Server Installer for Ubuntu
# =============================================================================
# This script sets up an iPXE server on Ubuntu that:
#   - Isolates the installation network from the enterprise network
#   - Acts as a NAT gateway so machines being installed can reach the internet
#   - Provides DHCP + TFTP (dnsmasq) and HTTP (nginx) services
#
# Usage:
#   sudo bash install.sh [--wan <iface>] [--lan <iface>] [--lan-ip <cidr>]
#                        [--dhcp-start <ip>] [--dhcp-end <ip>]
#
# Defaults:
#   --wan        ens3            Upstream / enterprise NIC
#   --lan        ens4            Downstream / installation NIC
#   --lan-ip     192.168.100.1/24
#   --dhcp-start 192.168.100.100
#   --dhcp-end   192.168.100.200
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
WAN_IFACE="ens3"
LAN_IFACE="ens4"
LAN_CIDR="192.168.100.1/24"
DHCP_START="192.168.100.100"
DHCP_END="192.168.100.200"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/ipxe-install.log"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wan)        WAN_IFACE="$2";   shift 2 ;;
    --lan)        LAN_IFACE="$2";   shift 2 ;;
    --lan-ip)     LAN_CIDR="$2";    shift 2 ;;
    --dhcp-start) DHCP_START="$2";  shift 2 ;;
    --dhcp-end)   DHCP_END="$2";    shift 2 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# =/p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Derive LAN IP without the prefix-length (e.g. 192.168.100.1/24 -> 192.168.100.1)
LAN_IP="${LAN_CIDR%%/*}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%d %T')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
  log "=== Pre-flight checks ==="
  require_root

  # Ubuntu 20.04 / 22.04 / 24.04
  if ! grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
    die "This script is designed for Ubuntu. Detected OS is not Ubuntu."
  fi

  # Check that the LAN interface exists (WAN may be the current default)
  if ! ip link show "$LAN_IFACE" &>/dev/null; then
    die "LAN interface '$LAN_IFACE' not found. Use --lan <iface> to specify the correct one."
  fi

  # Ensure required tools are available after install
  log "Checking internet connectivity…"
  if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
    log "WARNING: Cannot reach 8.8.8.8. Package installation may fail."
  fi
}

# ---------------------------------------------------------------------------
# 2. Install packages
# ---------------------------------------------------------------------------
install_packages() {
  log "=== Installing packages ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    dnsmasq \
    nginx \
    ipxe \
    iptables-persistent \
    curl \
    wget
}

# ---------------------------------------------------------------------------
# 3. Configure network (netplan)
# ---------------------------------------------------------------------------
configure_network() {
  log "=== Configuring network ==="

  local netplan_file="/etc/netplan/99-ipxe-lan.yaml"

  cat > "$netplan_file" <<NETPLAN
# Managed by iPXE installer — do not edit manually
network:
  version: 2
  ethernets:
    ${LAN_IFACE}:
      addresses:
        - ${LAN_CIDR}
      dhcp4: false
NETPLAN

  # Fix permissions on all netplan files (including any pre-existing ones)
  find /etc/netplan -name "*.yaml" -exec chmod 600 {} \;

  # Ensure systemd-networkd is running so netplan apply can configure the interface
  if ! systemctl enable --now systemd-networkd 2>/dev/null; then
    log "WARNING: Could not enable/start systemd-networkd — netplan may fall back to a hard restart."
  fi

  netplan apply

  # Wait for the LAN interface to acquire the configured IP address (up to 15 s)
  local max_wait=15 elapsed=0
  while ! ip addr show "${LAN_IFACE}" 2>/dev/null | grep -q "${LAN_IP}"; do
    if [[ $elapsed -ge $max_wait ]]; then
      die "${LAN_IFACE} did not acquire IP ${LAN_IP} within ${max_wait}s. Check netplan configuration."
    fi
    sleep 1
    (( elapsed++ ))
  done

  log "Netplan applied: ${LAN_IFACE} set to ${LAN_CIDR}"
}

# ---------------------------------------------------------------------------
# 4. Enable IP forwarding and NAT (gateway)
# ---------------------------------------------------------------------------
configure_nat() {
  log "=== Configuring NAT / IP forwarding ==="

  # Enable forwarding immediately
  sysctl -w net.ipv4.ip_forward=1

  # Persist across reboots
  sed -i '/^#\?net\.ipv4\.ip_forward/d' /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  # Flush existing rules (non-destructive: only touch the chains we add)
  iptables -t nat -D POSTROUTING -s "${LAN_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "${WAN_IFACE}" -o "${LAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  # Add rules
  iptables -t nat -A POSTROUTING -s "${LAN_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE
  iptables -A FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT
  iptables -A FORWARD -i "${WAN_IFACE}" -o "${LAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # Persist
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4

  log "NAT configured: ${LAN_IFACE} -> ${WAN_IFACE}"
}

# ---------------------------------------------------------------------------
# 5. Configure dnsmasq (DHCP + TFTP)
# ---------------------------------------------------------------------------
configure_dnsmasq() {
  log "=== Configuring dnsmasq (DHCP + TFTP) ==="

  local tftp_root="/srv/tftp"
  mkdir -p "${tftp_root}"

  # Copy iPXE boot files shipped with the ipxe package
  if [[ -f /usr/lib/ipxe/undionly.kpxe ]]; then
    cp /usr/lib/ipxe/undionly.kpxe "${tftp_root}/"
  fi
  if [[ -f /usr/lib/ipxe/ipxe.efi ]]; then
    cp /usr/lib/ipxe/ipxe.efi "${tftp_root}/"
  fi

  # Copy our iPXE menu scripts
  install -m 644 "${REPO_DIR}/ipxe/boot.ipxe"   "${tftp_root}/boot.ipxe"
  install -m 644 "${REPO_DIR}/ipxe/ubuntu.ipxe" "${tftp_root}/ubuntu.ipxe"

  # Disable the systemd-resolved DNS stub listener so dnsmasq can own port 53
  # on the LAN interface without conflicts.
  if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' \
      > /etc/systemd/resolved.conf.d/no-dnsstub.conf
    systemctl restart systemd-resolved
  fi

  # Stop any running dnsmasq before rewriting its configuration
  systemctl stop dnsmasq 2>/dev/null || true

  cat > /etc/dnsmasq.d/ipxe.conf <<DNSMASQ
# iPXE server — managed by iPXE installer

# Listen only on the isolated LAN interface; never on loopback
interface=${LAN_IFACE}
except-interface=lo
bind-interfaces

# Do not use /etc/resolv.conf for upstream DNS; forward to public resolvers
no-resolv
server=8.8.8.8
server=8.8.4.4

# DHCP range and lease time
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h

# Default gateway and DNS for clients
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

# TFTP
enable-tftp
tftp-root=${tftp_root}

# PXE boot — BIOS clients
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,undionly.kpxe,,${LAN_IP}

# PXE boot — UEFI clients
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,ipxe.efi,,${LAN_IP}

# Once iPXE is running, point it at the boot script served via HTTP
dhcp-userclass=set:ipxe,iPXE
dhcp-boot=tag:ipxe,http://${LAN_IP}/boot.ipxe
DNSMASQ

  systemctl enable dnsmasq
  if ! systemctl restart dnsmasq; then
    log "ERROR: dnsmasq failed to start — check: journalctl -xeu dnsmasq.service"
    journalctl -xeu dnsmasq.service --no-pager -n 30 | tee -a "$LOG_FILE" || true
    die "dnsmasq could not be started. See log above."
  fi
  log "dnsmasq configured and started"
}

# ---------------------------------------------------------------------------
# 6. Configure nginx (HTTP file server)
# ---------------------------------------------------------------------------
configure_nginx() {
  log "=== Configuring nginx ==="

  local web_root="/srv/ipxe"
  mkdir -p "${web_root}"

  # Copy iPXE scripts to web root
  install -m 644 "${REPO_DIR}/ipxe/boot.ipxe"   "${web_root}/boot.ipxe"
  install -m 644 "${REPO_DIR}/ipxe/ubuntu.ipxe" "${web_root}/ubuntu.ipxe"

  # Disable the default nginx site
  rm -f /etc/nginx/sites-enabled/default

  cat > /etc/nginx/sites-available/ipxe <<NGINX
# iPXE HTTP server — managed by iPXE installer
server {
    listen ${LAN_IP}:80;
    server_name _;

    root ${web_root};
    autoindex on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Serve Ubuntu preseed / autoinstall files
    location /ubuntu/ {
        alias ${web_root}/ubuntu/;
        autoindex on;
    }

    access_log /var/log/nginx/ipxe_access.log;
    error_log  /var/log/nginx/ipxe_error.log;
}
NGINX

  ln -sf /etc/nginx/sites-available/ipxe /etc/nginx/sites-enabled/ipxe
  nginx -t
  systemctl enable --now nginx
  log "nginx configured and started"
}

# ---------------------------------------------------------------------------
# 7. Deploy iPXE scripts (from repo — created in later steps)
# ---------------------------------------------------------------------------
deploy_ipxe_scripts() {
  log "=== Deploying iPXE scripts ==="

  local web_root="/srv/ipxe"
  mkdir -p "${web_root}/ubuntu"

  # Re-copy to web root (also done in configure_nginx, but explicit here)
  install -m 644 "${REPO_DIR}/ipxe/boot.ipxe"   "${web_root}/boot.ipxe"
  install -m 644 "${REPO_DIR}/ipxe/ubuntu.ipxe" "${web_root}/ubuntu.ipxe"

  # Warn if the example preseed still contains the placeholder password
  local preseed_src="${REPO_DIR}/config/ubuntu/preseed.cfg"
  if grep -q 'REPLACE_WITH_HASHED_PASSWORD' "${preseed_src}" 2>/dev/null; then
    log "WARNING: config/ubuntu/preseed.cfg still contains the placeholder password."
    log "         Edit it and set a real password hash before deploying:"
    log "           echo 'yourpassword' | mkpasswd -m sha-512 -s"
    log "         Then copy to: ${web_root}/ubuntu/preseed.cfg"
  else
    install -m 640 "${preseed_src}" "${web_root}/ubuntu/preseed.cfg"
    log "Preseed deployed to ${web_root}/ubuntu/preseed.cfg"
  fi

  log "iPXE scripts deployed to ${web_root}"
}

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
print_summary() {
  log "=== Installation complete ==="
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║              iPXE Server — Installation Summary          ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  printf "║  WAN interface  : %-38s ║\n" "$WAN_IFACE"
  printf "║  LAN interface  : %-38s ║\n" "$LAN_IFACE"
  printf "║  LAN IP / CIDR  : %-38s ║\n" "$LAN_CIDR"
  printf "║  DHCP range     : %-38s ║\n" "${DHCP_START} – ${DHCP_END}"
  printf "║  TFTP root      : %-38s ║\n" "/srv/tftp"
  printf "║  HTTP root      : %-38s ║\n" "/srv/ipxe"
  printf "║  Boot script    : %-38s ║\n" "http://${LAN_IP}/boot.ipxe"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "Logs: $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  preflight
  install_packages
  configure_network
  configure_nat
  configure_dnsmasq
  configure_nginx
  deploy_ipxe_scripts
  print_summary
}

main "$@"
