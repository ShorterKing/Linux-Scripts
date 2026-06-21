#!/usr/bin/env bash
# ==============================================================
#  install-docker.sh — Universal Docker Installer
#  Supports: Debian, Ubuntu, RHEL, CentOS, Fedora, Arch,
#            openSUSE, Alpine, Raspberry Pi OS, Amazon Linux,
#            and anything else supported by get.docker.com
#  Usage: sudo bash install-docker.sh
# ==============================================================

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Logging ────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERR ]${RESET}  $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}▶  $*${RESET}"; }

cmd_exists() { command -v "$1" &>/dev/null; }

# ── Banner ─────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
cat <<'BANNER'
 ____             _               ___           _        _ _
|  _ \  ___   ___| | _____ _ __  |_ _|_ __  ___| |_ __ _| | | ___ _ __
| | | |/ _ \ / __| |/ / _ \ '__|  | || '_ \/ __| __/ _` | | |/ _ \ '__|
| |_| | (_) | (__|   <  __/ |     | || | | \__ \ || (_| | | |  __/ |
|____/ \___/ \___|_|\_\___|_|    |___|_| |_|___/\__\__,_|_|_|\___|_|

       Universal Installer — Latest Docker Engine + Compose
BANNER
echo -e "${RESET}"

# ── Must run as root ───────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Please run as root:  sudo bash $0"
fi

# ── Detect OS ──────────────────────────────────────────────────
OS_ID="unknown"
OS_PRETTY="Unknown Linux"
OS_VERSION_ID=""

if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$ID}"
  OS_VERSION_ID="${VERSION_ID:-}"
elif [[ -f /etc/alpine-release ]]; then
  OS_ID="alpine"
  OS_PRETTY="Alpine Linux $(cat /etc/alpine-release)"
elif [[ -f /etc/redhat-release ]]; then
  OS_ID="rhel"
  OS_PRETTY="$(cat /etc/redhat-release)"
fi

ARCH="$(uname -m)"

info "OS      : ${OS_PRETTY}"
info "Arch    : ${ARCH}"
info "Kernel  : $(uname -r)"

case "$ARCH" in
  x86_64|aarch64|arm64|armv7l|armhf|s390x|ppc64le) ;;
  *) warn "Architecture '${ARCH}' may have limited Docker support." ;;
esac

# ==============================================================
#  STEP 1 — Fix broken apt sources (Debian/Ubuntu family only)
#
#  Why two layers?
#   Layer 1 (Python cleanup): permanently disables the stale
#     entry in whatever file it lives in — handles both the old
#     .list (single-line) format AND the new deb822 .sources
#     (multi-line stanza) format that Ubuntu 22.04+ uses.
#   Layer 2 (apt.conf override): sets APT::Update::Error-Mode
#     "any" right before Docker's own get.docker.com script
#     runs its `apt-get update`, so even if a stale entry slips
#     through, it can no longer abort the install.
# ==============================================================
fix_broken_apt_sources() {
  step "Pre-checking apt sources for stale repositories"

  # First pass — collect any broken repos
  local update_out
  update_out=$(apt-get update 2>&1 || true)

  if ! echo "$update_out" | grep -q "does not have a Release file"; then
    success "All apt sources look healthy"
    return
  fi

  warn "Stale/broken apt repositories detected — running cleanup"

  # Use Python so we can reliably handle BOTH formats:
  #   .list  → each repo is a single "deb URL SUITE COMPONENTS" line
  #   .sources → deb822 multi-line stanzas (URIs:, Suites: on separate lines)
  python3 - "$update_out" << 'PYEOF'
import sys, re, os, shutil

raw_apt_out = sys.argv[1]

# ── Parse broken repos from apt output ─────────────────────────
# Line format: E: The repository 'URL SUITE Release' does not have a Release file.
broken = []
for m in re.finditer(r"'([^']+)\s+Release'\s+does not have a Release file", raw_apt_out):
    spec  = m.group(1).strip()
    parts = spec.split(None, 1)
    broken.append({
        'url':   parts[0],
        'suite': parts[1].strip() if len(parts) > 1 else ''
    })

if not broken:
    print("[INFO]  No broken repos found to fix.")
    sys.exit(0)

for b in broken:
    print(f"[WARN]    → {b['url']} {b['suite']}")

# ── Find every apt source file that references a broken URL ────
apt_root = '/etc/apt'
to_process = []
for dirpath, _, files in os.walk(apt_root):
    for fname in files:
        if fname.endswith(('.list', '.sources')):
            fpath = os.path.join(dirpath, fname)
            try:
                content = open(fpath).read()
            except Exception:
                continue
            for b in broken:
                if b['url'] in content:
                    to_process.append(fpath)
                    break

if not to_process:
    print("[WARN]  Could not locate source files — please check /etc/apt/ manually.")
    sys.exit(0)

# ── Patch each affected file ────────────────────────────────────
TAG = "# [STALE REPO - DISABLED BY DOCKER INSTALLER]: "

for fpath in to_process:
    content = open(fpath).read()
    new_content = content
    changed = [False]

    if fpath.endswith('.sources'):
        # deb822 format: blank-line-separated stanzas
        # We need to comment out any stanza whose URI + Suites match
        def patch_stanza(stanza_text, broken_list):
            lines = stanza_text.splitlines()
            for b in broken_list:
                has_url   = any(b['url']   in l for l in lines if not l.lstrip().startswith('#'))
                has_suite = (not b['suite'] or
                             any(b['suite'] in l for l in lines if not l.lstrip().startswith('#')))
                if has_url and has_suite:
                    changed[0] = True
                    return '\n'.join(
                        (TAG + l) if (l.strip() and not l.startswith('#')) else l
                        for l in lines
                    )
            return stanza_text

        # Split preserving the blank-line separators
        parts = re.split(r'(\n{2,})', content)
        new_parts = [patch_stanza(p, broken) if not re.fullmatch(r'\n+', p) else p
                     for p in parts]
        new_content = ''.join(new_parts)

    else:
        # Traditional .list format: one repo per uncommented line
        out_lines = []
        for line in content.splitlines(keepends=True):
            stripped = line.rstrip('\n\r')
            patched  = stripped
            if not stripped.lstrip().startswith('#'):
                for b in broken:
                    if (b['url'] in stripped and
                            (not b['suite'] or b['suite'] in stripped)):
                        patched  = TAG + stripped
                        changed[0]  = True
                        break
            out_lines.append(patched + '\n')
        new_content = ''.join(out_lines)

    if changed[0]:
        backup = fpath + '.bak'
        shutil.copy2(fpath, backup)
        open(fpath, 'w').write(new_content)
        print(f"[ OK ]  Disabled stale entry in: {fpath}  (backup → {backup})")
    else:
        print(f"[INFO]  No matching entry found in: {fpath}")

print("[ OK ]  Python cleanup complete.")
PYEOF

  # Wipe stale apt cache so the next update is fully fresh
  rm -rf /var/lib/apt/lists/*
  info "Re-running apt-get update to confirm..."
  apt-get update 2>&1 | grep -E "^(E:|W:)" | grep -v "does not have a Release file" || true

  if apt-get update -qq 2>&1 | grep -q "does not have a Release file"; then
    warn "Some stale repos could not be auto-disabled."
    warn "The install will proceed anyway (see Layer 2 below)."
  else
    success "Apt sources are clean"
  fi
}

# ==============================================================
#  STEP 2 — Remove conflicting / old Docker packages
# ==============================================================
remove_old_docker() {
  step "Removing old Docker packages (if any)"
  case "$OS_ID" in
    ubuntu|debian|raspbian|linuxmint|pop|kali|elementary|zorin)
      DEBIAN_FRONTEND=noninteractive apt-get remove -y \
        docker docker-engine docker.io containerd runc \
        docker-desktop docker-doc docker-compose \
        podman-docker 2>/dev/null || true
      ;;
    centos|rhel|rocky|almalinux|ol)
      yum remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-latest-logrotate \
        docker-logrotate docker-engine 2>/dev/null || true
      ;;
    fedora)
      dnf remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-latest-logrotate \
        docker-logrotate docker-selinux docker-engine-selinux \
        docker-engine 2>/dev/null || true
      ;;
    arch|manjaro|endeavouros|garuda)
      pacman -Rns --noconfirm docker 2>/dev/null || true
      ;;
    opensuse*|sles)
      zypper remove -y docker docker-compose docker-compose-switch 2>/dev/null || true
      ;;
    alpine)
      apk del docker docker-compose 2>/dev/null || true
      ;;
    *)
      info "Skipping package removal for unrecognised distro." ;;
  esac
  success "Old packages removed"
}

# ==============================================================
#  STEP 3 — Install Docker
# ==============================================================

# --- 3a. get.docker.com (Debian/Ubuntu/RHEL/Fedora/Amazon/…) --
#
#  Layer 2 defence: inject APT::Update::Error-Mode "any" into
#  a temporary apt config file before Docker's install script
#  runs its own `apt-get update`.  This makes apt exit 0 even
#  when some repos have errors — so a single stale third-party
#  repo can never abort the whole Docker install.
#  The config file is removed immediately after.
# --------------------------------------------------------------
APT_ERRMODE_CONF="/etc/apt/apt.conf.d/99-docker-install-errmode"

install_via_get_script() {
  step "Fetching Docker's official install script (get.docker.com)"
  local dl_script="/tmp/get-docker.sh"

  if cmd_exists curl; then
    curl -fsSL https://get.docker.com -o "$dl_script"
  elif cmd_exists wget; then
    wget -qO "$dl_script" https://get.docker.com
  else
    error "Neither curl nor wget found. Install one and retry."
  fi

  # Layer 2: make apt-get update non-fatal for repo errors
  mkdir -p /etc/apt/apt.conf.d
  echo 'APT::Update::Error-Mode "any";' > "$APT_ERRMODE_CONF"
  info "Injected apt error-mode override (will be removed after install)"

  info "Executing installer…"
  sh "$dl_script"
  local rc=$?

  rm -f "$dl_script" "$APT_ERRMODE_CONF"

  [[ $rc -eq 0 ]] || error "get.docker.com install script exited with code $rc"
  success "Docker installed via get.docker.com"
}

# --- 3b. Alpine -----------------------------------------------
install_alpine() {
  step "Installing Docker on Alpine Linux"
  apk update
  apk add --no-cache docker docker-compose docker-cli-compose
  rc-update add docker boot 2>/dev/null || true
  service docker start  2>/dev/null || true
  success "Docker installed on Alpine"
}

# --- 3c. Arch / Manjaro / EndeavourOS -------------------------
install_arch() {
  step "Installing Docker on Arch Linux"
  pacman -Sy --noconfirm docker docker-compose
  systemctl enable --now docker
  success "Docker installed on Arch"
}

# --- 3d. Void Linux -------------------------------------------
install_void() {
  step "Installing Docker on Void Linux"
  xbps-install -Sy docker
  ln -s /etc/sv/docker /var/service/
  success "Docker installed on Void Linux"
}

# --- 3e. Gentoo -----------------------------------------------
install_gentoo() {
  step "Installing Docker on Gentoo"
  emerge --ask=n app-containers/docker app-containers/docker-cli
  rc-update add docker default
  success "Docker installed on Gentoo"
}

# ==============================================================
#  STEP 4 — Post-install setup
# ==============================================================
post_install() {
  step "Running post-install setup"

  # Enable & start Docker service (systemd)
  if cmd_exists systemctl && systemctl list-units --type=service &>/dev/null; then
    systemctl enable docker 2>/dev/null && success "Docker service enabled (systemd)"
    systemctl start  docker 2>/dev/null && success "Docker service started"
  fi

  # Add the invoking user to the docker group
  REAL_USER="${SUDO_USER:-}"
  if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    usermod -aG docker "$REAL_USER"
    success "User '${REAL_USER}' added to the 'docker' group"
    warn "Log out and back in (or run: newgrp docker) for this to take effect."
  fi

  # Install Docker Compose plugin if not already present
  if ! docker compose version &>/dev/null 2>&1; then
    step "Installing latest Docker Compose plugin"
    COMPOSE_DIR="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$COMPOSE_DIR"

    COMPOSE_TAG=""
    if cmd_exists curl; then
      COMPOSE_TAG=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    fi

    if [[ -n "$COMPOSE_TAG" ]]; then
      COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_TAG}/docker-compose-$(uname -s)-$(uname -m)"
      if curl -fsSL "$COMPOSE_URL" -o "${COMPOSE_DIR}/docker-compose"; then
        chmod +x "${COMPOSE_DIR}/docker-compose"
        success "Docker Compose ${COMPOSE_TAG} installed"
      else
        warn "Could not download Docker Compose. Install manually if needed."
      fi
    else
      warn "Could not determine latest Compose version. Skipping."
    fi
  else
    success "Docker Compose already present: $(docker compose version 2>/dev/null)"
  fi
}

# ==============================================================
#  STEP 5 — Verify
# ==============================================================
verify() {
  step "Verifying installation"

  if cmd_exists docker; then
    success "docker CLI   : $(docker --version)"
  else
    error "'docker' binary not found. Installation may have failed."
  fi

  if docker info &>/dev/null; then
    success "Docker daemon: running"
  else
    warn "Docker daemon doesn't seem to be running. Check: systemctl status docker"
  fi

  if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose: $(docker compose version)"
  fi

  info "Running hello-world smoke test…"
  if docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; then
    success "hello-world container ran successfully ✓"
  else
    warn "hello-world test inconclusive. Run 'docker info' to check daemon status."
  fi
}

# ==============================================================
#  MAIN
# ==============================================================
main() {
  # Ensure APT_ERRMODE_CONF is always cleaned up, even on error
  trap 'rm -f "$APT_ERRMODE_CONF"' EXIT

  case "$OS_ID" in
    alpine)
      remove_old_docker
      install_alpine
      ;;
    arch|manjaro|endeavouros|garuda|artix)
      remove_old_docker
      install_arch
      ;;
    void)
      remove_old_docker
      install_void
      ;;
    gentoo)
      remove_old_docker
      install_gentoo
      ;;
    ubuntu|debian|raspbian|linuxmint|pop|kali|elementary|zorin)
      fix_broken_apt_sources   # ← Layer 1: permanently patch source files
      remove_old_docker
      install_via_get_script   # ← Layer 2: apt error-mode override inside here
      ;;
    *)
      # RHEL, CentOS, Rocky, Alma, Fedora, openSUSE, Amazon Linux, etc.
      remove_old_docker
      install_via_get_script
      ;;
  esac

  post_install
  verify

  echo
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║        Docker is installed and ready!        ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo
  echo -e "  ${CYAN}docker run hello-world${RESET}        quick smoke test"
  echo -e "  ${CYAN}docker compose version${RESET}        check Compose"
  echo -e "  ${CYAN}docker ps${RESET}                     list running containers"
  echo -e "  ${CYAN}systemctl status docker${RESET}       service status"
  echo
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo -e "  ${YELLOW}⚠  Run 'newgrp docker' or re-login to use Docker without sudo.${RESET}"
    echo
  fi
}

main
