# CHANGELOG

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
