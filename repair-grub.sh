#!/bin/bash

set -e

echo "======================================"
echo "      Ubuntu GRUB Repair Utility"
echo "======================================"
echo

# Must be root
if [ "$EUID" -ne 0 ]; then
    echo "[!] Run this script with sudo:"
    echo "    sudo bash repair-grub.sh"
    exit 1
fi

# Check UEFI mode
if [ ! -d /sys/firmware/efi ]; then
    echo "[!] ERROR: The Live USB was booted in Legacy/BIOS mode."
    echo
    echo "    Reboot and select the UEFI version of your Ubuntu USB."
    exit 1
fi

echo "[+] UEFI boot detected."
echo

echo "[*] Detecting partitions..."
echo

lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,LABEL

echo
echo "======================================"
echo "Select the Ubuntu root partition"
echo "======================================"
echo
read -rp "Ubuntu root partition (example: /dev/sda5): " ROOT_PART

echo
echo "======================================"
echo "Select the EFI System Partition"
echo "======================================"
echo
read -rp "EFI partition (example: /dev/sda1): " EFI_PART

echo

# Basic sanity checks
if [ ! -b "$ROOT_PART" ]; then
    echo "[!] $ROOT_PART is not a valid block device."
    exit 1
fi

if [ ! -b "$EFI_PART" ]; then
    echo "[!] $EFI_PART is not a valid block device."
    exit 1
fi

echo "[+] Root partition: $ROOT_PART"
echo "[+] EFI partition : $EFI_PART"
echo

echo "[*] Checking filesystems..."

ROOT_FS=$(blkid -o value -s TYPE "$ROOT_PART" || true)
EFI_FS=$(blkid -o value -s TYPE "$EFI_PART" || true)

echo "    Root filesystem: ${ROOT_FS:-unknown}"
echo "    EFI filesystem : ${EFI_FS:-unknown}"
echo

if [ "$EFI_FS" != "vfat" ] && [ "$EFI_FS" != "fat32" ]; then
    echo "[!] WARNING: EFI partition does not appear to be FAT32."
    echo "    Detected: ${EFI_FS:-unknown}"
    echo
    read -rp "Continue anyway? [y/N]: " ANSWER

    if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
        echo "[*] Aborted."
        exit 1
    fi
fi

# Clean old mounts if they exist
echo "[*] Preparing /mnt..."

umount -R /mnt 2>/dev/null || true

mkdir -p /mnt
mkdir -p /mnt/boot/efi

echo "[+] Mounting Ubuntu root..."
mount "$ROOT_PART" /mnt

echo "[+] Mounting EFI System Partition..."
mount "$EFI_PART" /mnt/boot/efi

echo
echo "[+] Mounted partitions:"
findmnt /mnt
findmnt /mnt/boot/efi

echo
echo "[*] Checking installed Ubuntu..."

if [ ! -f /mnt/etc/os-release ]; then
    echo "[!] ERROR: $ROOT_PART does not appear to contain an Ubuntu installation."
    echo
    echo "    /etc/os-release was not found."
    exit 1
fi

echo "[+] Ubuntu installation detected."

# Bind mount virtual filesystems
echo
echo "[*] Mounting virtual filesystems..."

mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount --bind /run /mnt/run

echo "[+] Virtual filesystems mounted."

# Copy DNS configuration so networking works inside chroot
if [ -f /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true
fi

echo
echo "======================================"
echo "       Starting GRUB repair"
echo "======================================"
echo

chroot /mnt /bin/bash <<EOF

set -e

echo "[+] Entered installed Ubuntu environment."
echo

echo "[*] Checking EFI mount..."
findmnt /boot/efi

echo
echo "[*] Checking GRUB installation..."
grub-install --version

echo
echo "[*] Installing GRUB for UEFI..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --recheck

echo
echo "[+] GRUB installation completed."

echo
echo "[*] Rebuilding GRUB configuration..."

update-grub

echo
echo "======================================"
echo "        GRUB repair completed"
echo "======================================"
echo

echo "[*] EFI boot entries:"
efibootmgr -v || true

EOF

echo
echo "[*] Leaving mounted environment..."

sync

umount -R /mnt 2>/dev/null || true

echo
echo "======================================"
echo "          Repair Finished"
echo "======================================"
echo
echo "You can now reboot."
echo
read -rp "Reboot now? [y/N]: " REBOOT

if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    echo
    echo "[*] Rebooting..."
    sleep 2
    reboot
else
    echo
    echo "[+] Not rebooting."
    echo "    Remove the Ubuntu USB before rebooting manually."
fi
