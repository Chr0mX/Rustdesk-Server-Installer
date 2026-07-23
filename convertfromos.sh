#!/bin/bash
#
# convertfromos.sh - Migrates a legacy RustDesk Server Open Source
# installation (gohttpserver/rustdesksignal/rustdeskrelay systemd units,
# keys under /opt/rustdesk) to this fork's installer and asset
# infrastructure.
#
# It stops and removes the old services, runs this fork's own
# install.sh (never the official RustDesk one), and migrates the old
# keypair into the new install directory.
#
# Usage:
#   ./convertfromos.sh [options]
#
# Options (forwarded to install.sh):
#   -y, --non-interactive
#       --user <name>
#       --domain <fqdn>
#       --ip
#       --owner <owner>
#       --repo <repo>
#       --branch <branch>
#   -h, --help   Show this help and exit

set -uo pipefail

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,20p'
}

INSTALL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        --owner)
            GITHUB_OWNER="$2"; INSTALL_ARGS+=("$1" "$2"); shift
            ;;
        --repo)
            GITHUB_REPO="$2"; INSTALL_ARGS+=("$1" "$2"); shift
            ;;
        --branch)
            GITHUB_BRANCH="$2"; INSTALL_ARGS+=("$1" "$2"); shift
            ;;
        -y|--non-interactive)
            NONINTERACTIVE="true"; INSTALL_ARGS+=("$1")
            ;;
        *)
            INSTALL_ARGS+=("$1")
            ;;
    esac
    shift
done

export NONINTERACTIVE="${NONINTERACTIVE:-false}"
export GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH

##################################################################################################################
# Bootstrap lib.sh from this fork's own repository
##################################################################################################################

if [ ! -x "$(command -v curl)" ] || [ ! -x "$(command -v whiptail)" ]; then
    NEEDED_DEPS=(curl whiptail)
    echo "Installing these packages: ${NEEDED_DEPS[*]}"
    if [ -x "$(command -v apt-get)" ]; then
        apt-get install "${NEEDED_DEPS[@]}" -y
    elif [ -x "$(command -v apk)" ]; then
        apk add --no-cache "${NEEDED_DEPS[@]}"
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y "${NEEDED_DEPS[@]}"
    elif [ -x "$(command -v zypper)" ]; then
        zypper --non-interactive install "${NEEDED_DEPS[@]}"
    elif [ -x "$(command -v pacman)" ]; then
        pacman -S --noconfirm "${NEEDED_DEPS[@]}"
    elif [ -x "$(command -v yum)" ]; then
        yum install -y "${NEEDED_DEPS[@]}"
    elif [ -x "$(command -v emerge)" ]; then
        emerge -av "${NEEDED_DEPS[@]}"
    else
        echo "FAILED TO INSTALL! Package manager not found. You must manually install: ${NEEDED_DEPS[*]}" >&2
        exit 1
    fi
fi

SCRIPT_NAME="Convert-from-OS script"
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

##################################################################################################################
# Stop and remove legacy Open Source services
##################################################################################################################

info "Removing legacy RustDesk Server Open Source services..."
for legacy_svc in gohttpserver rustdesksignal rustdeskrelay; do
    stop_and_disable_service "${legacy_svc}.service"
    rm -f "/etc/systemd/system/${legacy_svc}.service"
done
systemctl daemon-reload

LEGACY_KEY_DIR="/opt/rustdesk"

##################################################################################################################
# Run this fork's own install.sh (never the official RustDesk one)
##################################################################################################################

info "Running this fork's install.sh..."
INSTALL_SH_LOCAL="$SCRIPT_DIR/install.sh"
TMP_INSTALL=""
if [ -f "$INSTALL_SH_LOCAL" ]; then
    INSTALL_CMD=(bash "$INSTALL_SH_LOCAL" "${INSTALL_ARGS[@]}")
else
    # install.sh lives at the repo root (not a release asset), so fetch
    # it directly from this fork's own repository.
    TMP_INSTALL=$(mktemp)
    _bootstrap_fetch_repo_file install.sh > "$TMP_INSTALL" || die "Could not fetch install.sh from ${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Web}@${GITHUB_BRANCH:-main}"
    INSTALL_CMD=(bash "$TMP_INSTALL" "${INSTALL_ARGS[@]}")
fi

if ! "${INSTALL_CMD[@]}"; then
    die "install.sh failed. Your old installation, if any, is still available in $LEGACY_KEY_DIR."
fi
[ -n "$TMP_INSTALL" ] && rm -f "$TMP_INSTALL"

##################################################################################################################
# Migrate the legacy keypair
##################################################################################################################

if [ -d "$LEGACY_KEY_DIR" ]; then
    info "Migrating keys from $LEGACY_KEY_DIR to $RUSTDESK_INSTALL_DIR..."
    rm -f "$RUSTDESK_INSTALL_DIR"/id_*
    if cp -f "$LEGACY_KEY_DIR"/id_* "$RUSTDESK_INSTALL_DIR/" 2>/dev/null; then
        if systemctl restart rustdesk-hbbr.service && systemctl restart rustdesk-hbbs.service; then
            rm -rf "$LEGACY_KEY_DIR"
            success "Key migration complete; legacy directory removed."
        else
            error "The new services failed to restart with the migrated keys. Legacy directory kept at $LEGACY_KEY_DIR for manual recovery."
        fi
    else
        warn "No id_* key files found in $LEGACY_KEY_DIR; nothing to migrate. New keys generated by install.sh remain in place."
    fi
fi

success "Conversion from RustDesk Server Open Source complete."
