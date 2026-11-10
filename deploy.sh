#!/usr/bin/env bash
# deploy.sh — Copia tutti i file sul server Proxmox e configura il servizio.
# Esegui da qualsiasi PC con SSH verso hermes@192.168.1.85.
set -euo pipefail

SERVER="hermes@192.168.1.85"
SCRIPT_NAME="proxmox-autoshutdown.sh"
SERVICE_NAME="proxmox-autoshutdown.service"

echo "▸ Copio files su ${SERVER}..."
scp -o ConnectTimeout=5 \
    "$SCRIPT_NAME" \
    "$SERVICE_NAME" \
    reload.sh \
    reload.timer \
    reload.service \
    "$SERVER:/tmp/"

echo "▸ Deploy sul server..."
ssh "$SERVER" '
set -e
SUDO="sudo"

echo "1/5 Copia script + service..."
$SUDO cp /tmp/proxmox-autoshutdown.sh /usr/local/sbin/
$SUDO chmod 755 /usr/local/sbin/proxmox-autoshutdown.sh
$SUDO cp /tmp/proxmox-autoshutdown.service \
    /etc/systemd/system/proxmox-autoshutdown.service

echo "2/5 Copia files di deploy..."
$SUDO cp /tmp/reload.sh /opt/proxmox-autoshutdown/reload.sh
chmod +x /opt/proxmox-autoshutdown/reload.sh
$SUDO cp /tmp/reload.timer \
    /etc/systemd/system/reload.timer
$SUDO cp /tmp/reload.service \
    /etc/systemd/system/reload.service

echo "3/5 Reload systemd..."
$SUDO systemctl daemon-reload

echo "4/5 Avvio servizi..."
$SUDO systemctl enable --now proxmox-autoshutdown.service
$SUDO systemctl enable --now reload.timer

echo "5/5 Verifica..."
if $SUDO systemctl is-active --quiet proxmox-autoshutdown.service; then
    echo "✓ Servizio: attivo"
else
    echo "⚠  Servizio: NON attivo"
fi
if $SUDO systemctl is-active --quiet reload.timer; then
    echo "✓ Timer: attivo"
else
    echo "⚠  Timer: NON attivo"
fi

# Commit sul repo locale del server
cd /opt/proxmox-autoshutdown
git add -A
git commit -m "Deploy via deploy.sh on $(date +%F)" 2>/dev/null || true
git push origin main 2>/dev/null || echo "⚠  Push git saltato"

echo ""
echo "Pulizia files temporanei..."
rm -f /tmp/proxmox-autoshutdown.sh /tmp/proxmox-autoshutdown.service \
    /tmp/reload.sh /tmp/reload.timer /tmp/reload.service

echo ""
echo "✅ Deploy completato!"
'
