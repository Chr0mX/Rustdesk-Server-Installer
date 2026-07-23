# RustDesk Server Installer (self-hosted fork)

This repository is a self-contained installer for RustDesk Server
(hbbs/hbbr/rustdesk-utils). It does **not** depend on
`github.com/rustdesk`, `rustdesk.com`, or any official RustDesk release
infrastructure — every script downloads its assets from **this**
repository instead.

## What's in here

| File               | Purpose                                                             |
|--------------------|-----------------------------------------------------------------------|
| `lib.sh`           | Shared library: logging, retries, GitHub API/asset resolution, download+checksum verification, arch/distro detection, package-manager and firewall abstraction, systemd helpers |
| `install.sh`       | Fresh install: dependencies, hbbs/hbbr/rustdesk-utils, systemd services, optional Nginx+Certbot TLS |
| `update.sh`        | Checks the latest release, upgrades in place, rolls back automatically if the upgraded services don't come up healthy |
| `uninstall.sh`     | Removes the install; supports `--purge` and a `--remove-dependencies` opt-in |
| `convertfromos.sh` | Migrates a legacy RustDesk Server Open Source install (old `gohttpserver`/`rustdesksignal`/`rustdeskrelay` units) to this fork |

Release assets (`rustdesk-server-linux-<arch>.tar.gz`, and the
`.deb` packages) can live either at the repository root or as
[GitHub Release](https://docs.github.com/en/repositories/releasing-projects-on-github)
assets — see [Repository layout](#repository-layout) below.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh -o install.sh
sudo bash install.sh
```

Non-interactive example (CI / scripted deployment):

```bash
sudo bash install.sh --non-interactive --user rustdesk --domain rustdesk.example.com
```

Update to the latest release:

```bash
sudo bash update.sh --non-interactive
```

Uninstall, keeping keys/config for a future reinstall:

```bash
sudo bash uninstall.sh --non-interactive
```

Uninstall and wipe everything RustDesk-specific:

```bash
sudo bash uninstall.sh --non-interactive --purge
```

## Repository layout

`lib.sh` resolves every asset in this order:

1. **GitHub Releases (preferred).** If `GITHUB_OWNER/GITHUB_REPO` has a
   published release, its assets are used (`rustdesk-server-linux-<arch>.tar.gz`,
   `rustdesk-server-{hbbs,hbbr,utils}_<version>_<arch>.deb`, plus an
   optional `<asset>.sha256` for integrity verification).
2. **Repository root (fallback).** If there is no release, or the asset
   isn't attached to it, the same file name is fetched from the root of
   the `GITHUB_BRANCH` branch.

This means the installer keeps working with zero script changes whether
you publish versioned GitHub Releases or simply keep files committed at
the repository root — and it starts using a Release the moment you
publish one.

Cutting a new release only requires:

```bash
git tag v1.8.6
git push origin v1.8.6
gh release create v1.8.6 rustdesk-server-linux-amd64.tar.gz rustdesk-server-linux-arm64.tar.gz \
    rustdesk-server-hbbs_1.8.6_amd64.deb rustdesk-server-hbbr_1.8.6_amd64.deb rustdesk-server-utils_1.8.6_amd64.deb
```

`update.sh` will pick it up automatically on the next run.

## Private repositories

If you keep this fork **private**, anonymous downloads of
`raw.githubusercontent.com` files and release assets return 404. Export
a token with `repo` (or fine-grained "Contents: Read") scope before
running any script:

```bash
export GITHUB_TOKEN=ghp_xxx
sudo -E bash install.sh --non-interactive
```

`-E` is required so `sudo` preserves the environment variable. No token
is needed once the repository is public.

## Configuration reference

All flags are also available as environment variables:

| Variable            | CLI flag        | Default                       | Meaning |
|---------------------|-----------------|--------------------------------|---------|
| `GITHUB_OWNER`       | `--owner`       | `Chr0mX`                       | Repo owner to pull assets from |
| `GITHUB_REPO`        | `--repo`        | `Rustdesk-Web`                 | Repo name to pull assets from |
| `GITHUB_BRANCH`      | `--branch`      | `main`                         | Branch used for the repo-root fallback |
| `GITHUB_TOKEN`       | -               | (unset)                        | Auth token; required for private repos |
| `NONINTERACTIVE`     | `-y`/`--non-interactive` | `false`                | Disable all whiptail prompts |
| `RUSTDESK_USER`      | `--user`        | (unset, root)                  | Unprivileged user hbbs/hbbr run as |
| `RUSTDESK_DOMAIN`    | `--domain`      | (unset, IP mode)                | Enables the Nginx+Certbot TLS flow |
| `RUSTDESK_INSTALL_DIR` | -             | `/var/lib/rustdesk-server`      | Install/config/key directory |
| `RUSTDESK_LOG_DIR`   | -               | `/var/log/rustdesk-server`      | Log directory |
| `DEBUG`              | -               | `false`                        | Verbose logging + OS/arch report, then exit |
| `DOWNLOAD_RETRIES`   | -               | `5`                            | Retry attempts for network operations |

`install.sh --help`, `update.sh --help` and `uninstall.sh --help` print
the full flag list for each script.

## Architecture & distro support

- **Architectures:** `amd64` (x86_64), `arm64` (aarch64), `armv7`. Adding a
  new one is a single line in `detect_arch()` in `lib.sh`.
- **Distros:** any distro using apt, dnf, yum, zypper, pacman, apk or
  emerge is supported — this covers Ubuntu, Debian, Linux Mint, Pop!_OS,
  Rocky Linux, AlmaLinux, Fedora, CentOS, RHEL and openSUSE.
- **Firewall:** `ufw` and `firewalld` are both handled automatically
  (`fw_allow`/`fw_delete`/`fw_enable` in `lib.sh`); distros with neither
  simply skip firewall configuration with a warning.

## Authentication model

RustDesk Server Pro's web console (served on port `21114`, or via
Nginx+TLS when a domain is configured) ships with its own local admin
account (`admin` / `test1234` by default) and manages users entirely
inside its own local SQLite database under
`/var/lib/rustdesk-server`. There is **no dependency on any external
RustDesk cloud/auth service** — this was already true of the upstream
binary and is preserved unchanged by this fork.

This repository only contains the installer scripts, not the hbbs/hbbr
Rust source, so there is no server-side auth code to modify. If you need
custom auth logic, it must be implemented against the Pro server's own
API/admin console (see its `/api` documentation once installed) rather
than in these scripts. **Change the default admin password immediately
after first login.**

## Rollback behavior

`update.sh` backs up the currently installed `hbbs`, `hbbr`,
`rustdesk-utils` and `static/` before touching anything. If the
post-upgrade services don't reach an active state within 60 seconds, it
automatically restores the backup and restarts the services, so a failed
release never leaves the server down.

See [`MIGRATION.md`](MIGRATION.md) for what changed from the original
scripts and why.
