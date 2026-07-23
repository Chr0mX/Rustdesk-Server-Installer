#!/bin/bash
#
# uninstall.sh - Removes a RustDesk Server installation
#
# Usage:
#   ./uninstall.sh [options]
#
# Options:
#   -y, --non-interactive     Never prompt; use flags below to decide scope
#       --purge               Also remove config/keys, logs, Nginx site
#                             config and the Let's Encrypt certificate
#                             (everything RustDesk-specific, but not
#                             shared system packages such as nginx/ufw)
#       --remove-dependencies Additionally remove shared packages this
#                             installer added (nginx, certbot, ufw,
#                             dnsutils, whiptail, curl). Off by default,
#                             even with --purge, since other software on
#                             the host may depend on them.
#   -h, --help                Show this help and exit
#
# Without --non-interactive, an interactive checklist is shown so you
# can pick exactly what to remove, matching the previous behavior.

set -uo pipefail

PURGE="false"
REMOVE_DEPENDENCIES="false"

print_usage() {
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed -n '2,20p'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--non-interactive)
            NONINTERACTIVE="true"
            ;;
        --purge)
            PURGE="true"
            ;;
        --remove-dependencies)
            REMOVE_DEPENDENCIES="true"
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

##################################################################################################################
# Bootstrap lib.sh from this fork's own repository
##################################################################################################################

if [ ! -x "$(command -v curl)" ] || { [ "$NONINTERACTIVE" != "true" ] && [ ! -x "$(command -v whiptail)" ]; }; then
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

SCRIPT_NAME="Uninstall script"
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
detect_pkg_manager
detect_firewall

if [ "${DEBUG:-false}" = "true" ]; then
    identify_os
    info "OS: $OS / VER: $VER / UPSTREAM_ID: $UPSTREAM_ID"
    exit 0
fi

##################################################################################################################
# Decide what to remove
##################################################################################################################

REMOVE_RUSTDESK_SERVER="yes"
REMOVE_RUSTDESK_LOG="no"
REMOVE_NGINX_CONF="no"
REMOVE_NGINX_PKG="no"
REMOVE_CERTBOT="no"
REMOVE_FIREWALL_RULES="yes"
REMOVE_CURL="no"
REMOVE_WHIPTAIL="no"
REMOVE_DNSUTILS="no"
REMOVE_UFW="no"

if [ "$PURGE" = "true" ]; then
    REMOVE_RUSTDESK_LOG="yes"
    REMOVE_NGINX_CONF="yes"
    REMOVE_CERTBOT="yes"
fi

if [ "$REMOVE_DEPENDENCIES" = "true" ]; then
    REMOVE_NGINX_PKG="yes"
    REMOVE_CURL="yes"
    REMOVE_WHIPTAIL="yes"
    REMOVE_DNSUTILS="yes"
    REMOVE_UFW="yes"
fi

if [ "$NONINTERACTIVE" != "true" ]; then
    CERTBOT_SWITCH="OFF"
    [ -d /etc/letsencrypt ] && CERTBOT_SWITCH="ON"

    if ! CHOICE=$(whiptail --title "$TITLE" --checklist \
"Please choose what to uninstall:

$CHECKLIST_GUIDE

$RUN_LATER_GUIDE" "$WT_HEIGHT" "$WT_WIDTH" 10 \
"rustdesk-server" "(RustDesk SERVER + RustDesk services)" ON \
"rustdesk-logs" "(RustDesk LOG dir)" OFF \
"firewall-rules" "(RustDesk firewall rules)" ON \
"nginx-rustdesk" "(RustDesk Nginx site config)" OFF \
"certbot" "(Let's Encrypt cert + Certbot)" "$CERTBOT_SWITCH" \
"nginx" "(Nginx package + ALL configs - shared by other sites!)" OFF \
"ufw" "(Firewall package itself - not just RustDesk rules)" OFF \
"whiptail" "(Menu package)" OFF \
"curl" "(System package)" OFF \
"dnsutils" "(System package)" OFF 3>&1 1>&2 2>&3); then
        exit 0
    fi

    REMOVE_RUSTDESK_SERVER="no"; REMOVE_RUSTDESK_LOG="no"; REMOVE_FIREWALL_RULES="no"
    REMOVE_NGINX_CONF="no"; REMOVE_CERTBOT="no"; REMOVE_NGINX_PKG="no"
    REMOVE_UFW="no"; REMOVE_WHIPTAIL="no"; REMOVE_CURL="no"; REMOVE_DNSUTILS="no"

    case "$CHOICE" in *"rustdesk-server"*) REMOVE_RUSTDESK_SERVER="yes" ;;& esac
    case "$CHOICE" in *"rustdesk-logs"*) REMOVE_RUSTDESK_LOG="yes" ;;& esac
    case "$CHOICE" in *"firewall-rules"*) REMOVE_FIREWALL_RULES="yes" ;;& esac
    case "$CHOICE" in *"nginx-rustdesk"*) REMOVE_NGINX_CONF="yes" ;;& esac
    case "$CHOICE" in *"certbot"*) REMOVE_CERTBOT="yes" ;;& esac
    case "$CHOICE" in *"nginx"*) REMOVE_NGINX_PKG="yes" ;;& esac
    case "$CHOICE" in *"ufw"*) REMOVE_UFW="yes" ;;& esac
    case "$CHOICE" in *"whiptail"*) REMOVE_WHIPTAIL="yes" ;;& esac
    case "$CHOICE" in *"curl"*) REMOVE_CURL="yes" ;;& esac
    case "$CHOICE" in *"dnsutils"*) REMOVE_DNSUTILS="yes" ;;& esac

    msg_box "WARNING WARNING WARNING

This script will remove EVERYTHING that was chosen in the previous selection.
You can choose to opt out after you hit OK."

    if ! yesno_box_no "Are you REALLY sure you want to continue with the uninstallation?"; then
        exit 0
    fi
fi

##################################################################################################################
# Firewall rules
##################################################################################################################

if [ "$REMOVE_FIREWALL_RULES" = "yes" ]; then
    info "Removing RustDesk firewall rules..."
    fw_delete tcp 21115-21119
    fw_delete udp 21116
    if [ -f "/etc/nginx/sites-available/rustdesk.conf" ] || [ -f "/etc/nginx/conf.d/rustdesk.conf" ]; then
        fw_delete tcp 80
        fw_delete tcp 443
    else
        fw_delete tcp 21114
    fi
    fw_disable
fi

##################################################################################################################
# RustDesk server + services
##################################################################################################################

if [ "$REMOVE_RUSTDESK_SERVER" = "yes" ]; then
    info "Removing RustDesk Server..."
    stop_and_disable_service rustdesk-hbbs.service
    stop_and_disable_service rustdesk-hbbr.service
    rm -f /etc/systemd/system/rustdesk-hbbs.service /etc/systemd/system/rustdesk-hbbr.service
    systemctl daemon-reload

    rm -f /usr/bin/hbbs /usr/bin/hbbr /usr/bin/rustdesk-utils

    if [ "$PURGE" = "true" ]; then
        rm -rf "$RUSTDESK_INSTALL_DIR"
    else
        # Keep configuration/keys (id_*, db files) so a future install.sh
        # run can pick the same install back up. Only remove the static
        # web assets, which are re-downloaded on every install anyway.
        rm -rf "${RUSTDESK_INSTALL_DIR:?}/static"
        [ -d "$RUSTDESK_INSTALL_DIR" ] && info "Configuration and keys kept in $RUSTDESK_INSTALL_DIR (use --purge to remove them)."
    fi
fi

##################################################################################################################
# Logs
##################################################################################################################

if [ "$REMOVE_RUSTDESK_LOG" = "yes" ]; then
    rm -rf "$RUSTDESK_LOG_DIR"
fi

##################################################################################################################
# Certbot / TLS certs
##################################################################################################################

if [ "$REMOVE_CERTBOT" = "yes" ]; then
    if command -v snap &>/dev/null && snap list 2>/dev/null | grep -q certbot; then
        snap remove certbot
    else
        purge_linux_package python3-certbot-nginx
    fi
    rm -rf /etc/letsencrypt
fi

##################################################################################################################
# Nginx
##################################################################################################################

if [ "$REMOVE_NGINX_CONF" = "yes" ]; then
    rm -f /etc/nginx/sites-available/rustdesk.conf /etc/nginx/sites-enabled/rustdesk.conf /etc/nginx/conf.d/rustdesk.conf
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
fi

if [ "$REMOVE_NGINX_PKG" = "yes" ]; then
    purge_linux_package nginx
    rm -rf /etc/nginx
fi

##################################################################################################################
# Shared system packages (opt-in only)
##################################################################################################################

[ "$REMOVE_CURL" = "yes" ] && purge_linux_package curl
[ "$REMOVE_DNSUTILS" = "yes" ] && { purge_linux_package dnsutils || purge_linux_package bind-utils; }
[ "$REMOVE_UFW" = "yes" ] && purge_linux_package ufw

if [ "$REMOVE_WHIPTAIL" = "yes" ]; then
    msg_box "Uninstallation complete!

Please hit OK to remove the last package (whiptail)."
    purge_linux_package whiptail
else
    success "Uninstallation complete!"
fi
