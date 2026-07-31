#!/bin/bash
set -euo pipefail

HUB01_IP="192.168.68.66"
DATA_MOUNT="/data"

echo "=== Bootstrap hub01 ==="

# Ensure /data is mounted
if ! mountpoint -q "$DATA_MOUNT"; then
  echo "ERROR: $DATA_MOUNT is not mounted. Mount the dedicated disk first."
  exit 1
fi
mkdir -p "$DATA_MOUNT/vcluster"

# Install Docker
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  sudo pacman -S --noconfirm docker
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  echo "Docker installed. Log out and back in, then re-run this script."
  exit 0
fi

# Verify current user can use Docker
if ! docker info &> /dev/null; then
  echo "ERROR: Docker daemon is not reachable. Ensure your user is in the 'docker' group and log out/in."
  exit 1
fi

# Install Tailscale
if ! command -v tailscale &> /dev/null; then
  echo "Installing Tailscale..."
  sudo pacman -S --noconfirm tailscale
  sudo systemctl enable --now tailscaled
  echo "Run 'sudo tailscale up' to authenticate."
fi

# Install vCluster CLI
if ! command -v vcluster &> /dev/null; then
  echo "Installing vCluster CLI..."
  curl -L -o /tmp/vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
  sudo install -c -m 0755 /tmp/vcluster /usr/local/bin/vcluster
  rm -f /tmp/vcluster
fi

# Set Docker as vCluster driver
vcluster use driver docker

echo "=== Bootstrap complete ==="
echo "Next steps:"
echo "1. Authenticate Tailscale: sudo tailscale up"
echo "2. Provision vCluster: vcluster create hub01 --values vcluster.yaml"
echo "3. Install Argo CD and Flux CD"
