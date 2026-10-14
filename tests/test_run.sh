#!/bin/sh
# Behaviour tests for expose-port.sh past the argument checks: --dry-run output for
# tcp/udp/both, the normal run, and every failure path of the mutating commands.
# SAFE BY CONSTRUCTION, like test_args.sh:
#
#   - never runs as real root (the script is a root script);
#   - every system tool the script calls (nft, ip, sysctl, systemctl, apt-get, curl,
#     id) is a mock on PATH that only appends the call to a log; nothing reaches the
#     host. The mocks answer the read-only queries from MOCK_* variables and fail on
#     demand (MOCK_FAIL = substring of "<command> <args>");
#   - every other tool that could change the host or the network (iptables, ufw, ssh,
#     ...) is a stub that fails the test if it is ever called;
#   - the two files the script writes (NFT_CONFIG, SYSCTL_CONF) point into a temp dir.

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/expose-port.sh
TEST_SH=${TEST_SH:-sh}

if [ "$(id -u)" -eq 0 ]; then
  echo "test_run: refusing to run as root" >&2
  exit 1
fi

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM

MOCK_DIR=$TEST_TMP/mock
FORBIDDEN_DIR=$TEST_TMP/forbidden
mkdir -p "$MOCK_DIR" "$FORBIDDEN_DIR"

MOCK_LIB=$MOCK_DIR/mock_lib.sh
MOCK_CALL_LOG=$TEST_TMP/calls.log
FORBIDDEN_LOG=$TEST_TMP/forbidden.log
NFT_CONFIG=$TEST_TMP/nftables.conf
SYSCTL_CONF=$TEST_TMP/sysctl.conf
: > "$MOCK_CALL_LOG"
: > "$FORBIDDEN_LOG"

# Settings of the mocks; reset_mocks gives every case the same starting point.
MOCK_TABLE=1
MOCK_LISTING=''
MOCK_FORWARD=1
MOCK_IP_RULE=''
MOCK_IP_ROUTE=''
MOCK_IP_ADDR=''
MOCK_FAIL=''
MOCK_CURL=''
STDIN=''
export MOCK_LIB MOCK_CALL_LOG NFT_CONFIG SYSCTL_CONF
export MOCK_TABLE MOCK_LISTING MOCK_FORWARD MOCK_IP_RULE MOCK_IP_ROUTE MOCK_IP_ADDR \
  MOCK_FAIL MOCK_CURL

# Shared by all mocks: log the call, fail when it matches MOCK_FAIL.
cat > "$MOCK_LIB" <<'LIB'
mock_begin() {
  echo "$*" >> "$MOCK_CALL_LOG"
  if [ -n "${MOCK_FAIL:-}" ]; then
    case "$*" in
      *"$MOCK_FAIL"*)
        echo "mock failure: $*" >&2
        exit 1
        ;;
    esac
  fi
}
LIB

mk_mock() {
  # shellcheck disable=SC2016  # the generated stub must expand $MOCK_LIB/$@ itself
  { printf '#!/bin/sh\n. "$MOCK_LIB"\nmock_begin %s "$@"\n' "$1"; cat; } > "$MOCK_DIR/$1"
  chmod +x "$MOCK_DIR/$1"
}

mk_mock nft <<'BODY'
case "$*" in
  "list table ip gamenat")
    if [ "$MOCK_TABLE" = 1 ]; then printf '%s\n' "$MOCK_LISTING"; exit 0; fi
    exit 1 ;;
  "list ruleset") echo "table ip gamenat { }" ;;
esac
exit 0
BODY

mk_mock ip <<'BODY'
case "$*" in
  "rule show") printf '%s\n' "$MOCK_IP_RULE" ;;
  "route show dev enp1s0") printf '%s\n' "$MOCK_IP_ROUTE" ;;
  "-4 addr show enp1s0") printf '%s\n' "$MOCK_IP_ADDR" ;;
esac
exit 0
BODY

mk_mock sysctl <<'BODY'
case "$*" in
  "-n net.ipv4.ip_forward") echo "$MOCK_FORWARD" ;;
esac
exit 0
BODY

mk_mock systemctl <<'BODY'
exit 0
BODY

mk_mock apt-get <<'BODY'
exit 0
BODY

mk_mock curl <<'BODY'
if [ "$MOCK_CURL" = FAIL ]; then exit 22; fi
printf '%s' "$MOCK_CURL"
BODY

# `id -u` -> 0 so the root check passes; anything else falls through to the real id.
REAL_ID=$(command -v id)
cat > "$MOCK_DIR/id" <<STUB
#!/bin/sh
if [ "\${1:-}" = "-u" ]; then
  echo 0
else
  exec "$REAL_ID" "\$@"
fi
STUB
chmod +x "$MOCK_DIR/id"

for cmd in apt wget iptables ip6tables ufw ssh scp tailscale firewall-cmd modprobe sudo; do
  cat > "$FORBIDDEN_DIR/$cmd" <<STUB
#!/bin/sh
echo "$cmd \$*" >> "$FORBIDDEN_LOG"
exit 99
STUB
  chmod +x "$FORBIDDEN_DIR/$cmd"
done

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

reset_mocks() {
  MOCK_TABLE=1
  MOCK_LISTING=''
  MOCK_FORWARD=1
  MOCK_IP_RULE='10: from all iif tailscale0 lookup 201'
  MOCK_IP_ROUTE='default via 10.0.0.1 proto dhcp src 10.0.0.5'
  MOCK_IP_ADDR='    inet 10.0.0.5/24 brd 10.0.0.255 scope global enp1s0'
  MOCK_FAIL=''
  MOCK_CURL='203.0.113.7'
  STDIN=''
  rm -f "$NFT_CONFIG" "$SYSCTL_CONF"
  : > "$MOCK_CALL_LOG"
  : > "$FORBIDDEN_LOG"
}

# run_script [args...] -> OUT (stdout+stderr), RC
run_script() {
  : > "$MOCK_CALL_LOG"
  OUT=$(printf '%s' "$STDIN" | PATH="$MOCK_DIR:$FORBIDDEN_DIR:$PATH" "$TEST_SH" "$SCRIPT" "$@" 2>&1)
  RC=$?
  if [ -s "$FORBIDDEN_LOG" ]; then
    fail "a forbidden tool was called: $(tr '\n' ';' < "$FORBIDDEN_LOG")"
  fi
}

# ── assertions ───────────────────────────────────────────────────────────────
rc_is() { # <name> <rc>
  if [ "$RC" -eq "$2" ]; then pass; else fail "$1: expected exit $2, got $RC ($OUT)"; fi
}
out_has() { # <name> <text>
  case "$OUT" in *"$2"*) pass ;; *) fail "$1: output lacks '$2' ($OUT)" ;; esac
}
out_lacks() { # <name> <text>
  case "$OUT" in *"$2"*) fail "$1: output contains '$2' ($OUT)" ;; *) pass ;; esac
}
called() { # <name> <exact call line>
  if grep -Fxq -- "$2" "$MOCK_CALL_LOG"; then pass; else
    fail "$1: not called: '$2' (calls: $(tr '\n' ';' < "$MOCK_CALL_LOG"))"
  fi
}
not_called() { # <name> <substring of a call line>
  if grep -Fq -- "$2" "$MOCK_CALL_LOG"; then
    fail "$1: unexpected call matching '$2' (calls: $(tr '\n' ';' < "$MOCK_CALL_LOG"))"
  else pass; fi
}
# Nothing but the read-only queries may have been called (dry-run contract).
only_reads() { # <name>
  extra=$(grep -Fvx \
    -e 'nft list table ip gamenat' -e 'ip rule show' -e 'ip route show dev enp1s0' \
    -e 'ip -4 addr show enp1s0' -e 'sysctl -n net.ipv4.ip_forward' "$MOCK_CALL_LOG")
  if [ -z "$extra" ]; then pass; else fail "$1: state-changing calls: $(echo "$extra" | tr '\n' ';')"; fi
}
file_is() { # <name> <path> <expected content>
  if [ "$(cat "$2" 2> /dev/null)" = "$3" ]; then pass; else
    fail "$1: $2 is '$(cat "$2" 2> /dev/null)', expected '$3'"
  fi
}
no_file() { # <name> <path>
  if [ -e "$2" ]; then fail "$1: $2 must not exist"; else pass; fi
}

TCP="nft add rule ip gamenat prerouting iifname enp1s0 tcp dport 25565 dnat to 192.168.0.21"
UDP="nft add rule ip gamenat prerouting iifname enp1s0 udp dport 25565 dnat to 192.168.0.21"
CHAIN_PRE="nft add chain ip gamenat prerouting { type nat hook prerouting priority -100 ; }"
CHAIN_PRE_SHOWN="nft add chain ip gamenat prerouting '{ type nat hook prerouting priority -100 ; }'"

# ── --dry-run: everything missing, so every step shows up ────────────────────
reset_mocks
MOCK_TABLE=0 MOCK_FORWARD=0 MOCK_IP_RULE=''
run_script --dry-run 25565 both
rc_is "dry-run both" 0
out_has "dry-run both: table" "[dry-run] nft add table ip gamenat"
out_has "dry-run both: chain is quoted for pasting" "[dry-run] $CHAIN_PRE_SHOWN"
out_has "dry-run both: masquerade" "[dry-run] nft add rule ip gamenat postrouting masquerade"
out_has "dry-run both: tcp rule" "[dry-run] $TCP"
out_has "dry-run both: udp rule" "[dry-run] $UDP"
out_has "dry-run both: sysctl" "[dry-run] sysctl -w net.ipv4.ip_forward=1"
out_has "dry-run both: sysctl.conf" "[dry-run] echo net.ipv4.ip_forward=1 >> $SYSCTL_CONF"
out_has "dry-run both: route" "[dry-run] ip route replace default via 10.0.0.1 dev enp1s0 table 201"
out_has "dry-run both: rule" "[dry-run] ip rule add iif tailscale0 table 201"
out_has "dry-run both: save" "[dry-run] nft list ruleset > $NFT_CONFIG"
out_has "dry-run both: enable" "[dry-run] systemctl enable nftables"
out_has "dry-run both: says nothing changed" "nothing was changed"
out_lacks "dry-run both: no success claim" "Added TCP"
out_lacks "dry-run both: no forwarding claim" "is now being forwarded"
only_reads "dry-run both"
no_file "dry-run both: nftables.conf" "$NFT_CONFIG"
no_file "dry-run both: sysctl.conf" "$SYSCTL_CONF"

reset_mocks
run_script --dry-run 25565 tcp
rc_is "dry-run tcp" 0
out_has "dry-run tcp: tcp rule" "[dry-run] $TCP"
out_lacks "dry-run tcp: no udp rule" "udp dport"
only_reads "dry-run tcp"

reset_mocks
run_script --dry-run 25565 udp
rc_is "dry-run udp" 0
out_has "dry-run udp: udp rule" "[dry-run] $UDP"
out_lacks "dry-run udp: no tcp rule" "tcp dport"
only_reads "dry-run udp"

reset_mocks
run_script --dry-run 25565
rc_is "dry-run default protocol" 0
out_has "dry-run default protocol: tcp" "[dry-run] $TCP"
out_has "dry-run default protocol: udp" "[dry-run] $UDP"

# existing table, forwarding on, routing configured: only the rules and the save
reset_mocks
run_script --dry-run 25565 both
out_lacks "dry-run steady state: no table" "nft add table"
out_lacks "dry-run steady state: no sysctl" "sysctl -w"
out_lacks "dry-run steady state: no routing" "ip rule add"
out_has "dry-run steady state: save" "[dry-run] nft list ruleset > $NFT_CONFIG"

# sysctl.conf already has the setting: it is edited in place, and left alone by dry-run
reset_mocks
MOCK_FORWARD=0
printf 'a=1\nnet.ipv4.ip_forward=0\nb=2\n' > "$SYSCTL_CONF"
run_script --dry-run 25565 tcp
out_has "dry-run sed" "[dry-run] sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' $SYSCTL_CONF"
file_is "dry-run leaves sysctl.conf" "$SYSCTL_CONF" "a=1
net.ipv4.ip_forward=0
b=2"
only_reads "dry-run sed"

# dry-run does not prompt for duplicates
reset_mocks
MOCK_LISTING='tcp dport 25565 dnat to 192.168.0.21'
run_script --dry-run 25565 tcp
rc_is "dry-run duplicate" 0
out_has "dry-run duplicate: notice" "would ask before adding duplicate rules"
out_has "dry-run duplicate: still shows the rule" "[dry-run] $TCP"

# --dry-run does not skip validation
reset_mocks
run_script --dry-run abc
rc_is "dry-run invalid port" 1
out_has "dry-run invalid port" "Invalid port: abc"
run_script --dry-run 25565 icmp
rc_is "dry-run invalid protocol" 1
out_has "dry-run invalid protocol" "Invalid protocol: icmp"
run_script --dry-run
rc_is "dry-run without port" 1
out_has "dry-run without port" "Usage: sudo ./expose-port.sh [--dry-run]"
only_reads "dry-run validation"

# ── normal run ───────────────────────────────────────────────────────────────
reset_mocks
MOCK_FORWARD=0 MOCK_IP_RULE=''
run_script 25565 both
rc_is "run both" 0
called "run both: tcp rule" "$TCP"
called "run both: udp rule" "$UDP"
called "run both: sysctl" "sysctl -w net.ipv4.ip_forward=1"
called "run both: route" "ip route replace default via 10.0.0.1 dev enp1s0 table 201"
called "run both: rule" "ip rule add iif tailscale0 table 201"
called "run both: save" "nft list ruleset"
called "run both: enable" "systemctl enable nftables"
not_called "run both: table exists" "nft add table"
file_is "run both: sysctl.conf" "$SYSCTL_CONF" "net.ipv4.ip_forward=1"
file_is "run both: nftables.conf" "$NFT_CONFIG" "table ip gamenat { }"
out_has "run both: summary" "is now being forwarded"
out_has "run both: public ip" "203.0.113.7:25565"
out_has "run both: target" "192.168.0.21:25565"
out_lacks "run both: no dry-run output" "[dry-run]"

reset_mocks
MOCK_TABLE=0
run_script 25565 tcp
rc_is "run tcp, table missing" 0
called "run tcp: table" "nft add table ip gamenat"
called "run tcp: chain" "$CHAIN_PRE"
called "run tcp: masquerade" "nft add rule ip gamenat postrouting masquerade"
called "run tcp: tcp rule" "$TCP"
not_called "run tcp: no udp rule" "udp dport"
not_called "run tcp: forwarding already on" "sysctl -w"
not_called "run tcp: routing already set" "ip rule add"

reset_mocks
run_script 25565 udp
called "run udp: udp rule" "$UDP"
not_called "run udp: no tcp rule" "tcp dport"

# the existing setting in sysctl.conf is rewritten, other lines survive
reset_mocks
MOCK_FORWARD=0
printf 'a=1\nnet.ipv4.ip_forward=0\nb=2\n' > "$SYSCTL_CONF"
run_script 25565 tcp
rc_is "run sysctl.conf edit" 0
file_is "run sysctl.conf edit" "$SYSCTL_CONF" "a=1
net.ipv4.ip_forward=1
b=2"

# gateway derived from the interface address when there is no default route
reset_mocks
MOCK_IP_RULE='' MOCK_IP_ROUTE=''
run_script 25565 tcp
called "run derived gateway" "ip route replace default via 10.0.0.1 dev enp1s0 table 201"
reset_mocks
MOCK_IP_RULE='' MOCK_IP_ROUTE='' MOCK_IP_ADDR=''
run_script 25565 tcp
rc_is "run no gateway at all" 1
out_has "run no gateway at all" "Cannot determine a gateway for enp1s0"
not_called "run no gateway at all: nothing bogus added" "ip route replace"

# the public IP never reaches printf as a format, and junk answers are dropped
for junk in '%s%s%d%n' '<html>502 Bad Gateway</html>' 'FAIL' ''; do
  reset_mocks
  MOCK_CURL=$junk
  run_script 25565 tcp
  rc_is "run junk public ip '$junk'" 0
  out_has "run junk public ip '$junk'" "<your-public-ip>:25565"
done

# ── duplicate rules prompt ───────────────────────────────────────────────────
reset_mocks
MOCK_LISTING='tcp dport 25565 dnat to 192.168.0.21' STDIN='n
'
run_script 25565 tcp
rc_is "duplicate, answer n" 0
out_has "duplicate, answer n" "Aborted. No changes made."
not_called "duplicate, answer n: nothing added" "nft add rule"
not_called "duplicate, answer n: nothing saved" "nft list ruleset"
no_file "duplicate, answer n: nftables.conf" "$NFT_CONFIG"

reset_mocks
MOCK_LISTING='tcp dport 25565 dnat to 192.168.0.21' STDIN='y
'
run_script 25565 tcp
rc_is "duplicate, answer y" 0
called "duplicate, answer y: rule added" "$TCP"

reset_mocks
MOCK_LISTING='tcp dport 25565 dnat to 192.168.0.21'
run_script 25565 tcp
out_has "duplicate, no answer (EOF) aborts" "Aborted. No changes made."
not_called "duplicate, no answer: nothing added" "nft add rule"

# a rule for dport 8080 is not a duplicate of port 80, and one at line end is a duplicate of 80
reset_mocks
MOCK_LISTING='tcp dport 8080 dnat to 192.168.0.21'
run_script 80 tcp
rc_is "port 80 vs rule for 8080" 0
out_lacks "port 80 vs rule for 8080: no prompt" "duplicate"
called "port 80 vs rule for 8080: rule added" "nft add rule ip gamenat prerouting iifname enp1s0 tcp dport 80 dnat to 192.168.0.21"
reset_mocks
MOCK_LISTING='tcp dport 80' STDIN='n
'
run_script 80 tcp
out_has "port 80 vs rule at line end: prompt" "Do you want to add duplicate rules"

# ── failing commands: loud, non-zero, and partial application is reported ────
reset_mocks
MOCK_FAIL='tcp dport 25565'
run_script 25565 both
rc_is "fail first rule" 1
out_has "fail first rule: message" "Command failed (exit 1): $TCP"
out_has "fail first rule: command output" "mock failure"
out_lacks "fail first rule: nothing applied yet" "Partially applied"
not_called "fail first rule: stops" "udp dport"
not_called "fail first rule: no save" "nft list ruleset"
not_called "fail first rule: no enable" "systemctl"
no_file "fail first rule: nftables.conf" "$NFT_CONFIG"

reset_mocks
MOCK_FAIL='udp dport 25565'
run_script 25565 both
rc_is "fail second rule" 1
out_has "fail second rule: message" "Command failed (exit 1): $UDP"
out_has "fail second rule: partial" "Partially applied, NOT rolled back"
out_has "fail second rule: lists the tcp rule" "    - $TCP"
out_has "fail second rule: inspect hint" "nft list table ip gamenat"
not_called "fail second rule: no save" "nft list ruleset"
not_called "fail second rule: no enable" "systemctl"
no_file "fail second rule: nftables.conf" "$NFT_CONFIG"

reset_mocks
MOCK_TABLE=0 MOCK_FAIL='add chain ip gamenat forward'
run_script 25565 both
rc_is "fail table creation" 1
out_has "fail table creation: message" "Command failed (exit 1): nft add chain ip gamenat forward"
out_has "fail table creation: lists the table" "    - nft add table ip gamenat"
out_has "fail table creation: lists the first chain" "    - $CHAIN_PRE_SHOWN"
out_lacks "fail table creation: not the failed chain" "    - nft add chain ip gamenat forward"
not_called "fail table creation: no rules" "dport"

reset_mocks
MOCK_TABLE=0 MOCK_FAIL='add table'
run_script 25565 both
rc_is "fail first command" 1
out_lacks "fail first command: nothing to report" "Partially applied"

reset_mocks
MOCK_FORWARD=0 MOCK_FAIL='sysctl -w'
run_script 25565 tcp
rc_is "fail sysctl" 1
out_has "fail sysctl: message" "Command failed (exit 1): sysctl -w net.ipv4.ip_forward=1"
out_has "fail sysctl: lists the rule" "    - $TCP"
no_file "fail sysctl: sysctl.conf" "$SYSCTL_CONF"

reset_mocks
MOCK_IP_RULE='' MOCK_FAIL='ip route replace'
run_script 25565 tcp
rc_is "fail ip route" 1
out_has "fail ip route: message" "Command failed (exit 1): ip route replace default via 10.0.0.1 dev enp1s0 table 201"
out_has "fail ip route: lists the rule" "    - $TCP"
not_called "fail ip route: no ip rule" "ip rule add"
no_file "fail ip route: nftables.conf" "$NFT_CONFIG"

reset_mocks
MOCK_IP_RULE='' MOCK_FAIL='ip rule add'
run_script 25565 tcp
rc_is "fail ip rule" 1
out_has "fail ip rule: message" "Command failed (exit 1): ip rule add iif tailscale0 table 201"
out_has "fail ip rule: lists the route" "    - ip route replace default via 10.0.0.1 dev enp1s0 table 201"
no_file "fail ip rule: nftables.conf" "$NFT_CONFIG"

# a failing `nft list ruleset` must not truncate the existing persistent config
reset_mocks
printf 'OLD CONFIG\n' > "$NFT_CONFIG"
MOCK_FAIL='list ruleset'
run_script 25565 tcp
rc_is "fail save" 1
out_has "fail save: message" "Command failed: nft list ruleset"
out_has "fail save: untouched" "left untouched"
out_has "fail save: lists the rule" "    - $TCP"
file_is "fail save: old config intact" "$NFT_CONFIG" "OLD CONFIG"
not_called "fail save: no enable" "systemctl"

reset_mocks
MOCK_FAIL='systemctl enable'
run_script 25565 tcp
rc_is "fail systemctl" 1
out_has "fail systemctl: message" "Command failed (exit 1): systemctl enable nftables"
out_has "fail systemctl: config was saved" "    - nft list ruleset > $NFT_CONFIG"
out_lacks "fail systemctl: no success summary" "is now being forwarded"
file_is "fail systemctl: config written" "$NFT_CONFIG" "table ip gamenat { }"

if [ "$FAIL" -gt 0 ]; then
  echo "test_run: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test_run: $PASS passed"
