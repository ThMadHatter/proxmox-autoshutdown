#!/bin/bash

# /opt/proxmox-autoshutdown/reload.sh
# Pull dal repo GitHub e, se lo script è cambiato, copia il nuovo script
# e riavvia il servizio systemd.

set -euo pipefail

REPO_DIR="/opt/proxmox-autoshutdown"
SCRIPT_PATH="/usr/local/sbin/proxmox-autoshutdown.sh"
SERVICE_NAME="proxmox-autoshutdown"

cd "$REPO_DIR" || exit 1

# 1. Pull delle ultime modifiche
git fetch origin --quiet
OLD_COMMIT=$(git rev-parse HEAD)
NEW_COMMIT=$(git rev-parse origin/main)

if [[ "$OLD_COMMIT" == "$NEW_COMMIT" ]]; then
    exit 0  # Nessuna modifica, esci
fi

git pull origin main --quiet

# 2. Calcola checksum dello script prima e dopo
BEFORE_SUM=$(md5sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}' || echo "none")
cp "$REPO_DIR/proxmox-autoshutdown.sh" "$SCRIPT_PATH"
AFTER_SUM=$(md5sum "$SCRIPT_PATH" | awk '{print $1}')

# 3. Se lo script è cambiato, aggiorna permessi e riavvia
if [[ "$BEFORE_SUM" != "$AFTER_SUM" ]]; then
    chmod 755 "$SCRIPT_PATH"
    systemctl reload-or-restart "$SERVICE_NAME"
    echo "[$(date '+%F %T')] Script aggiornato e servizio riavviato (commit ${OLD_COMMIT:0:7} -> ${NEW_COMMIT:0:7})"
else
    echo "[$(date '+%F %T']) Script identico, nessun riavvio (commit ${OLD_COMMIT:0:7} -> ${NEW_COMMIT:0:7})"
fi
