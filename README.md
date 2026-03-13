# iPXE-Ubuntu

Automated iPXE server setup for Ubuntu.

This project installs and configures a fully functional iPXE boot server that:

- **Isolates** the installation network from the enterprise network (dedicated LAN interface).
- **Acts as a NAT gateway** so machines being installed can reach the internet through the server.
- Provides **DHCP + TFTP** (via dnsmasq) for PXE booting (BIOS and UEFI).
- Provides an **HTTP server** (nginx) for serving iPXE scripts and Ubuntu preseed/autoinstall files.

---

## Architecture

```
Internet
    │
    │  WAN interface (ens3) — enterprise network
    ▼
┌───────────────────────────────┐
│        iPXE Server            │  ← this machine (Ubuntu)
│  IP forward + NAT (iptables)  │
│  DHCP + TFTP  (dnsmasq)       │
│  HTTP         (nginx)         │
└───────────────────────────────┘
    │
    │  LAN interface (ens4) — isolated installation network
    │  Server IP: 192.168.100.1/24
    │  DHCP pool: 192.168.100.100 – 192.168.100.200
    ▼
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Node 1  │  │  Node 2  │  │  Node N  │   ← machines being installed
└──────────┘  └──────────┘  └──────────┘
```

The installation network is **fully isolated** from the enterprise network at layer 2 — only the server bridges traffic (with NAT), so machines being installed cannot interact directly with the enterprise network.

---

## Requirements

| Item | Requirement |
|------|-------------|
| OS   | Ubuntu 20.04 / 22.04 / 24.04 LTS |
| NICs | At least **2** network interfaces |
| Internet | Required during installation (to download packages) |
| Privileges | `sudo` / root |

---

## Quick Start

### 1 — Clone the repository

```bash
git clone https://github.com/benk79hes/iPXE-Ubuntu.git
cd iPXE-Ubuntu
```

### 2 — Run the installer

```bash
sudo bash install.sh
```

The installer uses sensible defaults. Override them with flags:

```bash
sudo bash install.sh \
  --wan  ens3 \          # upstream / enterprise NIC  (default: ens3)
  --lan  ens4 \          # downstream / install NIC   (default: ens4)
  --lan-ip 192.168.100.1/24 \   # LAN static IP      (default: 192.168.100.1/24)
  --dhcp-start 192.168.100.100 \
  --dhcp-end   192.168.100.200
```

> **Tip**: run `ip link` to list your network interface names before running the installer.

### 3 — (Optional) Deploy a preseed file

Copy the example preseed to the HTTP root and customise it:

```bash
sudo cp config/ubuntu/preseed.cfg /srv/ipxe/ubuntu/preseed.cfg
sudo nano /srv/ipxe/ubuntu/preseed.cfg   # set password hash, hostname, timezone, etc.
```

Generate a password hash:
```bash
echo "yourpassword" | mkpasswd -m sha-512 -s
```

### 4 — Connect the installation switch

Plug the machines to be installed into the switch connected to the LAN interface (`ens4`).  
Configure their BIOS/UEFI to boot from the network (PXE). They will:

1. Receive an IP address from the DHCP server.
2. Download the iPXE bootloader via TFTP.
3. Load the boot menu from `http://192.168.100.1/boot.ipxe`.
4. Start the Ubuntu installation.

---

## File Structure

```
iPXE-Ubuntu/
├── install.sh               # Main installer — run this
├── uninstall.sh             # Removes all installed config
├── check.sh                 # Post-install health check — run after install.sh
├── ipxe/
│   ├── boot.ipxe            # iPXE boot menu script
│   └── ubuntu.ipxe          # Ubuntu netboot script
└── config/                  # Reference configuration templates
    ├── dnsmasq.conf         # DHCP + TFTP template
    ├── nginx.conf           # HTTP server template
    ├── netplan/
    │   └── 99-ipxe-lan.yaml # LAN interface static IP template
    ├── iptables/
    │   └── rules.v4         # iptables NAT rules template
    └── ubuntu/
        └── preseed.cfg      # Ubuntu legacy preseed template
```

---

## Services Installed

| Service | Purpose | Config location |
|---------|---------|-----------------|
| **dnsmasq** | DHCP + TFTP server | `/etc/dnsmasq.d/ipxe.conf` |
| **nginx** | HTTP file server (iPXE scripts, preseed) | `/etc/nginx/sites-available/ipxe` |
| **iptables-persistent** | Persist NAT rules across reboots | `/etc/iptables/rules.v4` |
| **ipxe** | Provides `undionly.kpxe` and `ipxe.efi` | `/srv/tftp/` |

---

## Network Isolation Details

The isolation is achieved through two mechanisms:

1. **Layer-2 separation**: The LAN interface is a separate physical (or virtual) NIC connected to a dedicated switch or VLAN. The enterprise network is on the WAN interface only.

2. **Layer-3 NAT**: `iptables` MASQUERADE rules translate all outbound traffic from the installation network (`192.168.100.0/24`) to the WAN IP. Machines on the installation network cannot be directly reached from the enterprise network (only `RELATED,ESTABLISHED` traffic is allowed back).

The relevant iptables rules installed are:

```
-t nat -A POSTROUTING -s 192.168.100.0/24 -o ens3 -j MASQUERADE
-A FORWARD -i ens4 -o ens3 -j ACCEPT
-A FORWARD -i ens3 -o ens4 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

---

## Customising the Boot Menu

Edit `ipxe/boot.ipxe` to add more operating systems or utilities.  
After editing, re-deploy to the HTTP root:

```bash
sudo cp ipxe/boot.ipxe   /srv/ipxe/boot.ipxe
sudo cp ipxe/ubuntu.ipxe /srv/ipxe/ubuntu.ipxe
```

---

## Verify the Installation

After running the installer, use `check.sh` to confirm that all services, files,
and network settings are in place:

```bash
sudo bash check.sh
```

Pass the same flags you used for `install.sh` if you changed the defaults:

```bash
sudo bash check.sh --wan ens3 --lan ens4 --lan-ip 192.168.100.1/24
```

The script checks:

| Check | What is verified |
|-------|-----------------|
| Services | `dnsmasq` and `nginx` are running and enabled |
| Config files | `/etc/dnsmasq.d/ipxe.conf`, nginx site, netplan file |
| Deployed files | iPXE scripts in `/srv/tftp/` and `/srv/ipxe/`, boot binaries |
| Network | LAN interface exists and has the expected IP |
| IP forwarding / NAT | `ip_forward=1`, iptables MASQUERADE and FORWARD rules |
| Ports | UDP 69 (TFTP) and TCP 80 (HTTP) are listening |
| nginx syntax | `nginx -t` passes |

A green `[PASS]` / red `[FAIL]` result is printed for each item.  
The script exits with code `0` when all checks pass, or `1` if any fail.

---

## Uninstall

To remove all configuration added by the installer (packages are left intact):

```bash
sudo bash uninstall.sh --wan ens3 --lan ens4
```

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---------|-------------|-----|
| Machines don't get an IP | Wrong LAN interface | Verify with `ip link`; re-run installer with correct `--lan` |
| TFTP timeout | Firewall blocking UDP 69 | `sudo ufw allow in on ens4` or disable ufw on LAN |
| Cannot reach internet from installed node | NAT not active | `sudo iptables -t nat -L -n -v` and check MASQUERADE rule |
| nginx 403 on preseed | Wrong file permissions | `sudo chmod 644 /srv/ipxe/ubuntu/preseed.cfg` |

Logs:

- Installer: `/var/log/ipxe-install.log`
- DHCP/TFTP: `journalctl -u dnsmasq -f`
- HTTP: `/var/log/nginx/ipxe_access.log`, `/var/log/nginx/ipxe_error.log`
