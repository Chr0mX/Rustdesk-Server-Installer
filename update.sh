#!/bin/bash
#
# update.sh - Updates an existing RustDesk Server installation
#
# Checks the latest release published on this fork's own GitHub
# repository, compares it against the installed version, and performs
# an upgrade if a newer release is available. Configuration and key
# files (id_*, everything outside static/) are always preserved. If the
# upgraded services fail to come up healthy, the previous binaries are
# restored automatically.
#
# Usage:
#   ./update.sh [options]
#
# Options:
#   -y, --non-interactive   Never prompt
#       --check-only        Only report whether an update is available
#       --force             Reinstall even if already on the latest version
#       --owner <owner>     Override the GitHub repo owner for assets
#       --repo <repo>       Override the GitHub repo name for assets
#       --branch <branch>   Override the branch used for repo-root fallback
#   -h, --help              Show this help and exit

set -uo pipefail

CHECK_ONLY="false"
FORCE_UPDATE="false"

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,20p'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--non-interactive)
            NONINTERACTIVE="true"
            ;;
        --check-only)
            CHECK_ONLY="true"
            ;;
        --force)
            FORCE_UPDATE="true"
            ;;
        --owner)
            GITHUB_OWNER="$2"; shift
            ;;
        --repo)
            GITHUB_REPO="$2"; shift
            ;;
        --branch)
            GITHUB_BRANCH="$2"; shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            print_usage
            exit 1
            ;;
    esac
    shift
done

export NONINTERACTIVE="${NONINTERACTIVE:-false}"
export GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH

##################################################################################################################
# Bootstrap lib.sh from this fork's own repository
##################################################################################################################

SCRIPT_NAME="Update script"
export SCRIPT_NAME
# Fetches a file from the repo root, transparently authenticating with
# GITHUB_TOKEN when set (required if this fork is kept private).
_bootstrap_fetch_repo_file() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.raw+json" \
            "${GITHUB_API:-https://api.github.com}/repos/${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Web}/contents/${1}?ref=${GITHUB_BRANCH:-main}"
    else
        curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
            "${GITHUB_RAW_HOST:-https://raw.githubusercontent.com}/${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Web}/${GITHUB_BRANCH:-main}/${1}"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib.sh" ]; then
    # shellcheck source=lib.sh
    source "$SCRIPT_DIR/lib.sh"
else
    LIB_SRC=$(_bootstrap_fetch_repo_file lib.sh) || { echo "FATAL: could not fetch lib.sh from ${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Web}@${GITHUB_BRANCH:-main}" >&2; exit 1; }
    # shellcheck source=/dev/null
    source <(echo "$LIB_SRC")
fi
unset SCRIPT_NAME

##################################################################################################################

root_check

if [ "${DEBUG:-false}" = "true" ]; then
    identify_os
    info "OS: $OS / VER: $VER / UPSTREAM_ID: $UPSTREAM_ID"
    exit 0
fi

detect_arch
[ -n "$ARCH_ALIAS" ] || die "Unsupported CPU architecture: $ARCH."

if [ ! -d "$RUSTDESK_INSTALL_DIR" ]; then
    die "No directory $RUSTDESK_INSTALL_DIR found. RustDesk Server does not appear to be installed (use install.sh first)."
fi

##################################################################################################################
# Determine current vs latest version
##################################################################################################################

INSTALLED_VERSION=$(read_installed_version)
[ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="unknown"
info "Installed version: $INSTALLED_VERSION"

if ! gh_fetch_latest_release; then
    die "Could not reach the GitHub Releases API for ${GITHUB_OWNER}/${GITHUB_REPO}. No version to update to."
fi
LATEST_VERSION=$(gh_release_tag)
[ -n "$LATEST_VERSION" ] || die "Could not determine the latest release tag from the GitHub API response."
info "Latest available version: $LATEST_VERSION"

if [ "$CHECK_ONLY" = "true" ]; then
    if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
        success "Already up to date ($INSTALLED_VERSION)."
    else
        info "Update available: $INSTALLED_VERSION -> $LATEST_VERSION"
    fi
    exit 0
fi

if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ] && [ "$FORCE_UPDATE" != "true" ]; then
    success "Already up to date ($INSTALLED_VERSION). Use --force to reinstall anyway."
    exit 0
fi

##################################################################################################################
# Backup current binaries + static assets for rollback
##################################################################################################################

BACKUP_DIR=$(mktemp -d)
info "Backing up current installation to $BACKUP_DIR for rollback safety..."
for bin in hbbs hbbr rustdesk-utils; do
    [ -f "/usr/bin/$bin" ] && cp -a "/usr/bin/$bin" "$BACKUP_DIR/$bin"
done
[ -d "$RUSTDESK_INSTALL_DIR/static" ] && cp -a "$RUSTDESK_INSTALL_DIR/static" "$BACKUP_DIR/static"

rollback() {
    error "Update failed - rolling back to $INSTALLED_VERSION."
    for bin in hbbs hbbr rustdesk-utils; do
        [ -f "$BACKUP_DIR/$bin" ] && cp -a "$BACKUP_DIR/$bin" "/usr/bin/$bin"
    done
    rm -rf "${RUSTDESK_INSTALL_DIR:?}/static"
    [ -d "$BACKUP_DIR/static" ] && cp -a "$BACKUP_DIR/static" "$RUSTDESK_INSTALL_DIR/static"
    chmod +x /usr/bin/hbbs /usr/bin/hbbr /usr/bin/rustdesk-utils 2>/dev/null
    systemctl restart rustdesk-hbbr.service rustdesk-hbbs.service 2>/dev/null
    rm -rf "$BACKUP_DIR"
}

##################################################################################################################
# Download and stage the new release
##################################################################################################################

ASSET_NAME="rustdesk-server-linux-${ARCH_ALIAS}.tar.gz"
WORKDIR=$(mktemp -d)
cleanup_workdir() { rm -rf "$WORKDIR"; }
trap cleanup_workdir EXIT

if ! fetch_and_verify "$ASSET_NAME" "$WORKDIR/$ASSET_NAME"; then
    error "Failed to download or verify $ASSET_NAME for version $LATEST_VERSION."
    rm -rf "$BACKUP_DIR"
    die "Update aborted; the currently installed version ($INSTALLED_VERSION) was left untouched."
fi

tar -xf "$WORKDIR/$ASSET_NAME" -C "$WORKDIR"
EXTRACTED_DIR="$WORKDIR/${ARCH_ALIAS}"
if [ ! -d "$EXTRACTED_DIR" ]; then
    error "Unexpected archive layout: expected directory '${ARCH_ALIAS}' inside $ASSET_NAME."
    rm -rf "$BACKUP_DIR"
    die "Update aborted; the currently installed version ($INSTALLED_VERSION) was left untouched."
fi

##################################################################################################################
# Perform the upgrade
##################################################################################################################

info "Stopping services..."
systemctl stop rustdesk-hbbs.service rustdesk-hbbr.service 2>/dev/null

info "Upgrading RustDesk Server to $LATEST_VERSION..."
rm -rf "${RUSTDESK_INSTALL_DIR:?}/static"
mv "$EXTRACTED_DIR/static" "$RUSTDESK_INSTALL_DIR/"
mv "$EXTRACTED_DIR/hbbr" /usr/bin/hbbr
mv "$EXTRACTED_DIR/hbbs" /usr/bin/hbbs
mv "$EXTRACTED_DIR/rustdesk-utils" /usr/bin/rustdesk-utils
chmod +x /usr/bin/hbbs /usr/bin/hbbr /usr/bin/rustdesk-utils

info "Starting services..."
systemctl start rustdesk-hbbr.service
systemctl start rustdesk-hbbs.service

if ! wait_for_service_active rustdesk-hbbr.service 60 || ! wait_for_service_active rustdesk-hbbs.service 60; then
    rollback
    die "The upgraded services failed to become active within the timeout. Rolled back to $INSTALLED_VERSION. Check: journalctl -u rustdesk-hbbr.service -u rustdesk-hbbs.service"
fi

write_installed_version "$LATEST_VERSION"
rm -rf "$BACKUP_DIR"
cleanup_workdir
trap - EXIT

success "Update complete: $INSTALLED_VERSION -> $LATEST_VERSION"
