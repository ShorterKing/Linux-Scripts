#!/bin/bash

# Update the package list
sudo apt update

# Install zsh, zsh-autosuggestions, zsh-syntax-highlighting, git, and dos2unix
sudo apt install -y zsh zsh-autosuggestions zsh-syntax-highlighting git dos2unix

# Clone zsh-autocomplete to /usr/share/zsh-autocomplete
sudo git clone https://github.com/marlonrichert/zsh-autocomplete.git /usr/share/zsh-autocomplete

# Backup existing .zshrc if it exists
if [ -f ~/.zshrc ]; then
    mv ~/.zshrc ~/.zshrc.backup
    echo "Existing .zshrc backed up to ~/.zshrc.backup"
fi

# Download the .zshrc file from the provided URL
curl -o ~/.zshrc https://raw.githubusercontent.com/ShorterKing/Linux-Scripts/refs/heads/main/zshrc.txt

# Convert .zshrc file from DOS to Unix format
dos2unix ~/.zshrc

# Inform the user
echo "Zsh has been set up with the downloaded .zshrc."
echo "Note: Ensure your .zshrc sources the autocomplete plugin from /usr/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
echo "To set zsh as your default shell, run: chsh -s \$(which zsh)"
echo "Then, log out and log back in for the change to take effect."
