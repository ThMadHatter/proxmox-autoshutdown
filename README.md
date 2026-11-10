# proxmox-autoshutdown

**Spegnimento automatico intelligente della workstation Proxmox.**

Spegne la macchina quando:
- **VM Gaming (100)** è spenta
- **VM Ollama (101)** non ha attività da 10 minuti
- **L'host Proxmox** è idle (nessuna sessione utente, carico CPU basso, I/O nullo)

Se stai usando SSH per configurare qualcosa, il timer si Resetta automaticamente.

## ⚙️ Come funziona

```
Gaming VM spenta?  → Sì → Controlla Ollama
                    ↓    ↓
No  →  Continua a monitorare  Ollama idle da 10 min? → No → Continua
                                ↓    ↓
                          Sì → Host is idle?  → No → Reset timer
                                ↓    ↓
                          Sì → Shutdown!
                          ↓
                     Wakelock attivo? → Sì → Annulla shutdown
```

### Rilevamento attività host (umano)

L'host è considerato non-idle se SI VERIFICA ALMENO UNA DI QUESTE:

1. **Sessione utente attiva** (SSH/TTY non-root) — `who` + `w`
2. **Carico CPU significativo** — load 1min > 0.3 (sottratti i servizi PVE)
3. **I/O Disco recente** — variazione su `/proc/diskstats` negli ultimi 120s
4. **Wakelock file** — `/run/proxmox-autoshutdown.wakelock` (blocco manuale)

## 🚀 Installazione

### Da locale (sulla workstation Proxmox)

```bash
# Se sei già sulla workstation Proxmox come user con sudo:
sudo ./local-install.sh
```

### Da remoto (da un altro PC)

```bash
# Clona la repo sul tuo PC
git clone https://github.com/ThMadHatter/proxmox-autoshutdown.git
cd proxmox-autoshutdown

# Deploy verso il server (di default hermes@192.168.1.85)
./remote-deploy.sh hermes@192.168.1.85

# Oppure con make (se hai make installato)
make deploy
```

## 🔒 Lock / Unlock

Proteggi lo shutdown quando fai configurazioni lunghe:

```bash
# Blocca lo shutdown
make lock

# Sblocca
make unlock
```

Oppure manualmente:

```bash
ssh hermes@192.168.1.85 " sudo touch /run/proxmox-autoshutdown.wakelock"
# ... fai le tue configurazioni ...
ssh hermes@192.168.1.85 " sudo rm -f /run/proxmox-autoshutdown.wakelock"
```

## 🔧 Comandi di diagnosi

```bash
# Stato del servizio
make status

# Log live (tail -f)
make log

# Ultime 50 righe di log
make log-remote

# Ultimi 20 log del timer di deploy
make log-timer

# Forza un reload immediato (per debug)
make reload
```

## 📁 Struttura dei file

```
proxmox-autoshutdown/
├── proxmox-autoshutdown.sh   # Script principale
├── proxmox-autoshutdown.service  # Unit file systemd
├── local-install.sh          # Installazione locale (sulla Proxmox)
├── remote-deploy.sh          # Deploy remoto (da altro PC)
├── Makefile                  # Automatizza tutto
├── reload.sh                 # Script di deploy automatico dal repo GitHub
├── reload.service            # Unit file systemd timer
├── reload.timer              # Timer ogni 5 minuti
├── deploy.sh                 # Alias per remote-deploy.sh
└── README.md                 # Questo file
```

## ⚡ Flusso di lavoro tipico

1. **Installi una volta**:
   ```bash
   make deploy  # dal tuo PC
   ```

2. **Modifichi lo script** (sul tuo PC):
   ```bash
   nano proxmox-autoshutdown.sh  # modifica
   git add .
   git commit -m "descrizione"
   git push origin main
   ```

3. **La workstation aggiorna in ~5 minuti**:
   - `reload.timer` fa `git pull` ogni 5 minuti
   - Se lo script è cambiato: copia in `/usr/local/sbin/` e riavvia il servizio

4. **Durante l'uso**:
   - Stai facendo configurazioni? Niente panico — lo script lo rileva e non spegne
   - Vuoi essere sicuro al 100%? `make lock`

## 🔧 Configurazione

Tutte le variabili sono all'inizio del file `proxmox-autoshutdown.sh`:

```bash
VM_GAMING=100          # ID VM Gaming
VM_OLLAMA=101          # ID VM Ollama
OLLAMA_TIMEOUT=600     # Minuti idle Ollama (600s = 10 min)
CHECK_INTERVAL=15      # Frequenza controlli (secondi)
HOST_CPU_THRESHOLD=0.3 # Soglia CPU (load 1min > 0.3 = non idle)
HOST_IO_ACTIVE_SEC=120 # Secondi I/O disc per idle check
HOST_IDLE_GRACE_MIN=5  # Minuti idle host prima di shutdown
```

## 🔍 Troubleshooting

**Il servizio non è attivo:**
```bash
ssh hermes@192.168.1.85 "sudo systemctl status proxmox-autoshutdown"
ssh hermes@192.168.1.85 "sudo journalctl -u proxmox-autoshutdown -n 50"
```

**Forza uno shutdown manuale:**
```bash
ssh hermes@192.168.1.85 " sudo systemctl restart proxmox-autoshutdown"
```

**Rimuovi tutto:**
```bash
make uninstall
```

**Testa il deploy script:**
```bash
ssh hermes@192.168.1.85 "sudo bash -x /opt/proxmox-autoshutdown/reload.sh"
```

## 📜 Note

- Lo script usa **QEMU Guest Agent** per controllare le richieste Ollama dentro la VM101 (nessun SSH necessario)
- Il timer di deploy è di **5 minuti** — non istantaneo ma affidabile
- Il sistema è progettato per **non spegnere mai** se c'è attività umana sul nodo host
- Il wakelock può essere usato anche **senza SSH** — basta creare il file con `touch` locale su Proxmox
