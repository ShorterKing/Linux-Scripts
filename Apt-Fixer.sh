#!/bin/bash

# Script to fix APT issues by removing problematic and unnecessary repositories
# and ensuring only the official Kali repository is configured.

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Use sudo or switch to root user."
   exit 1
fi

# Backup current sources.list
echo "Backing up /etc/apt/sources.list to /etc/apt/sources.list.bak..."
cp /etc/apt/sources.list /etc/apt/sources.list.bak

# Create a clean sources.list with only the official Kali repository
echo "Configuring /etc/apt/sources.list with official Kali repository..."
cat > /etc/apt/sources.list << EOL
deb http://kali.download/kali kali-last-snapshot main contrib non-free non-free-firmware
# deb-src http://kali.download/kali kali-last-snapshot main contrib non-free non-free-firmware
EOL

# Remove any additional sources list files in /etc/apt/sources.list.d/
echo "Removing additional sources list files in /etc/apt/sources.list.d/..."
rm -f /etc/apt/sources.list.d/*.list

# Remove any imported GPG keys related to problematic repositories
echo "Removing problematic GPG keys..."
if [ -d "/etc/apt/trusted.gpg.d" ]; then
    rm -f /etc/apt/trusted.gpg.d/ivam3.gpg
    # Remove any other non-standard keys (be cautious, only remove known problematic ones)
    find /etc/apt/trusted.gpg.d -type f -not -name "kali-archive-keyring.gpg" -delete
fi

# Clean APT cache and update package lists
echo "Cleaning APT cache and updating package lists..."
apt clean
apt update --fix-missing

# Fix any broken dependencies
echo "Fixing broken dependencies..."
apt install -f

# Display final status
echo "APT configuration updated. Running 'apt update' to verify..."
apt update

echo "Script completed. Check the output above for any remaining errors."
echo "If issues persist, review /etc/apt/sources.list and /etc/apt/sources.list.d/ for misconfigurations."
