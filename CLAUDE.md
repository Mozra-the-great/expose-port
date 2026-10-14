# expose-port

## Type
Public repo with one POSIX shell script, `expose-port.sh`: it exposes a game-server port over
an Oracle ARM instance (nftables DNAT via Tailscale). README is in German, code in English.

## Important
- The script runs as root and changes nftables, sysctl, routing and `/etc/nftables.conf`.
  **Never execute it on a dev machine or in CI.** Checks are static plus argument-handling
  tests that stop before any change.
- `tests/test_args.sh` stubs every system tool (they fail the test if called), fakes `id -u`
  and therefore refuses to run as real root.
- Keep LF line endings (`.gitattributes`); a CRLF shebang breaks the script on Linux.

## Commands
```sh
sh tests/test_args.sh                              # argument-handling tests (no root needed)
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
