#!/bin/sh
# ============================================================
# expose-port.sh
# Pterodactyl Game Server Port Relay – Oracle ARM Setup Script
# https://github.com/familie-schran
#
# Usage:
#   ./expose-port.sh [--dry-run] <port> [tcp|udp|both]
#
# <port>     decimal 1-65535, digits only, no leading zeros
# --dry-run  print the commands that would change the system instead of
#            running them (read-only queries still run, so root is needed)
#
# Examples:
#   ./expose-port.sh 25565 both       # Minecraft
#   ./expose-port.sh 2456 both        # Valheim
#   ./expose-port.sh 27015 both       # CS2
#   ./expose-port.sh --dry-run 7777 tcp
# ============================================================

# ── Configuration ────────────────────────────────────────────
WINGS_IP="192.168.0.21"          # Internal IP of Wings VM
PUBLIC_IFACE="enp1s0"            # NIC facing the internet
TAILSCALE_IFACE="tailscale0"     # Tailscale interface
NFT_TABLE="gamenat"              # nftables table name
# File paths; overridable through the environment so the tests never touch /etc
NFT_CONFIG="${NFT_CONFIG:-/etc/nftables.conf}"      # Persistent nftables config
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"      # Persistent sysctl settings
# ─────────────────────────────────────────────────────────────

RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
NC='[0m'

DRY_RUN=0
# Newline-separated list of changes already made, reported if a later step fails
APPLIED=""

log()    { printf "${GREEN}[+]${NC} %s
" "$1"; }
warn()   { printf "${YELLOW}[!]${NC} %s
" "$1"; }
# Print the error and, if some changes were already made, which ones (no rollback).
error()  {
    printf "${RED}[✗]${NC} %s
" "$1"
    if [ -n "$APPLIED" ]; then
        warn "Partially applied, NOT rolled back. Already changed before the failure:"
        printf '%s' "$APPLIED"
        printf "    Inspect with: nft list table ip %s
" "$NFT_TABLE"
    fi
    exit 1
}

# Success message for a real change; silent in --dry-run (nothing happened).
ok()     { [ "$DRY_RUN" -eq 1 ] || log "$1"; }

# Quote one argument for display so a printed command can be pasted into a shell.
quote_arg() {
    case $1 in
        ''|*[!A-Za-z0-9_./:=,@%+-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# fmt_cmd <cmd> [args...] -> "cmd arg1 'arg 2'"
fmt_cmd() {
    _out=""
    for _arg in "$@"; do
        _out="$_out $(quote_arg "$_arg")"
    done
    printf '%s' "${_out# }"
}

# run <cmd> [args...]: execute a command that changes the system. Output is hidden on
# success and shown on failure; a non-zero exit aborts the script. In --dry-run the
# command is only printed.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s
' "$(fmt_cmd "$@")"
        return 0
    fi
    _output=$("$@" 2>&1)
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        error "Command failed (exit $_rc): $(fmt_cmd "$@")${_output:+ -- $_output}"
    fi
    APPLIED="${APPLIED}    - $(fmt_cmd "$@")
"
}

# A valid port is 1-65535: digits only, no leading zeros, at most 5 characters. The
# text is checked before any arithmetic so that huge values cannot make `[ -le ]`
# error out ("Illegal number") and slip through as "not greater".
is_valid_port() {
    case $1 in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -le 65535 ]
}

if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

# ── Root check ───────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "Please run as root: sudo ./expose-port.sh <port> [tcp|udp|both]"
fi

# ── Usage check ──────────────────────────────────────────────
if [ -z "$1" ]; then
    printf "\nUsage: sudo ./expose-port.sh [--dry-run] <port> [tcp|udp|both]\n\n"
    printf "Examples:\n"
    printf "  sudo ./expose-port.sh 25565 both    # Minecraft\n"
    printf "  sudo ./expose-port.sh 2456  both    # Valheim\n"
    printf "  sudo ./expose-port.sh 27015 both    # CS2\n"
    printf "  sudo ./expose-port.sh 7777  both    # Terraria\n"
    printf "  sudo ./expose-port.sh --dry-run 7777 tcp    # only show the commands\n\n"
    exit 1
fi

PORT="$1"
PROTO="${2:-both}"

# ── Validate port ────────────────────────────────────────────
if ! is_valid_port "$PORT"; then
    error "Invalid port: $PORT (must be 1-65535, digits only, no leading zeros)"
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
if [ "$DRY_RUN" -eq 1 ]; then
    warn "Dry run: system-changing commands are printed, not executed"
fi
printf "\n"

# ── Check nft is available ───────────────────────────────────
if ! command -v nft > /dev/null 2>&1; then
    warn "nftables not found, installing..."
    run apt-get install -y nftables
fi

# ── Check if table exists, create if not ─────────────────────
if ! nft list table ip "$NFT_TABLE" > /dev/null 2>&1; then
    warn "nftables table '$NFT_TABLE' not found, creating..."
    run nft add table ip "$NFT_TABLE"
    run nft add chain ip "$NFT_TABLE" prerouting "{ type nat hook prerouting priority -100 ; }"
    run nft add chain ip "$NFT_TABLE" postrouting "{ type nat hook postrouting priority 100 ; }"
    run nft add chain ip "$NFT_TABLE" forward "{ type filter hook forward priority 0 ; policy accept ; }"
    run nft add rule ip "$NFT_TABLE" postrouting masquerade
    ok "Created nftables table '$NFT_TABLE'"
fi

# ── Check for duplicate rules ────────────────────────────────
# Match the whole port token: "dport 80" must not match "dport 8080".
DUP_RE="dport $PORT( |\$)"
if nft list table ip "$NFT_TABLE" 2>/dev/null | grep -Eq "$DUP_RE"; then
    warn "Port $PORT already has rules in nftables:"
    nft list table ip "$NFT_TABLE" | grep -E "$DUP_RE"
    printf "\n"
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "Dry run: the real run would ask before adding duplicate rules"
    else
        printf "Do you want to add duplicate rules? [y/N] "
        read -r CONFIRM
        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            log "Aborted. No changes made."
            exit 0
        fi
    fi
fi

# ── Add nftables DNAT rules ───────────────────────────────────
if [ "$PROTO" = "tcp" ] || [ "$PROTO" = "both" ]; then
    run nft add rule ip "$NFT_TABLE" prerouting iifname "$PUBLIC_IFACE" tcp dport "$PORT" dnat to "$WINGS_IP"
    ok "Added TCP $PORT → $WINGS_IP:$PORT"
fi

if [ "$PROTO" = "udp" ] || [ "$PROTO" = "both" ]; then
    run nft add rule ip "$NFT_TABLE" prerouting iifname "$PUBLIC_IFACE" udp dport "$PORT" dnat to "$WINGS_IP"
    ok "Added UDP $PORT → $WINGS_IP:$PORT"
fi

# ── Ensure IP forwarding is enabled ──────────────────────────
if ! sysctl -n net.ipv4.ip_forward | grep -q "^1$"; then
    warn "IP forwarding disabled, enabling..."
    run sysctl -w net.ipv4.ip_forward=1
    if grep -q "net.ipv4.ip_forward" "$SYSCTL_CONF" 2> /dev/null; then
        run sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' "$SYSCTL_CONF"
    elif [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] echo net.ipv4.ip_forward=1 >> %s\n' "$SYSCTL_CONF"
    else
        echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF" \
            || error "Cannot append to $SYSCTL_CONF"
        APPLIED="${APPLIED}    - echo net.ipv4.ip_forward=1 >> $SYSCTL_CONF
"
    fi
    ok "IP forwarding enabled"
fi

# ── Ensure policy routing for return traffic ─────────────────
if ! ip rule show | grep -q "iif $TAILSCALE_IFACE"; then
    IFACE_GW=$(ip route show dev "$PUBLIC_IFACE" | grep default | awk '{print $3}' | head -1)
    if [ -z "$IFACE_GW" ]; then
        # Try to derive gateway from interface IP
        IFACE_IP=$(ip -4 addr show "$PUBLIC_IFACE" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
        if [ -z "$IFACE_IP" ]; then
            error "Cannot determine a gateway for $PUBLIC_IFACE (no default route, no IPv4 address)"
        fi
        IFACE_NET=$(echo "$IFACE_IP" | cut -d. -f1-3)
        IFACE_GW="${IFACE_NET}.1"
    fi
    # `replace` is idempotent: a leftover route in table 201 is not an error
    run ip route replace default via "$IFACE_GW" dev "$PUBLIC_IFACE" table 201
    run ip rule add iif "$TAILSCALE_IFACE" table 201
    ok "Policy routing configured (return traffic via $PUBLIC_IFACE)"
fi

# ── Save nftables config ──────────────────────────────────────
# Write to a temp file first: `nft list ruleset > "$NFT_CONFIG"` would truncate the
# persistent config before nft ran, leaving it empty if nft fails.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] nft list ruleset > %s\n' "$NFT_CONFIG"
else
    NFT_TMP=$(mktemp) || error "Cannot create a temporary file to save the nftables config"
    if ! nft list ruleset > "$NFT_TMP"; then
        rm -f "$NFT_TMP"
        error "Command failed: nft list ruleset ($NFT_CONFIG left untouched)"
    fi
    if ! cat "$NFT_TMP" > "$NFT_CONFIG"; then
        rm -f "$NFT_TMP"
        error "Cannot write $NFT_CONFIG"
    fi
    rm -f "$NFT_TMP"
    APPLIED="${APPLIED}    - nft list ruleset > $NFT_CONFIG
"
    log "Saved nftables config to $NFT_CONFIG"
fi

# ── Enable nftables on boot ───────────────────────────────────
run systemctl enable nftables
ok "nftables enabled on boot"

# ── Summary ──────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    printf "\n${GREEN}======================================${NC}\n"
    printf "${GREEN}  Dry run complete - nothing was changed${NC}\n"
    printf "${GREEN}======================================${NC}\n\n"
    exit 0
fi

printf "\n${GREEN}======================================${NC}\n"
printf "${GREEN}  Done!${NC}\n"
printf "${GREEN}======================================${NC}\n\n"

# Only an IPv4-looking answer is used; anything else (HTML error page, empty) is ignored.
PUBLIC_IP=$(curl -s -f --max-time 5 ifconfig.me 2>/dev/null)
case $PUBLIC_IP in
    ''|*[!0-9.]*) PUBLIC_IP="<your-public-ip>" ;;
esac

printf "Port ${YELLOW}%s${NC} is now being forwarded:\n\n" "$PORT"
printf "  Internet  →  ${YELLOW}%s:%s${NC}\n" "$PUBLIC_IP" "$PORT"
printf "  Oracle    →  Tailscale  →  ${YELLOW}%s:%s${NC}\n\n" "$WINGS_IP" "$PORT"

printf "${YELLOW}⚠  Don't forget:${NC}\n"
printf "  1. Add port %s (TCP+UDP) to Oracle Security List\n" "$PORT"
printf "     Cloud Console → Networking → VCN → Subnet → Security List → Add Ingress Rule\n"
printf "  2. Add port %s as an Allocation in Pterodactyl Panel\n" "$PORT"
printf "     http://192.168.0.20/admin/nodes/1/allocation\n\n"
