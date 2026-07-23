#!/bin/bash
#
# update.sh - Updates an existing RustDesk Server installation
#
# Checks the latest hbbs/hbbr release (lejianwen/rustdesk-server by
# default) and the latest rustdesk-api/rustdesk-api-web source commits,
# and upgrades whichever of the three has moved since the last install/
# update. Configuration and key files are always preserved. If the
# upgraded services fail to come up healthy, the previous binaries are
# restored automatically.
#
# Usage:
#   ./update.sh [options]
#
# Options:
#   -y, --non-interactive   Never prompt
#       --check-only        Only report whether updates are available
#       --force             Reinstall even if already on the latest version
#       --skip-api          Only update hbbs/hbbr; leave rustdesk-api/web alone
#       --hbbs-owner <owner>  Override the hbbs/hbbr release source
#       --hbbs-repo <repo>
#       --api-owner <owner>   Override the rustdesk-api source
#       --api-repo <repo>
#       --api-branch <branch>
#       --web-owner <owner>   Override the rustdesk-api-web source
#       --web-repo <repo>
#       --web-branch <branch>
#       --owner <owner>     Override where THIS installer's own lib.sh
#       --repo <repo>       is fetched from, if not run from a local
#       --branch <branch>   clone (rarely needs changing)
#   -h, --help              Show this help and exit

set -uo pipefail

CHECK_ONLY="false"
FORCE_UPDATE="false"
SKIP_API="${SKIP_API:-false}"

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,30p'
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
        --skip-api)
            SKIP_API="true"
            ;;
        --hbbs-owner)
            HBBS_OWNER="$2"; shift
            ;;
        --hbbs-repo)
            HBBS_REPO="$2"; shift
            ;;
        --api-owner)
            API_OWNER="$2"; shift
            ;;
        --api-repo)
            API_REPO="$2"; shift
            ;;
        --api-branch)
            API_BRANCH="$2"; shift
            ;;
        --web-owner)
            WEB_OWNER="$2"; shift
            ;;
        --web-repo)
            WEB_REPO="$2"; shift
            ;;
        --web-branch)
            WEB_BRANCH="$2"; shift
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

export NONINTERACTIVE="${NONINTERACTIVE:-false}" SKIP_API
export GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH
export HBBS_OWNER HBBS_REPO API_OWNER API_REPO API_BRANCH WEB_OWNER WEB_REPO WEB_BRANCH

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

UPDATED_ANYTHING="false"

##################################################################################################################
# hbbs/hbbr
##################################################################################################################

update_hbbs() {
    local installed latest
    installed=$(read_installed_version hbbs)
    [ -n "$installed" ] || installed="unknown"
    info "hbbs/hbbr installed version: $installed"

    if ! gh_fetch_latest_release "$HBBS_OWNER" "$HBBS_REPO"; then
        warn "Could not reach the GitHub Releases API for ${HBBS_OWNER}/${HBBS_REPO}; skipping hbbs/hbbr update check."
        return 0
    fi
    latest=$(gh_release_tag)
    [ -n "$latest" ] || { warn "Could not determine the latest hbbs/hbbr release tag."; return 0; }
    info "hbbs/hbbr latest version: $latest"

    if [ "$CHECK_ONLY" = "true" ]; then
        if [ "$installed" = "$latest" ]; then
            success "hbbs/hbbr already up to date ($installed)."
        else
            info "hbbs/hbbr update available: $installed -> $latest"
        fi
        return 0
    fi

    if [ "$installed" = "$latest" ] && [ "$FORCE_UPDATE" != "true" ]; then
        success "hbbs/hbbr already up to date ($installed)."
        return 0
    fi

    local backup_dir
    backup_dir=$(mktemp -d)
    info "Backing up current hbbs/hbbr binaries to $backup_dir for rollback safety..."
    for bin in hbbs hbbr rustdesk-utils; do
        [ -f "/usr/bin/$bin" ] && cp -a "/usr/bin/$bin" "$backup_dir/$bin"
    done

    rollback_hbbs() {
        error "hbbs/hbbr update failed - rolling back to $installed."
        for bin in hbbs hbbr rustdesk-utils; do
            [ -f "$backup_dir/$bin" ] && cp -a "$backup_dir/$bin" "/usr/bin/$bin"
        done
        chmod +x /usr/bin/hbbs /usr/bin/hbbr /usr/bin/rustdesk-utils 2>/dev/null
        systemctl restart rustdesk-hbbr.service rustdesk-hbbs.service 2>/dev/null
        rm -rf "$backup_dir"
    }

    local zip_arch asset workdir extracted hbbs_bin hbbr_bin utils_bin
    zip_arch="$(zip_arch_alias)"
    [ -n "$zip_arch" ] || { error "No hbbs/hbbr release asset naming known for architecture $ARCH."; rm -rf "$backup_dir"; return 1; }
    asset="rustdesk-server-linux-${zip_arch}.zip"

    workdir=$(mktemp -d)
    if ! fetch_and_verify "$HBBS_OWNER" "$HBBS_REPO" "master" "$asset" "$workdir/$asset"; then
        error "Failed to download or verify $asset for version $latest."
        rm -rf "$backup_dir" "$workdir"
        die "hbbs/hbbr update aborted; the currently installed version ($installed) was left untouched."
    fi

    extracted="$workdir/extracted"
    extract_archive "$workdir/$asset" "$extracted"
    hbbs_bin=$(find_binary "$extracted" hbbs)
    hbbr_bin=$(find_binary "$extracted" hbbr)
    utils_bin=$(find_binary "$extracted" rustdesk-utils)
    if [ -z "$hbbs_bin" ] || [ -z "$hbbr_bin" ]; then
        error "Unexpected archive layout: hbbs/hbbr binary not found inside $asset."
        rm -rf "$backup_dir" "$workdir"
        die "hbbs/hbbr update aborted; the currently installed version ($installed) was left untouched."
    fi

    info "Stopping hbbs/hbbr..."
    systemctl stop rustdesk-hbbs.service rustdesk-hbbr.service 2>/dev/null

    info "Upgrading hbbs/hbbr to $latest..."
    mv "$hbbs_bin" /usr/bin/hbbs
    mv "$hbbr_bin" /usr/bin/hbbr
    [ -n "$utils_bin" ] && mv "$utils_bin" /usr/bin/rustdesk-utils
    chmod +x /usr/bin/hbbs /usr/bin/hbbr
    [ -f /usr/bin/rustdesk-utils ] && chmod +x /usr/bin/rustdesk-utils

    systemctl start rustdesk-hbbr.service
    systemctl start rustdesk-hbbs.service

    if ! wait_for_service_active rustdesk-hbbr.service 60 || ! wait_for_service_active rustdesk-hbbs.service 60; then
        rollback_hbbs
        rm -rf "$workdir"
        die "The upgraded hbbs/hbbr services failed to become active within the timeout. Rolled back to $installed. Check: journalctl -u rustdesk-hbbr.service -u rustdesk-hbbs.service"
    fi

    write_installed_version hbbs "$latest"
    rm -rf "$backup_dir" "$workdir"
    success "hbbs/hbbr update complete: $installed -> $latest"
    UPDATED_ANYTHING="true"
}

update_hbbs

##################################################################################################################
# rustdesk-api + rustdesk-api-web (rebuilt from source)
##################################################################################################################

update_api() {
    if [ "$SKIP_API" = "true" ]; then
        info "--skip-api set: not checking rustdesk-api/rustdesk-api-web."
        return 0
    fi
    if [ ! -d "$RUSTDESK_API_INSTALL_DIR" ]; then
        info "rustdesk-api is not installed (was this install done with --skip-api?); skipping."
        return 0
    fi

    local installed_api installed_web latest_api latest_web
    installed_api=$(read_installed_version api)
    installed_web=$(read_installed_version web)
    latest_api=$(gh_branch_sha "$API_OWNER" "$API_REPO" "$API_BRANCH") || { warn "Could not resolve ${API_OWNER}/${API_REPO}@${API_BRANCH}; skipping rustdesk-api update check."; return 0; }
    latest_web=$(gh_branch_sha "$WEB_OWNER" "$WEB_REPO" "$WEB_BRANCH") || { warn "Could not resolve ${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH}; skipping rustdesk-api-web update check."; return 0; }

    info "rustdesk-api installed commit: ${installed_api:-unknown}, latest: $latest_api"
    info "rustdesk-api-web installed commit: ${installed_web:-unknown}, latest: $latest_web"

    if [ "$CHECK_ONLY" = "true" ]; then
        if [ "$installed_api" = "$latest_api" ] && [ "$installed_web" = "$latest_web" ]; then
            success "rustdesk-api/rustdesk-api-web already up to date."
        else
            info "rustdesk-api/rustdesk-api-web update available."
        fi
        return 0
    fi

    if [ "$installed_api" = "$latest_api" ] && [ "$installed_web" = "$latest_web" ] && [ "$FORCE_UPDATE" != "true" ]; then
        success "rustdesk-api/rustdesk-api-web already up to date."
        return 0
    fi

    ensure_go 23
    ensure_node 18

    local backup_dir
    backup_dir=$(mktemp -d)
    info "Backing up current rustdesk-api binary+resources to $backup_dir for rollback safety..."
    [ -f /usr/bin/rustdesk-api ] && cp -a /usr/bin/rustdesk-api "$backup_dir/rustdesk-api"
    [ -d "$RUSTDESK_API_INSTALL_DIR/resources" ] && cp -a "$RUSTDESK_API_INSTALL_DIR/resources" "$backup_dir/resources"

    rollback_api() {
        error "rustdesk-api update failed - rolling back."
        [ -f "$backup_dir/rustdesk-api" ] && cp -a "$backup_dir/rustdesk-api" /usr/bin/rustdesk-api
        if [ -d "$backup_dir/resources" ]; then
            rm -rf "${RUSTDESK_API_INSTALL_DIR:?}/resources"
            cp -a "$backup_dir/resources" "$RUSTDESK_API_INSTALL_DIR/resources"
        fi
        chmod +x /usr/bin/rustdesk-api 2>/dev/null
        systemctl restart rustdesk-api.service 2>/dev/null
        rm -rf "$backup_dir"
    }

    local workdir
    workdir=$(mktemp -d)

    success "Building rustdesk-api (${API_OWNER}/${API_REPO}@${API_BRANCH})..."
    if ! fetch_source_tarball "$API_OWNER" "$API_REPO" "$API_BRANCH" "$workdir/rustdesk-api"; then
        rm -rf "$backup_dir" "$workdir"
        die "Could not fetch rustdesk-api source from ${API_OWNER}/${API_REPO}@${API_BRANCH}."
    fi
    if ! ( cd "$workdir/rustdesk-api" && mkdir -p release && go mod tidy && CGO_ENABLED=1 go build -o release/apimain ./cmd/apimain.go ); then
        rm -rf "$backup_dir" "$workdir"
        die "Building rustdesk-api failed; the currently installed version was left untouched."
    fi

    success "Building rustdesk-api-web (${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH})..."
    if ! fetch_source_tarball "$WEB_OWNER" "$WEB_REPO" "$WEB_BRANCH" "$workdir/rustdesk-api-web"; then
        rm -rf "$backup_dir" "$workdir"
        die "Could not fetch rustdesk-api-web source from ${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH}."
    fi
    if ! ( cd "$workdir/rustdesk-api-web" && npm install && npm run build ); then
        rm -rf "$backup_dir" "$workdir"
        die "Building rustdesk-api-web failed; the currently installed version was left untouched."
    fi

    info "Stopping rustdesk-api..."
    systemctl stop rustdesk-api.service 2>/dev/null

    info "Upgrading rustdesk-api..."
    mkdir -p "$workdir/rustdesk-api/release/resources/admin"
    cp -ar "$workdir/rustdesk-api-web/dist/." "$workdir/rustdesk-api/release/resources/admin/"
    rm -rf "${RUSTDESK_API_INSTALL_DIR:?}/resources"
    cp -ar "$workdir/rustdesk-api/release/resources" "$RUSTDESK_API_INSTALL_DIR/resources"
    mv "$workdir/rustdesk-api/release/apimain" /usr/bin/rustdesk-api
    chmod +x /usr/bin/rustdesk-api

    systemctl start rustdesk-api.service

    if ! wait_for_service_active rustdesk-api.service 60; then
        rollback_api
        rm -rf "$workdir"
        die "The upgraded rustdesk-api service failed to become active within the timeout. Rolled back. Check: journalctl -u rustdesk-api.service"
    fi

    write_installed_version api "$latest_api"
    write_installed_version web "$latest_web"
    rm -rf "$backup_dir" "$workdir"
    success "rustdesk-api/rustdesk-api-web update complete."
    UPDATED_ANYTHING="true"
}

update_api

##################################################################################################################

if [ "$CHECK_ONLY" != "true" ] && [ "$UPDATED_ANYTHING" != "true" ]; then
    success "Everything is already up to date. Use --force to reinstall anyway."
fi
