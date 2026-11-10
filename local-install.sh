#!/usr/bin/env bash
# local-install.sh — Installs script + service directly on the local Proxmox server.
# Run as root on the Proxmox machine.
set -euo pipefail

LOCAL_SCRIPT="/usr/local/sbin/proxmox-autoshutdown.sh"
LOCAL_SERVICE="/etc/systemd/system/proxmox-autoshutdown.service"
DEPLOY_DIR="/opt/proxmox-autoshutdown"

echo "[1/4] Copying script..."
cp proxmox-autoshutdown.sh "$LOCAL_SCRIPT"
chmod 755 "$LOCAL_SCRIPT"

echo "[2/4] Copying service..."
cp proxmox-autoshutdown.service "$LOCAL_SERVICE"

echo "[3/4] Copying deploy files..."
mkdir -p "$DEPLOY_DIR"
cp reload.sh "$DEPLOY_DIR/reload.sh"
chmod 755 "$DEPLOY_DIR/reload.sh"

echo "[4/4] Enabling services..."
systemctl daemon-reload
systemctl enable --now proxmox-autoshutdown.service
systemctl enable --now reload.timer

echo ""
echo "Installazione completata!"
echo "  Script: $LOCAL_SCRIPT"
echo "  Servizio: sudo systemctl status proxmox-autoshutdown"
echo "  Log:      sudo journalctl -u proxmox-autoshutdown -f"
echo "  Deploy:   ./remote-deploy.sh"
echo "  Lock:     make lock"
echo "  Unlock:   make unlock"
