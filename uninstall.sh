#!/usr/bin/env bash
# =============================================================================
# iPXE Server — Uninstaller / cleanup
# =============================================================================
# Removes all configuration added by install.sh.
# Does NOT remove packages (dnsmasq, nginx, ipxe) to avoid breaking other
# services that may rely on them.
# =============================================================================
set -euo pipefail

WAN_IFACE="ens3"
LAN_IFACE="ens4"
LAN_CIDR="192.168.100.1/24"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wan)  WAN_IFACE="$2"; shift 2 ;;
    --lan)  LAN_IFACE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

require_root() { [[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }; }
require_root

echo "=== Removing iPXE server configuration ==="

# dnsmasq
rm -f /etc/dnsmasq.d/ipxe.conf
systemctl restart dnsmasq 2>/dev/null || true

# nginx
rm -f /etc/nginx/sites-enabled/ipxe
rm -f /etc/nginx/sites-available/ipxe
systemctl restart nginx 2>/dev/null || true

# Netplan
rm -f /etc/netplan/99-ipxe-lan.yaml
netplan apply 2>/dev/null || true

# iptables rules
iptables -t nat -D POSTROUTING -s "${LAN_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "${WAN_IFACE}" -o "${LAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# IP forwarding (revert to disabled)
sed -i '/^net\.ipv4\.ip_forward/d' /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true

# Data
rm -rf /srv/tftp /srv/ipxe

echo "=== Cleanup complete ==="
