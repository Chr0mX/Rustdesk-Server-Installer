#!/bin/bash
#
# install.sh - RustDesk Server installer (community fork)
#
# Installs hbbs (rendezvous/signal server) and hbbr (relay server) using
# release assets published on this fork's own GitHub repository -
# there is no dependency on github.com/rustdesk or rustdesk.com.
#
# What this script does:
#   1. Detects CPU architecture and Linux distribution
#   2. Installs required dependencies via the distro's package manager
#   3. Resolves the latest release from the GitHub Releases API
#      (falls back to repo-root files if no release exists)
#   4. Downloads, verifies and installs hbbs/hbbr/rustdesk-utils
#   5. Creates systemd services for hbbs and hbbr
#   6. Optionally sets up Nginx + Certbot for a TLS-terminated domain
#   7. Supports a fully non-interactive mode for scripted deployments
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   -y, --non-interactive     Never prompt; use flags/env vars for input
#       --user <name>         Run hbbs/hbbr as this unprivileged user
#       --domain <fqdn>       Use a domain + Let's Encrypt TLS via Nginx
#       --ip                  Use IP-only mode (no domain/TLS)
#       --owner <owner>       Override the GitHub repo owner for assets
#       --repo <repo>         Override the GitHub repo name for assets
#       --branch <branch>     Override the branch used for repo-root fallback
#       --no-certbot-snap     Use distro packages for Certbot instead of snap
#   -h, --help                Show this help and exit
#
# All options can also be provided via environment variables:
#   NONINTERACTIVE, RUSTDESK_USER, RUSTDESK_DOMAIN, GITHUB_OWNER,
#   GITHUB_REPO, GITHUB_BRANCH, CERTBOT_USE_SNAP

set -uo pipefail

##################################################################################################################
# Argument parsing (done before sourcing lib.sh; only sets env vars)
##################################################################################################################

RUSTDESK_DOMAIN="${RUSTDESK_DOMAIN:-}"
RUSTDESK_USER="${RUSTDESK_USER:-}"
FORCE_IP_MODE="false"
CERTBOT_USE_SNAP="${CERTBOT_USE_SNAP:-true}"

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,30p'
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
export RUSTDESK_USER RUSTDESK_DOMAIN GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH CERTBOT_USE_SNAP

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
    detect_arch
    detect_pkg_manager
    detect_firewall
    info "OS: $OS / VER: $VER / UPSTREAM_ID: $UPSTREAM_ID"
    info "ARCH: $ARCH / ARCH_ALIAS: $ARCH_ALIAS"
    info "PKG_MANAGER: $PKG_MANAGER / FIREWALL: $FIREWALL"
    info "GitHub source: ${GITHUB_OWNER}/${GITHUB_REPO}@${GITHUB_BRANCH}"
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
# Select the user hbbs/hbbr will run as
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

run_as_rustdesk_user() {
    if [ -n "$RUSTDESK_USER" ]; then
        sudo -u "$RUSTDESK_USER" "$@"
    else
        "$@"
    fi
}

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

##################################################################################################################
# Firewall: open the ports hbbs/hbbr need
##################################################################################################################

fw_allow tcp 21115-21119
fw_allow udp 21116

##################################################################################################################
# Resolve latest release and download assets
##################################################################################################################

if gh_fetch_latest_release; then
    RELEASE_TAG=$(gh_release_tag)
    info "Latest release on ${GITHUB_OWNER}/${GITHUB_REPO}: $RELEASE_TAG"
else
    RELEASE_TAG=""
    warn "No GitHub release found for ${GITHUB_OWNER}/${GITHUB_REPO}; falling back to repository-root assets on branch '${GITHUB_BRANCH}'."
fi

ASSET_NAME="rustdesk-server-linux-${ARCH_ALIAS}.tar.gz"

if [ ! -d "$RUSTDESK_INSTALL_DIR" ]; then
    success "Installing RustDesk Server..."
    mkdir -p "$RUSTDESK_INSTALL_DIR"
    [ -d "$RUSTDESK_INSTALL_DIR" ] || die "The installation folder $RUSTDESK_INSTALL_DIR could not be created."

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    if ! fetch_and_verify "$ASSET_NAME" "$WORKDIR/$ASSET_NAME"; then
        die "Sorry, the installation package ($ASSET_NAME) failed to download or verify. Please try running the installer again."
    fi

    tar -xf "$WORKDIR/$ASSET_NAME" -C "$WORKDIR"
    EXTRACTED_DIR="$WORKDIR/${ARCH_ALIAS}"
    [ -d "$EXTRACTED_DIR" ] || die "Unexpected archive layout: expected directory '${ARCH_ALIAS}' inside $ASSET_NAME."

    mv "$EXTRACTED_DIR/static" "$RUSTDESK_INSTALL_DIR"/
    mv "$EXTRACTED_DIR/hbbr" /usr/bin/
    mv "$EXTRACTED_DIR/hbbs" /usr/bin/
    mv "$EXTRACTED_DIR/rustdesk-utils" /usr/bin/
    chmod +x /usr/bin/hbbr /usr/bin/hbbs /usr/bin/rustdesk-utils

    if [ -n "$RUSTDESK_USER" ]; then
        chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_INSTALL_DIR"
        chown "$RUSTDESK_USER":"$RUSTDESK_USER" /usr/bin/hbbr /usr/bin/hbbs /usr/bin/rustdesk-utils
    fi

    [ -n "$RELEASE_TAG" ] && write_installed_version "$RELEASE_TAG"

    rm -rf "$WORKDIR"
    trap - EXIT
else
    success "RustDesk server already installed in $RUSTDESK_INSTALL_DIR."
fi

##################################################################################################################
# Log directory
##################################################################################################################

if [ ! -d "$RUSTDESK_LOG_DIR" ]; then
    info "Creating $RUSTDESK_LOG_DIR"
    install -d -m 700 "$RUSTDESK_LOG_DIR"
    [ -n "$RUSTDESK_USER" ] && chown -R "$RUSTDESK_USER":"$RUSTDESK_USER" "$RUSTDESK_LOG_DIR"
fi

##################################################################################################################
# systemd services
##################################################################################################################

SERVICE_USER="${RUSTDESK_USER:-root}"

write_service_unit() {
    local name="$1"
    local bin="$2"
    local unit_path="/etc/systemd/system/rustdesk-${name}.service"
    cat > "$unit_path" <<UNIT
[Unit]
Description=RustDesk ${name} service
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${bin}
WorkingDirectory=${RUSTDESK_INSTALL_DIR}
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=always
RestartSec=10
StandardOutput=append:${RUSTDESK_LOG_DIR}/${name}.log
StandardError=append:${RUSTDESK_LOG_DIR}/${name}.error

[Install]
WantedBy=multi-user.target
UNIT
}

[ -f /etc/systemd/system/rustdesk-hbbs.service ] || write_service_unit hbbs /usr/bin/hbbs
[ -f /etc/systemd/system/rustdesk-hbbr.service ] || write_service_unit hbbr /usr/bin/hbbr

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
# IP vs Domain (TLS) setup
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
        ;;
    "IP"|*)
        fw_allow tcp 21114
        fw_enable
        ;;
esac

##################################################################################################################
# Final output
##################################################################################################################

if [ -n "$RUSTDESK_DOMAIN" ] && [ "$CHOICE" = "DNS" ]; then
    msg_box "Installation complete!

Your Public Key is:
$PUBLICKEY

Your DNS Address is:
$RUSTDESK_DOMAIN

Please login at https://$RUSTDESK_DOMAIN
Default User/Pass: admin/test1234
(change this immediately after first login)"
else
    msg_box "Installation complete!

Your Public Key is:
$PUBLICKEY

Your IP Address is:
$WANIP4

Please login at http://$WANIP4:21114
Default User/Pass: admin/test1234
(change this immediately after first login)"
fi

success "RustDesk Server installation finished."
