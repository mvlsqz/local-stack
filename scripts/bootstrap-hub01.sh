#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "$SCRIPT_DIR")
VCLUSTER_NAME="hub01"
VCLUSTER_VOLUME="/vcluster"
VCLUSTER_CONFIG="$REPO_ROOT/vcluster.yaml"

echo "=== Bootstrap hub01 ==="

# Ensure the vCluster volume is mounted
if ! mountpoint -q "$VCLUSTER_VOLUME"; then
  echo "ERROR: $VCLUSTER_VOLUME is not mounted. Mount the dedicated disk first."
  exit 1
fi
mkdir -p "$VCLUSTER_VOLUME"

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
read -r -p "Create vCluster '$VCLUSTER_NAME' now? [y/N] " CREATE_VCLUSTER

if [[ "$CREATE_VCLUSTER" =~ ^[Yy]$ ]]; then
  vcluster create "$VCLUSTER_NAME" --values "$VCLUSTER_CONFIG"
else
  echo "Cluster creation skipped. Run the script again when the host is ready."
fi
