# RustDesk Server Installer (self-hosted fork)

This repository installs a complete, **fully open-source** self-hosted
RustDesk stack. It does **not** depend on `github.com/rustdesk`,
`rustdesk.com`, or any closed-source RustDesk Server Pro binary — every
component comes from a genuinely open, freely-licensed project:

| Component | Source | License |
|---|---|---|
| hbbs / hbbr / rustdesk-utils | [lejianwen/rustdesk-server](https://github.com/lejianwen/rustdesk-server) (a fork of the official `rustdesk/rustdesk-server` adding WebSocket support, a connection-timeout fix, and optional `MUST_LOGIN` enforcement) | AGPL-3.0 |
| rustdesk-api (admin API backend) | [Chr0mX/rustdesk-api](https://github.com/Chr0mX/rustdesk-api), a fork of [lejianwen/rustdesk-api](https://github.com/lejianwen/rustdesk-api) | MIT |
| rustdesk-api-web (admin console frontend) | [Chr0mX/rustdesk-api-web](https://github.com/Chr0mX/rustdesk-api-web), a fork of [lejianwen/rustdesk-api-web](https://github.com/lejianwen/rustdesk-api-web) | MIT |

Earlier versions of this repository vendored the closed-source RustDesk
Server Pro binaries directly; those have been removed (see
[MIGRATION.md](MIGRATION.md)) in favor of this fully open stack.

## What's in here

| File               | Purpose                                                             |
|--------------------|-----------------------------------------------------------------------|
| `lib.sh`           | Shared library: logging, retries, GitHub API/asset resolution, download+checksum verification, arch/distro detection, package-manager and firewall abstraction, systemd helpers, Go/Node toolchain bootstrap |
| `install.sh`       | Fresh install: hbbs/hbbr/rustdesk-utils + builds and installs rustdesk-api/rustdesk-api-web from source, systemd services, optional Nginx+Certbot TLS |
| `update.sh`        | Checks for updates to each of the three components independently, upgrades whichever moved, rolls back automatically if the upgraded services don't come up healthy |
| `uninstall.sh`     | Removes the install; supports `--purge` and a `--remove-dependencies` opt-in |
| `convertfromos.sh` | Migrates a legacy RustDesk Server Open Source install (old `gohttpserver`/`rustdesksignal`/`rustdeskrelay` units) to this fork |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/Chr0mX/Rustdesk-Web/main/install.sh -o install.sh
sudo bash install.sh
```

Non-interactive example (CI / scripted deployment):

```bash
sudo bash install.sh --non-interactive --user rustdesk --domain rustdesk.example.com
```

Headless install (hbbs/hbbr only, no admin console — matches the plain
open-source project's own default):

```bash
sudo bash install.sh --non-interactive --skip-api
```

Update everything that's moved since the last run:

```bash
sudo bash update.sh --non-interactive
```

Uninstall, keeping keys/config/database for a future reinstall:

```bash
sudo bash uninstall.sh --non-interactive
```

Uninstall and wipe everything RustDesk-specific:

```bash
sudo bash uninstall.sh --non-interactive --purge
```

## How the three components fit together

- **hbbs/hbbr** do the actual rendezvous/NAT-traversal and relay work,
  same as any RustDesk deployment. Installed from a prebuilt release
  archive (`rustdesk-server-linux-<arch>.zip`).
- **rustdesk-api** is the open-source admin API server — it's what
  replaces RustDesk Server Pro's closed-source console. It has no
  prebuilt release, so `install.sh`/`update.sh` build it from source
  (Go, with CGO for its SQLite driver) on the target machine.
- **rustdesk-api-web** is that console's frontend (Vue/Vite), also
  built from source and copied into `rustdesk-api`'s `resources/admin`
  directory, matching [rustdesk-api's own documented build
  process](https://github.com/lejianwen/rustdesk-api/blob/master/README_EN.md#source-installation).

`install.sh` installs Go and Node.js toolchains automatically if the
distro's own packages are missing or too old (pinned fallback versions
downloaded from go.dev/nodejs.org — see `ensure_go`/`ensure_node` in
`lib.sh`).

### Source vs. release assets

Because rustdesk-api/rustdesk-api-web are always built from a branch
(no release binaries exist for these forks), their "installed version"
is tracked by git commit SHA (`gh_branch_sha` in `lib.sh`), not a
release tag — `update.sh` rebuilds them whenever the tracked branch has
moved. hbbs/hbbr continue to use the GitHub Releases API + repo-root
fallback pattern this fork has always used.

## Overriding the sources

Every component's GitHub source is independently configurable, as
flags or environment variables:

```bash
sudo bash install.sh \
  --hbbs-owner myorg --hbbs-repo my-rustdesk-server-fork \
  --api-owner myorg --api-repo my-rustdesk-api-fork --api-branch main \
  --web-owner myorg --web-repo my-rustdesk-api-web-fork --web-branch main
```

To use the plain official server instead of `lejianwen`'s fork (loses
the web client, since the official server has no WebSocket support):

```bash
sudo bash install.sh --hbbs-owner rustdesk --hbbs-repo rustdesk-server
```

## Private repositories

If any of the source repositories above are private, anonymous
downloads return 404. Export a token with `repo` (or fine-grained
"Contents: Read") scope before running any script:

```bash
export GITHUB_TOKEN=ghp_xxx
sudo -E bash install.sh --non-interactive
```

`-E` is required so `sudo` preserves the environment variable. No token
is needed for public repositories.

## Configuration reference

All flags are also available as environment variables:

| Variable            | CLI flag        | Default                       | Meaning |
|---------------------|-----------------|--------------------------------|---------|
| `HBBS_OWNER`         | `--hbbs-owner`  | `lejianwen`                    | hbbs/hbbr release source |
| `HBBS_REPO`          | `--hbbs-repo`   | `rustdesk-server`               | |
| `API_OWNER`          | `--api-owner`   | `Chr0mX`                       | rustdesk-api source |
| `API_REPO`           | `--api-repo`    | `rustdesk-api`                  | |
| `API_BRANCH`         | `--api-branch`  | `master`                        | |
| `WEB_OWNER`          | `--web-owner`   | `Chr0mX`                       | rustdesk-api-web source |
| `WEB_REPO`           | `--web-repo`    | `rustdesk-api-web`              | |
| `WEB_BRANCH`         | `--web-branch`  | `master`                        | |
| `GITHUB_OWNER`       | `--owner`       | `Chr0mX`                       | Where this installer's own `lib.sh` is fetched from, if not run from a local clone |
| `GITHUB_REPO`        | `--repo`        | `Rustdesk-Web`                 | |
| `GITHUB_BRANCH`      | `--branch`      | `main`                         | |
| `GITHUB_TOKEN`       | -               | (unset)                        | Auth token; required for private repos |
| `NONINTERACTIVE`     | `-y`/`--non-interactive` | `false`                | Disable all whiptail prompts |
| `RUSTDESK_USER`      | `--user`        | (unset, root)                  | Unprivileged user all services run as |
| `RUSTDESK_DOMAIN`    | `--domain`      | (unset, IP mode)                | Enables the Nginx+Certbot TLS flow |
| `SKIP_API`           | `--skip-api`    | `false`                        | Headless install: hbbs/hbbr only, no admin console |
| `RUSTDESK_INSTALL_DIR` | -             | `/var/lib/rustdesk-server`      | hbbs/hbbr install/config/key directory |
| `RUSTDESK_LOG_DIR`   | -               | `/var/log/rustdesk-server`      | hbbs/hbbr log directory |
| `RUSTDESK_API_INSTALL_DIR` | -        | `/var/lib/rustdesk-api`         | rustdesk-api install/config/database directory |
| `RUSTDESK_API_LOG_DIR` | -             | `/var/log/rustdesk-api`         | rustdesk-api log directory |
| `DEBUG`              | -               | `false`                        | Verbose logging + OS/arch report, then exit |
| `DOWNLOAD_RETRIES`   | -               | `5`                            | Retry attempts for network operations |

`install.sh --help`, `update.sh --help` and `uninstall.sh --help` print
the full flag list for each script.

## Architecture & distro support

- **Architectures:** `amd64` (x86_64), `arm64` (aarch64), `armv7`. Adding a
  new one is a single line in `detect_arch()` in `lib.sh` (plus its
  `zip_arch_alias`/`deb_arch_alias`/`go_arch_alias`/`node_arch_alias`
  mappings, since hbbs/hbbr, Go and Node.js each use their own
  per-arch naming convention).
- **Distros:** any distro using apt, dnf, yum, zypper, pacman, apk or
  emerge is supported — this covers Ubuntu, Debian, Linux Mint, Pop!_OS,
  Rocky Linux, AlmaLinux, Fedora, CentOS, RHEL and openSUSE.
- **Firewall:** `ufw` and `firewalld` are both handled automatically
  (`fw_allow`/`fw_delete`/`fw_enable` in `lib.sh`); distros with neither
  simply skip firewall configuration with a warning.
- **Build toolchain:** a C compiler (`gcc`, for CGO/SQLite) plus Go
  1.23+ and Node.js 18+ (auto-installed if missing/too old) are
  required unless `--skip-api` is used.

## Authentication model

rustdesk-api's admin console manages users entirely in its own local
database (SQLite by default) under `/var/lib/rustdesk-api/data` — there
is **no dependency on any external RustDesk cloud/auth service**. A
random admin password is generated on first startup and printed once to
`/var/log/rustdesk-api/rustdesk-api.log`; `install.sh` captures and
displays it at the end of the run. **Change it immediately after first
login.** Optional GitHub/Google/OIDC/LDAP login can be configured
afterward from the admin console itself.

## Rollback behavior

`update.sh` backs up hbbs/hbbr binaries and the rustdesk-api
binary+built frontend assets before touching anything, independently
for each component. If the post-upgrade services don't reach an active
state within 60 seconds, it automatically restores the backup and
restarts the services, so a failed update never leaves the server down.

See [`MIGRATION.md`](MIGRATION.md) for what changed from the original
scripts and why.
