#!/usr/bin/env bash
# remote-deploy.sh — Push script + service + timer sul server Proxmox.
set -euo pipefail

SERVER="${1:-hermes@192.168.1.85}"

echo "▸ Deploy verso ${SERVER}"

scp -o ConnectTimeout=5 \
    proxmox-autoshutdown.sh \
    proxmox-autoshutdown.service \
    reload.sh \
    reload.timer \
    reload.service \
    "$SERVER:/tmp/"

ssh "$SERVER" '
set -e

echo "[1/5] Script principale..."
sudo cp /tmp/proxmox-autoshutdown.sh /usr/local/sbin/
sudo chmod 755 /usr/local/sbin/proxmox-autoshutdown.sh

echo "[2/5] Service principale..."
sudo cp /tmp/proxmox-autoshutdown.service /etc/systemd/system/

echo "[3/5] Script deploy..."
sudo cp /tmp/reload.sh /opt/proxmox-autoshutdown/reload.sh
chmod 755 /opt/proxmox-autoshutdown/reload.sh

echo "[4/5] Timer + service..."
sudo cp /tmp/reload.timer /etc/systemd/system/
sudo cp /tmp/reload.service /etc/systemd/system/

echo "[5/5] Reload & verifica..."
sudo systemctl daemon-reload
sudo systemctl enable --now proxmox-autoshutdown.service
sudo systemctl enable --now reload.timer

if sudo systemctl is-active --quiet proxmox-autoshutdown.service; then
    echo "  ✓ proxmox-autoshutdown: active"
else
    echo "  ✗ proxmox-autoshutdown: inactive"
fi
if sudo systemctl is-active --quiet reload.timer; then
    echo "  ✓ reload.timer: active"
else
    echo "  ✗ reload.timer: inactive"
fi

cd /opt/proxmox-autoshutdown
git add -A
git commit -m "Deploy via remote-deploy.sh on $(date +%F)" 2>/dev/null || true
git push origin main 2>/dev/null || echo "⚠ Push saltato"

rm -f /tmp/proxmox-autoshutdown.sh /tmp/proxmox-autoshutdown.service
rm -f /tmp/reload.sh /tmp/reload.timer /tmp/reload.service

echo "✅ Completa!"
'
