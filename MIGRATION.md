# Migration notes: fork rewrite

This document summarizes the rewrite that removed every dependency on
the official RustDesk release infrastructure and replaced it with this
repository as the sole distribution source.

## Files changed and why

| File | Change |
|------|--------|
| `lib.sh` | Fully rewritten. Added: GitHub Releases API resolution with repo-root fallback (Layout A/B), private-repo-aware downloads (`GITHUB_TOKEN`), retry helper, checksum verification with graceful degradation, archive corruption sanity checks, arch detection table (amd64/arm64/armv7), package-manager abstraction covering apt/dnf/yum/zypper/pacman/apk/emerge, firewall abstraction for ufw **and** firewalld, systemd service helpers with active-wait/timeout, non-interactive fallbacks for every whiptail wrapper, colorized `info/warn/error/success/debug` logging. Also fixed pre-existing bugs: `WT_HEIGHT`/`WT_WIDTH`/`RUN_LATER_GUIDE` were referenced by `install.sh`/`uninstall.sh` but never defined in the original `lib.sh`, which would have made every whiptail dialog error out. |
| `install.sh` | Fully rewritten. No longer sources `lib.sh` from `raw.githubusercontent.com/rustdesk/...` — sources it from this repo (local file first, then this repo's raw/contents API). No longer calls `api.github.com/repos/rustdesk/rustdesk-server-pro/releases/latest` — uses `GITHUB_OWNER/GITHUB_REPO` (this fork) via `lib.sh`. Added CLI flags for full non-interactive operation, generalized firewall setup (ufw/firewalld), generalized architecture handling (previously amd64/armv7/arm64v8-only inline logic), and download integrity verification. |
| `update.sh` | Fully rewritten. Was a flat, unstructured script with no error handling and no rollback; the old `wget`/hardcoded-`RDLATEST` URLs pointed at `rustdesk/rustdesk-server-pro`. Now: version comparison via a local `.installed_version` file, pre-upgrade backup, health-checked restart with automatic rollback on failure, `--check-only` and `--force` flags. |
| `uninstall.sh` | Rewritten on top of the same interactive checklist UX, plus non-interactive flags (`--purge`, `--remove-dependencies`), firewalld cleanup (previously ufw-only), and a safer default (config/keys are kept unless `--purge` is passed, so a subsequent `install.sh` can pick the same install back up). |
| `convertfromos.sh` | Rewritten to invoke **this fork's** `install.sh` (local copy if present, otherwise fetched from this repo) instead of `raw.githubusercontent.com/rustdesk/rustdesk-server-pro/main/install.sh`. Legacy key migration logic preserved. |
| `README.md` | New. Usage, configuration reference, layout/auth/rollback documentation. |
| `MIGRATION.md` | New (this file). |

No Rust/server source files exist in this repository — only the
installer scripts and (optionally) the binary release assets — so there
was nothing to modify for requirement "local authentication": see
[Authentication model](README.md#authentication-model) in the README for
what was verified and why no source change was needed or possible here.

## Deliberate design decisions

- **`.deb` assets are not the primary install path.** The tar.gz archive
  is architecture-portable and its contents (`hbbs`, `hbbr`,
  `rustdesk-utils`, `static/`) are fully known, so both `install.sh` and
  `update.sh` always install from it. The `.deb` packages are published
  for users who prefer `dpkg -i` directly on Debian/Ubuntu-family hosts,
  but the installer doesn't invoke them automatically: their postinst
  scripts are unknown to this fork and could create systemd units or
  users that conflict with the ones `install.sh` generates. This
  prioritizes reliability over using every listed asset unconditionally.
- **`uninstall.sh` no longer removes shared system packages by
  default**, even with `--purge`. The original script's interactive
  checklist defaulted to removing `curl`, `dnsutils`, `ufw`, etc.
  entirely, which can break unrelated services on the host. `--purge`
  now means "wipe everything RustDesk-specific" (config, keys, logs,
  Nginx site, cert); removing shared packages requires the explicit,
  separate `--remove-dependencies` flag.
- **Checksum verification is best-effort.** No checksums are published
  for the current assets, so `verify_checksum()` looks for an optional
  `<asset>.sha256` (release asset or repo-root file) and warns rather
  than failing when it's absent. Publish `.sha256` files alongside a
  release to get hard verification for free — no script changes needed.
- **Private-repository support.** Testing during this rewrite found the
  target repository is currently private, which makes anonymous
  `raw.githubusercontent.com` and `browser_download_url` fetches 404.
  Every download path now transparently authenticates via `GITHUB_TOKEN`
  (Contents API for repo-root files, release-assets API for release
  assets) when the token is set, and falls back to the plain public URLs
  when it isn't — so the same scripts work unchanged whether the repo is
  public or private.

## First-time setup for the repo owner

1. Either publish a GitHub Release with the tar.gz/deb assets attached
   (preferred — enables `update.sh` version comparison), or leave the
   files at the repository root as they are now (Layout A fallback).
2. If the repository stays private, document that consumers must
   `export GITHUB_TOKEN=...` before running the scripts (see README).
3. Nothing else needs to change — `GITHUB_OWNER`/`GITHUB_REPO` already
   default to this fork's own coordinates in `lib.sh`.
