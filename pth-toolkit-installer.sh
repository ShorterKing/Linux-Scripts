#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  install-pth-toolkit.sh
#  Installs the Pass-the-Hash (PTH) toolkit system-wide on Linux.
#
#  What it does:
#   • Kali / Parrot            → native 'passing-the-hash' apt package
#   • Ubuntu / Debian & others → clones byt3bl33d3r/pth-toolkit, then
#                                patches the ancient (~2013) bundled
#                                binaries so they run on a modern system:
#                                  - installs real libpopt0 (LIBPOPT_0 syms)
#                                  - shims libreadline.so.6 -> system readline
#                                  - wraps each tool into /usr/local/bin
#
#  Tested against Ubuntu 24.04.  The bundled binaries need libpopt0 and an
#  old readline; without them only 'winexe' runs.  This script fixes that.
#
#  Usage:  sudo bash install-pth-toolkit.sh
# ──────────────────────────────────────────────────────────────
set -uo pipefail   # NB: not -e; we handle errors explicitly and count in loops

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

INSTALL_DIR="/opt/pth-toolkit"
BIN_LINK_DIR="/usr/local/bin"
REPO_URL="https://github.com/byt3bl33d3r/pth-toolkit.git"
REPO_ALT_URL="https://github.com/yodresh/pth-toolkit.git"

info()    { echo -e "${CYAN}[*]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
fail()    { echo -e "${RED}[-]${NC} $*"; exit 1; }

check_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root:  sudo $0"
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"; DISTRO_ID="${DISTRO_ID,,}"
        DISTRO_LIKE="${ID_LIKE:-}"; DISTRO_LIKE="${DISTRO_LIKE,,}"
    else
        DISTRO_ID="unknown"; DISTRO_LIKE=""
    fi
}

# ── Native Kali/Parrot package ───────────────────────────────
install_apt_package() {
    info "Trying native 'passing-the-hash' apt package..."
    apt-get update -qq 2>/dev/null || true
    if apt-get install -y passing-the-hash 2>/dev/null; then
        success "Installed 'passing-the-hash' via apt (tools are pth-*)."
        return 0
    fi
    warn "'passing-the-hash' package unavailable in these repos."
    return 1
}

# ── Fix the ancient bundled binaries on modern systems ───────
# The GitHub bundle ships 2013-era Samba binaries that need:
#   libpopt.so.0  with the versioned symbol LIBPOPT_0  (real libpopt0 pkg;
#                 the bundled samba 'libpopt_samba3.so' does NOT provide it)
#   libreadline.so.6                                   (modern distros ship .so.8)
#   libsocket_wrapper.so  (already bundled in lib/private) - needs the above first
patch_dependencies() {
    info "Patching bundled-binary dependencies for a modern system..."

    # 1) real libpopt0 – required by smbclient/net/rpcclient/smbget/wmic/wmis
    if ! ldconfig -p 2>/dev/null | grep -q 'libpopt\.so\.0'; then
        info "Installing libpopt0 (provides libpopt.so.0 / LIBPOPT_0)..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y libpopt0 2>/dev/null || warn "apt could not install libpopt0"
        elif command -v dnf &>/dev/null; then
            dnf install -y popt 2>/dev/null || warn "dnf could not install popt"
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm --needed popt 2>/dev/null || warn "pacman could not install popt"
        fi
    fi
    if ldconfig -p 2>/dev/null | grep -q 'libpopt\.so\.0'; then
        success "libpopt.so.0 present."
    else
        warn "libpopt.so.0 still missing — only 'winexe' will run until you install it."
    fi

    # 2) libreadline.so.6 shim – needed by smbclient/net/rpcclient
    if ! ldconfig -p 2>/dev/null | grep -q 'libreadline\.so\.6'; then
        local rl
        rl="$(ldconfig -p 2>/dev/null | grep -oE '/[^ ]*libreadline\.so\.[0-9]+' | sort -V | tail -1)"
        if [[ -n "$rl" && -e "$rl" ]]; then
            ln -sf "$rl" "${INSTALL_DIR}/lib/libreadline.so.6"
            success "Shimmed libreadline.so.6 -> ${rl##*/} (inside bundle)."
        else
            warn "No system libreadline found; smbclient/net/rpcclient may not run."
        fi
    fi

    # Refresh the linker cache if we touched system libs
    ldconfig 2>/dev/null || true
}

# ── Install from GitHub ──────────────────────────────────────
install_from_github() {
    command -v git &>/dev/null || fail "git is required. Install it and re-run."

    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Removing existing ${INSTALL_DIR}..."
        rm -rf "$INSTALL_DIR"
    fi

    info "Cloning pth-toolkit..."
    if ! git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null; then
        warn "Primary repo failed; trying alternate fork..."
        git clone --depth 1 "$REPO_ALT_URL" "$INSTALL_DIR" 2>/dev/null \
            || fail "Could not clone pth-toolkit from any source."
    fi
    success "Cloned to ${INSTALL_DIR}"

    info "Setting permissions..."
    find "$INSTALL_DIR" -maxdepth 1 -name 'pth-*' -exec chmod +x {} \; 2>/dev/null
    [[ -d "${INSTALL_DIR}/bin" ]] && chmod +x "${INSTALL_DIR}/bin/"* 2>/dev/null

    patch_dependencies

    # Wrapper scripts in /usr/local/bin. Plain symlinks DON'T work: the
    # bundled pth-* scripts use RELATIVE paths (lib/, bin/foo), so the tool
    # must run from INSTALL_DIR. Each wrapper cd's in first, then execs.
    info "Creating wrappers in ${BIN_LINK_DIR}..."
    mkdir -p "$BIN_LINK_DIR"
    local count=0 tool name
    for tool in "${INSTALL_DIR}"/pth-*; do
        [[ -f "$tool" ]] || continue
        name="$(basename "$tool")"
        cat > "${BIN_LINK_DIR}/${name}" <<WRAPPER
#!/usr/bin/env bash
cd "${INSTALL_DIR}" || exit 1
exec "./${name}" "\$@"
WRAPPER
        chmod +x "${BIN_LINK_DIR}/${name}"
        count=$((count + 1))
    done
    [[ $count -gt 0 ]] || fail "No pth-* wrappers found in the repo — layout changed?"
    success "Created ${count} wrapper(s) in ${BIN_LINK_DIR}."
}

# ── Verify: actually RUN each tool, don't just check it exists ───
verify_install() {
    echo ""
    info "Verifying (running each tool with --help)..."
    echo "──────────────────────────────────────────────"
    local tools=( pth-winexe pth-smbclient pth-net pth-rpcclient
                  pth-smbget pth-wmic pth-wmis pth-curl pth-sqsh )
    local ok=0 broken=0 absent=0 t out
    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            echo -e "  ${YELLOW}–${NC}  ${t} (not installed)"; absent=$((absent+1)); continue
        fi
        out="$(timeout 8 "$t" --help 2>&1)"
        if echo "$out" | grep -qiE 'loading shared libraries|not found|no such file'; then
            echo -e "  ${RED}✗${NC}  ${t} — ${RED}lib error${NC}: $(echo "$out" | grep -iE 'shared libraries|not found' | head -1 | sed 's/^[^:]*: //')"
            broken=$((broken+1))
        else
            echo -e "  ${GREEN}✓${NC}  ${t}"
            ok=$((ok+1))
        fi
    done
    echo "──────────────────────────────────────────────"
    success "${ok} working · ${broken} lib-broken · ${absent} absent"
    if [[ $broken -gt 0 ]]; then
        warn "Broken tools are missing a system library. Most often:"
        warn "   sudo apt install libpopt0        # for smbclient/net/rpcclient/smbget/wmic/wmis"
        warn "   (readline is auto-shimmed; if a readline symbol error persists,"
        warn "    install an older libreadline6 .deb)"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PTH-Toolkit Installer for Linux      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    check_root
    detect_distro
    info "Distro: ${DISTRO_ID} (like: ${DISTRO_LIKE:-n/a})"

    case "$DISTRO_ID" in
        kali|parrot)
            install_apt_package || install_from_github
            ;;
        debian|ubuntu|linuxmint|pop|zorin|elementary|kali|parrot)
            # Ubuntu family: the native package usually isn't there → GitHub + patch
            install_apt_package || install_from_github
            ;;
        *)
            if command -v apt-get &>/dev/null; then
                install_apt_package || install_from_github
            else
                install_from_github
            fi
            ;;
    esac

    verify_install
    success "Done. Try:  pth-winexe -U 'DOMAIN/user%<LMHASH>:<NTHASH>' //TARGET cmd.exe"
    echo ""
}

main "$@"
