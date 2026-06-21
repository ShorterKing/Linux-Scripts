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

# ── Sanity-check architecture ──────────────────────────────────
case "$ARCH" in
  x86_64|aarch64|arm64|armv7l|armhf|s390x|ppc64le) ;;
  *) warn "Architecture '${ARCH}' may have limited Docker support." ;;
esac

# ==============================================================
#  STEP 1 — Remove conflicting / old Docker packages
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
#  STEP 2 — Install Docker
# ==============================================================

# --- 2a. get.docker.com (works for Debian/Ubuntu/RHEL/Fedora/
#         CentOS/Raspbian/Amazon Linux/SLES/openSUSE/…) ---------
install_via_get_script() {
  step "Fetching Docker's official install script (get.docker.com)"
  local script="/tmp/get-docker.sh"

  if cmd_exists curl; then
    curl -fsSL https://get.docker.com -o "$script"
  elif cmd_exists wget; then
    wget -qO "$script" https://get.docker.com
  else
    error "Neither curl nor wget found. Install one and retry."
  fi

  info "Executing installer…"
  sh "$script"
  rm -f "$script"
  success "Docker installed via get.docker.com"
}

# --- 2b. Alpine (get.docker.com not supported) -----------------
install_alpine() {
  step "Installing Docker on Alpine Linux"
  apk update
  apk add --no-cache docker docker-compose docker-cli-compose
  rc-update add docker boot 2>/dev/null || true
  service docker start  2>/dev/null || true
  success "Docker installed on Alpine"
}

# --- 2c. Arch / Manjaro / EndeavourOS -------------------------
install_arch() {
  step "Installing Docker on Arch Linux"
  pacman -Sy --noconfirm docker docker-compose
  systemctl enable --now docker
  success "Docker installed on Arch"
}

# --- 2d. Void Linux -------------------------------------------
install_void() {
  step "Installing Docker on Void Linux"
  xbps-install -Sy docker
  ln -s /etc/sv/docker /var/service/
  success "Docker installed on Void Linux"
}

# --- 2e. Gentoo -----------------------------------------------
install_gentoo() {
  step "Installing Docker on Gentoo"
  emerge --ask=n app-containers/docker app-containers/docker-cli
  rc-update add docker default
  success "Docker installed on Gentoo"
}

# ==============================================================
#  STEP 3 — Post-install setup
# ==============================================================
post_install() {
  step "Running post-install setup"

  # Enable & start Docker service (systemd)
  if cmd_exists systemctl && systemctl list-units --type=service &>/dev/null; then
    systemctl enable docker  2>/dev/null && success "Docker service enabled (systemd)"
    systemctl start  docker  2>/dev/null && success "Docker service started"
  fi

  # Add the invoking user to the docker group so sudo isn't needed later
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
#  STEP 4 — Verify
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

  if cmd_exists docker && docker compose version &>/dev/null 2>&1; then
    success "Docker Compose: $(docker compose version)"
  fi

  info "Running hello-world smoke test…"
  if docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; then
    success "hello-world container ran successfully ✓"
  else
    warn "hello-world test failed. Docker may still work — run 'docker info' to check."
  fi
}

# ==============================================================
#  MAIN
# ==============================================================
main() {
  remove_old_docker

  case "$OS_ID" in
    alpine)
      install_alpine ;;
    arch|manjaro|endeavouros|garuda|artix)
      install_arch ;;
    void)
      install_void ;;
    gentoo)
      install_gentoo ;;
    *)
      # Handles: debian, ubuntu, raspbian, pop, kali, linuxmint,
      #          centos, rhel, rocky, almalinux, ol, fedora,
      #          opensuse-*, sles, amzn, and many others
      install_via_get_script ;;
  esac

  post_install
  verify

  # ── Summary ────────────────────────────────────────────────
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
