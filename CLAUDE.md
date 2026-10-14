# expose-port

## Type
Public repo with one POSIX shell script, `expose-port.sh`: it exposes a game-server port over
an Oracle ARM instance (nftables DNAT via Tailscale). README is in German, code in English.

## Important
- The script runs as root and changes nftables, sysctl, routing and `/etc/nftables.conf`.
  **Never execute it on a dev machine or in CI.** Checks are static plus tests against stubs.
- `tests/test_args.sh` (argument handling, stops before any change) stubs every system tool
  (they fail the test if called), fakes `id -u` and therefore refuses to run as real root.
- `tests/test_run.sh` runs the whole script against mocks of nft/ip/sysctl/systemctl/apt-get/
  curl/id (call log, `MOCK_FAIL` makes a command fail); `NFT_CONFIG`/`SYSCTL_CONF` point into
  a temp dir. Also refuses to run as real root.
- Every mutating command goes through `run` in the script (checks the exit code, records it for
  the "partially applied" report, prints instead in `--dry-run`). The two steps that need
  redirection (append to sysctl.conf, save the ruleset) do the same by hand. New mutating steps
  must be checked and recorded as well; extra arguments are rejected so `--dry-run` must be first.
- Keep LF line endings (`.gitattributes`); a CRLF shebang breaks the script on Linux.

## Commands
```sh
sh tests/test_args.sh                              # argument-handling tests (no root needed)
sh tests/test_run.sh                               # dry-run, normal run and failure paths (mocked tools)
shellcheck --shell=sh expose-port.sh tests/*.sh    # .shellcheckrc excludes SC2059 on purpose
sh -n expose-port.sh && dash -n expose-port.sh     # syntax only
```

## CI (`.github/workflows/`)
- `ci.yml`: jobs `shellcheck`, `syntax`, `test` (stable names, no path filter).
- `workflow-lint.yml`: actionlint + zizmor. `secret-scan.yml`: gitleaks on PRs.
- No Claude workflows by design (single script, rare changes). Actions pinned by SHA;
  Dependabot keeps them fresh.

## Conventions
- Conventional commits in English, feature branches, no direct pushes to `main`.
- Validation order in the script is root check, usage, port, protocol; the tests pin it.
- Port policy: digits only, 1-65535, max 5 characters, no leading zeros (checked textually before
  any arithmetic).
- `WINGS_IP` is 192.168.0.21 (homelab-infra inventory, host `wings`); keep README and script equal.
