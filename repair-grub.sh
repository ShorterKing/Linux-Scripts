#!/usr/bin/env bash
#
# repair-grub.sh — GRUB bootloader repair for Ubuntu / Debian
#
#   Run from a Live USB. Detects your installation (including LVM, LUKS and
#   btrfs), chroots into it, reinstalls GRUB and rebuilds the boot menu.
#   Handles both UEFI and legacy BIOS. Always unmounts cleanly, even on
#   failure or Ctrl-C.
#
#   Usage:  sudo bash repair-grub.sh [options]
#           sudo bash repair-grub.sh --help
#
# ---------------------------------------------------------------------------

set -Eeuo pipefail

readonly SCRIPT_VERSION="2.0"
readonly STAMP=$(date +%Y%m%d-%H%M%S)
readonly MNT=/mnt/grub-repair
readonly INNER=/root/.grub-repair-inner.sh
readonly ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

# ----- options --------------------------------------------------------------
OPT_ROOT=""
OPT_ESP=""
OPT_BOOT=""
OPT_BIOS_DISK=""
FORCE_MODE=""           # "", "uefi" or "bios"
DO_REMOVABLE=0
DO_OSPROBER=0
DO_NVRAM=1
DO_INITRAMFS=0
ALLOW_APT=0
DRY_RUN=0
ASSUME_YES=0
USE_COLOR=1

# ----- discovered state -----------------------------------------------------
FW_MODE=""              # uefi | bios
EFI_TARGET=""           # x86_64-efi, arm64-efi, ...
FALLBACK_NAME=""        # BOOTX64.EFI, ...
GRUB_EFI_NAME=""        # grubx64.efi, ...
SECURE_BOOT="unknown"
ROOT_DEV=""; ROOT_FS=""; ROOT_OPTS=""
BOOT_DEV=""
ESP_DEV=""
BIOS_DISK=""
OS_NAME="Unknown"
LOG_FILE=""
BACKUP_FILE=""
CLEANUP_ARMED=0
RESOLV_SAVED=0
OPENED_LUKS=()
WARNINGS=()

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ $USE_COLOR -eq 1 && -t 1 && -z ${NO_COLOR:-} ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
        C_BLU=$'\033[34m';  C_CYN=$'\033[36m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
    fi
}

banner() { printf '\n%s%s%s\n%s %s %s\n%s%s%s\n\n' \
           "$C_BOLD$C_BLU" "══════════════════════════════════════════════" "$C_RESET" \
           "$C_BOLD" "$*" "$C_RESET" \
           "$C_BOLD$C_BLU" "══════════════════════════════════════════════" "$C_RESET"; }
step()   { printf '\n%s▸ %s%s\n' "$C_BOLD$C_CYN" "$*" "$C_RESET"; }
info()   { printf '  %s•%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
skip()   { printf '  %s◦ %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()   { printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_RESET"; WARNINGS+=("$*"); }
err()    { printf '  %s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()    { err "$*"; exit 1; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

# Prompts must come from the terminal, not stdin — this script is often piped.
ask() {
    local prompt=$1 __var=$2 reply
    read -rp "  ${C_BOLD}${prompt}${C_RESET} " reply </dev/tty || reply=""
    printf -v "$__var" '%s' "$reply"
}

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -rp "  ${C_BOLD}$1 [y/N]${C_RESET} " reply </dev/tty || return 1
    [[ $reply =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Cleanup — runs on ANY exit path. This is the part the original script lacked.
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    trap - ERR EXIT INT TERM
    [[ $CLEANUP_ARMED -eq 1 ]] || exit "$rc"

    printf '\n'
    step "Cleaning up"

    if [[ $RESOLV_SAVED -eq 1 ]]; then
        rm -f "${MNT}/etc/resolv.conf"
        if [[ -e ${MNT}/etc/resolv.conf.grub-repair || -L ${MNT}/etc/resolv.conf.grub-repair ]]; then
            mv "${MNT}/etc/resolv.conf.grub-repair" "${MNT}/etc/resolv.conf"
            info "Restored the system's original /etc/resolv.conf"
        fi
    fi
    rm -f "${MNT}${INNER}"

    sync

    local attempt m remaining
    for attempt in 1 2 3; do
        remaining=0
        while IFS= read -r m; do
            umount "$m" 2>/dev/null || remaining=1
        done < <(findmnt -lRno TARGET "$MNT" 2>/dev/null | tac)
        (( remaining == 0 )) && break
        sleep 1
    done

    # Anything still stuck gets a lazy unmount so a reboot is still safe.
    while IFS= read -r m; do
        if umount -l "$m" 2>/dev/null; then
            warn "Lazily unmounted ${m} (something was still using it)."
        fi
    done < <(findmnt -lRno TARGET "$MNT" 2>/dev/null | tac)

    local dm
    for dm in ${OPENED_LUKS[@]+"${OPENED_LUKS[@]}"}; do
        cryptsetup close "$dm" 2>/dev/null && info "Closed LUKS mapping ${dm}" || true
    done

    rmdir "$MNT" 2>/dev/null || true
    info "All partitions unmounted."
    exit "$rc"
}

on_error() {
    err "Failed at line $1."
    err "The system was NOT left half-mounted — cleanup runs next."
    [[ -n $LOG_FILE ]] && err "Log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
cat <<HELP_EOF
repair-grub.sh v${SCRIPT_VERSION} — GRUB repair for Ubuntu / Debian

  Boot a Live USB, open a terminal, and run this. It finds your installed
  system, chroots in, and reinstalls the bootloader.

OPTIONS
  -r, --root DEV      Root partition or LV (default: auto-detect, then ask)
  -e, --esp DEV       EFI System Partition (default: read from fstab)
  -b, --boot DEV      Separate /boot partition (default: read from fstab)
      --bios DISK     Legacy BIOS install to a whole disk, e.g. /dev/sda
      --uefi          Force UEFI mode
      --removable     Also write the fallback path EFI/BOOT/BOOT*.EFI.
                      Use when firmware ignores its own NVRAM entries.
      --no-nvram      Do not touch firmware boot entries (read-only efivars)
      --os-prober     Re-enable os-prober so Windows/other distros appear
                      in the menu (Ubuntu 22.04+ disables it by default)
      --initramfs     Also rebuild initramfs for every installed kernel
      --allow-apt     Let the chroot install missing GRUB packages
  -y, --yes           Do not prompt for confirmation
  -n, --dry-run       Detect and report; change nothing
      --no-color      Plain output
  -h, --help          This help
  -V, --version       Version

EXAMPLES
  sudo bash repair-grub.sh
  sudo bash repair-grub.sh --root /dev/sda5 --esp /dev/sda1 --yes
  sudo bash repair-grub.sh --removable --os-prober
  sudo bash repair-grub.sh --bios /dev/sda
  sudo bash repair-grub.sh --dry-run
HELP_EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--root)   OPT_ROOT=${2:?--root needs a device};      shift 2 ;;
            -e|--esp)    OPT_ESP=${2:?--esp needs a device};        shift 2 ;;
            -b|--boot)   OPT_BOOT=${2:?--boot needs a device};      shift 2 ;;
            --bios)      OPT_BIOS_DISK=${2:?--bios needs a disk}; FORCE_MODE=bios; shift 2 ;;
            --uefi)      FORCE_MODE=uefi;   shift ;;
            --removable) DO_REMOVABLE=1;    shift ;;
            --no-nvram)  DO_NVRAM=0;        shift ;;
            --os-prober) DO_OSPROBER=1;     shift ;;
            --initramfs) DO_INITRAMFS=1;    shift ;;
            --allow-apt) ALLOW_APT=1;       shift ;;
            -y|--yes)    ASSUME_YES=1;      shift ;;
            -n|--dry-run) DRY_RUN=1;        shift ;;
            --no-color)  USE_COLOR=0;       shift ;;
            -h|--help)   setup_colors; usage; exit 0 ;;
            -V|--version) echo "repair-grub.sh ${SCRIPT_VERSION}"; exit 0 ;;
            *) setup_colors; usage >&2; echo; die "Unknown option: $1" ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
    [[ $EUID -eq 0 ]] || die "Run with sudo:  sudo bash ${0##*/}"

    local missing=() t
    for t in lsblk blkid findmnt mount umount chroot awk sed tac; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    (( ${#missing[@]} )) && die "Missing required tools: ${missing[*]}"

    if [[ ! -e /proc/mounts ]]; then
        die "/proc is not mounted. Are you really in a Linux live session?"
    fi
    return 0
}

detect_firmware() {
    step "Detecting firmware mode"

    if [[ -n $FORCE_MODE ]]; then
        FW_MODE=$FORCE_MODE
        warn "Firmware mode forced to ${FW_MODE^^} by command line."
    elif [[ -d /sys/firmware/efi ]]; then
        FW_MODE=uefi
    else
        FW_MODE=bios
    fi

    if [[ $FW_MODE == bios ]]; then
        info "Legacy BIOS / CSM mode."
        warn "If this machine's Ubuntu was installed in UEFI mode, this Live USB \
booted the wrong way. Reboot and pick the 'UEFI:' entry for your USB, or pass --uefi."
        return 0
    fi

    info "UEFI boot detected."

    local bits="64"
    [[ -r /sys/firmware/efi/fw_platform_size ]] && bits=$(cat /sys/firmware/efi/fw_platform_size)

    case "$(uname -m)" in
        x86_64|amd64)
            if [[ $bits == 32 ]]; then
                EFI_TARGET=i386-efi;   FALLBACK_NAME=BOOTIA32.EFI; GRUB_EFI_NAME=grubia32.efi
            else
                EFI_TARGET=x86_64-efi; FALLBACK_NAME=BOOTX64.EFI;  GRUB_EFI_NAME=grubx64.efi
            fi ;;
        aarch64|arm64)
            EFI_TARGET=arm64-efi; FALLBACK_NAME=BOOTAA64.EFI; GRUB_EFI_NAME=grubaa64.efi ;;
        armv7l|armhf)
            EFI_TARGET=arm-efi;   FALLBACK_NAME=BOOTARM.EFI;  GRUB_EFI_NAME=grubarm.efi ;;
        i686|i386)
            EFI_TARGET=i386-efi;  FALLBACK_NAME=BOOTIA32.EFI; GRUB_EFI_NAME=grubia32.efi ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
    info "GRUB target: ${EFI_TARGET}"

    local sb_var=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    if command -v mokutil >/dev/null && mokutil --sb-state >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | grep -qi enabled && SECURE_BOOT=enabled || SECURE_BOOT=disabled
    elif [[ -r $sb_var ]]; then
        [[ $(od -An -t u1 "$sb_var" 2>/dev/null | awk '{print $5}') == 1 ]] \
            && SECURE_BOOT=enabled || SECURE_BOOT=disabled
    fi
    info "Secure Boot: ${SECURE_BOOT}"

    if [[ ! -d /sys/firmware/efi/efivars ]] || ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
    fi
    if [[ -z $(ls -A /sys/firmware/efi/efivars 2>/dev/null) ]]; then
        warn "efivarfs is unavailable — firmware boot entries cannot be written. \
Falling back to --no-nvram --removable."
        DO_NVRAM=0; DO_REMOVABLE=1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Storage discovery
# ---------------------------------------------------------------------------
activate_stacked_devices() {
    step "Activating LVM / RAID / encrypted volumes"

    if command -v mdadm >/dev/null; then
        mdadm --assemble --scan >/dev/null 2>&1 && info "Assembled MD RAID arrays." \
            || skip "No inactive MD RAID arrays found."
    fi

    if command -v vgchange >/dev/null; then
        if vgchange -ay >/dev/null 2>&1; then
            local vgs; vgs=$(vgs --noheadings -o vg_name 2>/dev/null | xargs || true)
            [[ -n $vgs ]] && info "Activated LVM volume groups: ${vgs}" \
                          || skip "No LVM volume groups found."
        fi
    else
        skip "lvm2 not installed in this live session."
    fi

    # Offer to unlock any LUKS container that is not already open.
    command -v cryptsetup >/dev/null || { skip "cryptsetup not available."; return 0; }
    local dev
    while IFS= read -r dev; do
        [[ -n $dev ]] || continue
        cryptsetup isLuks "$dev" 2>/dev/null || continue
        local uuid mapper
        uuid=$(cryptsetup luksUUID "$dev" 2>/dev/null || echo "")
        mapper="luks-${uuid}"
        [[ -e /dev/mapper/$mapper ]] && { skip "${dev} already unlocked."; continue; }

        warn "${dev} is LUKS-encrypted."
        if [[ $DRY_RUN -eq 1 ]]; then
            skip "would offer to unlock ${dev}"
            continue
        fi
        if confirm "Unlock ${dev} now?"; then
            if cryptsetup open "$dev" "$mapper"; then
                OPENED_LUKS+=("$mapper")
                info "Unlocked as /dev/mapper/${mapper}"
                command -v vgchange >/dev/null && vgchange -ay >/dev/null 2>&1 || true
            else
                warn "Could not unlock ${dev}."
            fi
        fi
    done < <(lsblk -rno PATH,FSTYPE | awk '$2 == "crypto_LUKS" {print $1}')
    return 0
}

# Every block device that could plausibly hold a root filesystem.
list_block_devices() {
    lsblk -rno PATH,TYPE \
        | awk '$2 == "part" || $2 == "lvm" || $2 == "crypt" || $2 == "raid1" \
               || $2 == "raid0" || $2 == "raid5" || $2 == "raid10" {print $1}'
}

dev_attr() { blkid -o value -s "$2" "$1" 2>/dev/null || true; }
dev_size() { lsblk -dno SIZE "$1" 2>/dev/null | xargs || echo "?"; }

# btrfs installs put the root in a subvolume, usually @.
btrfs_subvol_opt() {
    local dev=$1 probe rc=""
    [[ $(dev_attr "$dev" TYPE) == btrfs ]] || { echo ""; return 0; }
    probe=$(mktemp -d)
    if mount -o ro "$dev" "$probe" 2>/dev/null; then
        [[ -d ${probe}/@/etc ]] && rc="subvol=@"
        umount "$probe" 2>/dev/null || true
    fi
    rmdir "$probe" 2>/dev/null || true
    echo "$rc"
}

# Mount read-only somewhere temporary and see whether it looks like a Linux root.
probe_root() {
    local dev=$1 probe opts name="" found=1
    opts=$(btrfs_subvol_opt "$dev")
    probe=$(mktemp -d)
    if mount -o "ro${opts:+,$opts}" "$dev" "$probe" 2>/dev/null; then
        if [[ -f ${probe}/etc/os-release && -d ${probe}/boot && -d ${probe}/etc/apt ]]; then
            name=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' "${probe}/etc/os-release")
            found=0
        fi
        umount "$probe" 2>/dev/null || true
    fi
    rmdir "$probe" 2>/dev/null || true
    printf '%s' "${name:-Linux}"
    return $found
}

choose_root() {
    step "Looking for installed systems"

    if [[ -n $OPT_ROOT ]]; then
        [[ -b $OPT_ROOT ]] || die "${OPT_ROOT} is not a block device."
        ROOT_DEV=$OPT_ROOT
        OS_NAME=$(probe_root "$ROOT_DEV") \
            || warn "${ROOT_DEV} does not look like a Debian/Ubuntu root, using it anyway."
        info "Using ${ROOT_DEV} (${OS_NAME})"
        return 0
    fi

    local devs=() names=() dev name
    while IFS= read -r dev; do
        [[ -b $dev ]] || continue
        case "$(dev_attr "$dev" TYPE)" in
            ""|swap|vfat|iso9660|squashfs|crypto_LUKS|LVM2_member|linux_raid_member) continue ;;
        esac
        if name=$(probe_root "$dev"); then
            devs+=("$dev"); names+=("$name")
            info "$(printf '%-22s %-8s %s' "$dev" "$(dev_size "$dev")" "$name")"
        fi
    done < <(list_block_devices)

    if (( ${#devs[@]} == 0 )); then
        err "No Ubuntu/Debian installation found."
        printf '\n'
        lsblk -o NAME,SIZE,FSTYPE,TYPE,LABEL,MOUNTPOINTS
        printf '\n'
        die "If your root is on LVM or LUKS, unlock it first, or pass --root DEVICE."
    fi

    if (( ${#devs[@]} == 1 )); then
        ROOT_DEV=${devs[0]}; OS_NAME=${names[0]}
        info "Only one candidate — selecting ${ROOT_DEV}"
        return 0
    fi

    printf '\n'
    local i
    for i in "${!devs[@]}"; do
        printf '   %s%2d)%s %-22s %-8s %s\n' "$C_BOLD" "$((i+1))" "$C_RESET" \
               "${devs[$i]}" "$(dev_size "${devs[$i]}")" "${names[$i]}"
    done
    printf '\n'

    local choice
    while :; do
        ask "Which installation do you want to repair? [1-${#devs[@]}]:" choice
        [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devs[@]} )) && break
        warn "Enter a number between 1 and ${#devs[@]}."
    done
    ROOT_DEV=${devs[$((choice-1))]}
    OS_NAME=${names[$((choice-1))]}
    info "Selected ${ROOT_DEV} (${OS_NAME})"
    return 0
}

mount_root() {
    step "Mounting the installed system"

    findmnt -rno SOURCE | grep -qx "$ROOT_DEV" \
        && warn "${ROOT_DEV} is already mounted somewhere else; unmount it if this fails."

    mkdir -p "$MNT"
    CLEANUP_ARMED=1

    ROOT_FS=$(dev_attr "$ROOT_DEV" TYPE)
    ROOT_OPTS=$(btrfs_subvol_opt "$ROOT_DEV")

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "mounting ${ROOT_DEV} (${ROOT_FS}${ROOT_OPTS:+, $ROOT_OPTS}) READ-ONLY to inspect it"
        # Read-only is enough to read fstab, and cannot damage anything.
        mount -o "ro${ROOT_OPTS:+,$ROOT_OPTS}" "$ROOT_DEV" "$MNT" \
            || die "Could not mount ${ROOT_DEV} read-only."
        return 0
    fi

    mount ${ROOT_OPTS:+-o "$ROOT_OPTS"} "$ROOT_DEV" "$MNT" \
        || die "Could not mount ${ROOT_DEV}. The filesystem may need fsck: fsck -f ${ROOT_DEV}"

    info "Mounted ${ROOT_DEV}${ROOT_OPTS:+ (${ROOT_OPTS})} at ${MNT}"
    [[ -f ${MNT}/etc/os-release ]] || die "${ROOT_DEV} has no /etc/os-release — wrong partition."
    return 0
}

# Turn UUID=/LABEL=/PARTUUID= from fstab into a real device node.
resolve_spec() {
    local spec=$1
    case $spec in
        /dev/*) [[ -b $spec ]] && printf '%s' "$spec" ;;
        UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
            command -v findfs >/dev/null && findfs "$spec" 2>/dev/null || true ;;
    esac
    # An unresolvable spec is normal (unplugged disk); never let it abort the run.
    return 0
}

# Read the installed system's own fstab — far more reliable than asking a human.
discover_from_fstab() {
    step "Reading the installed system's fstab"

    local fstab=${MNT}/etc/fstab
    [[ -f $fstab ]] || { warn "No /etc/fstab found."; return 0; }

    local spec mp rest resolved
    while read -r spec mp rest; do
        [[ $spec == \#* || -z $spec ]] && continue
        case $mp in
            /boot)
                resolved=$(resolve_spec "$spec")
                [[ -n $resolved ]] && { BOOT_DEV=$resolved; info "fstab: /boot → ${BOOT_DEV}"; } \
                                   || warn "fstab lists /boot as ${spec}, which does not resolve." ;;
            /boot/efi)
                resolved=$(resolve_spec "$spec")
                [[ -n $resolved ]] && { ESP_DEV=$resolved; info "fstab: /boot/efi → ${ESP_DEV}"; } \
                                   || warn "fstab lists /boot/efi as ${spec}, which does not resolve." ;;
        esac
    done < "$fstab"

    [[ -z $BOOT_DEV && -z $ESP_DEV ]] && skip "fstab lists no separate /boot or ESP."
    return 0
}

is_esp() {
    local dev=$1 ptype fs
    ptype=$(lsblk -dno PARTTYPE "$dev" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fs=$(dev_attr "$dev" TYPE)
    [[ $ptype == "$ESP_GUID" || $ptype == 0xef ]] && [[ $fs == vfat ]]
}

find_esp() {
    [[ $FW_MODE == uefi ]] || return 0
    step "Locating the EFI System Partition"

    if [[ -n $OPT_ESP ]]; then
        [[ -b $OPT_ESP ]] || die "${OPT_ESP} is not a block device."
        ESP_DEV=$OPT_ESP
        is_esp "$ESP_DEV" || warn "${ESP_DEV} is not flagged as an ESP — continuing because you asked."
        info "Using ${ESP_DEV}"
        return 0
    fi

    if [[ -n $ESP_DEV ]]; then
        is_esp "$ESP_DEV" || warn "${ESP_DEV} (from fstab) is not flagged as an ESP."
        return 0
    fi

    local candidates=() dev root_disk
    root_disk=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null | head -1 || true)
    while IFS= read -r dev; do
        is_esp "$dev" && candidates+=("$dev")
    done < <(list_block_devices)

    if (( ${#candidates[@]} == 0 )); then
        err "No EFI System Partition found on any disk."
        die "Create one (100–512 MB, FAT32, 'esp' flag) or pass --esp DEVICE."
    fi

    # Prefer an ESP on the same physical disk as the root filesystem.
    if [[ -n $root_disk ]]; then
        for dev in "${candidates[@]}"; do
            if [[ $(lsblk -no pkname "$dev" 2>/dev/null | head -1) == "$root_disk" ]]; then
                ESP_DEV=$dev
                info "Found ${ESP_DEV} on the same disk as root (/dev/${root_disk})."
                return 0
            fi
        done
    fi

    if (( ${#candidates[@]} == 1 )); then
        ESP_DEV=${candidates[0]}
        info "Found ${ESP_DEV}"
        warn "This ESP is on a different disk than your root filesystem."
        return 0
    fi

    printf '\n'
    local i
    for i in "${!candidates[@]}"; do
        printf '   %s%2d)%s %-22s %-8s\n' "$C_BOLD" "$((i+1))" "$C_RESET" \
               "${candidates[$i]}" "$(dev_size "${candidates[$i]}")"
    done
    printf '\n'
    local choice
    while :; do
        ask "Which EFI partition? [1-${#candidates[@]}]:" choice
        [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )) && break
        warn "Enter a number between 1 and ${#candidates[@]}."
    done
    ESP_DEV=${candidates[$((choice-1))]}
    info "Selected ${ESP_DEV}"
    return 0
}

find_bios_disk() {
    [[ $FW_MODE == bios ]] || return 0
    step "Choosing the disk for the BIOS bootloader"

    if [[ -n $OPT_BIOS_DISK ]]; then
        [[ -b $OPT_BIOS_DISK ]] || die "${OPT_BIOS_DISK} is not a block device."
        BIOS_DISK=$OPT_BIOS_DISK
    else
        local pk; pk=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null | head -1 || true)
        [[ -n $pk ]] || die "Could not determine the disk holding ${ROOT_DEV}. Pass --bios /dev/sdX."
        BIOS_DISK=/dev/$pk
    fi
    info "GRUB will be written to the MBR of ${BIOS_DISK}"

    if [[ $(lsblk -dno PTTYPE "$BIOS_DISK" 2>/dev/null) == gpt ]]; then
        local has_bboot=0 d
        while IFS= read -r d; do
            [[ $(lsblk -dno PARTTYPE "$d" 2>/dev/null) == 21686148-6449-6e6f-744e-656564454649 ]] && has_bboot=1
        done < <(lsblk -rno PATH,TYPE "$BIOS_DISK" | awk '$2=="part"{print $1}')
        (( has_bboot )) || warn "${BIOS_DISK} is GPT with no BIOS boot partition. \
grub-install will likely fail; you need a 1 MB unformatted partition with the bios_grub flag."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Chroot preparation
# ---------------------------------------------------------------------------
mount_supporting_filesystems() {
    step "Preparing the chroot"

    if [[ -n $BOOT_DEV ]]; then
        run mkdir -p "${MNT}/boot"
        run mount "$BOOT_DEV" "${MNT}/boot" || die "Could not mount ${BOOT_DEV} at ${MNT}/boot"
        info "Mounted /boot from ${BOOT_DEV}"
    fi

    if [[ $FW_MODE == uefi ]]; then
        findmnt -rno SOURCE | grep -qx "$ESP_DEV" && run umount "$ESP_DEV" 2>/dev/null || true
        run mkdir -p "${MNT}/boot/efi"
        run mount "$ESP_DEV" "${MNT}/boot/efi" || die "Could not mount ${ESP_DEV} at ${MNT}/boot/efi"
        info "Mounted the ESP from ${ESP_DEV}"
    fi

    [[ $DRY_RUN -eq 1 ]] && { skip "would bind-mount /dev /proc /sys /run"; return 0; }

    # rbind, not bind: a plain bind of /sys leaves efivars behind, and then
    # grub-install cannot register a firmware boot entry. rslave stops any
    # unmount inside the chroot from propagating back to the live system.
    local src
    for src in dev sys run; do
        mount --rbind "/$src" "${MNT}/${src}"
        mount --make-rslave "${MNT}/${src}" 2>/dev/null || true
    done
    mount -t proc proc "${MNT}/proc"
    info "Bind-mounted /dev, /sys, /run and mounted /proc"

    if [[ $FW_MODE == uefi ]]; then
        if [[ -d ${MNT}/sys/firmware/efi/efivars ]] && \
           [[ -z $(ls -A "${MNT}/sys/firmware/efi/efivars" 2>/dev/null) ]]; then
            mount -t efivarfs efivarfs "${MNT}/sys/firmware/efi/efivars" 2>/dev/null || true
        fi
        [[ -n $(ls -A "${MNT}/sys/firmware/efi/efivars" 2>/dev/null) ]] \
            && info "efivars visible inside the chroot" \
            || warn "efivars not visible in the chroot; NVRAM entries will not be written."
    fi

    # The installed resolv.conf is normally a symlink into /run. Replacing it
    # with a plain file leaves the repaired system with broken DNS, so the
    # original is saved and restored during cleanup.
    if [[ -e ${MNT}/etc/resolv.conf || -L ${MNT}/etc/resolv.conf ]]; then
        mv "${MNT}/etc/resolv.conf" "${MNT}/etc/resolv.conf.grub-repair"
    fi
    cp -L /etc/resolv.conf "${MNT}/etc/resolv.conf" 2>/dev/null || true
    RESOLV_SAVED=1
    return 0
}

backup_current_state() {
    [[ $DRY_RUN -eq 1 ]] && { skip "would back up the current EFI directory"; return 0; }
    step "Backing up the current boot configuration"

    BACKUP_FILE="${MNT}/root/grub-repair-backup-${STAMP}.tar.gz"
    local items=()
    [[ -d ${MNT}/boot/efi/EFI ]] && items+=(boot/efi/EFI)
    [[ -f ${MNT}/boot/grub/grub.cfg ]] && items+=(boot/grub/grub.cfg)
    [[ -f ${MNT}/etc/default/grub ]] && items+=(etc/default/grub)

    if (( ${#items[@]} )); then
        if tar -czf "$BACKUP_FILE" -C "$MNT" "${items[@]}" 2>/dev/null; then
            info "Saved to ${BACKUP_FILE#"$MNT"} on the repaired system"
        else
            BACKUP_FILE=""; warn "Backup failed; continuing anyway."
        fi
    else
        BACKUP_FILE=""; skip "Nothing to back up (EFI directory is empty)."
    fi

    if [[ $FW_MODE == uefi ]] && command -v efibootmgr >/dev/null; then
        printf '\n'
        efibootmgr 2>/dev/null | sed 's/^/    /' || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
show_plan() {
    banner "Repair plan"
    printf '  %-18s %s\n' "System:"     "$OS_NAME"
    printf '  %-18s %s (%s%s)\n' "Root:" "$ROOT_DEV" "$ROOT_FS" "${ROOT_OPTS:+, $ROOT_OPTS}"
    [[ -n $BOOT_DEV ]] && printf '  %-18s %s\n' "Separate /boot:" "$BOOT_DEV"
    printf '  %-18s %s\n' "Firmware:"   "${FW_MODE^^}"

    if [[ $FW_MODE == uefi ]]; then
        printf '  %-18s %s\n' "ESP:"         "$ESP_DEV"
        printf '  %-18s %s\n' "GRUB target:" "$EFI_TARGET"
        printf '  %-18s %s\n' "Secure Boot:" "$SECURE_BOOT"
        printf '  %-18s %s\n' "NVRAM entry:" "$([[ $DO_NVRAM -eq 1 ]] && echo 'yes' || echo 'no (--no-nvram)')"
        printf '  %-18s %s\n' "Fallback:"    "$([[ $DO_REMOVABLE -eq 1 ]] && echo "yes (EFI/BOOT/${FALLBACK_NAME})" || echo 'no')"
    else
        printf '  %-18s %s\n' "Target disk:" "$BIOS_DISK"
    fi
    printf '  %-18s %s\n' "os-prober:"  "$([[ $DO_OSPROBER -eq 1 ]] && echo 'enable' || echo 'leave as is')"
    printf '  %-18s %s\n' "initramfs:"  "$([[ $DO_INITRAMFS -eq 1 ]] && echo 'rebuild' || echo 'skip')"
    printf '\n'

    if [[ $SECURE_BOOT == enabled && $FW_MODE == uefi ]]; then
        warn "Secure Boot is on. The install needs shim-signed and grub-efi-*-signed; \
if they are missing, add --allow-apt (with a network connection) or turn Secure Boot off in firmware."
    fi

    [[ $DRY_RUN -eq 1 ]] && return 0
    confirm "Proceed with the repair?" || { info "Aborted at your request."; exit 0; }
    return 0
}

# ---------------------------------------------------------------------------
# The actual repair, executed inside the chroot
# ---------------------------------------------------------------------------
write_inner_script() {
cat > "${MNT}${INNER}" <<'INNER_EOF'
#!/bin/bash
# Generated by repair-grub.sh — safe to delete.
set -uo pipefail
FAILS=0

say()  { printf '  \033[32m•\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

command -v grub-install >/dev/null || { bad "grub-install is not installed."; exit 9; }
say "GRUB version: $(grub-install --version 2>/dev/null | head -1)"

# --- sanity: is there anything to boot? ------------------------------------
kernels=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)
if [ "$kernels" -eq 0 ]; then
    bad "No kernel in /boot. GRUB will install but the system still will not boot."
    note "Fix with: apt-get install --reinstall linux-image-generic"
else
    say "Found ${kernels} kernel(s) in /boot"
fi

avail=$(df -Pk /boot | awk 'NR==2 {print $4}')
if [ "${avail:-0}" -lt 102400 ]; then
    note "/boot has only $((avail / 1024)) MB free — update-grub or initramfs may fail."
    note "Free space with: apt-get autoremove --purge"
fi

# --- optional package repair -----------------------------------------------
if [ "${ALLOW_APT:-0}" = "1" ]; then
    say "Refreshing package lists…"
    apt-get update -qq || note "apt-get update failed (no network?)"
    if [ "${FW_MODE}" = "uefi" ]; then
        case "${EFI_TARGET}" in
            x86_64-efi) pkgs="grub-efi-amd64 grub-efi-amd64-signed shim-signed" ;;
            arm64-efi)  pkgs="grub-efi-arm64 grub-efi-arm64-signed shim-signed" ;;
            *)          pkgs="grub-efi" ;;
        esac
    else
        pkgs="grub-pc"
    fi
    say "Ensuring packages: ${pkgs}"
    apt-get install -y -qq --reinstall $pkgs || note "Package install failed; continuing."
fi

# --- os-prober -------------------------------------------------------------
if [ "${DO_OSPROBER:-0}" = "1" ]; then
    if ! command -v os-prober >/dev/null; then
        if [ "${ALLOW_APT:-0}" = "1" ]; then
            apt-get install -y -qq os-prober >/dev/null 2>&1 || note "Could not install os-prober."
        else
            note "os-prober is not installed; other systems will not be detected."
            note "Re-run with --allow-apt (needs a network connection) to install it."
        fi
    fi
    if grep -q '^ *GRUB_DISABLE_OS_PROBER=' /etc/default/grub 2>/dev/null; then
        sed -i 's/^ *GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    else
        printf '\nGRUB_DISABLE_OS_PROBER=false\n' >> /etc/default/grub
    fi
    say "os-prober enabled — other operating systems will be added to the menu."
fi

# --- install the bootloader -------------------------------------------------
if [ "${FW_MODE}" = "uefi" ]; then
    set -- --target="${EFI_TARGET}" --efi-directory=/boot/efi \
           --bootloader-id="${BOOTLOADER_ID}" --recheck
    [ "${DO_NVRAM}" = "0" ] && set -- "$@" --no-nvram

    say "Installing GRUB for UEFI…"
    if grub-install "$@"; then
        say "GRUB installed to /boot/efi/EFI/${BOOTLOADER_ID}"
    else
        bad "grub-install failed."
        note "Common fix: re-run with --no-nvram --removable"
    fi

    if [ "${DO_REMOVABLE:-0}" = "1" ]; then
        say "Writing the removable fallback path…"
        grub-install --target="${EFI_TARGET}" --efi-directory=/boot/efi \
                     --removable --recheck \
            && say "Fallback written to /boot/efi/EFI/BOOT/${FALLBACK_NAME}" \
            || bad "Fallback install failed."
    fi
else
    say "Installing GRUB to the MBR of ${BIOS_DISK}…"
    grub-install --target=i386-pc --recheck "${BIOS_DISK}" \
        && say "GRUB installed to ${BIOS_DISK}" \
        || bad "grub-install failed."
fi

# --- initramfs --------------------------------------------------------------
if [ "${DO_INITRAMFS:-0}" = "1" ] && command -v update-initramfs >/dev/null; then
    say "Rebuilding initramfs for all kernels…"
    update-initramfs -u -k all && say "initramfs rebuilt." || bad "update-initramfs failed."
fi

# --- rebuild the menu -------------------------------------------------------
say "Rebuilding the GRUB menu…"
if update-grub; then
    entries=$(grep -c "^menuentry" /boot/grub/grub.cfg 2>/dev/null || echo 0)
    say "grub.cfg written with ${entries} menu entries."
else
    bad "update-grub failed."
fi

if [ "${FW_MODE}" = "uefi" ] && command -v efibootmgr >/dev/null; then
    printf '\n'
    efibootmgr -v 2>/dev/null | sed 's/^/    /' || note "efibootmgr could not read NVRAM."
fi

exit "$FAILS"
INNER_EOF
chmod 0755 "${MNT}${INNER}"
}

run_repair() {
    banner "Repairing GRUB"

    if [[ $DRY_RUN -eq 1 ]]; then
        skip "would chroot into ${MNT} and run grub-install + update-grub"
        return 0
    fi

    write_inner_script

    local rc=0
    chroot "$MNT" /usr/bin/env \
        FW_MODE="$FW_MODE" \
        EFI_TARGET="$EFI_TARGET" \
        FALLBACK_NAME="$FALLBACK_NAME" \
        BOOTLOADER_ID="ubuntu" \
        BIOS_DISK="$BIOS_DISK" \
        DO_NVRAM="$DO_NVRAM" \
        DO_REMOVABLE="$DO_REMOVABLE" \
        DO_OSPROBER="$DO_OSPROBER" \
        DO_INITRAMFS="$DO_INITRAMFS" \
        ALLOW_APT="$ALLOW_APT" \
        /bin/bash "$INNER" || rc=$?

    (( rc == 0 )) && info "Chroot stage completed with no errors." \
                  || warn "Chroot stage reported ${rc} problem(s) — see above."
    return 0
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify() {
    [[ $DRY_RUN -eq 1 ]] && { skip "Skipping verification in dry-run mode."; return 0; }
    step "Verifying the result"

    local fails=0

    if [[ -f ${MNT}/boot/grub/grub.cfg ]]; then
        local n; n=$(grep -c '^menuentry' "${MNT}/boot/grub/grub.cfg" 2>/dev/null || echo 0)
        (( n > 0 )) && info "grub.cfg present with ${n} entries" \
                    || { err "grub.cfg has no menu entries"; fails=$((fails+1)); }
    else
        err "/boot/grub/grub.cfg is missing"; fails=$((fails+1))
    fi

    if compgen -G "${MNT}/boot/vmlinuz-*" >/dev/null; then
        info "Kernel image present in /boot"
    else
        err "No kernel in /boot — the system still will not boot"; fails=$((fails+1))
    fi

    if [[ $FW_MODE == uefi ]]; then
        if [[ -f ${MNT}/boot/efi/EFI/ubuntu/${GRUB_EFI_NAME} ]]; then
            info "EFI/ubuntu/${GRUB_EFI_NAME} written to the ESP"
        else
            err "EFI/ubuntu/${GRUB_EFI_NAME} is missing from the ESP"; fails=$((fails+1))
        fi

        [[ -f ${MNT}/boot/efi/EFI/BOOT/${FALLBACK_NAME} ]] \
            && info "Fallback EFI/BOOT/${FALLBACK_NAME} present"

        if [[ $DO_NVRAM -eq 1 ]] && command -v efibootmgr >/dev/null; then
            efibootmgr 2>/dev/null | grep -qi 'ubuntu' \
                && info "Firmware boot entry for Ubuntu exists" \
                || warn "No Ubuntu entry in firmware NVRAM. Re-run with --removable, \
or add the entry from your firmware's boot menu."
        fi
    else
        info "BIOS install — verify by rebooting; there is nothing on disk to inspect."
    fi

    (( fails == 0 )) && return 0
    err "${fails} verification check(s) failed."
    return 1
}

summary() {
    banner "Repair finished"

    [[ -n $BACKUP_FILE ]] && printf '  Backup of the previous config: %s\n' "${BACKUP_FILE#"$MNT"}"
    [[ -n $LOG_FILE ]] && printf '  Log: %s\n' "$LOG_FILE"

    if (( ${#WARNINGS[@]} )); then
        printf '\n  %sWarnings (%d)%s\n' "$C_BOLD$C_YEL" "${#WARNINGS[@]}" "$C_RESET"
        local w; for w in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "$C_YEL" "$C_RESET" "$w"; done
    fi

    printf '\n  %sIf it still does not boot%s\n' "$C_BOLD" "$C_RESET"
    printf '    • Firmware ignoring NVRAM  → re-run with --removable\n'
    printf '    • Secure Boot errors       → disable Secure Boot, or use --allow-apt\n'
    printf '    • Windows missing from menu→ re-run with --os-prober\n'
    printf '    • Wrong partition chosen   → re-run with --root /dev/sdXY\n'
    printf '\n'
}

offer_reboot() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    printf '  %sRemove the Live USB before the machine boots again.%s\n\n' "$C_DIM" "$C_RESET"
    if confirm "Reboot now?"; then
        info "Rebooting in 3 seconds — pull the USB out."
        sync; sleep 3
        systemctl reboot 2>/dev/null || reboot
    else
        info "Not rebooting. Everything is unmounted; reboot whenever you are ready."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    setup_colors
    parse_args "$@"
    setup_colors
    preflight

    if [[ $DRY_RUN -eq 0 ]]; then
        LOG_FILE="/tmp/grub-repair-${STAMP}.log"
        : > "$LOG_FILE"
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi

    banner "Ubuntu GRUB Repair Utility  (v${SCRIPT_VERSION})"
    [[ $DRY_RUN -eq 1 ]] && printf '  %sDRY RUN — nothing will be changed.%s\n' "$C_BOLD$C_YEL" "$C_RESET"

    detect_firmware
    activate_stacked_devices
    choose_root
    mount_root
    discover_from_fstab
    find_esp
    find_bios_disk
    show_plan
    mount_supporting_filesystems
    backup_current_state
    run_repair

    local rc=0
    verify || rc=1
    summary
    (( rc == 0 )) && offer_reboot
    exit "$rc"
}

main "$@"
