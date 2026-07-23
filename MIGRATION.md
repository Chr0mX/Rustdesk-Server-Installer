# Migration notes: fork rewrite

This document summarizes the rewrite that removed every dependency on
the official RustDesk release infrastructure and replaced it with this
repository as the sole distribution source.

## Update: full open-source stack (hbbs/hbbr + rustdesk-api + rustdesk-api-web)

Following the proprietary-binary removal below, this installer now
deploys a complete, working replacement for what RustDesk Server Pro
provided, built entirely from genuinely open-source projects:

- **hbbs/hbbr/rustdesk-utils** now come from
  [lejianwen/rustdesk-server](https://github.com/lejianwen/rustdesk-server)
  (AGPL-3.0) by default instead of a vendored Pro tarball. This fork of
  the official `rustdesk/rustdesk-server` adds the WebSocket support the
  web client needs, a connection-timeout fix, and optional `MUST_LOGIN`
  enforcement — confirmed via its own README/license, no phone-home
  licensing of any kind. The plain official `rustdesk/rustdesk-server`
  works too (`--hbbs-owner rustdesk --hbbs-repo rustdesk-server`) for
  everything except the web client, which needs WebSocket support
  neither it nor this fork's install path can add on its own.
- **rustdesk-api** (Go, MIT) and **rustdesk-api-web** (Vue, MIT) —
  forked into `Chr0mX/rustdesk-api` and `Chr0mX/rustdesk-api-web` — are
  the open-source admin API/console this installer now deploys in place
  of Pro's closed-source console. Neither has published release
  binaries, so `install.sh`/`update.sh` build them from source on the
  target machine (`ensure_go`/`ensure_node` in `lib.sh` install
  toolchains automatically if needed), following the exact build recipe
  in `rustdesk-api`'s own `build.sh`/`Dockerfile`.
- Asset naming differs by upstream: the official/`lejianwen` server
  releases use `rustdesk-server-linux-<arch>.zip` (arch aliases
  `amd64`/`arm64v8`/`armv7`/`i386`) and `.deb` packages with Debian arch
  names (`amd64`/`arm64`/`armhf`/`i386`) — both different from the old
  Pro `.tar.gz`/`amd64` naming. `lib.sh` gained per-asset-type alias
  tables (`zip_arch_alias`/`deb_arch_alias`) plus defensive extraction
  (`find_binary` locates hbbs/hbbr/rustdesk-utils wherever they land in
  the archive, rather than assuming a fixed internal path) since this
  fork could not download and inspect the real archive's internal
  layout from within the environment this rewrite was done in (its
  network access is scoped to `Chr0mX`-owned repos only).
- `lib.sh`'s GitHub asset/release functions (`gh_fetch_latest_release`,
  `fetch_repo_file`, `fetch_release_asset`, `fetch_and_verify`,
  `verify_checksum`) now take explicit `<owner> <repo> [<branch>]`
  parameters instead of reading fixed `GITHUB_OWNER`/`GITHUB_REPO`
  globals, since the installer now pulls from three independent
  repositories in the same run. `write_installed_version`/
  `read_installed_version` similarly gained a `<component>` parameter
  (`hbbs`/`api`/`web`) to track each independently.
- Version tracking for the two source-built components is by git commit
  SHA (`gh_branch_sha`, new in `lib.sh`), not a release tag, since they
  build from a branch; `update.sh` rebuilds whichever component's
  tracked SHA/tag no longer matches upstream.
- The admin console's authentication is unaffected in spirit — still
  fully local (rustdesk-api's own SQLite user database), just a
  different (and fully open-source) implementation than Pro's. The
  random first-run admin password is now captured from rustdesk-api's
  own log output and shown at the end of `install.sh`, rather than the
  fixed `admin`/`test1234` Pro used.

## Update: proprietary binaries removed from the repository

`rustdesk-server-hbbs_1.8.5_amd64.deb`, `rustdesk-server-hbbr_1.8.5_amd64.deb`,
`rustdesk-server-utils_1.8.5_amd64.deb`, and `rustdesk-server-linux-amd64.tar.gz`
have been deleted from the repository root. Those were compiled RustDesk
Server Pro binaries — closed-source, license-gated software requiring a
paid license validated against `rustdesk.com` (see the
[Authentication model](README.md#authentication-model) section) — which
this repository had no rights to redistribute. Removing them does not
change any script logic: `lib.sh`'s asset resolution already falls back
gracefully (with a clear error, not a crash) when neither a GitHub
Release nor a repo-root file can be found. The repository is now
installer-scripts-only; supplying legitimately-licensed assets (via a
GitHub Release, or by pointing `GITHUB_OWNER`/`GITHUB_REPO`/`GITHUB_BRANCH`
elsewhere) is left entirely to whoever deploys this fork.

Note: this removal only affects the current tree going forward. The
files still exist in this repository's git history (the initial commit)
since removing them there would require a history rewrite and
force-push — a much more disruptive operation that wasn't done here
without being asked for explicitly.

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

- **`.deb` assets are not the primary install path.** The `.zip` archive
  is architecture-portable across every supported distro, so both
  `install.sh` and `update.sh` always install from it (locating
  `hbbs`/`hbbr`/`rustdesk-utils` defensively inside it via
  `find_binary`, since this fork could not verify the archive's exact
  internal layout upfront). The `.deb` packages are published for users
  who prefer `dpkg -i` directly on Debian/Ubuntu-family hosts,
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
