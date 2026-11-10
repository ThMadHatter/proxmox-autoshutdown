.SHELL := /bin/bash
.PHONY: help install uninstall lock unlock status reload log-remote log deploy clean

SERVER  = hermes@192.168.1.85
LOCK    = /run/proxmox-autoshutdown.wakelock

## ── Help ─────────────────────────────────────────────
help:
	@echo "========================================================="
	@echo " proxmox-autoshutdown — Makefile"
	@echo "========================================================="
	@echo ""
	@echo "Installazione:"
	@echo "  make install        Installa script + service sul server"
	@echo "  make uninstall      Disinstalla (stop + rimuove)"
	@echo ""
	@echo "Lock / Unlock (impedisce lo shutdown):"
	@echo "  make lock           Crea wakelock — shutdown bloccato"
	@echo "  make unlock         Rimuove wakelock — shutdown riattivato"
	@echo ""
	@echo "Deploy remoto:"
	@echo "  make deploy         Push script + service + timer sul server"
	@echo ""
	@echo "Diagnostica:"
	@echo "  make status         Stato servizio, VM, wakelock"
	@echo "  make log-remote     Ultime 50 righe log servizio"
	@echo "  make log            Log live del servizio (tail -f)"
	@echo "  make log-timer      Ultime 20 righe log timer"
	@echo "  make reload         Forza un reload immediato (per debug)"
	@echo ""
	@echo "Utilità:"
	@echo "  make clean          Pulisce file temporanei"

## ── Installazione ────────────────────────────────────
install:
	@bash remote-deploy.sh $(SERVER)

uninstall:
	sudo systemctl stop --now proxmox-autoshutdown.service 2>/dev/null || true
	sudo rm -f /usr/local/sbin/proxmox-autoshutdown.sh
	sudo rm -f /etc/systemd/system/proxmox-autoshutdown.service
	sudo rm -f /etc/systemd/system/reload.timer
	sudo rm -f /etc/systemd/system/reload.service
	sudo rm -f /opt/proxmox-autoshutdown/reload.sh 2>/dev/null || true
	@rm -f /run/proxmox-autoshutdown.wakelock 2>/dev/null || true
	@echo "Disinstallato."

## ── Lock / Unlock ──────────────────────────────────
lock:
	@ssh $(SERVER) "sudo touch $(LOCK) && echo '🔒 Lock attivo.'"

unlock:
	@ssh $(SERVER) "sudo rm -f $(LOCK) && echo '🔓 Unlock.'"

## ── Status ─────────────────────────────────────────
status:
	@ssh $(SERVER) '
	echo "=== proxmox-autoshutdown ==="
	sudo systemctl is-active proxmox-autoshutdown.service
	sudo systemctl is-active reload.timer
	echo ""
	[ -f /run/proxmox-autoshutdown.wakelock ] && echo "🔒 WAKELock ATTIVO" || echo "🔓 Nessun wakelock"
	echo ""
	/usr/sbin/qm status 100 2>/dev/null || echo "VM100: ???"
	/usr/sbin/qm status 101 2>/dev/null || echo "VM101: ???"
	'

## ── Log ────────────────────────────────────────────
log-remote:
	@ssh $(SERVER) "journalctl -u proxmox-autoshutdown --no-pager -n 50"

log:
	@ssh $(SERVER) "sudo journalctl -u proxmox-autoshutdown -f --no-pager"

log-timer:
	@ssh $(SERVER) "journalctl -u reload.timer --no-pager -n 20"

## ── Reload immediato (per debug) ──────────────────
reload:
	@ssh $(SERVER) "bash -x /opt/proxmox-autoshutdown/reload.sh"

## ── Deploy remoto ──────────────────────────────────
deploy:
	@bash remote-deploy.sh

## ── Cleanup locale ─────────────────────────────────
clean:
	rm -f ./*.new ./*.bak ./*.tmp
