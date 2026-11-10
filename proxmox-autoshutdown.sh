#!/usr/bin/env bash

set -u

# ============================================================
# Configurazione
# ============================================================

VM_GAMING=100
VM_OLLAMA=101

# Timeout di inattivita Ollama:
# 1800 secondi = 10 minuti
OLLAMA_TIMEOUT=600

# Intervallo tra i controlli
CHECK_INTERVAL=10

# Servizio Ollama nella VM101
OLLAMA_SERVICE="ollama.service"

LOCK_FILE="/run/proxmox-autoshutdown.lock"

# ============================================================
# Funzioni
# ============================================================

log() {
    printf '%s - %s\n' "$(date '+%F %T')" "$*"
}

get_vm_status() {
    local vmid="$1"
    local status

    status=$(/usr/sbin/qm status "$vmid" 2>/dev/null | /usr/bin/awk '{print $2}')

    case "$status" in
        running|stopped)
            printf '%s\n' "$status"
            ;;
        *)
            printf '%s\n' "unknown"
            ;;
    esac
}

guest_agent_available() {
    timeout 10 /usr/sbin/qm guest cmd "$VM_OLLAMA" ping >/dev/null 2>&1
}

ollama_has_new_requests() {
    local since_epoch="$1"
    local result

    # Esegue il controllo direttamente dentro VM101 tramite QEMU Guest Agent.
    # Non serve SSH e non serve autenticazione.
    #
    # Il comando interno termina con:
    #   exit 0 = trovata almeno una richiesta
    #   exit 1 = nessuna richiesta
    #
    # qm guest exec restituisce JSON, quindi controlliamo exitcode=0.

    result=$(
        timeout 25 /usr/sbin/qm guest exec "$VM_OLLAMA" \
            --timeout 20 -- \
            /bin/bash -c "
                /usr/bin/journalctl \
                    -u '$OLLAMA_SERVICE' \
                    --since '@$since_epoch' \
                    --no-pager \
                    -o cat 2>/dev/null |
                /usr/bin/grep -Eiq \
                    '(method=(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)|(^|[[:space:]])(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)[[:space:]]|/api/(generate|chat|embed|embeddings|completion|pull|push|create|copy|delete|show|tags|ps|version))'
            " 2>/dev/null
    ) || return 1

    printf '%s\n' "$result" |
        /usr/bin/grep -Eq '"exitcode"[[:space:]]*:[[:space:]]*0'
}

shutdown_host() {
    log "Condizione di spegnimento raggiunta."
    log "Arresto completo del nodo Proxmox."

    /usr/bin/sync
    /usr/bin/systemctl poweroff
}

# ============================================================
# Blocco istanza multipla
# ============================================================

exec 9>"$LOCK_FILE"

if ! /usr/bin/flock -n 9; then
    log "Un'altra istanza dello script e gia attiva."
    exit 1
fi

# ============================================================
# Stato iniziale
# ============================================================

previous_vm100_status=$(get_vm_status "$VM_GAMING")
vm101_status=$(get_vm_status "$VM_OLLAMA")

now=$(date +%s)
last_ollama_activity="$now"
last_journal_scan=$((now - 5))
ollama_monitoring_started=0
guest_agent_warning_shown=0

if [[ "$vm101_status" == "running" ]]; then
    ollama_monitoring_started=1
fi

log "Monitor avviato."
log "VM${VM_GAMING}: ${previous_vm100_status}"
log "VM${VM_OLLAMA}: ${vm101_status}"
log "Timeout Ollama: ${OLLAMA_TIMEOUT} secondi"

if (( ollama_monitoring_started == 1 )); then
    log "VM${VM_OLLAMA} attiva: timeout Ollama avviato."
fi

# ============================================================
# Ciclo principale
# ============================================================

while true; do
    now=$(date +%s)

    vm100_status=$(get_vm_status "$VM_GAMING")
    vm101_status=$(get_vm_status "$VM_OLLAMA")

    # --------------------------------------------------------
    # Condizione 1
    # VM100 passa realmente da running a stopped
    # --------------------------------------------------------

    if [[ "$previous_vm100_status" == "running" &&
          "$vm100_status" == "stopped" ]]; then

        log "VM${VM_GAMING} e passata da running a stopped."
        shutdown_host
        exit 0
    fi

    # Non memorizza unknown, per evitare falsi spegnimenti
    # dovuti a un errore temporaneo di qm.
    if [[ "$vm100_status" == "running" ||
          "$vm100_status" == "stopped" ]]; then
        previous_vm100_status="$vm100_status"
    fi

    # --------------------------------------------------------
    # Condizione 2
    # VM101 senza richieste Ollama per il timeout
    # --------------------------------------------------------

    if [[ "$vm101_status" == "running" ]]; then

        # VM101 e appena stata avviata.
        if (( ollama_monitoring_started == 0 )); then
            ollama_monitoring_started=1
            last_ollama_activity="$now"
            last_journal_scan=$((now - 5))

            log "VM${VM_OLLAMA} avviata."
            log "Monitoraggio richieste Ollama iniziato."
        fi

        if guest_agent_available; then
            guest_agent_warning_shown=0

            if ollama_has_new_requests "$last_journal_scan"; then
                last_ollama_activity="$now"
                log "Rilevata richiesta Ollama. Timeout azzerato."
            fi

            # Sovrapposizione di 2 secondi per non perdere righe
            # generate esattamente tra due controlli.
            last_journal_scan=$((now - 2))
        else
            if (( guest_agent_warning_shown == 0 )); then
                log "QEMU Guest Agent della VM${VM_OLLAMA} non raggiungibile."
                log "Il timeout continua dall'ultima attivita rilevata."
                guest_agent_warning_shown=1
            fi
        fi
    fi

    # Dopo che VM101 e stata rilevata almeno una volta accesa,
    # il timeout continua anche se VM101 viene spenta.
    if (( ollama_monitoring_started == 1 )); then
        idle_seconds=$((now - last_ollama_activity))

        if (( idle_seconds >= OLLAMA_TIMEOUT )); then
            log "Nessuna richiesta Ollama da ${idle_seconds} secondi."
            shutdown_host
            exit 0
        fi

        # Aggiornamento ogni 5 minuti.
        if (( idle_seconds > 0 &&
              idle_seconds % 300 < CHECK_INTERVAL )); then

            remaining_seconds=$((OLLAMA_TIMEOUT - idle_seconds))

            log "Ollama inattivo da ${idle_seconds} secondi; timeout tra circa ${remaining_seconds} secondi."
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
