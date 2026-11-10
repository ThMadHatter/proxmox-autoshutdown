#!/usr/bin/env bash
#
# proxmox-autoshutdown.sh
# Spegnimento automatico della workstation Proxmox quando:
#   - VM Gaming (100) è spenta
#   - Ollama (101) è idle da timeout
#   - L'host è idle su tutte le soglie (sessions, CPU, I/O)
#
# Uso lock manuale:
#   make lock   → /run/proxmox-autoshutdown.wakelock (blocca shutdown)
#   make unlock → rimuove wakelock (riattiva shutdown)
#

set -u

# ============================================================
# Configurazione
# ============================================================

VM_GAMING=100
VM_OLLAMA=101

# ████████████████████████████████████████████████████
# OLLAMA TIMEOUT
# ████████████████████████████████████████████████████
# Tempo senza richieste Ollama prima di considerare lo
# spegnimento. Default: 600s = 10 minuti.
#
# Nota: il timer si RESETTA automaticamente se l'host
# rileva attività utente (SSH, CPU, I/O).
# ████████████████████████████████████████████████████
OLLAMA_TIMEOUT=600

# Intervallo tra i controlli (in secondi)
CHECK_INTERVAL=15

# Servizio Ollama nella VM101 (journalctl unit name)
OLLAMA_SERVICE="ollama.service"

# ── File di blocco ────────────────────────────────────
# Lock file per evitare istanze multiple dello script
LOCK_FILE="/run/proxmox-autoshutdown.lock"
# Wakelock: se esiste, lo shutdown viene bloccato completamente
WAKELOCK_FILE="/run/proxmox-autoshutdown.wakelock"

# ── Soglie idle rilevamento host ─────────────────────
#
# L'host è considerato "non idle" (e lo shutdown viene
# posticipato) se SI VERIFICA ALMENO UNA DI QUESTE:
#
#  1. Sessione utente attiva (SSH/TTY non-root)
#     → host_has_active_sessions()
#
#  2. Carico CPU significativo
#     → host_high_cpu_load()
#     Soglia: load 1min > HOST_CPU_THRESHOLD
#     (sottrae ~0.2 per i servizi di sistema Proxmox)
#
#  3. I/O Disco recente (ultimi HOST_IO_ACTIVE_SEC secondo)
#     → host_active_io()
#     Usa iostat se disponibile, altrimenti md5sum di
#     /proc/diskstats per rilevare variazioni
#
HOST_IDLE_CHECK_SEC=30       # ogni quanti secondi controlla l'host
HOST_GRACE_SEC=120           # minuti di aviso prima dello spegnimento
HOST_IDLE_GRACE_MIN=5        # minuti consecutivi di idle host prima di shutdown
HOST_CPU_THRESHOLD=0.3       # load 1min (> = attività significativa)
HOST_IO_ACTIVE_SEC=120       # se I/O attivo negli ultimi 120s → host non idle

# ═══════════════════════════════════════════════════════
# Funzioni di rilevamento VM
# ═══════════════════════════════════════════════════════

log() {
    printf '%s - %s\n' "$(date '+%F %T')" "$*"
}

get_vm_status() {
    local vmid="$1"
    local status

    status=$(/usr/sbin/qm status "$vmid" 2>/dev/null \
             | /usr/bin/awk '{print $2}')

    case "$status" in
        running|stopped) printf '%s\n' "$status" ;;
        *)               printf '%s\n' "unknown"    ;;
    esac
}

guest_agent_available() {
    timeout 10 /usr/sbin/qm guest cmd "$VM_OLLAMA" ping \
        >/dev/null 2>&1
}

ollama_has_new_requests() {
    local since_epoch="$1"
    local result

    # Esegue il controllo direttamente dentro VM101 tramite QEMU Guest Agent.
    # Il comando interno termina con:
    #   exit 0 = trovata almeno una richiesta
    #   exit 1 = nessuna richiesta
    result=$(
        timeout 25 /usr/sbin/qm guest exec "$VM_OLLAMA" \
            --timeout 20 -- \
                /bin/bash -c "
                    /usr/bin/journalctl \
                        -u '${OLLAMA_SERVICE}' \
                        --since '@${since_epoch}' \
                        --no-pager -o cat 2>/dev/null |
                    /usr/bin/grep -Eiq \
                        '(method=(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)|(/api/(generate|chat|embed|embeddings|completion|pull|push|create|copy|delete|show|tags|ps|version)))'
                " 2>/dev/null
    ) || return 1

    printf '%s\n' "$result" |
        /usr/bin/grep -Eq '"exitcode"[[:space:]]*:[[:space:]]*0'
}

shutdown_host() {
    log "▸ Shutdown avviato"
    log "Arresto completo del nodo Proxmox."
    /usr/bin/sync
    /usr/bin/systemctl poweroff
}

# ═══════════════════════════════════════════════════════
# Funzioni di rilevamento attività host (umano)
# ═══════════════════════════════════════════════════════

# Restituisce 0 se una sessione utente (non-root) è attiva su SSH/TTY
host_has_active_sessions() {
    local count

    # who → sessoni fisiche/Virtual console
    count=$(who 2>/dev/null \
            | awk '$1 != "root" { n++ } END { print n+0 }')
    if (( count > 0 )); then
        return 0
    fi

    # w → sessioni SSH (anche idle)
    count=$(w -h 2>/dev/null \
            | awk '$1 != "root" && $1 != "" { n++ } END { print n+0 }')
    if (( count > 0 )); then
        return 0
    fi

    return 1
}

# Restituisce 0 se il carico CPU è sopra la soglia
host_high_cpu_load() {
    local load_1min

    load_1min=$(awk '{print $1}' /proc/loadavg)

    if awk "BEGIN {exit !(${load_1min} > ${HOST_CPU_THRESHOLD})}"; then
        return 0  # carico significativo → non idle
    fi
    return 1
}

# Restituisce 0 se c'è stato I/O Disco recente
host_active_io() {
    local diskstat_1 diskstat_2

    diskstat_1=$(head -20 /proc/diskstats 2>/dev/null \
                 | md5sum | awk '{ print $1 }')
    sleep 2
    diskstat_2=$(head -20 /proc/diskstats 2>/dev/null \
                 | md5sum | awk '{ print $1 }')

    [[ "$diskstat_1" != "$diskstat_2" ]]
}

# Restituisce 0 se l'host è completamente idle
host_is_idle() {
    if ! host_has_active_sessions; then
        :  # nessuna sessione attiva → OK
    else
        log "  ✗ Sessione utente attiva"
        return 1
    fi

    if ! host_high_cpu_load; then
        :  # carico OK
    else
        local load
        load=$(awk '{print $1}' /proc/loadavg)
        log "  ✗ Carico CPU elevato (${load})"
        return 1
    fi

    if ! host_active_io; then
        :  # I/O OK
    else
        log "  ✗ I/O Disco rilevato"
        return 1
    fi

    return 0  # tutto idle ✓
}

# ═══════════════════════════════════════════════════════
# Blocco istanza multipla
# ═══════════════════════════════════════════════════════

exec 9>"$LOCK_FILE"
if ! /usr/bin/flock -n 9; then
    log "Un'altra istanza dello script è già attiva."
    exit 1
fi

# ═══════════════════════════════════════════════════════
# Stato iniziale
# ═══════════════════════════════════════════════════════

previous_vm100_status=$(get_vm_status "$VM_GAMING")
vm101_status=$(get_vm_status "$VM_OLLAMA")

now=$(date +%s)
last_ollama_activity="$now"
last_journal_scan=$((now - 5))
ollama_monitoring_started=0
guest_agent_warning_shown=0
host_idle_sec=0            # secondi consecutivi di host_idle
host_idle_check_next=$((now + HOST_IDLE_CHECK_SEC))

if [[ "$vm101_status" == "running" ]]; then
    ollama_monitoring_started=1
fi

log "===== Monitor avviato ====="
log "VM${VM_GAMING}: ${previous_vm100_status}"
log "VM${VM_OLLAMA}: ${vm101_status}"
log "Timeout Ollama: ${OLLAMA_TIMEOUT}s"
log "Host idle detection: enabled"
log ""

if (( ollama_monitoring_started == 0 )); then
    log "Avviare VM${VM_OLLAMA} per abilitare il monitoraggio Ollama."
fi

# ═══════════════════════════════════════════════════════
# Ciclo principale
# ═══════════════════════════════════════════════════════

while true; do
    now=$(date +%s)

    vm100_status=$(get_vm_status "$VM_GAMING")
    vm101_status=$(get_vm_status "$VM_OLLAMA")

    # ── Wakelock: blocca incondizionatamente ──
    if [[ -f "$WAKELOCK_FILE" ]]; then
        if (( now % 300 < CHECK_INTERVAL )); then
            log "🔒 Wakelock attivo — shutdown sospeso"
        fi
        last_ollama_activity="$now"
        ollama_monitoring_started=0   # reset completo
        host_idle_sec=0
    fi

    # ── Host idle check (periodico) ──
    if (( now >= host_idle_check_next )); then
        host_idle_check_next=$((now + HOST_IDLE_CHECK_SEC))

        if host_is_idle; then
            (( host_idle_sec += HOST_IDLE_CHECK_SEC ))
        else
            host_idle_sec=0  # reset se non idle
        fi
    fi

    # ── Condizione 1: Gaming stopped (da running) ──
    if [[ "$previous_vm100_status" == "running" &&
          "$vm100_status" == "stopped" ]]; then
        log "VM${VM_GAMING} spenta. Avvio shutdown."
        shutdown_host
        exit 0
    fi

    if [[ "$vm100_status" == "running" ||
          "$vm100_status" == "stopped" ]]; then
        previous_vm100_status="$vm100_status"
    fi

    # ── Condizione 2: Ollama idle + host idle per grace period ──
    if [[ "$vm101_status" == "running" ]]; then
        # VM appena avviata → reset monitoraggio
        if (( ollama_monitoring_started == 0 )); then
            ollama_monitoring_started=1
            last_ollama_activity="$now"
            last_journal_scan=$((now - 5))
            host_idle_sec=0

            log "VM${VM_OLLAMA} avviata — monitoraggio Ollama attivo"
        fi

        # Controllo richieste Ollama (solo se non wakelock)
        if [[ ! -f "$WAKELOCK_FILE" ]]; then
            if guest_agent_available; then
                guest_agent_warning_shown=0

                if ollama_has_new_requests "$last_journal_scan"; then
                    last_ollama_activity="$now"
                    host_idle_sec=0  # activity detected on Ollama
                    log "Richiesta Ollama rilevata — timeout azzerato"
                fi
                last_journal_scan=$((now - 2))
            elif (( guest_agent_warning_shown == 0 )); then
                log "guest-agent VM${VM_OLLAMA} irraggiungibile"
                guest_agent_warning_shown=1
            fi
        fi
    fi

    # ── Verifica shutdown: Ollama idle + host idle per grace ──
    if (( ollama_monitoring_started == 1 )); then
        idle_seconds=$((now - last_ollama_activity))

        # ═══ Ollama idle da timeout ═══
        if (( idle_seconds >= OLLAMA_TIMEOUT )); then

            # ═══ Host idle per grace period? ═══
            if (( host_idle_sec >= (HOST_IDLE_GRACE_MIN * 60) )); then
                # Shutdown — verifica finale wakelock
                if [[ -f "$WAKELOCK_FILE" ]]; then
                    log "🔒 Wakelock: shutdown annullato"
                else
                    log "🔑 Shutdown (Ollama idle + host idle)"
                    shutdown_host
                fi
                exit 0
            elif (( idle_seconds >= (OLLAMA_TIMEOUT + HOST_IDLE_GRACE_MIN * 60) )); then
                # Host non idle da troppo tempo rispetto al timeout:
                # spegni comunque per non restare acceso indefinitamente
                # (fallback di sicurezza)
                if [[ ! -f "$WAKELOCK_FILE" ]]; then
                    log "⚠️  Ollama idle + host non idle da ${host_idle_sec}s"
                    log "🔑 Shutdown di sicurezza (timeout raggiunto)"
                    shutdown_host
                fi
                exit 0
            else
                # Ollama idle ma host ancora attivo → non spegnere
                log "🔐 Ollama idle (${idle_seconds}s) ma host attivo — posticipato"
            fi
        fi

        # Update ogni 5 minuti
        if (( idle_seconds > 0 && idle_seconds % 300 < CHECK_INTERVAL )); then
            remaining=$((OLLAMA_TIMEOUT - idle_seconds))
            log "Ollama idle ${idle_seconds}s — timeout ~${remaining}s"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
