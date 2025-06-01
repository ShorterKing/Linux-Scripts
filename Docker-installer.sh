#!/bin/bash

# Exit on any error
set -e

echo "Updating package list..."
sudo apt update

echo "Installing dependencies..."
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

echo "Adding Docker GPG key..."
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "Adding Docker repository..."
# Assumes Debian 12 'bookworm' for Parrot OS 6.3+. Replace 'bookworm' with your codename if different (e.g., 'bullseye' for Debian 11).
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" | sudo tee /etc/apt/sources.list.d/docker.list

echo "Updating package list again..."
sudo apt update

echo "Installing Docker..."
sudo apt install -y docker-ce docker-ce-cli containerd.io

echo "Starting and enabling Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

echo "Adding user to docker group..."
sudo usermod -aG docker $USER

echo "Installing Docker Compose..."
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

echo "Testing Docker installation..."
docker --version

echo "Testing Docker Compose installation..."
docker-compose --version

echo "Docker and Docker Compose installed successfully."
echo "Please log out and log back in to use Docker without sudo."
