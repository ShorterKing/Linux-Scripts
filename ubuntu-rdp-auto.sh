#!/usr/bin/env bash
#
# setup-rdp.sh — XRDP + XFCE remote desktop installer for Ubuntu / Debian
#
#   Idempotent, verifiable, and reversible. Handles the usual XRDP papercuts:
#   polkit authentication popups, the ssl-cert group, locked user passwords,
#   Xwrapper permissions, and session/locale environment.
#
#   Usage:  sudo ./setup-rdp.sh [options]
#           sudo ./setup-rdp.sh --help
#
# ---------------------------------------------------------------------------

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly SCRIPT_VERSION="2.0"
readonly MARKER="# managed-by: setup-rdp.sh (do not edit by hand)"
readonly STAMP=$(date +%Y%m%d-%H%M%S)

readonly STARTWM=/etc/xrdp/startwm.sh
readonly XRDP_INI=/etc/xrdp/xrdp.ini
readonly SESMAN_INI=/etc/xrdp/sesman.ini
readonly XWRAPPER=/etc/X11/Xwrapper.config
readonly POLKIT_RULES=/etc/polkit-1/rules.d/49-xrdp-desktop.rules
readonly POLKIT_PKLA=/etc/polkit-1/localauthority/50-local.d/45-xrdp-desktop.pkla
readonly F2B_FILTER=/etc/fail2ban/filter.d/xrdp-sesman.conf
readonly F2B_JAIL=/etc/fail2ban/jail.d/xrdp.conf

# ----- defaults -------------------------------------------------------------
TARGET_USER=""
RDP_PORT=3389
BIND_ADDR=""            # empty => xrdp default (all interfaces)
ALLOW_FROM=""           # empty => open to everyone (with a loud warning)
DO_FIREWALL=1
DO_GOODIES=1
DO_SOUND=0
DO_FAIL2BAN=0
DO_UNINSTALL=0
PURGE_DESKTOP=0
DRY_RUN=0
ASSUME_YES=0
USE_COLOR=1
LOG_FILE=""
WARNINGS=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ $USE_COLOR -eq 1 && -t 1 && -z ${NO_COLOR:-} ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
        C_RED=$'\033[31m';  C_GRN=$'\033[32m';  C_YEL=$'\033[33m'
        C_BLU=$'\033[34m';  C_CYN=$'\033[36m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED="";   C_GRN="";  C_YEL=""; C_BLU=""; C_CYN=""
    fi
}

banner()  { printf '\n%s%s%s\n%s %s %s\n%s%s%s\n\n' \
            "$C_BOLD$C_BLU" "════════════════════════════════════════════════" "$C_RESET" \
            "$C_BOLD" "$*" "$C_RESET" \
            "$C_BOLD$C_BLU" "════════════════════════════════════════════════" "$C_RESET"; }
step()    { printf '\n%s▸ %s%s\n' "$C_BOLD$C_CYN" "$*" "$C_RESET"; }
info()    { printf '  %s•%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
skip()    { printf '  %s◦ %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()    { printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_RESET"; WARNINGS+=("$*"); }
err()     { printf '  %s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()     { err "$*"; exit 1; }

on_error() {
    local line=$1
    err "Failed at line ${line}. Nothing further was changed."
    [[ -n $LOG_FILE ]] && err "Full log: ${LOG_FILE}"
    err "Re-run with --dry-run to preview, or check: journalctl -u xrdp -n 50"
}
trap 'on_error $LINENO' ERR

# Run a command, honouring --dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

confirm() {
    [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
    local reply
    read -r -p "  ${C_BOLD}$1 [y/N]${C_RESET} " reply </dev/tty || return 1
    [[ $reply =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
cat <<EOF_HELP
${SCRIPT_NAME} v${SCRIPT_VERSION} — XRDP + XFCE setup for Ubuntu / Debian

USAGE
  sudo ./${SCRIPT_NAME} [options]

OPTIONS
  -u, --user USER        Account that will log in over RDP
                         (default: \$SUDO_USER, i.e. whoever ran sudo)
  -p, --port PORT        TCP port for XRDP                  (default: 3389)
  -b, --bind ADDRESS     Bind XRDP to one address only. Use 127.0.0.1 to
                         force access through an SSH tunnel  (default: all)
  -a, --allow-from CIDR  Firewall: allow only this source, e.g. 192.168.1.0/24
      --no-firewall      Do not touch ufw at all
      --no-goodies       Skip xfce4-goodies (leaner install)
      --sound            Also try to enable audio redirection
      --fail2ban         Install a fail2ban jail for RDP brute-force attempts
      --uninstall        Revert everything this script configured
      --purge-desktop    With --uninstall, also remove XFCE
  -n, --dry-run          Print what would happen; change nothing
  -y, --yes              Assume "yes" for all prompts
      --no-color         Plain output
  -h, --help             Show this help
  -V, --version          Show version

EXAMPLES
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --user alice --allow-from 192.168.1.0/24
  sudo ./${SCRIPT_NAME} --bind 127.0.0.1 --no-firewall   # SSH-tunnel only
  sudo ./${SCRIPT_NAME} --uninstall
EOF_HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)        TARGET_USER=${2:?--user needs a value}; shift 2 ;;
            -p|--port)        RDP_PORT=${2:?--port needs a value};     shift 2 ;;
            -b|--bind)        BIND_ADDR=${2:?--bind needs a value};    shift 2 ;;
            -a|--allow-from)  ALLOW_FROM=${2:?--allow-from needs a value}; shift 2 ;;
            --no-firewall)    DO_FIREWALL=0;   shift ;;
            --no-goodies)     DO_GOODIES=0;    shift ;;
            --sound)          DO_SOUND=1;      shift ;;
            --fail2ban)       DO_FAIL2BAN=1;   shift ;;
            --uninstall)      DO_UNINSTALL=1;  shift ;;
            --purge-desktop)  PURGE_DESKTOP=1; shift ;;
            -n|--dry-run)     DRY_RUN=1;       shift ;;
            -y|--yes)         ASSUME_YES=1;    shift ;;
            --no-color)       USE_COLOR=0;     shift ;;
            -h|--help)        setup_colors; usage; exit 0 ;;
            -V|--version)     echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            *) setup_colors; usage >&2; echo; die "Unknown option: $1" ;;
        esac
    done

    [[ $RDP_PORT =~ ^[0-9]+$ ]] && (( RDP_PORT > 0 && RDP_PORT < 65536 )) \
        || die "Invalid port: ${RDP_PORT}"

    [[ $PURGE_DESKTOP -eq 1 && $DO_UNINSTALL -eq 0 ]] \
        && die "--purge-desktop only makes sense together with --uninstall."

    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    [[ $EUID -eq 0 ]] || die "Please run with sudo:  sudo ./${SCRIPT_NAME}"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        info "Detected: ${PRETTY_NAME:-unknown}"
        [[ ${ID:-} == debian || ${ID:-} == ubuntu || ${ID_LIKE:-} == *debian* ]] \
            || die "This script targets Debian/Ubuntu (apt). Found: ${ID:-unknown}"
    else
        warn "/etc/os-release missing — assuming Debian-family."
    fi

    command -v apt-get >/dev/null || die "apt-get not found."
    command -v systemctl >/dev/null || die "systemd not found; this script needs systemctl."

    if ! systemctl is-system-running --quiet 2>/dev/null; then
        local state; state=$(systemctl is-system-running 2>/dev/null || true)
        [[ $state == degraded || $state == starting ]] \
            && warn "systemd reports '${state}'; continuing anyway." \
            || die "systemd is not managing this system (state: ${state:-none}). \
On WSL, enable systemd in /etc/wsl.conf first."
    fi

    if grep -qi microsoft /proc/version 2>/dev/null; then
        warn "WSL detected. XRDP works, but connect to the WSL IP, not localhost, \
unless you set up port forwarding."
    fi
}

resolve_user() {
    if [[ -z $TARGET_USER ]]; then
        TARGET_USER=${SUDO_USER:-}
    fi
    if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
        TARGET_USER=$(logname 2>/dev/null || true)
    fi
    [[ -n $TARGET_USER ]] || die "Could not determine the RDP user. Pass --user USERNAME."
    id "$TARGET_USER" >/dev/null 2>&1 || die "No such user: ${TARGET_USER}"

    local uid; uid=$(id -u "$TARGET_USER")
    (( uid >= 1000 )) || warn "'${TARGET_USER}' is a system account (uid ${uid}); that is unusual for a desktop login."

    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    [[ -d $USER_HOME ]] || warn "Home directory ${USER_HOME} does not exist."
    info "RDP user: ${C_BOLD}${TARGET_USER}${C_RESET} (home: ${USER_HOME})"
}

# Locked / passwordless accounts silently fail at the XRDP login screen.
check_password() {
    local status
    status=$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}' || echo "?")
    case $status in
        P) info "Password is set for '${TARGET_USER}'." ;;
        L|NP|"")
            warn "Account '${TARGET_USER}' has no usable password — RDP login WILL fail."
            if confirm "Set a password for '${TARGET_USER}' now?"; then
                run passwd "$TARGET_USER"
            else
                warn "Remember to run:  sudo passwd ${TARGET_USER}"
            fi
            ;;
        *) warn "Could not determine password status for '${TARGET_USER}'." ;;
    esac
}

check_local_session() {
    command -v loginctl >/dev/null || return 0
    if loginctl list-sessions --no-legend 2>/dev/null \
       | awk -v u="$TARGET_USER" '$3 == u {print}' | grep -q 'seat'; then
        warn "'${TARGET_USER}' appears to have an active local desktop session. \
XFCE cannot run twice for one user — log out locally before connecting."
    fi
}

check_port_free() {
    command -v ss >/dev/null || return 0
    local holder
    holder=$(ss -lntpH "sport = :${RDP_PORT}" 2>/dev/null | grep -v xrdp || true)
    [[ -n $holder ]] && warn "Something already listens on port ${RDP_PORT}: ${holder}"
    return 0
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
backup_file() {
    local f=$1
    [[ -f $f ]] || return 0
    [[ $DRY_RUN -eq 1 ]] && { skip "would back up ${f}"; return 0; }
    cp -a "$f" "${f}.bak.${STAMP}"
    skip "backup: ${f}.bak.${STAMP}"
}

# Set key=value inside [section] of an INI file, preserving everything else.
ini_set() {
    local file=$1 section=$2 key=$3 value=$4
    if [[ ! -f $file ]]; then
        # In dry-run the packages were never installed, so this is expected.
        [[ $DRY_RUN -eq 1 ]] && skip "would set [${section}] ${key}=${value} in ${file}" \
                             || warn "Missing ${file}; skipped ${section}/${key}"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would set [${section}] ${key}=${value} in ${file}"
        return 0
    fi

    local tmp; tmp=$(mktemp)
    awk -v section="$section" -v key="$key" -v value="$value" '
        function flush(  i) { for (i = 0; i < blanks; i++) print ""; blanks = 0 }
        BEGIN { inside = 0; done = 0; blanks = 0 }

        # Hold blank lines inside the target section so a new key is inserted
        # above them rather than orphaned against the next header.
        { if (inside && $0 ~ /^[[:space:]]*$/) { blanks++; next } }

        /^[[:space:]]*\[/ {
            if (inside && !done) { print key "=" value; done = 1 }
            flush()
            inside = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
            print; next
        }
        {
            if (inside) {
                flush()
                if ($0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
                    if (!done) { print key "=" value; done = 1 }
                    next
                }
            }
            print
        }
        END { if (inside && !done) print key "=" value; flush() }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"      # preserve inode, ownership and mode
    rm -f "$tmp"
}

# A leftover ~/.xsession from an earlier attempt is ignored by our startwm.sh,
# which surprises people who put their session command there.
check_stale_xsession() {
    local f="${USER_HOME}/.xsession"
    [[ -f $f ]] && warn "${f} exists but is NOT used by this setup — \
the desktop comes from ${STARTWM}. Delete it to avoid confusion."
    return 0
}

# ---------------------------------------------------------------------------
# Installation steps
# ---------------------------------------------------------------------------
install_packages() {
    step "Installing packages"

    local pkgs=(xrdp xorgxrdp xfce4 dbus-x11 x11-xserver-utils)
    [[ $DO_GOODIES -eq 1 ]] && pkgs+=(xfce4-goodies)
    [[ $DO_FAIL2BAN -eq 1 ]] && pkgs+=(fail2ban)

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a           # stop the "restart services?" TUI

    info "apt-get update…"
    run apt-get update -qq || warn "apt-get update reported problems; continuing."

    info "Installing: ${pkgs[*]}"
    run apt-get install -y -qq "${pkgs[@]}"

    if [[ $DRY_RUN -eq 0 ]]; then
        command -v xfce4-session >/dev/null || die "xfce4-session missing after install."
        command -v xrdp >/dev/null || die "xrdp missing after install."
    fi
}

configure_startwm() {
    step "Configuring the XRDP session launcher"

    if [[ -f $STARTWM ]] && grep -qF "$MARKER" "$STARTWM"; then
        skip "${STARTWM} already managed by this script — rewriting to current template."
    else
        backup_file "$STARTWM"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would write ${STARTWM} (exec startxfce4)"
        return 0
    fi

    cat > "$STARTWM" <<EOF
#!/bin/sh
${MARKER}
#
# Launched by xrdp-sesman once the X server is up. Must end with 'exec' so the
# session dies cleanly when the desktop exits.

# Locale — without this an XRDP session often falls back to POSIX/C.
if [ -r /etc/default/locale ]; then
    . /etc/default/locale
    export LANG LANGUAGE LC_ALL
fi

if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "\$HOME/.profile" ]; then . "\$HOME/.profile"; fi

# Tell portals, xdg-open and toolkits which desktop this is.
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export DESKTOP_SESSION=xfce

exec startxfce4
EOF

    chmod 0755 "$STARTWM"
    info "Wrote ${STARTWM}"
}

configure_permissions() {
    step "Fixing XRDP permissions"

    # xrdp must read /etc/ssl/private/ssl-cert-snakeoil.key for TLS.
    if getent group ssl-cert >/dev/null; then
        if id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -qx ssl-cert; then
            skip "xrdp already in the ssl-cert group."
        else
            run adduser --quiet xrdp ssl-cert
            info "Added user 'xrdp' to the ssl-cert group (TLS key access)."
        fi
    else
        skip "No ssl-cert group on this system."
    fi

    # Xorg refuses to start for non-console users without this.
    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would ensure allowed_users=anybody in ${XWRAPPER}"
    elif [[ -f $XWRAPPER ]] && grep -q '^allowed_users=anybody' "$XWRAPPER"; then
        skip "${XWRAPPER} already allows any user."
    else
        backup_file "$XWRAPPER"
        if [[ -f $XWRAPPER ]] && grep -q '^allowed_users=' "$XWRAPPER"; then
            sed -i 's/^allowed_users=.*/allowed_users=anybody/' "$XWRAPPER"
        else
            echo 'allowed_users=anybody' >> "$XWRAPPER"
        fi
        info "Set allowed_users=anybody in ${XWRAPPER}"
    fi
}

configure_polkit() {
    step "Suppressing polkit authentication popups"
    # These are the two dialogs that greet every XRDP login on a stock Ubuntu:
    #   "Authentication is required to create a color managed device"
    #   "Authentication is required to refresh the system repositories"

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would install polkit rules for colord + packagekit"
        return 0
    fi

    # polkit >= 106 (Ubuntu 23.10+): JavaScript rules.
    mkdir -p "$(dirname "$POLKIT_RULES")"
    cat > "$POLKIT_RULES" <<'EOF'
// managed-by: setup-rdp.sh
// Colour-manager device registration is harmless; allow it for everyone so
// remote desktop sessions do not prompt on every login.
polkit.addRule(function (action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
        return polkit.Result.YES;
    }
});

// Repository refresh: allow it without a prompt, but only for admins.
polkit.addRule(function (action, subject) {
    if ((action.id == "org.freedesktop.packagekit.system-sources-refresh" ||
         action.id == "org.freedesktop.packagekit.system-network-proxy-configure") &&
        (subject.isInGroup("sudo") || subject.isInGroup("admin"))) {
        return polkit.Result.YES;
    }
});
EOF
    chmod 0644 "$POLKIT_RULES"
    info "Wrote ${POLKIT_RULES}"

    # polkit 0.105 (Ubuntu 22.04 and older): local-authority .pkla.
    if [[ -d ${POLKIT_PKLA%/50-local.d/*} ]]; then
        mkdir -p "$(dirname "$POLKIT_PKLA")"
        cat > "$POLKIT_PKLA" <<'EOF'
# managed-by: setup-rdp.sh
[Allow colord for remote desktop sessions]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=yes
ResultInactive=yes
ResultActive=yes

[Allow package repository refresh for admins]
Identity=unix-group:sudo
Action=org.freedesktop.packagekit.system-sources-refresh
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
        chmod 0644 "$POLKIT_PKLA"
        info "Wrote ${POLKIT_PKLA} (legacy polkit)"
    fi
}

configure_xrdp_ini() {
    step "Tuning xrdp.ini and sesman.ini"

    backup_file "$XRDP_INI"
    backup_file "$SESMAN_INI"

    ini_set "$XRDP_INI" Globals port "$RDP_PORT"
    ini_set "$XRDP_INI" Globals crypt_level high
    ini_set "$XRDP_INI" Globals security_layer negotiate
    ini_set "$XRDP_INI" Globals max_bpp 32
    ini_set "$XRDP_INI" Globals bitmap_compression true
    ini_set "$XRDP_INI" Globals tcp_nodelay true
    ini_set "$XRDP_INI" Globals tcp_keepalive true
    ini_set "$XRDP_INI" Globals new_cursors true
    ini_set "$XRDP_INI" Globals allow_multimon true
    ini_set "$XRDP_INI" Globals autorun Xorg     # skip the session dropdown

    if [[ -n $BIND_ADDR ]]; then
        ini_set "$XRDP_INI" Globals address "$BIND_ADDR"
        info "XRDP will listen on ${BIND_ADDR}:${RDP_PORT} only."
    else
        info "XRDP will listen on 0.0.0.0:${RDP_PORT}."
    fi

    # Keep sessions alive across disconnects so reconnecting resumes your desktop.
    ini_set "$SESMAN_INI" Sessions KillDisconnected false
    ini_set "$SESMAN_INI" Sessions DisconnectedTimeLimit 0
    ini_set "$SESMAN_INI" Sessions IdleTimeLimit 0
    ini_set "$SESMAN_INI" Security AllowRootLogin false

    info "Root RDP login disabled; disconnected sessions are preserved."
}

configure_sound() {
    [[ $DO_SOUND -eq 1 ]] || return 0
    step "Audio redirection"

    local pkg=""
    for candidate in pipewire-module-xrdp xrdp-pulseaudio-installer; do
        if apt-cache policy "$candidate" 2>/dev/null | grep -q 'Candidate: [^(]'; then
            pkg=$candidate; break
        fi
    done

    if [[ -n $pkg ]]; then
        run apt-get install -y -qq "$pkg"
        info "Installed ${pkg}. Enable 'Play on this computer' in your RDP client."
    else
        warn "No prebuilt audio module in your repos. Audio needs a manual build: \
https://github.com/neutrinolabs/pipewire-module-xrdp"
    fi
}

configure_fail2ban() {
    [[ $DO_FAIL2BAN -eq 1 ]] || return 0
    step "Configuring fail2ban for RDP"

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would write ${F2B_FILTER} and ${F2B_JAIL}"
        return 0
    fi

    cat > "$F2B_FILTER" <<'EOF'
# managed-by: setup-rdp.sh
[Definition]
failregex = ^.*AUTHFAIL: user=\S* ip=<HOST>(:\d+)? time=.*$
            ^.*login failed for user .* from <HOST>.*$
ignoreregex =
EOF

    cat > "$F2B_JAIL" <<EOF
# managed-by: setup-rdp.sh
[xrdp-sesman]
enabled  = true
port     = ${RDP_PORT}
protocol = tcp
filter   = xrdp-sesman
logpath  = /var/log/xrdp-sesman.log
maxretry = 5
findtime = 10m
bantime  = 1h
EOF

    run systemctl enable --now fail2ban
    run systemctl restart fail2ban
    info "fail2ban jail 'xrdp-sesman' active (5 failures = 1 hour ban)."
    info "Check it with:  sudo fail2ban-client status xrdp-sesman"
}

configure_firewall() {
    [[ $DO_FIREWALL -eq 1 ]] || { skip "Firewall untouched (--no-firewall)."; return 0; }
    step "Firewall"

    if [[ $BIND_ADDR == 127.0.0.1 || $BIND_ADDR == localhost ]]; then
        skip "Bound to loopback — no firewall rule needed."
        return 0
    fi

    if ! command -v ufw >/dev/null; then
        warn "ufw is not installed. If another firewall is active, open TCP ${RDP_PORT} yourself."
        return 0
    fi

    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        skip "ufw is installed but inactive — no rule added."
        warn "If you enable ufw later, run: sudo ufw allow ${RDP_PORT}/tcp"
        return 0
    fi

    if [[ -n $ALLOW_FROM ]]; then
        run ufw allow from "$ALLOW_FROM" to any port "$RDP_PORT" proto tcp
        info "Allowed ${ALLOW_FROM} → TCP ${RDP_PORT}."
    else
        run ufw allow "${RDP_PORT}/tcp"
        info "Allowed TCP ${RDP_PORT} from anywhere."
        warn "RDP is now reachable from any address. Prefer --allow-from CIDR, \
or --bind 127.0.0.1 plus an SSH tunnel."
    fi
}

enable_services() {
    step "Enabling services"
    run systemctl daemon-reload
    run systemctl enable --quiet xrdp xrdp-sesman 2>/dev/null || run systemctl enable --quiet xrdp
    run systemctl restart xrdp-sesman 2>/dev/null || true
    run systemctl restart xrdp
    [[ $DRY_RUN -eq 0 ]] && sleep 2
    info "xrdp and xrdp-sesman enabled and restarted."
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify() {
    [[ $DRY_RUN -eq 1 ]] && { skip "Skipping verification in dry-run mode."; return 0; }

    step "Verifying"
    local failures=0
    local check

    for check in xrdp xrdp-sesman; do
        if systemctl is-active --quiet "$check"; then
            info "${check}: active"
        else
            err "${check}: NOT running"
            failures=$((failures + 1))
        fi
    done

    if ss -lntH "sport = :${RDP_PORT}" 2>/dev/null | grep -q .; then
        info "Listening on port ${RDP_PORT}"
    else
        err "Nothing is listening on port ${RDP_PORT}"
        failures=$((failures + 1))
    fi

    [[ -x $STARTWM ]] && info "${STARTWM} is executable" \
                      || { err "${STARTWM} is not executable"; failures=$((failures + 1)); }

    if command -v xfce4-session >/dev/null; then
        info "XFCE is installed"
    else
        err "xfce4-session not found"
        failures=$((failures + 1))
    fi

    if (( failures > 0 )); then
        err "${failures} check(s) failed. Inspect: journalctl -u xrdp -u xrdp-sesman -n 60 --no-pager"
        return 1
    fi
    return 0
}

print_summary() {
    banner "XRDP setup complete"

    local ips=()
    if command -v hostname >/dev/null && hostname -I >/dev/null 2>&1; then
        read -r -a ips <<< "$(hostname -I)"
    else
        mapfile -t ips < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
    fi

    printf '%sConnection details%s\n' "$C_BOLD" "$C_RESET"
    printf '  Username : %s\n' "$TARGET_USER"
    printf '  Port     : %s\n' "$RDP_PORT"
    if [[ -n $BIND_ADDR ]]; then
        printf '  Address  : %s (bound to this address only)\n' "$BIND_ADDR"
    elif (( ${#ips[@]} )); then
        printf '  Address  : %s\n' "${ips[0]}"
        (( ${#ips[@]} > 1 )) && printf '             also: %s\n' "${ips[*]:1}"
    else
        printf '  Address  : (no global IPv4 address found)\n'
    fi

    printf '\n%sClients%s\n' "$C_BOLD" "$C_RESET"
    printf '  Windows  : Win+R → mstsc → %s:%s\n' "${ips[0]:-<server-ip>}" "$RDP_PORT"
    printf '  macOS    : Windows App (formerly Microsoft Remote Desktop)\n'
    printf '  Linux    : xfreerdp3 /v:%s:%s /u:%s /dynamic-resolution +clipboard\n' \
           "${ips[0]:-<server-ip>}" "$RDP_PORT" "$TARGET_USER"

    if [[ $BIND_ADDR == 127.0.0.1 || -n $ALLOW_FROM ]]; then
        printf '\n%sSSH tunnel (from your local machine)%s\n' "$C_BOLD" "$C_RESET"
        printf '  ssh -L %s:localhost:%s %s@%s\n' \
               "$RDP_PORT" "$RDP_PORT" "$TARGET_USER" "${ips[0]:-<server-ip>}"
        printf '  then point your RDP client at localhost:%s\n' "$RDP_PORT"
    fi

    printf '\n%sUseful commands%s\n' "$C_BOLD" "$C_RESET"
    printf '  sudo systemctl status xrdp\n'
    printf '  sudo journalctl -u xrdp -u xrdp-sesman -f\n'
    printf '  sudo tail -f /var/log/xrdp-sesman.log\n'
    printf '  sudo ./%s --uninstall\n' "$SCRIPT_NAME"

    if (( ${#WARNINGS[@]} )); then
        printf '\n%sWarnings (%d)%s\n' "$C_BOLD$C_YEL" "${#WARNINGS[@]}" "$C_RESET"
        local w; for w in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "$C_YEL" "$C_RESET" "$w"; done
    fi

    printf '\n%sNote:%s log out of any local desktop session for "%s" before connecting — \nXFCE cannot run twice for the same user.\n' \
           "$C_DIM" "$C_RESET" "$TARGET_USER"
    [[ -n $LOG_FILE ]] && printf '%sLog: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
restore_newest_backup() {
    local target=$1 newest
    newest=$(ls -1t "${target}".bak.* "${target}".backup.* 2>/dev/null | head -n1 || true)
    if [[ -n $newest ]]; then
        run cp -a "$newest" "$target"
        info "Restored ${target} from ${newest}"
    else
        skip "No backup found for ${target}"
    fi
}

uninstall() {
    banner "Uninstalling XRDP configuration"

    if ! confirm "Remove XRDP and revert all changes made by this script?"; then
        info "Cancelled."
        exit 0
    fi

    step "Stopping services"
    run systemctl disable --now xrdp xrdp-sesman 2>/dev/null || true

    step "Restoring configuration"
    restore_newest_backup "$STARTWM"
    restore_newest_backup "$XRDP_INI"
    restore_newest_backup "$SESMAN_INI"
    restore_newest_backup "$XWRAPPER"

    step "Removing generated files"
    local f
    for f in "$POLKIT_RULES" "$POLKIT_PKLA" "$F2B_FILTER" "$F2B_JAIL"; do
        if [[ -f $f ]]; then run rm -f "$f"; info "Removed ${f}"; fi
    done
    run systemctl restart fail2ban 2>/dev/null || true

    step "Firewall"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        run ufw delete allow "${RDP_PORT}/tcp" 2>/dev/null || true
        [[ -n $ALLOW_FROM ]] && run ufw delete allow from "$ALLOW_FROM" to any port "$RDP_PORT" proto tcp 2>/dev/null || true
        info "Removed ufw rules for port ${RDP_PORT} (where present)."
    else
        skip "ufw inactive or absent."
    fi

    step "Removing packages"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get purge -y -qq xrdp xorgxrdp || true
    if [[ $PURGE_DESKTOP -eq 1 ]]; then
        run apt-get purge -y -qq xfce4 xfce4-goodies || true
        info "XFCE removed."
    else
        skip "XFCE left installed (use --purge-desktop to remove it)."
    fi
    run apt-get autoremove -y -qq || true

    banner "Uninstall complete"
    printf '  Backups were kept as *.bak.* next to each config file.\n\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    setup_colors            # so early die() calls have colour vars defined
    parse_args "$@"
    setup_colors            # re-apply, now that --no-color is known
    preflight

    if [[ $DRY_RUN -eq 0 ]]; then
        LOG_FILE="/var/log/xrdp-setup-${STAMP}.log"
        install -m 0600 /dev/null "$LOG_FILE" 2>/dev/null || LOG_FILE=""
        [[ -n $LOG_FILE ]] && exec > >(tee -a "$LOG_FILE") 2>&1
    fi

    if [[ $DO_UNINSTALL -eq 1 ]]; then
        resolve_user 2>/dev/null || true
        uninstall
        exit 0
    fi

    banner "Ubuntu XRDP + XFCE Setup  (v${SCRIPT_VERSION})"
    [[ $DRY_RUN -eq 1 ]] && printf '  %s%s%s\n' "$C_BOLD$C_YEL" \
        "DRY RUN — nothing will actually change." "$C_RESET"

    resolve_user
    check_password
    check_local_session
    check_stale_xsession
    check_port_free

    install_packages
    configure_startwm
    configure_permissions
    configure_polkit
    configure_xrdp_ini
    configure_sound
    configure_fail2ban
    configure_firewall
    enable_services

    if verify; then
        print_summary
        exit 0
    else
        print_summary
        exit 1
    fi
}

main "$@"
