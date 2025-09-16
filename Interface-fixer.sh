#!/bin/bash

# Exit on any error
set -e

# Check if interface is provided as an argument
if [ -z "$1" ]; then
  echo "Error: Please provide a network interface (e.g., wlan0) as an argument."
  echo "Usage: $0 <interface>"
  exit 1
fi

INTERFACE="$1"
EXPECTED_IP="192.168.1.1"
GATEWAY="192.168.1.1"
DNS_SERVERS="8.8.8.8 8.8.4.4"

# Validate network interface
if ! ip link show "$INTERFACE" &> /dev/null; then
  echo "Error: Network interface '$INTERFACE' does not exist."
  exit 1
fi

# Step 0: Initial Diagnostic Tests
echo "Running initial diagnostic tests..."
echo "Current interface status:"
ip addr show "$INTERFACE"
echo "Current routing table:"
ip route
echo "Current DNS settings:"
cat /etc/resolv.conf
echo "Checking for running services:"
sudo systemctl status dnsmasq.service 2>/dev/null || echo "DNSMASQ not running."
sudo systemctl status nginx.service 2>/dev/null || echo "Nginx not running."
sudo systemctl status opennds.service 2>/dev/null || echo "openNDS not running."
sudo systemctl status NetworkManager.service 2>/dev/null || echo "NetworkManager not running."
echo "Initial ping tests:"
ping -c 3 "$GATEWAY" &> /dev/null && echo "Ping to $GATEWAY successful." || echo "Ping to $GATEWAY failed."
ping -c 3 8.8.8.8 &> /dev/null && echo "Ping to 8.8.8.8 successful." || echo "Ping to 8.8.8.8 failed."
ping -c 3 google.com &> /dev/null && echo "DNS resolution to google.com successful." || echo "DNS resolution to google.com failed."

# Step 1: Stop and disable all interfering services
echo "Stopping and disabling interfering services..."
for service in dnsmasq nginx opennds; do
  sudo systemctl stop $service.service || echo "$service service already stopped."
  sudo systemctl disable $service.service || echo "$service service already disabled."
done

# Step 2: Remove all residual configurations
echo "Removing residual configurations..."
# DNSMASQ
DNSMASQ_CONF="/etc/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ]; then
  sudo rm -f "$DNSMASQ_CONF" || echo "Failed to remove $DNSMASQ_CONF."
fi
[ -d "/etc/dnsmasq.d" ] && sudo rm -rf /etc/dnsmasq.d || echo "DNSMASQ directory not found."

# Nginx
NGINX_DEFAULT="/etc/nginx/sites-enabled/default"
if [ -f "$NGINX_DEFAULT" ]; then
  if [ -f "$NGINX_DEFAULT.bak" ]; then
    sudo mv "$NGINX_DEFAULT.bak" "$NGINX_DEFAULT"
  else
    sudo rm -f "$NGINX_DEFAULT" || echo "Failed to remove $NGINX_DEFAULT."
  fi
fi
[ -d "/var/log/nginx" ] && sudo rm -rf /var/log/nginx/captiveportal.*.log || echo "No Nginx log files found."
for file in /etc/nginx/snippets/self-signed.conf /etc/nginx/snippets/ssl-params.conf; do
  [ -f "$file" ] && sudo rm -f "$file" || echo "$file not found."
done
[ -d "/etc/nginx/snippets" ] && sudo rmdir --ignore-fail-on-non-empty /etc/nginx/snippets || echo "Snippets directory already removed."
[ -f "/etc/ssl/certs/nginx-selfsigned.crt" ] && sudo rm -f /etc/ssl/certs/nginx-selfsigned.crt || echo "SSL certificate not found."
[ -f "/etc/ssl/private/nginx-selfsigned.key" ] && sudo rm -f /etc/ssl/private/nginx-selfsigned.key || echo "SSL key not found."
[ -f "/etc/nginx/dhparam.pem" ] && sudo rm -f /etc/nginx/dhparam.pem || echo "DH parameters not found."

# openNDS
OPENNDS_CONF="/etc/opennds/opennds.conf"
if [ -f "$OPENNDS_CONF" ]; then
  sudo rm -f "$OPENNDS_CONF" || echo "Failed to remove $OPENNDS_CONF."
fi
[ -d "/etc/opennds" ] && sudo rm -rf /etc/opennds || echo "openNDS directory not found."

# Web root
WEB_ROOT="/var/www/your.domain.com"
[ -d "$WEB_ROOT" ] && sudo rm -rf "$WEB_ROOT" || echo "Web directory not found."

# Step 3: Re-enable NetworkManager
echo "Re-enabling NetworkManager..."
sudo systemctl enable NetworkManager.service || echo "Failed to enable NetworkManager."
sudo systemctl start NetworkManager.service || echo "Failed to start NetworkManager."

# Step 4: Reconnect to WiFi
echo "Scanning for WiFi networks..."
sudo nmcli dev wifi list || echo "Failed to scan WiFi networks."

echo "Please provide your WiFi SSID and password."
read -p "Enter WiFi SSID: " WIFI_SSID
read -s -p "Enter WiFi Password: " WIFI_PASSWORD
echo

if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASSWORD" ]; then
  echo "Connecting to WiFi network '$WIFI_SSID'..."
  sudo nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" ifname "$INTERFACE" || echo "Failed to connect to WiFi. Check SSID and password."
else
  echo "Error: SSID and password are required."
  echo "Manually connect using: sudo nmcli dev wifi connect <SSID> password <PASSWORD> ifname $INTERFACE"
fi

# Step 5: Fix IP address
echo "Fixing IP address for $INTERFACE..."
sudo ip addr flush dev "$INTERFACE"
sudo ip addr add "$EXPECTED_IP/24" dev "$INTERFACE"
echo "$INTERFACE IP set to $EXPECTED_IP."

# Step 6: Ensure interface is up
echo "Ensuring $INTERFACE is up..."
sudo ip link set "$INTERFACE" up

# Step 7: Reset routing table
echo "Resetting routing table..."
sudo ip route flush dev "$INTERFACE"
sudo ip route add default via "$GATEWAY" dev "$INTERFACE" || echo "Failed to set default gateway."
sudo ip route add 192.168.1.0/24 dev "$INTERFACE" scope link src "$EXPECTED_IP"

# Step 8: Restore DNS settings
echo "Restoring DNS settings..."
RESOLV_CONF="/etc/resolv.conf"
if [ -L "$RESOLV_CONF" ]; then
  sudo rm -f "$RESOLV_CONF"
fi
echo "# Restored by ultimate_fix_internet_wlan0.sh" | sudo tee "$RESOLV_CONF" > /dev/null
for dns in $DNS_SERVERS; do
  echo "nameserver $dns" | sudo tee -a "$RESOLV_CONF" > /dev/null
done

# Step 9: Reset iptables and nftables
echo "Resetting iptables and nftables..."
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

if command -v nft > /dev/null; then
  sudo nft flush ruleset || echo "Failed to flush nftables."
fi

if command -v iptables-save > /dev/null; then
  sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || echo "Failed to save iptables rules."
fi

# Step 10: Restart networking
echo "Restarting networking..."
sudo dhclient -r "$INTERFACE" || echo "No DHCP lease to release."
if systemctl is-active --quiet networking; then
  sudo systemctl restart networking || echo "Failed to restart networking service."
fi

# Step 11: Final Diagnostic Tests
echo "Running final diagnostic tests..."
echo "Final interface status:"
ip addr show "$INTERFACE"
echo "Final routing table:"
ip route
echo "Final DNS settings:"
cat /etc/resolv.conf
echo "Final ping tests:"
ping -c 3 "$GATEWAY" &> /dev/null && echo "Ping to $GATEWAY successful." || echo "Ping to $GATEWAY failed."
ping -c 3 8.8.8.8 &> /dev/null && echo "Ping to 8.8.8.8 successful." || echo "Ping to 8.8.8.8 failed."
ping -c 3 google.com &> /dev/null && echo "DNS resolution to google.com successful." || echo "DNS resolution to google.com failed."
echo "Checking for conflicting services:"
sudo netstat -tulnp 2>/dev/null || echo "netstat failed."

echo "Ultimate fix process complete!"
echo "If internet is still not working, try restarting your router or providing the output of the diagnostics above for further help."
