#!/usr/bin/env bash
# =============================================================================
# iPXE Server — Post-Install Check Script
# =============================================================================
# Verifies that all components installed by install.sh are present and working.
#
# Usage:
#   sudo bash check.sh [--wan <iface>] [--lan <iface>] [--lan-ip <cidr>]
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults (must match the values used in install.sh)
# ---------------------------------------------------------------------------
WAN_IFACE="ens3"
LAN_IFACE="ens4"
LAN_CIDR="192.168.100.1/24"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wan)    WAN_IFACE="$2";  shift 2 ;;
    --lan)    LAN_IFACE="$2";  shift 2 ;;
    --lan-ip) LAN_CIDR="$2";   shift 2 ;;
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

LAN_IP="${LAN_CIDR%%/*}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'  # no color

ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; (( PASS++ )) || :; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; (( FAIL++ )) || :; }
info() { echo -e "  ${YELLOW}[INFO]${NC} $*"; }

section() { echo ""; echo "── $* ──"; }

require_root() {
  [[ $EUID -eq 0 ]] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# 1. Services
# ---------------------------------------------------------------------------
check_services() {
  section "Services"

  for svc in dnsmasq nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "$svc is running"
    else
      fail "$svc is NOT running  (fix: sudo systemctl start $svc)"
    fi

    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      ok "$svc is enabled (survives reboot)"
    else
      fail "$svc is NOT enabled  (fix: sudo systemctl enable $svc)"
    fi
  done
}

# ---------------------------------------------------------------------------
# 2. Configuration files
# ---------------------------------------------------------------------------
check_configs() {
  section "Configuration files"

  local dnsmasq_conf="/etc/dnsmasq.d/ipxe.conf"
  if [[ -f "$dnsmasq_conf" ]]; then
    ok "dnsmasq config exists: $dnsmasq_conf"
  else
    fail "dnsmasq config missing: $dnsmasq_conf"
  fi

  local nginx_site="/etc/nginx/sites-enabled/ipxe"
  if [[ -L "$nginx_site" || -f "$nginx_site" ]]; then
    ok "nginx site enabled: $nginx_site"
  else
    fail "nginx site not enabled: $nginx_site"
  fi

  local netplan_file="/etc/netplan/99-ipxe-lan.yaml"
  if [[ -f "$netplan_file" ]]; then
    ok "netplan config exists: $netplan_file"
  else
    fail "netplan config missing: $netplan_file"
  fi
}

# ---------------------------------------------------------------------------
# 3. Deployed files
# ---------------------------------------------------------------------------
check_files() {
  section "Deployed files"

  local files=(
    "/srv/tftp/boot.ipxe"
    "/srv/tftp/ubuntu.ipxe"
    "/srv/ipxe/boot.ipxe"
    "/srv/ipxe/ubuntu.ipxe"
  )

  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      ok "File present: $f"
    else
      fail "File missing: $f"
    fi
  done

  # At least one iPXE boot binary should be in the TFTP root
  if [[ -f /srv/tftp/undionly.kpxe || -f /srv/tftp/ipxe.efi ]]; then
    ok "iPXE boot binary present in /srv/tftp/"
  else
    fail "No iPXE boot binary found in /srv/tftp/ (undionly.kpxe or ipxe.efi)"
  fi
}

# ---------------------------------------------------------------------------
# 4. Network interface
# ---------------------------------------------------------------------------
check_network() {
  section "Network interface"

  if ip link show "$LAN_IFACE" &>/dev/null; then
    ok "LAN interface exists: $LAN_IFACE"
  else
    fail "LAN interface not found: $LAN_IFACE"
    return
  fi

  if ip addr show "$LAN_IFACE" 2>/dev/null | grep -q "${LAN_IP}"; then
    ok "LAN interface has IP ${LAN_IP}"
  else
    fail "LAN interface $LAN_IFACE does not have IP ${LAN_IP}"
  fi
}

# ---------------------------------------------------------------------------
# 5. IP forwarding and NAT
# ---------------------------------------------------------------------------
check_nat() {
  section "IP forwarding / NAT"

  local forward
  forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
  if [[ "$forward" == "1" ]]; then
    ok "IPv4 forwarding is enabled"
  else
    fail "IPv4 forwarding is disabled  (fix: sudo sysctl -w net.ipv4.ip_forward=1)"
  fi

  if iptables -t nat -C POSTROUTING -s "${LAN_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null; then
    ok "iptables MASQUERADE rule present"
  else
    fail "iptables MASQUERADE rule missing for ${LAN_CIDR} -> ${WAN_IFACE}"
  fi

  if iptables -C FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null; then
    ok "iptables FORWARD rule (LAN -> WAN) present"
  else
    fail "iptables FORWARD rule (LAN -> WAN) missing"
  fi
}

# ---------------------------------------------------------------------------
# 6. Listening ports
# ---------------------------------------------------------------------------
check_ports() {
  section "Listening ports"

  # UDP 69 — TFTP
  if ss -ulnH 'sport = :69' 2>/dev/null | grep -q .; then
    ok "TFTP port 69/udp is listening"
  else
    fail "TFTP port 69/udp is NOT listening (dnsmasq TFTP may not be active)"
  fi

  # TCP 80 — HTTP (nginx)
  if ss -tlnH 'sport = :80' 2>/dev/null | grep -q .; then
    ok "HTTP port 80/tcp is listening"
  else
    fail "HTTP port 80/tcp is NOT listening (nginx may not be active)"
  fi
}

# ---------------------------------------------------------------------------
# 7. nginx configuration test
# ---------------------------------------------------------------------------
check_nginx_config() {
  section "nginx configuration syntax"

  if nginx -t 2>/dev/null; then
    ok "nginx configuration syntax is valid"
  else
    fail "nginx configuration has errors  (fix: sudo nginx -t)"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "══════════════════════════════════════════════════════════"
  if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}All ${PASS} checks passed — iPXE server looks healthy.${NC}"
  else
    echo -e "  ${RED}${FAIL} check(s) FAILED, ${PASS} passed.${NC}"
    echo -e "  ${RED}Review the FAIL items above and re-run install.sh if needed.${NC}"
  fi
  echo "══════════════════════════════════════════════════════════"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root

echo "iPXE Server — Health Check"
echo "WAN: ${WAN_IFACE}  |  LAN: ${LAN_IFACE}  |  LAN IP: ${LAN_CIDR}"

check_services
check_configs
check_files
check_network
check_nat
check_ports
check_nginx_config

print_summary

[[ $FAIL -eq 0 ]]
