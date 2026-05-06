#!/bin/bash
# HTB Kerberos Time Sync Fix
# Usage: sudo ./kerbfix.sh [dc_ip] [domain] [username] [password]

DC_IP="${1:-10.129.245.56}"
DOMAIN="${2:-PING.HTB}"
USER="${3:-c.roberts}"
PASS="${4:-AssumedBreach123}"
DC_HOST="dc1.${DOMAIN,,}"  # lowercase domain for hostname

echo "[*] Killing VBoxService timesync..."
sudo kill $(pgrep -f "VBoxService") 2>/dev/null
sleep 1

echo "[*] Restarting VBoxService without timesync..."
sudo /usr/sbin/VBoxService --disable-timesync &>/dev/null &
sleep 1

echo "[*] Syncing time to DC ($DC_IP)..."
sudo ntpdate -u "$DC_IP"
sleep 1

echo "[*] Verifying clock is stable..."
T1=$(date +%s)
sleep 3
T2=$(date +%s)
DRIFT=$((T2 - T1 - 3))
if [ ${DRIFT#-} -gt 2 ]; then
    echo "[-] Clock still drifting! Drift: ${DRIFT}s — try running again"
    exit 1
fi
echo "[+] Clock stable"

echo "[*] Getting Kerberos ticket for $USER@$DOMAIN..."
kdestroy 2>/dev/null
echo "$PASS" | kinit "$USER@$DOMAIN"

if klist &>/dev/null; then
    echo "[+] Ticket obtained:"
    klist
else
    echo "[-] kinit failed — check credentials or DNS"
    exit 1
fi

echo "[*] Testing SMB with Kerberos..."
nxc smb "$DC_HOST" -d "${DOMAIN,,}" -u "$USER" -p "$PASS" -k
