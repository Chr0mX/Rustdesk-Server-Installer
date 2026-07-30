#!/bin/bash
#
# install.sh - RustDesk Server installer (community fork)
#
# Installs a complete, self-hosted, fully open-source RustDesk stack -
# no dependency on github.com/rustdesk, rustdesk.com, or any closed-
# source RustDesk Server Pro binary:
#
#   - hbbs/hbbr/rustdesk-utils, from Chr0mX/rustdesk-server (an
#     AGPL-3.0 fork of lejianwen/rustdesk-server, itself a fork of the
#     official rustdesk/rustdesk-server, adding the WebSocket support the
#     web client needs plus upstream 1.1.15/1.1.16 fixes lejianwen's fork
#     hadn't picked up)
#   - rustdesk-api, the open-source admin API/console backend (built
#     from source; Go)
#   - rustdesk-api-web, its frontend (built from source; Vue/Vite)
#
# What this script does:
#   1. Detects CPU architecture and Linux distribution
#   2. Installs required dependencies via the distro's package manager
#      (including Go/Node.js toolchains if not already present, needed
#      to build rustdesk-api/rustdesk-api-web from source)
#   3. Downloads and installs hbbs/hbbr/rustdesk-utils
#   4. Builds and installs rustdesk-api + rustdesk-api-web
#   5. Creates systemd services for all of the above
#   6. Optionally sets up Nginx + Certbot for a TLS-terminated domain
#   7. Supports a fully non-interactive mode for scripted deployments
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   -y, --non-interactive     Never prompt; use flags/env vars for input
#       --user <name>         Run all services as this unprivileged user
#       --domain <fqdn>       Use a domain + Let's Encrypt TLS via Nginx
#       --ip                  Use IP-only mode (no domain/TLS)
#       --skip-api            Only install hbbs/hbbr; skip rustdesk-api
#                             and rustdesk-api-web (headless server,
#                             matching the plain open-source project)
#       --hbbs-owner <owner>  Override the hbbs/hbbr release source
#       --hbbs-repo <repo>
#       --server-branch <branch>  Branch of hbbs-owner/hbbs-repo's source
#                             tree to pull libs/hbb_common/*.proto from
#                             when generating rustdesk-api-web's webclient
#                             protobuf bindings (default: forapi)
#       --api-owner <owner>   Override the rustdesk-api source
#       --api-repo <repo>
#       --api-branch <branch>
#       --web-owner <owner>   Override the rustdesk-api-web source
#       --web-repo <repo>
#       --web-branch <branch>
#       --owner <owner>       Override where THIS installer's own
#       --repo <repo>         lib.sh is fetched from, if not run from a
#       --branch <branch>     local clone (rarely needs changing)
#       --no-certbot-snap     Use distro packages for Certbot instead of snap
#   -h, --help                Show this help and exit
#
# All options can also be provided via environment variables:
#   NONINTERACTIVE, RUSTDESK_USER, RUSTDESK_DOMAIN, SKIP_API,
#   HBBS_OWNER, HBBS_REPO, API_OWNER, API_REPO, API_BRANCH,
#   WEB_OWNER, WEB_REPO, WEB_BRANCH, GITHUB_OWNER, GITHUB_REPO,
#   GITHUB_BRANCH, CERTBOT_USE_SNAP

set -uo pipefail

##################################################################################################################
# Argument parsing (done before sourcing lib.sh; only sets env vars)
##################################################################################################################

RUSTDESK_DOMAIN="${RUSTDESK_DOMAIN:-}"
RUSTDESK_USER="${RUSTDESK_USER:-}"
FORCE_IP_MODE="false"
CERTBOT_USE_SNAP="${CERTBOT_USE_SNAP:-true}"
SKIP_API="${SKIP_API:-false}"

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,45p'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--non-interactive)
            NONINTERACTIVE="true"
            ;;
        --user)
            RUSTDESK_USER="$2"; shift
            ;;
        --domain)
            RUSTDESK_DOMAIN="$2"; shift
            ;;
        --ip)
            FORCE_IP_MODE="true"
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
        --server-branch)
            SERVER_BRANCH="$2"; shift
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
        --no-certbot-snap)
            CERTBOT_USE_SNAP="false"
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
export RUSTDESK_USER RUSTDESK_DOMAIN CERTBOT_USE_SNAP SKIP_API
export GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH
export HBBS_OWNER HBBS_REPO SERVER_BRANCH API_OWNER API_REPO API_BRANCH WEB_OWNER WEB_REPO WEB_BRANCH

##################################################################################################################
# Bootstrap: minimal deps + source lib.sh from this fork's own repository
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

SCRIPT_NAME="Install script"
export SCRIPT_NAME
# Fetches a file from the repo root, transparently authenticating with
# GITHUB_TOKEN when set (required if this fork is kept private).
_bootstrap_fetch_repo_file() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.raw+json" \
            "${GITHUB_API:-https://api.github.com}/repos/${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Server-Installer}/contents/${1}?ref=${GITHUB_BRANCH:-main}"
    else
        curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
            "${GITHUB_RAW_HOST:-https://raw.githubusercontent.com}/${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Server-Installer}/${GITHUB_BRANCH:-main}/${1}"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib.sh" ]; then
    # shellcheck source=lib.sh
    source "$SCRIPT_DIR/lib.sh"
else
    LIB_SRC=$(_bootstrap_fetch_repo_file lib.sh) || { echo "FATAL: could not fetch lib.sh from ${GITHUB_OWNER:-Chr0mX}/${GITHUB_REPO:-Rustdesk-Server-Installer}@${GITHUB_BRANCH:-main}" >&2; exit 1; }
    # shellcheck source=/dev/null
    source <(echo "$LIB_SRC")
fi
unset SCRIPT_NAME

##################################################################################################################

root_check

if [ "${DEBUG:-false}" = "true" ]; then
    identify_os
    detect_arch
    detect_pkg_manager
    detect_firewall
    info "OS: $OS / VER: $VER / UPSTREAM_ID: $UPSTREAM_ID"
    info "ARCH: $ARCH / ARCH_ALIAS: $ARCH_ALIAS"
    info "PKG_MANAGER: $PKG_MANAGER / FIREWALL: $FIREWALL"
    info "hbbs/hbbr source: ${HBBS_OWNER}/${HBBS_REPO}"
    info "rustdesk-api source: ${API_OWNER}/${API_REPO}@${API_BRANCH}"
    info "rustdesk-api-web source: ${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH}"
    exit 0
fi

detect_arch
[ -n "$ARCH_ALIAS" ] || die "Unsupported CPU architecture: $ARCH. Supported: x86_64/amd64, aarch64/arm64, armv7l."

identify_os
detect_pkg_manager
[ -n "$PKG_MANAGER" ] || die "Unsupported distribution: no known package manager (apt/dnf/yum/zypper/pacman/apk/emerge) found."
detect_firewall

info "Detected: $OS $VER, arch=$ARCH_ALIAS, package manager=$PKG_MANAGER, firewall=$FIREWALL"

get_wanip4

# Automatic restart of services while installing packages.
if [ ! -f /etc/needrestart/needrestart.conf ]; then
    install_linux_package needrestart || true
    if [ -f /etc/needrestart/needrestart.conf ] && ! grep -rq "{restart} = 'a'" /etc/needrestart/needrestart.conf; then
        sed -i "s|#\$nrconf{restart} =.*|\$nrconf{restart} = 'a'\;|g" /etc/needrestart/needrestart.conf
    fi
fi

##################################################################################################################
# Select the user services will run as
##################################################################################################################

if [ -z "$RUSTDESK_USER" ] && [ "$NONINTERACTIVE" != "true" ]; then
    msg_box "RustDesk can be installed as an unprivileged user, but we need root for everything else.
Running with an unprivileged user enhances security, and is recommended."

    if yesno_box_yes "Do you want to use an unprivileged user for RustDesk?"; then
        while :
        do
            RUSTDESK_USER=$(input_box_flow "Please enter the name of your non-root user:")
            if ! id "$RUSTDESK_USER" &>/dev/null; then
                msg_box "We couldn't find $RUSTDESK_USER on the system, are you sure it's correct?
Please try again."
            else
                break
            fi
        done
    fi
fi

if [ -n "$RUSTDESK_USER" ] && ! id "$RUSTDESK_USER" &>/dev/null; then
    die "User '$RUSTDESK_USER' does not exist on this system."
fi
SERVICE_USER="${RUSTDESK_USER:-root}"

##################################################################################################################
# Dependencies
##################################################################################################################

install_linux_package unzip
install_linux_package tar
install_linux_package jq || warn "jq could not be installed; falling back to text parsing of the GitHub API response."
if ! install_linux_package dnsutils; then
    install_linux_package bind9-utils || install_linux_package bind-utils
fi
if [ "$FIREWALL" = "none" ]; then
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        install_linux_package ufw && detect_firewall
    fi
fi
if [ "$SKIP_API" != "true" ]; then
    # gcc is required for CGO (rustdesk-api uses go-sqlite3).
    install_linux_package gcc || die "A C compiler (gcc) is required to build rustdesk-api and could not be installed."
fi

##################################################################################################################
# Firewall: open the ports hbbs/hbbr need
##################################################################################################################

fw_allow tcp 21115-21119
fw_allow udp 21116

##################################################################################################################
# hbbs/hbbr/rustdesk-utils
##################################################################################################################

if gh_fetch_latest_release "$HBBS_OWNER" "$HBBS_REPO"; then
    HBBS_RELEASE_TAG=$(gh_release_tag)
    info "Latest hbbs/hbbr release on ${HBBS_OWNER}/${HBBS_REPO}: $HBBS_RELEASE_TAG"
else
    die "Could not find any release on ${HBBS_OWNER}/${HBBS_REPO}. Check --hbbs-owner/--hbbs-repo, or your network connection."
fi

ZIP_ARCH="$(zip_arch_alias)"
[ -n "$ZIP_ARCH" ] || die "No hbbs/hbbr release asset naming known for architecture $ARCH."
HBBS_ASSET_NAME="rustdesk-server-linux-${ZIP_ARCH}.zip"

if [ ! -d "$RUSTDESK_INSTALL_DIR" ]; then
    success "Installing hbbs/hbbr..."
    mkdir -p "$RUSTDESK_INSTALL_DIR"
    [ -d "$RUSTDESK_INSTALL_DIR" ] || die "The installation folder $RUSTDESK_INSTALL_DIR could not be created."

    HBBS_WORKDIR=$(mktemp -d)
    trap 'rm -rf "$HBBS_WORKDIR"' EXIT

    if ! fetch_and_verify "$HBBS_OWNER" "$HBBS_REPO" "master" "$HBBS_ASSET_NAME" "$HBBS_WORKDIR/$HBBS_ASSET_NAME"; then
        die "Sorry, the hbbs/hbbr package ($HBBS_ASSET_NAME) failed to download or verify. Please try running the installer again."
    fi

    EXTRACTED_DIR="$HBBS_WORKDIR/extracted"
    extract_archive "$HBBS_WORKDIR/$HBBS_ASSET_NAME" "$EXTRACTED_DIR"

    HBBS_BIN=$(find_binary "$EXTRACTED_DIR" hbbs)
    HBBR_BIN=$(find_binary "$EXTRACTED_DIR" hbbr)
    UTILS_BIN=$(find_binary "$EXTRACTED_DIR" rustdesk-utils)
    [ -n "$HBBS_BIN" ] || die "Could not find an hbbs binary inside $HBBS_ASSET_NAME - unexpected archive layout."
    [ -n "$HBBR_BIN" ] || die "Could not find an hbbr binary inside $HBBS_ASSET_NAME - unexpected archive layout."

    mv "$HBBS_BIN" /usr/bin/hbbs
    mv "$HBBR_BIN" /usr/bin/hbbr
    chmod +x /usr/bin/hbbs /usr/bin/hbbr
    if [ -n "$UTILS_BIN" ]; then
        mv "$UTILS_BIN" /usr/bin/rustdesk-utils
        chmod +x /usr/bin/rustdesk-utils
    else
        warn "rustdesk-utils binary not found in $HBBS_ASSET_NAME; skipping (not required for hbbs/hbbr to run)."
    fi

    if [ -n "$RUSTDESK_USER" ]; then
        chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_INSTALL_DIR"
        chown "$RUSTDESK_USER":"$RUSTDESK_USER" /usr/bin/hbbr /usr/bin/hbbs
        [ -n "$UTILS_BIN" ] && chown "$RUSTDESK_USER":"$RUSTDESK_USER" /usr/bin/rustdesk-utils
    fi

    write_installed_version hbbs "$HBBS_RELEASE_TAG"

    rm -rf "$HBBS_WORKDIR"
    trap - EXIT
else
    success "hbbs/hbbr already installed in $RUSTDESK_INSTALL_DIR."
fi

##################################################################################################################
# Log directory (hbbs/hbbr)
##################################################################################################################

if [ ! -d "$RUSTDESK_LOG_DIR" ]; then
    info "Creating $RUSTDESK_LOG_DIR"
    install -d -m 700 "$RUSTDESK_LOG_DIR"
    [ -n "$RUSTDESK_USER" ] && chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_LOG_DIR"
fi

##################################################################################################################
# systemd services (hbbs/hbbr)
##################################################################################################################

write_service_unit() {
    local name="$1" bin="$2" workdir="$3" logdir="$4"
    local unit_path="/etc/systemd/system/rustdesk-${name}.service"
    cat > "$unit_path" <<UNIT
[Unit]
Description=RustDesk ${name} service
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${bin}
WorkingDirectory=${workdir}
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=always
RestartSec=10
StandardOutput=append:${logdir}/${name}.log
StandardError=append:${logdir}/${name}.error

[Install]
WantedBy=multi-user.target
UNIT
}

[ -f /etc/systemd/system/rustdesk-hbbs.service ] || write_service_unit hbbs /usr/bin/hbbs "$RUSTDESK_INSTALL_DIR" "$RUSTDESK_LOG_DIR"
[ -f /etc/systemd/system/rustdesk-hbbr.service ] || write_service_unit hbbr /usr/bin/hbbr "$RUSTDESK_INSTALL_DIR" "$RUSTDESK_LOG_DIR"

systemctl daemon-reload
enable_and_start_service rustdesk-hbbr.service
enable_and_start_service rustdesk-hbbs.service

if ! wait_for_service_active rustdesk-hbbr.service 60; then
    die "rustdesk-hbbr.service failed to become active. Check: journalctl -u rustdesk-hbbr.service"
fi

##################################################################################################################
# Wait for the keypair to be generated
##################################################################################################################

PUBKEYNAME=""
WAITED=0
while [ -z "$PUBKEYNAME" ]; do
    PUBKEYNAME=$(find "$RUSTDESK_INSTALL_DIR" -maxdepth 1 -name "*.pub" | head -n1)
    if [ -z "$PUBKEYNAME" ]; then
        if [ "$WAITED" -ge 60 ]; then
            die "Timed out waiting for the RustDesk keypair to be generated. Check: journalctl -u rustdesk-hbbs.service"
        fi
        info "Checking if public key is generated... (${WAITED}s/60s)"
        sleep 5
        WAITED=$((WAITED + 5))
    fi
done
success "Public key path: $PUBKEYNAME"
PUBLICKEY=$(cat "$PUBKEYNAME")

##################################################################################################################
# IP vs Domain (TLS) setup - decided now so rustdesk-api's api-server
# config below can be set correctly on first boot.
##################################################################################################################

if [ "$FORCE_IP_MODE" = "true" ]; then
    CHOICE="IP"
elif [ -n "$RUSTDESK_DOMAIN" ]; then
    CHOICE="DNS"
elif [ "$NONINTERACTIVE" = "true" ]; then
    CHOICE="IP"
else
    CHOICE=$(whiptail --title "RustDesk installation script" --menu \
"Choose your preferred option, IP or DNS/Domain:

IP  = You don't want to set up TLS
DNS = Setup RustDesk with TLS based on Nginx and free TLS certificates from Let's Encrypt
$MENU_GUIDE

$RUN_LATER_GUIDE" "$WT_HEIGHT" "$WT_WIDTH" 4 \
"IP" "($WANIP4)" \
"DNS" "(e.g. rustdesk.example.com)" 3>&1 1>&2 2>&3)
fi

case "$CHOICE" in
    "DNS")
        if [ -z "$RUSTDESK_DOMAIN" ]; then
            while :
            do
                RUSTDESK_DOMAIN=$(input_box_flow "Please enter your domain, e.g. rustdesk.example.com")
                if ! [[ "$RUSTDESK_DOMAIN" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
                    msg_box "$RUSTDESK_DOMAIN is an invalid domain/DNS address! Please try again."
                    RUSTDESK_DOMAIN=""
                else
                    break
                fi
            done
        elif ! [[ "$RUSTDESK_DOMAIN" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
            die "'$RUSTDESK_DOMAIN' is not a valid domain name."
        fi

        DIG=$(dig +short "${RUSTDESK_DOMAIN}" @8.8.8.8)
        if echo "$DIG" | grep -q "$WANIP4"; then
            success "DNS seems correct when checking with dig!"
        else
            msg_box "DNS lookup failed with dig. The external IP ($WANIP4) \
address of this server is not the same as the A-record ($DIG).
Please check your DNS settings! Maybe the domain hasn't propagated?
Please check https://www.whatsmydns.net/#A/${RUSTDESK_DOMAIN} if the IP seems correct."
            die "DNS validation failed for $RUSTDESK_DOMAIN."
        fi

        info "Installing Nginx and Certbot..."
        install_linux_package nginx
        if [ "$CERTBOT_USE_SNAP" = "true" ]; then
            if install_linux_package snapd; then
                snap install certbot --classic
                CERTBOT_BIN="/snap/bin/certbot"
            else
                warn "snapd wasn't found on your system, using distro Certbot package instead."
                install_linux_package python3-certbot-nginx || install_linux_package certbot
                CERTBOT_BIN="certbot"
            fi
        else
            install_linux_package python3-certbot-nginx || install_linux_package certbot
            CERTBOT_BIN="certbot"
        fi

        if [ -d "/etc/nginx/sites-available" ] && [ -d "/etc/nginx/sites-enabled" ]; then
            SITES_CONF_DIR="sites-available"
        elif [ -d "/etc/nginx/conf.d" ]; then
            SITES_CONF_DIR="conf.d"
        else
            die "Couldn't find the Nginx config directory. Please check your system!"
        fi

        NGINX_CONF="/etc/nginx/$SITES_CONF_DIR/rustdesk.conf"
        if [ ! -f "$NGINX_CONF" ]; then
            cat > "$NGINX_CONF" <<NGINX_RUSTDESK_CONF
server {
  server_name ${RUSTDESK_DOMAIN};
  location / {
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:21114/;
  }

  # hbbs's own websocket ports (21118 id, 21119 relay - its base port
  # +2/+3), reached via a fixed path instead of forwarding whatever port
  # the browser asked for. This is what the webclient (both the legacy
  # bundle and rustdesk-api-web's from-source rebuild) actually connects
  # to for a domain-name server: hbbs speaks plain ws:// and has no TLS
  # of its own, so a page loaded over https (which requires wss://, a
  # plain ws:// socket throws SecurityError) has nowhere else to
  # terminate TLS except here, alongside the domain's own cert.
  location /ws/id {
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass http://127.0.0.1:21118/;
  }
  location /ws/relay {
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass http://127.0.0.1:21119/;
  }
}
NGINX_RUSTDESK_CONF
        fi

        if [ "$SITES_CONF_DIR" = "sites-available" ] && [ ! -f /etc/nginx/sites-enabled/rustdesk.conf ]; then
            ln -s /etc/nginx/sites-available/rustdesk.conf /etc/nginx/sites-enabled/rustdesk.conf
        fi

        fw_allow tcp 80
        fw_allow tcp 443
        fw_enable

        systemctl reload nginx 2>/dev/null || systemctl restart nginx

        if ! "$CERTBOT_BIN" --nginx --cert-name "${RUSTDESK_DOMAIN}" --key-type ecdsa --renew-by-default --no-eff-email --agree-tos --server https://acme-v02.api.letsencrypt.org/directory -d "${RUSTDESK_DOMAIN}"; then
            die "Sorry, the TLS certificate for $RUSTDESK_DOMAIN failed to generate. Please check that ports 80/443 are correctly forwarded and that the DNS record points to this server's IP, then try again."
        fi

        API_SERVER_URL="https://${RUSTDESK_DOMAIN}"
        ;;
    "IP"|*)
        fw_allow tcp 21114
        fw_enable
        API_SERVER_URL="http://${WANIP4}:21114"
        ;;
esac

##################################################################################################################
# rustdesk-api + rustdesk-api-web (built from source)
##################################################################################################################

ADMIN_PASSWORD_LINE=""

if [ "$SKIP_API" = "true" ]; then
    info "--skip-api set: leaving hbbs/hbbr as a headless install with no admin console."
else
    ensure_go 23
    ensure_node 18

    API_WORKDIR=$(mktemp -d)
    trap 'rm -rf "$API_WORKDIR"' EXIT

    API_SHA=$(gh_branch_sha "$API_OWNER" "$API_REPO" "$API_BRANCH") || die "Could not resolve ${API_OWNER}/${API_REPO}@${API_BRANCH}."
    WEB_SHA=$(gh_branch_sha "$WEB_OWNER" "$WEB_REPO" "$WEB_BRANCH") || die "Could not resolve ${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH}."

    if [ ! -d "$RUSTDESK_API_INSTALL_DIR" ] || [ "$(read_installed_version api)" != "$API_SHA" ] || [ "$(read_installed_version web)" != "$WEB_SHA" ]; then
        success "Building rustdesk-api (${API_OWNER}/${API_REPO}@${API_BRANCH})..."
        fetch_source_tarball "$API_OWNER" "$API_REPO" "$API_BRANCH" "$API_WORKDIR/rustdesk-api" \
            || die "Could not fetch rustdesk-api source from ${API_OWNER}/${API_REPO}@${API_BRANCH}."

        (
            cd "$API_WORKDIR/rustdesk-api" || exit 1
            mkdir -p release
            # go.sum as checked into the repo can be incomplete for a
            # fresh module cache; `go mod tidy` fills in any gaps before
            # the real build so it doesn't fail on missing sum entries.
            go mod tidy
            CGO_ENABLED=1 go build -o release/apimain ./cmd/apimain.go
        ) || die "Building rustdesk-api failed."

        success "Building rustdesk-api-web (${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH})..."
        fetch_source_tarball "$WEB_OWNER" "$WEB_REPO" "$WEB_BRANCH" "$API_WORKDIR/rustdesk-api-web" \
            || die "Could not fetch rustdesk-api-web source from ${WEB_OWNER}/${WEB_REPO}@${WEB_BRANCH}."

        (
            cd "$API_WORKDIR/rustdesk-api-web" || exit 1
            npm install
            generate_webclient_protobuf "$API_WORKDIR/rustdesk-api-web"
            npm run build
        ) || die "Building rustdesk-api-web failed."

        # Assemble the release layout rustdesk-api's own build.sh produces:
        # the full resources/ tree (i18n, templates, web, public, version)
        # from source first -- InitI18n() etc. panic without it -- then the
        # built admin frontend is overlaid into resources/admin.
        cp -ar "$API_WORKDIR/rustdesk-api/resources" "$API_WORKDIR/rustdesk-api/release/resources"
        mkdir -p "$API_WORKDIR/rustdesk-api/release/resources/admin"
        cp -ar "$API_WORKDIR/rustdesk-api-web/dist/." "$API_WORKDIR/rustdesk-api/release/resources/admin/"
        cp -ar "$API_WORKDIR/rustdesk-api/docs" "$API_WORKDIR/rustdesk-api/release/" 2>/dev/null || true
        mkdir -p "$API_WORKDIR/rustdesk-api/release/conf" "$API_WORKDIR/rustdesk-api/release/data" "$API_WORKDIR/rustdesk-api/release/runtime"
        cp -n "$API_WORKDIR/rustdesk-api/conf/config.yaml" "$API_WORKDIR/rustdesk-api/release/conf/config.yaml" 2>/dev/null || true

        # Install into place, preserving any existing conf/data across rebuilds.
        mkdir -p "$RUSTDESK_API_INSTALL_DIR"
        for d in resources conf data runtime; do
            if [ -d "$RUSTDESK_API_INSTALL_DIR/$d" ] && [ "$d" != "resources" ]; then
                continue # keep existing conf/data/runtime; only resources (built assets) is always refreshed
            fi
            rm -rf "${RUSTDESK_API_INSTALL_DIR:?}/$d"
            cp -ar "$API_WORKDIR/rustdesk-api/release/$d" "$RUSTDESK_API_INSTALL_DIR/$d"
        done
        mv "$API_WORKDIR/rustdesk-api/release/apimain" /usr/bin/rustdesk-api
        chmod +x /usr/bin/rustdesk-api

        # Configure conf/config.yaml for this install. In domain/TLS mode,
        # the webclient (both the legacy bundle and rustdesk-api-web's
        # rebuild) resolves a bare domain to a fixed /ws/id or /ws/relay
        # path with no port at all - see the /ws/id and /ws/relay nginx
        # locations set up above - so id-server/relay-server need to be
        # the domain itself, not WANIP4:port (which the desktop/mobile
        # clients still connect to directly, unaffected by this - they
        # don't go through nginx or nginx's websocket proxy at all).
        ID_SERVER_VALUE="${WANIP4}:21116"
        RELAY_SERVER_VALUE="${WANIP4}:21117"
        if [ -n "$RUSTDESK_DOMAIN" ]; then
            ID_SERVER_VALUE="$RUSTDESK_DOMAIN"
            RELAY_SERVER_VALUE="$RUSTDESK_DOMAIN"
        fi
        CONFIG_FILE="$RUSTDESK_API_INSTALL_DIR/conf/config.yaml"
        sed -i \
            -e "s#^\(lang:\s*\).*#\1\"en\"#" \
            -e "s#^\(\s*id-server:\s*\).*#\1\"${ID_SERVER_VALUE}\"#" \
            -e "s#^\(\s*relay-server:\s*\).*#\1\"${RELAY_SERVER_VALUE}\"#" \
            -e "s#^\(\s*api-server:\s*\).*#\1\"${API_SERVER_URL}\"#" \
            -e "s#^\(\s*key-file:\s*\).*#\1\"${RUSTDESK_INSTALL_DIR}/id_ed25519.pub\"#" \
            "$CONFIG_FILE"

        if [ -n "$RUSTDESK_USER" ]; then
            chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_API_INSTALL_DIR" /usr/bin/rustdesk-api
        fi

        write_installed_version api "$API_SHA"
        write_installed_version web "$WEB_SHA"
    else
        success "rustdesk-api/rustdesk-api-web already built and up to date."
    fi

    rm -rf "$API_WORKDIR"
    trap - EXIT

    if [ ! -d "$RUSTDESK_API_LOG_DIR" ]; then
        install -d -m 700 "$RUSTDESK_API_LOG_DIR"
        [ -n "$RUSTDESK_USER" ] && chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_API_LOG_DIR"
    fi

    [ -f /etc/systemd/system/rustdesk-api.service ] || write_service_unit api /usr/bin/rustdesk-api "$RUSTDESK_API_INSTALL_DIR" "$RUSTDESK_API_LOG_DIR"
    systemctl daemon-reload
    enable_and_start_service rustdesk-api.service

    if ! wait_for_service_active rustdesk-api.service 60; then
        die "rustdesk-api.service failed to become active. Check: journalctl -u rustdesk-api.service"
    fi

    # The randomly-generated admin password is only ever printed once,
    # to this log, on the very first migration/startup.
    sleep 2
    ADMIN_PASSWORD_LINE=$(grep -h "Admin Password Is:" "$RUSTDESK_API_LOG_DIR"/*.log 2>/dev/null | tail -n1)
fi

##################################################################################################################
# Final output
##################################################################################################################

FINAL_MSG="Installation complete!

Your Public Key is:
$PUBLICKEY
"

if [ "$SKIP_API" = "true" ]; then
    FINAL_MSG+="
No admin console was installed (--skip-api). Point your RustDesk clients
directly at this server's ID/relay server and the public key above."
elif [ "$CHOICE" = "DNS" ]; then
    FINAL_MSG+="
Admin console: https://$RUSTDESK_DOMAIN
"
else
    FINAL_MSG+="
Admin console: http://$WANIP4:21114
"
fi

if [ -n "$ADMIN_PASSWORD_LINE" ]; then
    FINAL_MSG+="
$ADMIN_PASSWORD_LINE
(This is shown once. Log in as 'admin' and change it immediately.)"
elif [ "$SKIP_API" != "true" ]; then
    FINAL_MSG+="
(Admin was already initialized in a previous run; its password is not
re-printed. Use the CLI to reset it: rustdesk-api reset-admin-pwd <pwd>,
run from $RUSTDESK_API_INSTALL_DIR.)"
fi

msg_box "$FINAL_MSG"
success "RustDesk Server installation finished."
