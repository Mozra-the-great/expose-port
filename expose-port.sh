#!/bin/sh
# ============================================================
# expose-port.sh
# Pterodactyl Game Server Port Relay – Oracle ARM Setup Script
# https://github.com/familie-schran
#
# Usage:
#   ./expose-port.sh <port> [tcp|udp|both]
#
# Examples:
#   ./expose-port.sh 25565 both       # Minecraft
#   ./expose-port.sh 2456 both        # Valheim
#   ./expose-port.sh 27015 both       # CS2
# ============================================================

# ── Configuration ────────────────────────────────────────────
WINGS_IP="192.168.0.21"          # Internal IP of Wings VM
PUBLIC_IFACE="enp1s0"            # NIC facing the internet
TAILSCALE_IFACE="tailscale0"     # Tailscale interface
NFT_TABLE="gamenat"              # nftables table name
NFT_CONFIG="/etc/nftables.conf"  # Persistent nftables config
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()   { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()  { printf "${RED}[✗]${NC} %s\n" "$1"; exit 1; }

# ── Root check ───────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "Please run as root: sudo ./expose-port.sh <port> [tcp|udp|both]"
fi

# ── Usage check ──────────────────────────────────────────────
if [ -z "$1" ]; then
    printf "\nUsage: sudo ./expose-port.sh <port> [tcp|udp|both]\n\n"
    printf "Examples:\n"
    printf "  sudo ./expose-port.sh 25565 both    # Minecraft\n"
    printf "  sudo ./expose-port.sh 2456  both    # Valheim\n"
    printf "  sudo ./expose-port.sh 27015 both    # CS2\n"
    printf "  sudo ./expose-port.sh 7777  both    # Terraria\n\n"
    exit 1
fi

PORT="$1"
PROTO="${2:-both}"

# ── Validate port ────────────────────────────────────────────
if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    error "Invalid port: $PORT (must be 1-65535)"
fi

# ── Validate protocol ────────────────────────────────────────
if [ "$PROTO" != "tcp" ] && [ "$PROTO" != "udp" ] && [ "$PROTO" != "both" ]; then
    error "Invalid protocol: $PROTO (use tcp, udp, or both)"
fi

printf "\n${GREEN}======================================${NC}\n"
printf "${GREEN}  Game Server Port Relay Setup${NC}\n"
printf "${GREEN}======================================${NC}\n\n"
log "Port:      $PORT"
log "Protocol:  $PROTO"
log "Target:    $WINGS_IP:$PORT"
printf "\n"

# ── Check nft is available ───────────────────────────────────
if ! command -v nft > /dev/null 2>&1; then
    warn "nftables not found, installing..."
    apt-get install -y nftables > /dev/null 2>&1 || error "Failed to install nftables"
fi

# ── Check if table exists, create if not ─────────────────────
if ! nft list table ip "$NFT_TABLE" > /dev/null 2>&1; then
    warn "nftables table '$NFT_TABLE' not found, creating..."
    nft add table ip "$NFT_TABLE"
    nft add chain ip "$NFT_TABLE" prerouting "{ type nat hook prerouting priority -100 ; }"
    nft add chain ip "$NFT_TABLE" postrouting "{ type nat hook postrouting priority 100 ; }"
    nft add chain ip "$NFT_TABLE" forward "{ type filter hook forward priority 0 ; policy accept ; }"
    nft add rule ip "$NFT_TABLE" postrouting masquerade
    log "Created nftables table '$NFT_TABLE'"
fi

# ── Check for duplicate rules ────────────────────────────────
if nft list table ip "$NFT_TABLE" 2>/dev/null | grep -q "dport $PORT"; then
    warn "Port $PORT already has rules in nftables:"
    nft list table ip "$NFT_TABLE" | grep "dport $PORT"
    printf "\n"
    printf "Do you want to add duplicate rules? [y/N] "
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        log "Aborted. No changes made."
        exit 0
    fi
fi

# ── Add nftables DNAT rules ───────────────────────────────────
if [ "$PROTO" = "tcp" ] || [ "$PROTO" = "both" ]; then
    nft add rule ip "$NFT_TABLE" prerouting iifname "$PUBLIC_IFACE" tcp dport "$PORT" dnat to "$WINGS_IP"
    log "Added TCP $PORT → $WINGS_IP:$PORT"
fi

if [ "$PROTO" = "udp" ] || [ "$PROTO" = "both" ]; then
    nft add rule ip "$NFT_TABLE" prerouting iifname "$PUBLIC_IFACE" udp dport "$PORT" dnat to "$WINGS_IP"
    log "Added UDP $PORT → $WINGS_IP:$PORT"
fi

# ── Ensure IP forwarding is enabled ──────────────────────────
if ! sysctl -n net.ipv4.ip_forward | grep -q "^1$"; then
    warn "IP forwarding disabled, enabling..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward" /etc/sysctl.conf && \
        sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    log "IP forwarding enabled"
fi

# ── Ensure policy routing for return traffic ─────────────────
IFACE_GW=$(ip route show dev "$PUBLIC_IFACE" | grep default | awk '{print $3}' | head -1)
if [ -z "$IFACE_GW" ]; then
    # Try to derive gateway from interface IP
    IFACE_IP=$(ip -4 addr show "$PUBLIC_IFACE" | grep inet | awk '{print $2}' | cut -d/ -f1)
    IFACE_NET=$(echo "$IFACE_IP" | cut -d. -f1-3)
    IFACE_GW="${IFACE_NET}.1"
fi

if ! ip rule show | grep -q "iif $TAILSCALE_IFACE"; then
    ip route add default via "$IFACE_GW" dev "$PUBLIC_IFACE" table 201 2>/dev/null || true
    ip rule add iif "$TAILSCALE_IFACE" table 201 2>/dev/null || true
    log "Policy routing configured (return traffic via $PUBLIC_IFACE)"
fi

# ── Save nftables config ──────────────────────────────────────
nft list ruleset > "$NFT_CONFIG"
log "Saved nftables config to $NFT_CONFIG"

# ── Enable nftables on boot ───────────────────────────────────
systemctl enable nftables > /dev/null 2>&1
log "nftables enabled on boot"

# ── Summary ──────────────────────────────────────────────────
printf "\n${GREEN}======================================${NC}\n"
printf "${GREEN}  Done!${NC}\n"
printf "${GREEN}======================================${NC}\n\n"

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-public-ip>")

printf "Port ${YELLOW}$PORT${NC} is now being forwarded:\n\n"
printf "  Internet  →  ${YELLOW}$PUBLIC_IP:$PORT${NC}\n"
printf "  Oracle    →  Tailscale  →  ${YELLOW}$WINGS_IP:$PORT${NC}\n\n"

printf "${YELLOW}⚠  Don't forget:${NC}\n"
printf "  1. Add port $PORT (TCP+UDP) to Oracle Security List\n"
printf "     Cloud Console → Networking → VCN → Subnet → Security List → Add Ingress Rule\n"
printf "  2. Add port $PORT as an Allocation in Pterodactyl Panel\n"
printf "     http://192.168.0.20/admin/nodes/1/allocation\n\n"
