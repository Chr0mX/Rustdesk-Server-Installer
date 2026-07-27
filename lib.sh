#!/bin/bash
#
# lib.sh - shared library for the RustDesk Server installer fork
#
# Sourced by install.sh, update.sh, uninstall.sh and convertfromos.sh.
# All distribution assets (scripts + release binaries) are pulled from
# this fork's own GitHub repository instead of the official RustDesk
# infrastructure. See README.md for the full list of supported
# environment variables and CLI flags.

# shellcheck disable=SC2034
true

############################################################
# Repository configuration
############################################################

# The GitHub repository that hosts this fork's installer scripts.
# Override with env vars if you maintain your own fork.
GITHUB_OWNER="${GITHUB_OWNER:-Chr0mX}"
GITHUB_REPO="${GITHUB_REPO:-Rustdesk-Server-Installer}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_RAW_HOST="${GITHUB_RAW_HOST:-https://raw.githubusercontent.com}"

# hbbs/hbbr binaries: Chr0mX/rustdesk-server, this project's own fork of
# lejianwen/rustdesk-server (itself a fork of official rustdesk/rustdesk-server)
# with the WebSocket support the web client needs, a connection-timeout fix,
# and optional MUST_LOGIN enforcement - plus the upstream 1.1.15/1.1.16
# fixes lejianwen's fork hadn't picked up (notably a UDP punch-hole
# reflection/amplification fix and an i32-overflow peer-online-state bug).
# Set HBBS_OWNER/HBBS_REPO to "rustdesk"/"rustdesk-server" to use the plain
# official server instead (everything works except the web client, which
# needs WebSocket support neither the official server nor this fork's
# install path can add on its own).
HBBS_OWNER="${HBBS_OWNER:-Chr0mX}"
HBBS_REPO="${HBBS_REPO:-rustdesk-server}"

# rustdesk-api (Go backend) and rustdesk-api-web (Vue frontend): the
# open-source admin console/API layer this installer deploys instead of
# RustDesk Server Pro's closed-source console. Built from source at
# install time (see ensure_go/ensure_node below) since there are no
# published release binaries for these forks yet.
API_OWNER="${API_OWNER:-Chr0mX}"
API_REPO="${API_REPO:-rustdesk-api}"
API_BRANCH="${API_BRANCH:-master}"
WEB_OWNER="${WEB_OWNER:-Chr0mX}"
WEB_REPO="${WEB_REPO:-rustdesk-api-web}"
WEB_BRANCH="${WEB_BRANCH:-master}"

# Optional token used for all GitHub API/download requests. Not needed
# against a public repository beyond raising the API rate limit
# (unauthenticated requests are capped at 60/hour), but required if
# GITHUB_OWNER/GITHUB_REPO points at a private repository, since raw
# file and release asset URLs 404 for anonymous requests there.
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# PATH & DIR (hbbs/hbbr)
RUSTDESK_INSTALL_DIR="${RUSTDESK_INSTALL_DIR:-/var/lib/rustdesk-server}"
RUSTDESK_LOG_DIR="${RUSTDESK_LOG_DIR:-/var/log/rustdesk-server}"
RUSTDESK_VERSION_FILE="$RUSTDESK_INSTALL_DIR/.installed_version"

# PATH & DIR (rustdesk-api), matching the paths in rustdesk-api's own
# systemd/rustdesk-api.service template.
RUSTDESK_API_INSTALL_DIR="${RUSTDESK_API_INSTALL_DIR:-/var/lib/rustdesk-api}"
RUSTDESK_API_LOG_DIR="${RUSTDESK_API_LOG_DIR:-/var/log/rustdesk-api}"

# Non-interactive mode: set to "true" to disable all whiptail prompts.
NONINTERACTIVE="${NONINTERACTIVE:-false}"

# Set to "true" to enable verbose debug logging.
DEBUG="${DEBUG:-false}"

# Download/retry tuning
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-5}"
DOWNLOAD_RETRY_DELAY="${DOWNLOAD_RETRY_DELAY:-3}"

############################################################
# Colors & logging
############################################################

Color_Off='\e[0m'
Red='\e[0;31m'
Green='\e[0;32m'
Yellow='\e[0;33m'
Blue='\e[0;34m'
Cyan='\e[0;36m'
IRed='\e[0;91m'
IGreen='\e[0;92m'
IYellow='\e[0;93m'
ICyan='\e[0;96m'

print_text_in_color() {
    printf "%b%s%b\n" "$1" "$2" "$Color_Off"
}

_log_prefix() {
    date "+%Y-%m-%d %H:%M:%S"
}

info() {
    print_text_in_color "$ICyan" "[INFO]  $(_log_prefix) $*"
}

warn() {
    print_text_in_color "$IYellow" "[WARN]  $(_log_prefix) $*" >&2
}

error() {
    print_text_in_color "$IRed" "[ERROR] $(_log_prefix) $*" >&2
}

success() {
    print_text_in_color "$IGreen" "[OK]    $(_log_prefix) $*"
}

debug() {
    if [ "$DEBUG" = "true" ]; then
        print_text_in_color "$Blue" "[DEBUG] $(_log_prefix) $*" >&2
    fi
}

die() {
    error "$*"
    exit 1
}

############################################################
# Whiptail menus (interactive mode) with non-interactive fallback
############################################################

SCRIPT_NAME="${SCRIPT_NAME:-}"
TITLE="RustDesk Server - $(date +%Y)"
[ -n "$SCRIPT_NAME" ] && TITLE+=" - $SCRIPT_NAME"
WT_HEIGHT="${WT_HEIGHT:-20}"
WT_WIDTH="${WT_WIDTH:-78}"
CHECKLIST_GUIDE="Navigate with the [ARROW] keys and (de)select with the [SPACE] key. \
Confirm by pressing [ENTER]. Cancel by pressing [ESC]."
MENU_GUIDE="Navigate with the [ARROW] keys and confirm by pressing [ENTER]. Cancel by pressing [ESC]."
RUN_LATER_GUIDE="You can run this script again later if you change your mind."

msg_box() {
    [ -n "${2:-}" ] && local SUBTITLE=" - $2"
    if [ "$NONINTERACTIVE" = "true" ]; then
        info "$1"
        return 0
    fi
    whiptail --title "$TITLE${SUBTITLE:-}" --msgbox "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3
}

# yesno_box_yes: defaults to "yes" when non-interactive (unless
# NONINTERACTIVE_DEFAULT_NO=true is set by the caller for this prompt).
yesno_box_yes() {
    [ -n "${2:-}" ] && local SUBTITLE=" - $2"
    if [ "$NONINTERACTIVE" = "true" ]; then
        [ "${NONINTERACTIVE_DEFAULT_NO:-false}" = "true" ] && return 1
        return 0
    fi
    if (whiptail --title "$TITLE${SUBTITLE:-}" --yesno "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3); then
        return 0
    else
        return 1
    fi
}

# yesno_box_no: defaults to "no" when non-interactive.
yesno_box_no() {
    [ -n "${2:-}" ] && local SUBTITLE=" - $2"
    if [ "$NONINTERACTIVE" = "true" ]; then
        [ "${NONINTERACTIVE_DEFAULT_YES:-false}" = "true" ] && return 0
        return 1
    fi
    if (whiptail --title "$TITLE${SUBTITLE:-}" --defaultno --yesno "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3); then
        return 0
    else
        return 1
    fi
}

# input_box: in non-interactive mode there is nothing sensible to
# prompt for, so callers must never rely on this without a pre-set
# value. It dies loudly instead of hanging on a prompt that can't show.
input_box() {
    [ -n "${2:-}" ] && local SUBTITLE=" - $2"
    if [ "$NONINTERACTIVE" = "true" ]; then
        die "input_box() called in non-interactive mode for '$1'. Pass the required value via a CLI flag or environment variable instead."
    fi
    local RESULT
    RESULT=$(whiptail --title "$TITLE${SUBTITLE:-}" --nocancel --inputbox "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3)
    echo "$RESULT"
}

input_box_flow() {
    local RESULT
    local SUBTITLE="${2:-}"
    while :
    do
        RESULT=$(input_box "$1" "$SUBTITLE") || return 1
        if [ -z "$RESULT" ]; then
            msg_box "Input is empty, please try again." "$SUBTITLE"
        elif ! yesno_box_yes "Is this correct? $RESULT" "$SUBTITLE"; then
            msg_box "OK, please try again." "$SUBTITLE"
        else
            break
        fi
    done
    echo "$RESULT"
}

############################################################
# Root check
############################################################

is_root() {
    [ "$EUID" -eq 0 ]
}

root_check() {
    if ! is_root; then
        msg_box "Sorry, you are not root. You now have two options:

1. Use SUDO directly:
   a) :~\$ sudo bash name-of-script.sh

2. Become ROOT and then type your command:
   a) :~\$ sudo -i
   b) :~# bash name-of-script.sh

More information can be found here: https://unix.stackexchange.com/a/3064"
        exit 1
    fi
}

############################################################
# OS / distro / package manager detection
############################################################

identify_os() {
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        # shellcheck source=/dev/null
        source /etc/os-release
        OS="$NAME"
        VER="$VERSION_ID"
        DISTRO_ID="${ID,,}"
        UPSTREAM_ID="${ID_LIKE,,}"

        if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
            UPSTREAM_ID="$(echo "${ID_LIKE,,}" | sed 's/"//g' | cut -d' ' -f1)"
        fi
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
        DISTRO_ID="${OS,,}"
    elif [ -f /etc/lsb-release ]; then
        # shellcheck source=/dev/null
        source /etc/lsb-release
        # shellcheck disable=SC2153
        OS="$DISTRIB_ID"
        VER="$DISTRIB_RELEASE"
        DISTRO_ID="${OS,,}"
    elif [ -f /etc/debian_version ]; then
        OS=Debian
        VER=$(cat /etc/debian_version)
        DISTRO_ID="debian"
    elif [ -f /etc/SuSE-release ]; then
        OS=SuSE
        VER=$(cat /etc/SuSE-release)
        DISTRO_ID="suse"
    elif [ -f /etc/redhat-release ]; then
        OS=RedHat
        VER=$(cat /etc/redhat-release)
        DISTRO_ID="rhel"
    else
        OS=$(uname -s)
        VER=$(uname -r)
        DISTRO_ID="unknown"
    fi
    export OS VER UPSTREAM_ID DISTRO_ID
}

# Detects which package manager is available and sets PKG_MANAGER
# accordingly. Supports the apt/dnf/yum/zypper/pacman/apk/emerge family,
# covering Ubuntu, Debian, Mint, Pop!_OS, Rocky, AlmaLinux, Fedora,
# CentOS, RHEL and openSUSE.
detect_pkg_manager() {
    if [ -x "$(command -v apt-get)" ]; then
        PKG_MANAGER="apt-get"
    elif [ -x "$(command -v dnf)" ]; then
        PKG_MANAGER="dnf"
    elif [ -x "$(command -v zypper)" ]; then
        PKG_MANAGER="zypper"
    elif [ -x "$(command -v yum)" ]; then
        PKG_MANAGER="yum"
    elif [ -x "$(command -v pacman)" ]; then
        PKG_MANAGER="pacman"
    elif [ -x "$(command -v apk)" ]; then
        PKG_MANAGER="apk"
    elif [ -x "$(command -v emerge)" ]; then
        PKG_MANAGER="emerge"
    else
        PKG_MANAGER=""
    fi
    export PKG_MANAGER
}

install_linux_package() {
    [ -z "${PKG_MANAGER+x}" ] && detect_pkg_manager
    info "Installing ${1}..."
    case "$PKG_MANAGER" in
        apt-get)
            apt-get install -y "${1}"
            ;;
        dnf)
            dnf install -y "${1}"
            ;;
        zypper)
            zypper --non-interactive install "${1}"
            ;;
        yum)
            yum install -y "${1}"
            ;;
        pacman)
            pacman -S --noconfirm "${1}"
            ;;
        apk)
            apk add --no-cache "${1}"
            ;;
        emerge)
            emerge -av "${1}"
            ;;
        *)
            error "FAILED TO INSTALL ${1}! Package manager not found: your OS is currently unsupported."
            return 1
            ;;
    esac
}

purge_linux_package() {
    [ -z "${PKG_MANAGER+x}" ] && detect_pkg_manager
    case "$PKG_MANAGER" in
        apt-get)
            apt-get purge --autoremove -y "${1}"
            ;;
        dnf)
            dnf remove -y "${1}"
            ;;
        zypper)
            zypper --non-interactive remove "${1}"
            ;;
        yum)
            yum remove -y "${1}"
            ;;
        pacman)
            pacman -Rs --noconfirm "${1}"
            ;;
        apk)
            apk del "${1}"
            ;;
        emerge)
            emerge -Cv "${1}"
            ;;
        *)
            error "FAILED TO REMOVE ${1}! Package manager not found: your OS is currently unsupported."
            return 1
            ;;
    esac
}

############################################################
# Architecture detection
############################################################

# Maps uname -m output to a canonical architecture alias. Add a line
# here to support a new architecture without touching install.sh/update.sh.
# rustdesk-server's own release assets use two DIFFERENT per-arch naming
# conventions depending on asset type (zip vs deb) - zip_arch_alias()/
# deb_arch_alias() below translate this canonical alias into each.
detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            ARCH_ALIAS="amd64"
            ;;
        aarch64|arm64)
            ARCH_ALIAS="arm64"
            ;;
        armv7l|armv7)
            ARCH_ALIAS="armv7"
            ;;
        *)
            ARCH_ALIAS=""
            ;;
    esac
    export ARCH ARCH_ALIAS
}

# zip_arch_alias: rustdesk-server-linux-<alias>.zip naming.
zip_arch_alias() {
    case "$ARCH_ALIAS" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64v8" ;;
        armv7) echo "armv7" ;;
        *) echo "" ;;
    esac
}

# deb_arch_alias: rustdesk-server-{hbbs,hbbr,utils}_<version>_<alias>.deb
# naming (standard Debian architecture names).
deb_arch_alias() {
    case "$ARCH_ALIAS" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        armv7) echo "armhf" ;;
        *) echo "" ;;
    esac
}

# go_arch_alias / node_arch_alias: naming used by go.dev/dl and
# nodejs.org/dist releases respectively, for ensure_go/ensure_node.
go_arch_alias() {
    case "$ARCH_ALIAS" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        armv7) echo "armv6l" ;;
        *) echo "" ;;
    esac
}

node_arch_alias() {
    case "$ARCH_ALIAS" in
        amd64) echo "x64" ;;
        arm64) echo "arm64" ;;
        armv7) echo "armv7l" ;;
        *) echo "" ;;
    esac
}

############################################################
# Networking helpers
############################################################

get_wanip4() {
    WANIP4=$(curl -s -k -m 5 -4 https://api64.ipify.org)
    export WANIP4
}

############################################################
# Retry helper
############################################################

# retry <max_attempts> <delay_seconds> -- <command...>
retry() {
    local max="$1"; shift
    local delay="$1"; shift
    if [ "$1" = "--" ]; then shift; fi
    local attempt=1
    until "$@"; do
        if [ "$attempt" -ge "$max" ]; then
            return 1
        fi
        warn "Command failed (attempt $attempt/$max): $* - retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    return 0
}

############################################################
# GitHub release / asset resolution
#
# Everything here works against a public repository with no extra
# configuration. If GITHUB_TOKEN is set (e.g. because the fork is kept
# private), the same functions transparently authenticate: the Contents
# API is used instead of raw.githubusercontent.com, and release assets
# are fetched through the authenticated release-assets API instead of
# the bare browser_download_url, both of which 404 for anonymous
# requests against a private repository.
############################################################

_gh_curl() {
    local args=(-fsSL --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY" --retry-connrefused)
    if [ -n "$GITHUB_TOKEN" ]; then
        args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${args[@]}" "$@"
}

# gh_fetch_latest_release <owner> <repo>
# Fetches the latest release JSON from GitHub for <owner>/<repo>.
# Sets RELEASE_JSON on success, returns 1 if no releases exist / API call
# fails, so callers can gracefully fall back to the repo-root layout.
gh_fetch_latest_release() {
    local owner="$1" repo="$2"
    debug "Querying latest release for ${owner}/${repo}"
    RELEASE_JSON=$(_gh_curl "$GITHUB_API/repos/${owner}/${repo}/releases/latest" 2>/dev/null) || return 1
    [ -n "$RELEASE_JSON" ] || return 1
    if echo "$RELEASE_JSON" | grep -q '"message": *"Not Found"'; then
        return 1
    fi
    export RELEASE_JSON
    return 0
}

# Extracts the tag name from RELEASE_JSON. Prefers jq when available,
# falls back to a grep/awk parse otherwise.
gh_release_tag() {
    if command -v jq &>/dev/null; then
        echo "$RELEASE_JSON" | jq -r '.tag_name'
    else
        echo "$RELEASE_JSON" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
    fi
}

# gh_branch_sha <owner> <repo> <branch>
# Resolves a branch's current commit SHA - used to version-track
# components built from a branch (rustdesk-api/rustdesk-api-web) rather
# than from a tagged release, so update.sh can tell whether the branch
# has actually moved before rebuilding.
gh_branch_sha() {
    local owner="$1" repo="$2" branch="$3"
    local json
    json=$(_gh_curl "${GITHUB_API}/repos/${owner}/${repo}/git/ref/heads/${branch}" 2>/dev/null) || return 1
    [ -n "$json" ] || return 1
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.object.sha'
    else
        echo "$json" | grep '"sha"' | head -n1 | sed -E 's/.*"sha": *"([^"]+)".*/\1/'
    fi
}

# Returns "<id> <browser_download_url>" for a given asset name if it is
# present in RELEASE_JSON, empty otherwise. The numeric asset id is
# required to hit the authenticated release-assets API for private repos.
_gh_release_asset_lookup() {
    local asset="$1"
    if command -v jq &>/dev/null; then
        echo "$RELEASE_JSON" | jq -r --arg name "$asset" '.assets[]? | select(.name == $name) | "\(.id) \(.browser_download_url)"'
    else
        # Best-effort fallback without jq, assuming compact single-line
        # asset objects as returned by the GitHub API.
        echo "$RELEASE_JSON" | tr ',' '\n' | grep -B2 -A2 "\"name\": *\"${asset}\"" \
            | { id=$(grep '"id"' | head -n1 | sed -E 's/.*"id": *([0-9]+).*/\1/'); \
                dl=$(grep browser_download_url | head -n1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/'); \
                echo "$id $dl"; }
    fi
}

# fetch_repo_file <owner> <repo> <branch> <path> <dest>
# Downloads a file that lives at the repository root (Layout A), e.g.
# lib.sh, install.sh, or a committed .tar.gz/.deb asset.
fetch_repo_file() {
    local owner="$1" repo="$2" branch="$3" path="$4" dest="$5"
    if [ -n "$GITHUB_TOKEN" ]; then
        retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.raw+json" \
            -o "$dest" \
            "${GITHUB_API}/repos/${owner}/${repo}/contents/${path}?ref=${branch}"
    else
        retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused \
            -o "$dest" \
            "${GITHUB_RAW_HOST}/${owner}/${repo}/${branch}/${path}"
    fi
}

# fetch_release_asset <owner> <repo> <asset-name> <dest>
# Downloads a named asset from RELEASE_JSON (Layout B). Caller must have
# called gh_fetch_latest_release for the same <owner>/<repo> first and
# confirmed the asset exists.
fetch_release_asset() {
    local owner="$1" repo="$2" asset="$3" dest="$4"
    local id dl
    read -r id dl <<<"$(_gh_release_asset_lookup "$asset")"
    [ -n "$id" ] && [ "$id" != "null" ] || return 1

    if [ -n "$GITHUB_TOKEN" ]; then
        retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/octet-stream" \
            -o "$dest" \
            "${GITHUB_API}/repos/${owner}/${repo}/releases/assets/${id}"
    else
        [ -n "$dl" ] || return 1
        retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused -o "$dest" "$dl"
    fi
}

# asset_exists_in_release <asset-name>
asset_exists_in_release() {
    [ -n "${RELEASE_JSON:-}" ] || return 1
    local id
    read -r id _ <<<"$(_gh_release_asset_lookup "$1")"
    [ -n "$id" ] && [ "$id" != "null" ]
}

############################################################
# Download & verification
############################################################

compute_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

# verify_checksum <owner> <repo> <branch> <file> <asset-name>
# Looks for a "<asset-name>.sha256" file next to the asset (release or
# repo root, wherever the asset itself was found) and verifies the
# downloaded file against it. If no checksum file is published, this
# degrades gracefully to a warning rather than failing the install,
# since checksums are optional infrastructure.
verify_checksum() {
    local owner="$1" repo="$2" branch="$3" file="$4" asset="$5"
    local sumfile
    sumfile=$(mktemp)
    local got_sum="false"

    if asset_exists_in_release "${asset}.sha256" && fetch_release_asset "$owner" "$repo" "${asset}.sha256" "$sumfile" 2>/dev/null; then
        got_sum="true"
    elif fetch_repo_file "$owner" "$repo" "$branch" "${asset}.sha256" "$sumfile" 2>/dev/null; then
        got_sum="true"
    fi

    if [ "$got_sum" != "true" ] || [ ! -s "$sumfile" ]; then
        rm -f "$sumfile"
        warn "No checksum published for ${asset}; skipping integrity verification."
        return 0
    fi

    local expected actual
    expected=$(awk '{print $1}' "$sumfile")
    rm -f "$sumfile"
    actual=$(compute_sha256 "$file")
    if [ "$expected" != "$actual" ]; then
        error "Checksum mismatch for ${asset}: expected $expected, got $actual"
        return 1
    fi
    success "Checksum verified for ${asset}."
}

# sanity_check_archive <file>
# Cheap corruption check that doesn't depend on published checksums.
sanity_check_archive() {
    case "$1" in
        *.tar.gz|*.tgz)
            tar -tzf "$1" >/dev/null 2>&1
            ;;
        *.zip)
            unzip -t "$1" >/dev/null 2>&1
            ;;
        *.deb)
            dpkg-deb -I "$1" >/dev/null 2>&1
            ;;
        *)
            [ -s "$1" ]
            ;;
    esac
}

# fetch_and_verify <owner> <repo> <branch> <asset-name> <dest-path>
# Full pipeline: prefer the release asset (Layout B), fall back to the
# repo-root file (Layout A) -> corruption check -> checksum
# verification (best-effort).
fetch_and_verify() {
    local owner="$1" repo="$2" branch="$3" asset="$4" dest="$5"

    info "Downloading $(basename "$dest") ..."
    if asset_exists_in_release "$asset"; then
        fetch_release_asset "$owner" "$repo" "$asset" "$dest" || { error "Failed to download release asset '$asset'."; return 1; }
    else
        [ -n "${RELEASE_JSON:-}" ] && debug "Asset '$asset' not found in release, falling back to repo root layout"
        fetch_repo_file "$owner" "$repo" "$branch" "$asset" "$dest" || { error "Failed to download '$asset' from ${owner}/${repo}@${branch}."; return 1; }
    fi

    if [ ! -s "$dest" ]; then
        error "Downloaded file $dest is empty."
        return 1
    fi
    if ! sanity_check_archive "$dest"; then
        error "$asset appears to be corrupted (failed integrity sanity check)."
        return 1
    fi
    verify_checksum "$owner" "$repo" "$branch" "$dest" "$asset"
}

# extract_archive <archive-path> <dest-dir>
# Extracts a .zip or .tar.gz into <dest-dir>, which is created if needed.
extract_archive() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    case "$archive" in
        *.zip)
            unzip -q -o "$archive" -d "$dest"
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *)
            die "extract_archive: unsupported archive type: $archive"
            ;;
    esac
}

# find_binary <search-dir> <binary-name>
# Locates a named binary anywhere under <search-dir>, regardless of
# whether the archive it came from nested it in an arch-named
# subdirectory or shipped it flat - defensive against release layouts
# this fork can't pin down without a live copy of every upstream's
# archives. Echoes the path found, or nothing (caller should check).
find_binary() {
    find "$1" -type f -name "$2" 2>/dev/null | head -n1
}

############################################################
# Building from source (rustdesk-api / rustdesk-api-web have no
# published release binaries yet, so install.sh/update.sh build them
# from source using the toolchains below).
############################################################

# fetch_source_tarball <owner> <repo> <ref> <dest-dir>
# Downloads and extracts a repository's source at <ref> (branch, tag or
# SHA) into <dest-dir> via GitHub's tarball API, which - unlike the
# plain /archive/ redirect links - supports GITHUB_TOKEN the same way
# every other fetch in this library does, so it works for private repos
# too. <dest-dir> is replaced if it already exists.
fetch_source_tarball() {
    local owner="$1" repo="$2" ref="$3" dest_dir="$4"
    local tmp_tar tmp_extract top_dir

    tmp_tar=$(mktemp)
    if ! _gh_curl -o "$tmp_tar" "${GITHUB_API}/repos/${owner}/${repo}/tarball/${ref}"; then
        rm -f "$tmp_tar"
        error "Failed to download source tarball for ${owner}/${repo}@${ref}."
        return 1
    fi
    if [ ! -s "$tmp_tar" ]; then
        rm -f "$tmp_tar"
        error "Source tarball for ${owner}/${repo}@${ref} is empty."
        return 1
    fi

    tmp_extract=$(mktemp -d)
    if ! tar -xzf "$tmp_tar" -C "$tmp_extract"; then
        rm -rf "$tmp_tar" "$tmp_extract"
        error "Failed to extract source tarball for ${owner}/${repo}@${ref}."
        return 1
    fi
    rm -f "$tmp_tar"

    top_dir=$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)
    if [ -z "$top_dir" ]; then
        rm -rf "$tmp_extract"
        error "Unexpected source tarball layout for ${owner}/${repo}@${ref}."
        return 1
    fi

    mkdir -p "$(dirname "$dest_dir")"
    rm -rf "$dest_dir"
    mv "$top_dir" "$dest_dir"
    rm -rf "$tmp_extract"
}

# ensure_go <min-minor-version>
# Ensures a Go toolchain >= 1.<min-minor-version> is on PATH, installing
# a pinned fallback version from go.dev if the distro's own Go package
# is missing or too old. rustdesk-api needs a recent Go (see its go.mod)
# for its use of go-sqlite3 (CGO) and other dependencies.
GO_FALLBACK_VERSION="${GO_FALLBACK_VERSION:-go1.23.4}"
ensure_go() {
    local min_minor="${1:-23}"
    if command -v go &>/dev/null; then
        local ver minor
        ver=$(go version | awk '{print $3}' | sed 's/^go//')
        minor=$(echo "$ver" | cut -d. -f2)
        if [ -n "$minor" ] && [ "$minor" -ge "$min_minor" ] 2>/dev/null; then
            info "Using existing Go toolchain: $(go version)"
            return 0
        fi
        warn "Installed Go ($ver) is older than required (1.${min_minor}+); installing ${GO_FALLBACK_VERSION} instead."
    fi

    local goarch
    goarch=$(go_arch_alias)
    [ -n "$goarch" ] || die "No Go toolchain available for architecture $ARCH."

    info "Installing Go ${GO_FALLBACK_VERSION} toolchain..."
    local tmp
    tmp=$(mktemp)
    retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused \
        -o "$tmp" "https://go.dev/dl/${GO_FALLBACK_VERSION}.linux-${goarch}.tar.gz" \
        || die "Failed to download the Go toolchain."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$tmp"
    rm -f "$tmp"
    export PATH="/usr/local/go/bin:$PATH"
    command -v go &>/dev/null || die "Go installation appears to have failed."
    success "Installed $(go version)"
}

# ensure_node <min-major-version>
# Ensures Node.js >= <min-major-version> (with npm) is on PATH,
# installing a pinned fallback version from nodejs.org if the distro's
# own package is missing or too old. rustdesk-api-web's Vite 6 build
# needs a reasonably recent Node.
NODE_FALLBACK_VERSION="${NODE_FALLBACK_VERSION:-v20.18.1}"
ensure_node() {
    local min_major="${1:-18}"
    if command -v node &>/dev/null; then
        local ver major
        ver=$(node -v)
        major=$(echo "$ver" | sed 's/^v//' | cut -d. -f1)
        if [ -n "$major" ] && [ "$major" -ge "$min_major" ] 2>/dev/null; then
            info "Using existing Node.js: $ver"
            return 0
        fi
        warn "Installed Node.js ($ver) is older than required (v${min_major}+); installing ${NODE_FALLBACK_VERSION} instead."
    fi

    local nodearch
    nodearch=$(node_arch_alias)
    [ -n "$nodearch" ] || die "No Node.js build available for architecture $ARCH."

    info "Installing Node.js ${NODE_FALLBACK_VERSION} toolchain..."
    local tmp
    tmp=$(mktemp)
    retry "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY" -- curl -fsSL --retry-connrefused \
        -o "$tmp" "https://nodejs.org/dist/${NODE_FALLBACK_VERSION}/node-${NODE_FALLBACK_VERSION}-linux-${nodearch}.tar.xz" \
        || die "Failed to download Node.js."
    rm -rf /usr/local/lib/nodejs
    mkdir -p /usr/local/lib/nodejs
    tar -xJf "$tmp" -C /usr/local/lib/nodejs --strip-components=1
    rm -f "$tmp"
    export PATH="/usr/local/lib/nodejs/bin:$PATH"
    command -v node &>/dev/null || die "Node.js installation appears to have failed."
    success "Installed Node.js $(node -v), npm $(npm -v)"
}

############################################################
# Version bookkeeping
############################################################

# write_installed_version <component> <version>
# <component> is one of: hbbs, api, web - tracked separately since each
# now comes from a different upstream and updates independently.
write_installed_version() {
    mkdir -p "$(dirname "$RUSTDESK_VERSION_FILE")"
    mkdir -p "${RUSTDESK_VERSION_FILE}.d"
    echo "$2" > "${RUSTDESK_VERSION_FILE}.d/$1"
}

# read_installed_version <component>
read_installed_version() {
    [ -f "${RUSTDESK_VERSION_FILE}.d/$1" ] && cat "${RUSTDESK_VERSION_FILE}.d/$1" || echo ""
}

############################################################
# systemd service helpers
############################################################

service_is_active() {
    systemctl is-active --quiet "$1"
}

enable_and_start_service() {
    systemctl enable "$1"
    systemctl restart "$1"
}

stop_and_disable_service() {
    systemctl disable "$1" 2>/dev/null
    systemctl stop "$1" 2>/dev/null
}

# wait_for_service_active <service> <timeout-seconds>
wait_for_service_active() {
    local svc="$1"
    local timeout="${2:-60}"
    local waited=0
    while ! service_is_active "$svc"; do
        if [ "$waited" -ge "$timeout" ]; then
            return 1
        fi
        info "Waiting for $svc to become active... (${waited}s/${timeout}s)"
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

############################################################
# Firewall abstraction (ufw / firewalld)
############################################################

detect_firewall() {
    if command -v ufw &>/dev/null; then
        FIREWALL="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        FIREWALL="firewalld"
    else
        FIREWALL="none"
    fi
    export FIREWALL
}

# fw_allow <proto> <port-or-range>
# port-or-range uses dash for ranges, e.g. "21115-21119".
fw_allow() {
    local proto="$1"
    local port="$2"
    [ -z "${FIREWALL+x}" ] && detect_firewall
    case "$FIREWALL" in
        ufw)
            ufw allow "${port//-/:}/${proto}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
            ;;
        *)
            warn "No supported firewall (ufw/firewalld) detected; skipping firewall rule for ${port}/${proto}."
            ;;
    esac
}

fw_delete() {
    local proto="$1"
    local port="$2"
    [ -z "${FIREWALL+x}" ] && detect_firewall
    case "$FIREWALL" in
        ufw)
            ufw delete allow "${port//-/:}/${proto}" 2>/dev/null
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
            ;;
        *)
            ;;
    esac
}

fw_enable() {
    [ -z "${FIREWALL+x}" ] && detect_firewall
    case "$FIREWALL" in
        ufw)
            ufw --force enable
            ufw --force reload
            ;;
        firewalld)
            systemctl enable --now firewalld >/dev/null 2>&1
            firewall-cmd --reload >/dev/null
            ;;
        *)
            ;;
    esac
}

fw_disable() {
    [ -z "${FIREWALL+x}" ] && detect_firewall
    case "$FIREWALL" in
        ufw)
            ufw --force disable
            ;;
        firewalld)
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        *)
            ;;
    esac
}
