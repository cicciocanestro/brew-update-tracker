# CHANGELOG

## [1.1.0] - 2026-05-27

### Added
- Funzione `process_packages` per la gestione in blocco (bulk) delle chiamate alle API di Homebrew.
- Pulizia automatica dei nomi dei tap (es. `tap/nome`) dai nuovi cask prima della richiesta delle informazioni.

### Changed
- **Performance:** Sostituiti i lenti cicli `while` individuali con un'elaborazione in blocco tramite `xargs` e `jq` per `brew info`, riducendo drasticamente i tempi di esecuzione.
- Il comando `brew outdated` ora utilizza l'output nativo `--json=v2` invece di un fragile parsing testuale tramite `sed`, rendendo lo script molto più robusto ai futuri aggiornamenti di Homebrew.

### Removed
- Rimossa la funzione `safe_jq_parse` in quanto sostituita nativamente dalle query ottimizzate di `jq` nell'elaborazione in blocco.

## 2026-05-24 — Migliorie principali

- Fix: Estrazione precisa di *New Formulae* e *New Casks* dall'output di `brew update` (limita la sezione fino al successivo `==>`).
- Fix: Normalizzazione dei nomi (rimozione di suffissi `:` e descrizioni dopo `:` per i cask; rimozione versioni tra parentesi da `brew outdated`).
- Miglioria: Esecuzione di `brew update` in background con indicatore di progresso; output catturato in file temporaneo per parsing più affidabile.
- Fix: Processo di recupero informazioni semplificato — per ogni pacchetto si usa `brew info --json=v2` e si leggono `homepage`/`desc` direttamente (più robusto rispetto alla costruzione di grandi array JSON).
- Fix: Migliorata gestione dei messaggi/log (`printf` invece di `echo -e`) e migliore gestione di errori non critici.
- Rimozione: Tolte chiamate costose a `brew search` per il confronto completo delle liste (più veloce e meno fragile).
- Pulizia: Rimozione di script di debug e file di test temporanei dal workspace.

### Perché queste modifiche
Le modifiche puntano a rendere lo script più affidabile nel parsing dell'output di Homebrew, ridurre falsi positivi (nomi errati nelle sezioni "New"), e mostrare homepage/descrizioni reali per i pacchetti quando disponibili. Alcuni trade‑off: la nuova strategia chiama `brew info` per ogni pacchetto (leggermente più lenta), ma è più robusta.

---

File rilevanti modificati: `brew_upgrade_tracker.sh` (diverse revisioni tra 2025 e 2026).

(Commit aggiunto automaticamente il 2026-05-24)
