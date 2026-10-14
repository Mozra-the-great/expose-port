#!/bin/sh
# Argument-handling tests for expose-port.sh. SAFE BY CONSTRUCTION:
#
#   expose-port.sh is a root script that edits nftables, sysctl, routing and
#   /etc/nftables.conf. This test only exercises the paths that stop BEFORE any
#   change: not root, no/empty port, invalid port, invalid protocol. Every system
#   tool the script could reach (nft, ip, sysctl, systemctl, apt-get, curl, iptables,
#   ufw, ssh, tailscale, ...) is a stub on PATH that records the call and exits 99;
#   each case asserts that nothing was called. `id` is stubbed to report uid 0 so the
#   script gets past its root check - which is also why this test refuses to run as
#   real root: a regression that skips the validation must not be able to reach
#   /etc/nftables.conf.
#
# Contract (read from the script): usage and every validation error exit 1 and print
# to stdout; the order is root check, usage (no/empty port), port, protocol.
# A valid port/protocol would continue into the nft steps, so those cases are only
# probed through a later error (valid port + invalid protocol).

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/expose-port.sh
TEST_SH=${TEST_SH:-sh}

if [ "$(id -u)" -eq 0 ]; then
  echo "test_args: refusing to run as root" >&2
  exit 1
fi

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM

CALL_LOG=$TEST_TMP/calls.log
FORBIDDEN_DIR=$TEST_TMP/forbidden
FAKEROOT_DIR=$TEST_TMP/fakeroot
mkdir -p "$FORBIDDEN_DIR" "$FAKEROOT_DIR"
: > "$CALL_LOG"

# Everything the script (or a regression of it) could use to change the host or the
# network. A call is recorded and fails.
for cmd in nft ip sysctl systemctl apt-get apt curl wget iptables ip6tables ufw ssh scp tailscale \
           firewall-cmd modprobe sudo; do
  cat > "$FORBIDDEN_DIR/$cmd" <<STUB
#!/bin/sh
echo "$cmd \$*" >> "$CALL_LOG"
exit 99
STUB
  chmod +x "$FORBIDDEN_DIR/$cmd"
done
# `id -u` -> 0 so the root check passes; anything else falls through to the real id.
REAL_ID=$(command -v id)
cat > "$FAKEROOT_DIR/id" <<STUB
#!/bin/sh
if [ "\${1:-}" = "-u" ]; then
  echo 0
else
  exec "$REAL_ID" "\$@"
fi
STUB
chmod +x "$FAKEROOT_DIR/id"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

# run_script <path-prefix> [args...] -> OUT (stdout+stderr), RC
run_script() {
  prefix=$1
  shift
  : > "$CALL_LOG"
  OUT=$(PATH="$prefix:$FORBIDDEN_DIR:$PATH" "$TEST_SH" "$SCRIPT" "$@" 2>&1)
  RC=$?
}

# check <name> <expected rc> <expected text>: exit code, message, and no system tool called
check() {
  if [ "$RC" -eq "$2" ]; then pass; else fail "$1: expected exit $2, got $RC ($OUT)"; fi
  case "$OUT" in
    *"$3"*) pass ;;
    *) fail "$1: expected output to contain '$3', got '$OUT'" ;;
  esac
  if [ -s "$CALL_LOG" ]; then
    fail "$1: a system tool was called: $(tr '\n' ';' < "$CALL_LOG")"
  else
    pass
  fi
}

# ── root check ───────────────────────────────────────────────────────────────
# real (non-root) id: the script must refuse before doing anything
run_script "$TEST_TMP/none" 25565 both
check "not root" 1 "Please run as root"

# ── usage ────────────────────────────────────────────────────────────────────
run_script "$FAKEROOT_DIR"
check "no arguments" 1 "Usage: sudo ./expose-port.sh <port> [tcp|udp|both]"

run_script "$FAKEROOT_DIR" ""
check "empty port argument" 1 "Usage: sudo ./expose-port.sh"

# ── port validation ──────────────────────────────────────────────────────────
for bad in abc 0 65536 70000 -1 1.5 80a a80 +80 "8 0" --help -h; do
  run_script "$FAKEROOT_DIR" "$bad" both
  check "invalid port '$bad'" 1 "Invalid port: $bad (must be 1-65535)"
done

# the port is validated before the protocol
run_script "$FAKEROOT_DIR" 0 icmp
check "invalid port and protocol: port is reported" 1 "Invalid port: 0"

# ── protocol validation (valid port, so only the protocol check can fire) ────
for port in 1 80 25565 65535; do
  run_script "$FAKEROOT_DIR" "$port" icmp
  check "port $port is valid, protocol icmp is not" 1 "Invalid protocol: icmp (use tcp, udp, or both)"
done

for bad in TCP UDP Both tcp+udp "tcp udp" all; do
  run_script "$FAKEROOT_DIR" 25565 "$bad"
  check "invalid protocol '$bad'" 1 "Invalid protocol: $bad"
done

if [ "$FAIL" -gt 0 ]; then
  echo "test_args: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test_args: $PASS passed"
