#!/bin/zsh

# brew_upgrade_tracker.sh
#
# Brew Update Tracker — unified edition:
# 1. Runs 'brew update' with visual spinner
# 2. Parses outdated packages and newly added formulae/casks
# 3. Fetches package metadata in bulk using 'brew info --json=v2' & 'jq'
# 4. Generates an interactive HTML dashboard (Dark Mode, Search, Filters,
#    Copy Commands) unless --no-dashboard is given
# 5. Prompts for 'brew upgrade' (or runs it with --yes)

set +e

# Color definitions for terminal output
GREEN="\033[0;32m"
BRIGHT_GREEN="\033[1;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RESET="\033[0m"

# Parse Options / Flags
AUTO_UPGRADE=false
NO_DASHBOARD=false
SCRIPT_NAME="$0"

usage() {
    printf "Usage: %s [-y|--yes] [-n|--no-dashboard] [-h|--help]\n" "$SCRIPT_NAME"
    printf "  -y, --yes            Perform 'brew upgrade' automatically without prompting\n"
    printf "  -n, --no-dashboard   Terminal-only mode: skip HTML dashboard generation\n"
    printf "  -h, --help           Show this help message\n"
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            AUTO_UPGRADE=true
            ;;
        -n|--no-dashboard)
            NO_DASHBOARD=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '%bError: unknown option: %s%b\n' "$RED" "$arg" "$RESET" >&2
            usage
            exit 1
            ;;
    esac
done

# System temporary directory and log file
TMP_BASE="${TMPDIR:-/tmp}"
LOG_FILE="${TMP_BASE}/brew-update-tracker-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null

log_error() {
    local msg="$1"
    printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
    printf '%bWarning: %s (See %s for details)%b\n' "$YELLOW" "$msg" "$LOG_FILE" "$RESET" >&2
}

# Dependency checks
if ! command -v brew &> /dev/null; then
    printf '%bError: Homebrew is not installed%b\n' "$RED" "$RESET" >&2
    log_error "Homebrew command not found"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    printf '%bError: jq is not installed%b\n' "$RED" "$RESET" >&2
    printf '%bPlease install it with: brew install jq%b\n' "$CYAN" "$RESET"
    log_error "jq command not found"
    exit 1
fi

TEMP_DIR=$(mktemp -d "${TMP_BASE}/brew-update-tracker.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

printf '%b🍺 Brew Update Tracker%b\n' "$BRIGHT_GREEN" "$RESET"
printf '%b=======================%b\n' "$BRIGHT_GREEN" "$RESET"

# Step 1: Run brew update and capture output
printf '\n%b🔄 Updating Homebrew...%b\n' "$CYAN" "$RESET"
# IMPORTANT: capture stderr too (2>&1). Since Homebrew 4.1+ the whole update
# report ("==> New Formulae", "==> New Casks", ...) is written to STDERR when
# stdout is not a TTY (see cmd/update-report.rb), so parsing stdout alone would
# never find new packages.
(
    HOMEBREW_NO_COLOR=1 HOMEBREW_NO_EMOJI=1 brew update > "$TEMP_DIR/brew_update_output.txt" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '.'
        sleep 0.5
    done
    wait "$pid"
) 2>/dev/null
update_exit=$?
printf '\n'
[[ $update_exit -ne 0 ]] && log_error "brew update failed (exit code $update_exit); new packages may be incomplete"
< "$TEMP_DIR/brew_update_output.txt" cat

# Step 2: Extract "New Formulae" and "New Casks" from update output
clean_update_output="$TEMP_DIR/brew_update_clean.txt"
tr -d '\r' < "$TEMP_DIR/brew_update_output.txt" > "$clean_update_output" 2>/dev/null || cp "$TEMP_DIR/brew_update_output.txt" "$clean_update_output"

extract_new_packages() {
    local section_title="$1"
    local input_file="$2"

    awk -v title="$(echo "$section_title" | tr '[:upper:]' '[:lower:]')" '
        BEGIN { p = 0 }
        # Only an actual "==> New Formulae"-style header starts the section
        # (a package line whose description merely mentions the title must not)
        p == 0 && tolower($0) ~ "^==>[[:space:]]*" title "[[:space:]]*$" { p = 1; next }
        p && /^==>/ {
            if (tolower($0) ~ /==>[[:space:]]*(new formulae|new casks|updated formulae|updated casks|outdated|deleted|renamed)/) {
                p = 0
            }
            next
        }
        p { 
            # Remove anything inside parenthesis
            gsub(/\([^)]*\)/, "")
            # Remove anything after a colon (descriptions)
            sub(/:.*/, "")
            # Split by whitespace
            n = split($0, arr, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                pkg = arr[i]
                if (pkg != "") {
                    # Remove tap path if present (e.g., homebrew/core/pkg -> pkg)
                    sub(/^.*\//, "", pkg)
                    if (pkg ~ /^[a-zA-Z0-9@+._-]+$/) {
                        print pkg
                    }
                }
            }
        }
    ' "$input_file" | sort -u
}

extract_new_packages "New Formulae" "$clean_update_output" > "$TEMP_DIR/new_formulae.txt"
extract_new_packages "New Casks" "$clean_update_output" > "$TEMP_DIR/new_casks.txt"

# Step 3: Find outdated packages using JSON
printf '\n%b🔍 Finding outdated packages...%b\n' "$CYAN" "$RESET"
if ! brew outdated --json=v2 > "$TEMP_DIR/outdated.json" 2>>"$LOG_FILE"; then
    log_error "Failed to fetch outdated packages JSON"
    echo '{"formulae":[],"casks":[]}' > "$TEMP_DIR/outdated.json"
fi

jq -r '.formulae[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_formulae.txt" 2>/dev/null
jq -r '.casks[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_casks.txt" 2>/dev/null

# Helper for Bulk Processing in CLI
# Runs `xargs brew info --json=v2 | jq` and reports pipeline failures instead
# of silently swallowing them. Returns the jq output via stdout.
run_bulk_info() {
    local input_file="$1"
    local jq_query="$2"
    local out xargs_rc jq_rc

    # Two-stage pipe so we can inspect both exit codes (set -o pipefail
    # would be cleaner but we keep `set +e` globally for resilience).
    out=$(< "$input_file" xargs brew info --json=v2 2>>"$LOG_FILE")
    xargs_rc=$?
    [[ $xargs_rc -ne 0 ]] && log_error "brew info bulk fetch exited with code $xargs_rc"

    printf '%s' "$out" | jq -r "$jq_query" 2>>"$LOG_FILE"
    jq_rc=$?
    [[ $jq_rc -ne 0 ]] && log_error "jq bulk processing exited with code $jq_rc"
}

process_packages() {
    local file="$1"
    local title="$2"
    local jq_query="$3"

    printf '\n%b📊 %s:%b\n' "$BRIGHT_GREEN" "$title" "$RESET"

    if [[ ! -s "$file" ]]; then
        printf "  %bNo packages available.%b\n" "$GREEN" "$RESET"
        return
    fi

    local requested
    requested=$(wc -l < "$file" | tr -d '[:space:]')
    local output
    output=$(run_bulk_info "$file" "$jq_query")

    # Heuristic mismatch detection: if we asked for N packages and got 0
    # lines of output (excluding pure whitespace), something likely failed.
    local got
    got=$(printf '%s\n' "$output" | grep -c 'Homepage: ' || true)
    if [[ "$requested" -gt 0 && "$got" -eq 0 ]]; then
        log_error "Bulk metadata returned 0 entries for $requested package(s) in '$title' — see log"
    fi

    printf '%s\n' "$output"
}

JQ_FORMULAE_QUERY='.formulae[] | "  - \(.name):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'
JQ_CASKS_QUERY='.casks[] | "  - \(.token):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'

# CLI Output for outdated & new
process_packages "$TEMP_DIR/outdated_formulae.txt" "📦 Updated Formulae" "$JQ_FORMULAE_QUERY"
process_packages "$TEMP_DIR/outdated_casks.txt" "📦 Updated Casks" "$JQ_CASKS_QUERY"
process_packages "$TEMP_DIR/new_formulae.txt" "🆕 New Formulae" "$JQ_FORMULAE_QUERY"
process_packages "$TEMP_DIR/new_casks.txt" "🆕 New Casks" "$JQ_CASKS_QUERY"

# Helper function to get names as clean JSON array
get_names_json() {
    local file="$1"
    if [[ -s "$file" ]]; then
        tr -s '[:space:]' '\n' < "$file" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null
    else
        echo "[]"
    fi
}

# Step 4: Generate Interactive Dashboard HTML
generate_landing_page() {
    local landing_file="/tmp/brew-update-landing.html"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    printf '\n%b🌐 Generating modern interactive dashboard...%b\n' "$CYAN" "$RESET"

    # ------------------------------------------------------------------
    # Data assembly (bulk metadata fetch, robust JSON payload)
    # ------------------------------------------------------------------
    local f_list="$TEMP_DIR/all_formulae.txt"
    local c_list="$TEMP_DIR/all_casks.txt"
    cat "$TEMP_DIR/outdated_formulae.txt" "$TEMP_DIR/new_formulae.txt" 2>/dev/null | tr -s '[:space:]' '\n' | sort -u | grep -v '^$' > "$f_list"
    cat "$TEMP_DIR/outdated_casks.txt" "$TEMP_DIR/new_casks.txt" 2>/dev/null | tr -s '[:space:]' '\n' | sort -u | grep -v '^$' > "$c_list"

    local formulae_json="[]"
    local casks_json="[]"

    if [[ -s "$f_list" ]]; then
        local f_raw f_rc
        f_raw=$(< "$f_list" xargs brew info --json=v2 2>>"$LOG_FILE")
        f_rc=$?
        [[ $f_rc -ne 0 ]] && log_error "Dashboard: bulk formulae fetch exited with code $f_rc"
        formulae_json=$(printf '%s' "$f_raw" | jq -s '[.[].formulae[]?]' 2>>"$LOG_FILE")
        [[ -z "$formulae_json" ]] && formulae_json="[]"
    fi
    if [[ -s "$c_list" ]]; then
        local c_raw c_rc
        c_raw=$(< "$c_list" xargs brew info --json=v2 2>>"$LOG_FILE")
        c_rc=$?
        [[ $c_rc -ne 0 ]] && log_error "Dashboard: bulk casks fetch exited with code $c_rc"
        casks_json=$(printf '%s' "$c_raw" | jq -s '[.[].casks[]?]' 2>>"$LOG_FILE")
        [[ -z "$casks_json" ]] && casks_json="[]"
    fi

    local outdated_json_data="{}"
    if [[ -s "$TEMP_DIR/outdated.json" ]]; then
        outdated_json_data=$(< "$TEMP_DIR/outdated.json" cat)
    else
        outdated_json_data='{"formulae":[],"casks":[]}'
    fi

    local new_f_names new_c_names out_f_names out_c_names
    new_f_names=$(get_names_json "$TEMP_DIR/new_formulae.txt")
    new_c_names=$(get_names_json "$TEMP_DIR/new_casks.txt")
    out_f_names=$(get_names_json "$TEMP_DIR/outdated_formulae.txt")
    out_c_names=$(get_names_json "$TEMP_DIR/outdated_casks.txt")

    # Assemble the unified JSON payload (same schema as before)
    local json_data=""
    json_data=$(jq -c -n \
        --arg timestamp "$timestamp" \
        --argjson formulae "$formulae_json" \
        --argjson casks "$casks_json" \
        --argjson outdated "$outdated_json_data" \
        --argjson new_f "$new_f_names" \
        --argjson new_c "$new_c_names" \
        --argjson out_f "$out_f_names" \
        --argjson out_c "$out_c_names" \
        '{
            timestamp: $timestamp,
            formulae: $formulae,
            casks: $casks,
            outdated: $outdated,
            new_formulae: $new_f,
            new_casks: $new_c,
            outdated_formulae: $out_f,
            outdated_casks: $out_c
        }' 2>/dev/null)
    [[ -z "$json_data" ]] && json_data='{}'

    # ------------------------------------------------------------------
    # Emit the dashboard: static skeleton + inline JSON + application JS
    # (quoted heredocs so no shell escaping is needed inside CSS/JS)
    # ------------------------------------------------------------------
    {
        cat << 'BREW_HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="theme-color" content="#05060b">
<title>🍺 Brew Update Tracker</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root {
        --bg: #05060b;
        --surface: rgba(17, 19, 28, 0.62);
        --surface-strong: rgba(22, 25, 36, 0.85);
        --border: rgba(255, 255, 255, 0.08);
        --border-hi: rgba(129, 140, 248, 0.45);
        --text: #eef2ff;
        --muted: #8b93ab;
        --indigo: #818cf8;
        --cyan: #22d3ee;
        --emerald: #34d399;
        --amber: #fbbf24;
        --rose: #fb7185;
        --violet: #a78bfa;
        --r-lg: 20px;
        --r-md: 14px;
        --font: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        --mono: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
    }

    html { scroll-behavior: smooth; }

    body {
        font-family: var(--font);
        background: var(--bg);
        color: var(--text);
        min-height: 100vh;
        line-height: 1.55;
        -webkit-font-smoothing: antialiased;
        overflow-x: hidden;
    }

    ::selection { background: rgba(99, 102, 241, 0.45); }
    :focus-visible { outline: 2px solid rgba(129, 140, 248, 0.75); outline-offset: 2px; }
    ::-webkit-scrollbar { width: 10px; }
    ::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.12); border-radius: 8px; border: 2px solid transparent; background-clip: content-box; }
    ::-webkit-scrollbar-track { background: transparent; }

    /* ---------- ambient aurora background ---------- */
    .orb {
        position: fixed;
        border-radius: 50%;
        filter: blur(90px);
        opacity: 0.5;
        z-index: -1;
        pointer-events: none;
        will-change: transform;
    }
    .orb-a { width: 520px; height: 520px; top: -160px; left: -120px; background: radial-gradient(circle at 30% 30%, rgba(99,102,241,0.55), transparent 65%); animation: drift 26s ease-in-out infinite alternate; }
    .orb-b { width: 460px; height: 460px; top: 30%; right: -160px; background: radial-gradient(circle at 60% 40%, rgba(34,211,238,0.38), transparent 65%); animation: drift 32s ease-in-out infinite alternate-reverse; }
    .orb-c { width: 420px; height: 420px; bottom: -180px; left: 28%; background: radial-gradient(circle at 50% 50%, rgba(167,139,250,0.35), transparent 65%); animation: drift 38s ease-in-out infinite alternate; }
    @keyframes drift {
        0%   { transform: translate(0, 0) scale(1); }
        50%  { transform: translate(40px, -30px) scale(1.08); }
        100% { transform: translate(-30px, 30px) scale(0.96); }
    }

    /* ---------- sticky glass top bar ---------- */
    .topbar {
        position: sticky;
        top: 0;
        z-index: 50;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        flex-wrap: wrap;
        padding: 14px clamp(16px, 4vw, 36px);
        background: rgba(8, 10, 16, 0.82);
        backdrop-filter: blur(18px) saturate(150%);
        -webkit-backdrop-filter: blur(18px) saturate(150%);
        border-bottom: 1px solid rgba(129, 140, 248, 0.22);
    }
    .brand { display: flex; align-items: center; gap: 12px; }
    .brand-logo {
        width: 42px; height: 42px;
        display: grid; place-items: center;
        font-size: 1.35rem;
        border-radius: 13px;
        background: linear-gradient(135deg, rgba(99,102,241,0.35), rgba(34,211,238,0.15));
        border: 1px solid rgba(129, 140, 248, 0.35);
        box-shadow: 0 6px 20px -6px rgba(99, 102, 241, 0.5);
    }
    .brand-name { display: block; font-weight: 800; font-size: 1rem; letter-spacing: -0.2px; }
    .brand-sub { display: block; font-size: 0.68rem; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 1.4px; }
    .topbar-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .chip {
        display: inline-flex; align-items: center; gap: 8px;
        padding: 7px 14px;
        border-radius: 999px;
        background: rgba(255, 255, 255, 0.04);
        border: 1px solid var(--border);
        font-size: 0.76rem; color: var(--muted); font-weight: 600;
        font-variant-numeric: tabular-nums;
    }
    .dot {
        width: 7px; height: 7px; border-radius: 50%;
        background: var(--emerald);
        box-shadow: 0 0 10px var(--emerald);
        animation: pulse 2.2s infinite;
    }
    @keyframes pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.45; transform: scale(0.8); } }
    .btn-ghost {
        display: inline-flex; align-items: center; gap: 8px;
        padding: 8px 16px;
        border-radius: 999px;
        border: 1px solid rgba(129, 140, 248, 0.35);
        background: linear-gradient(135deg, rgba(99,102,241,0.18), rgba(34,211,238,0.10));
        color: var(--text);
        font: inherit; font-size: 0.8rem; font-weight: 700;
        cursor: pointer;
        transition: all 0.2s ease;
    }
    .btn-ghost:hover { border-color: var(--border-hi); box-shadow: 0 8px 24px -8px rgba(99, 102, 241, 0.55); transform: translateY(-1px); }
    .btn-ghost:active { transform: translateY(0); }

    /* ---------- layout ---------- */
    .container { max-width: 1060px; margin: 0 auto; padding: clamp(24px, 4vw, 44px) clamp(16px, 4vw, 32px) 80px; }

    .hero { text-align: center; margin-bottom: 26px; animation: rise 0.7s cubic-bezier(0.16, 1, 0.3, 1) both; }
    .hero-title {
        font-size: clamp(2rem, 5vw, 2.9rem);
        font-weight: 800;
        letter-spacing: -1.5px;
        line-height: 1.08;
    }
    .grad {
        background: linear-gradient(92deg, #818cf8 0%, #22d3ee 55%, #34d399 100%);
        -webkit-background-clip: text;
        background-clip: text;
        -webkit-text-fill-color: transparent;
        color: transparent;
    }
    .hero-sub { margin-top: 10px; color: var(--muted); font-size: 1rem; font-weight: 500; }
    .hero-sub b { color: var(--text); font-weight: 700; }
    @keyframes rise { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

    /* ---------- metric cards ---------- */
    .stats-row {
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        gap: 14px;
        margin-bottom: 14px;
        animation: rise 0.7s cubic-bezier(0.16, 1, 0.3, 1) 0.08s both;
    }
    .stat-card {
        position: relative;
        overflow: hidden;
        text-align: center;
        background: var(--surface);
        backdrop-filter: blur(20px) saturate(150%);
        -webkit-backdrop-filter: blur(20px) saturate(150%);
        border: 1px solid var(--border);
        border-radius: var(--r-lg);
        padding: 16px 18px;
        transition: transform 0.25s ease, border-color 0.25s ease, box-shadow 0.25s ease;
    }
    .stat-card:hover { transform: translateY(-3px); border-color: var(--border-hi); box-shadow: 0 18px 40px -18px rgba(0, 0, 0, 0.6); }
    .stat-card::after {
        content: '';
        position: absolute;
        inset: auto -30% -60% -30%;
        height: 70%;
        background: radial-gradient(closest-side, var(--glow, rgba(99,102,241,0.25)), transparent);
        opacity: 0.7;
        pointer-events: none;
    }
    .stat-icon { font-size: 1.15rem; margin-bottom: 8px; }
    .stat-value { font-size: 2rem; font-weight: 800; line-height: 1; letter-spacing: -1.5px; font-variant-numeric: tabular-nums; }
    .stat-label { margin-top: 6px; font-size: 0.66rem; font-weight: 700; letter-spacing: 1.4px; text-transform: uppercase; color: var(--muted); }
    .c-amber { --glow: rgba(251, 191, 36, 0.28); } .c-amber .stat-value { color: var(--amber); }
    .c-cyan  { --glow: rgba(34, 211, 238, 0.25); } .c-cyan  .stat-value { color: var(--cyan); }
    .c-indigo{ --glow: rgba(129, 140, 248, 0.28); } .c-indigo .stat-value { color: var(--indigo); }
    .c-violet{ --glow: rgba(167, 139, 250, 0.28); } .c-violet .stat-value { color: var(--violet); }

    /* ---------- donut breakdown card ---------- */
    .donut-card {
        display: flex;
        align-items: center;
        gap: 24px;
        flex-wrap: wrap;
        margin-bottom: 26px;
        background: var(--surface);
        backdrop-filter: blur(20px) saturate(150%);
        -webkit-backdrop-filter: blur(20px) saturate(150%);
        border: 1px solid var(--border);
        border-radius: var(--r-lg);
        padding: 16px 24px;
    }
    .donut-wrap { position: relative; width: 108px; height: 108px; flex: none; }
    .donut-wrap svg { transform: rotate(-90deg); }
    .donut-center { position: absolute; inset: 0; display: grid; place-content: center; text-align: center; }
    .donut-total { font-size: 1.55rem; font-weight: 800; letter-spacing: -1px; line-height: 1; }
    .donut-cap { font-size: 0.58rem; font-weight: 700; letter-spacing: 1.2px; text-transform: uppercase; color: var(--muted); margin-top: 2px; }
    .legend { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 8px 26px; flex: 1; min-width: 280px; }
    .legend-item { display: flex; align-items: center; gap: 8px; font-size: 0.82rem; color: var(--muted); font-weight: 600; }
    .legend-item b { color: var(--text); font-weight: 800; }
    .swatch { width: 10px; height: 10px; border-radius: 3px; flex: none; }

    /* ---------- search + filter pills ---------- */
    .controls {
        display: flex;
        gap: 14px;
        flex-wrap: wrap;
        align-items: center;
        margin-bottom: 22px;
        animation: rise 0.7s cubic-bezier(0.16, 1, 0.3, 1) 0.16s both;
    }
    .search-box { position: relative; flex: 1; min-width: 240px; }
    .search-box .s-ico { position: absolute; left: 15px; top: 50%; transform: translateY(-50%); font-size: 0.85rem; opacity: 0.7; pointer-events: none; }
    .search-box input {
        width: 100%;
        padding: 12px 44px 12px 42px;
        border-radius: 999px;
        background: rgba(10, 12, 20, 0.6);
        border: 1px solid var(--border);
        color: var(--text);
        font: inherit;
        font-size: 0.92rem;
        outline: none;
        transition: border-color 0.2s ease, box-shadow 0.2s ease, background 0.2s ease;
    }
    .search-box input::placeholder { color: #5b6379; }
    .search-box input:focus { border-color: var(--border-hi); box-shadow: 0 0 0 4px rgba(99, 102, 241, 0.18); background: rgba(10, 12, 20, 0.85); }
    .search-box kbd {
        position: absolute; right: 14px; top: 50%; transform: translateY(-50%);
        padding: 2px 8px; border-radius: 6px;
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.05);
        font-family: var(--mono); font-size: 0.7rem; color: var(--muted);
        pointer-events: none;
    }
    .pills { display: flex; gap: 8px; flex-wrap: wrap; }
    .pill {
        padding: 9px 16px;
        border-radius: 999px;
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.03);
        color: var(--muted);
        font: inherit; font-size: 0.82rem; font-weight: 700;
        cursor: pointer;
        white-space: nowrap;
        transition: all 0.2s ease;
    }
    .pill b { font-weight: 800; margin-left: 3px; font-variant-numeric: tabular-nums; }
    .pill:hover { color: var(--text); border-color: rgba(255, 255, 255, 0.18); }
    .pill.active {
        color: #fff;
        background: linear-gradient(135deg, rgba(99, 102, 241, 0.9), rgba(34, 211, 238, 0.75));
        border-color: transparent;
        box-shadow: 0 8px 22px -8px rgba(99, 102, 241, 0.65);
    }

    /* ---------- package cards ---------- */
    .feed { display: flex; flex-direction: column; gap: 14px; }
    .card {
        position: relative;
        background: var(--surface);
        backdrop-filter: blur(20px) saturate(150%);
        -webkit-backdrop-filter: blur(20px) saturate(150%);
        border: 1px solid var(--border);
        border-radius: var(--r-lg);
        padding: 20px 22px;
        transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1), border-color 0.25s ease, box-shadow 0.25s ease;
        animation: rise 0.55s cubic-bezier(0.16, 1, 0.3, 1) both;
    }
    .card:hover { transform: translateY(-3px); border-color: var(--border-hi); box-shadow: 0 22px 46px -20px rgba(0, 0, 0, 0.65); }
    .card::before {
        content: '';
        position: absolute; inset: 0;
        border-radius: inherit;
        background: linear-gradient(120deg, rgba(129, 140, 248, 0.09), transparent 40%);
        opacity: 0;
        transition: opacity 0.25s ease;
        pointer-events: none;
    }
    .card:hover::before { opacity: 1; }
    .card-main { display: flex; gap: 16px; position: relative; }
    .avatar {
        flex: none;
        width: 46px; height: 46px;
        border-radius: 14px;
        display: grid; place-items: center;
        font-weight: 800; font-size: 1.15rem;
        color: #fff;
        text-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
        box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.25), 0 8px 18px -8px rgba(0, 0, 0, 0.5);
    }
    .g0 { background: linear-gradient(135deg, #6366f1, #8b5cf6); }
    .g1 { background: linear-gradient(135deg, #06b6d4, #3b82f6); }
    .g2 { background: linear-gradient(135deg, #f59e0b, #ef4444); }
    .g3 { background: linear-gradient(135deg, #10b981, #06b6d4); }
    .g4 { background: linear-gradient(135deg, #ec4899, #8b5cf6); }
    .g5 { background: linear-gradient(135deg, #f43f5e, #f97316); }
    .card-body { flex: 1; min-width: 0; }
    .card-top { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 4px; }
    .pkg-name { font-size: 1.06rem; font-weight: 800; color: var(--text); text-decoration: none; letter-spacing: -0.2px; transition: color 0.2s ease; }
    a.pkg-name:hover { color: var(--indigo); }
    .badge {
        font-size: 0.62rem; font-weight: 800; letter-spacing: 0.8px; text-transform: uppercase;
        padding: 3px 9px; border-radius: 999px; border: 1px solid transparent;
    }
    .b-formula { color: var(--indigo); background: rgba(99, 102, 241, 0.13); border-color: rgba(99, 102, 241, 0.3); }
    .b-cask    { color: var(--violet);  background: rgba(167, 139, 250, 0.13); border-color: rgba(167, 139, 250, 0.3); }
    .b-new     { color: var(--cyan);    background: rgba(34, 211, 238, 0.12);  border-color: rgba(34, 211, 238, 0.3); }
    .b-update  { color: var(--amber);   background: rgba(251, 191, 36, 0.12);  border-color: rgba(251, 191, 36, 0.3); }
    .ver {
        display: inline-flex; align-items: center; gap: 9px;
        margin: 7px 0 2px;
        padding: 5px 13px;
        border-radius: 999px;
        background: rgba(0, 0, 0, 0.32);
        border: 1px solid rgba(255, 255, 255, 0.06);
        font-family: var(--mono); font-size: 0.76rem;
        width: max-content; max-width: 100%;
    }
    .ver-old { color: var(--rose); }
    .ver-arrow { color: var(--muted); animation: nudge 1.6s ease-in-out infinite; }
    @keyframes nudge { 0%, 100% { transform: translateX(0); opacity: 0.6; } 50% { transform: translateX(4px); opacity: 1; } }
    .ver-new { color: var(--emerald); font-weight: 700; }
    .pkg-desc {
        color: var(--muted); font-size: 0.9rem;
        margin: 6px 0 12px;
        display: -webkit-box;
        -webkit-line-clamp: 2;
        -webkit-box-orient: vertical;
        overflow: hidden;
    }
    .card-actions {
        display: flex; align-items: center; gap: 9px; flex-wrap: wrap;
        padding-top: 12px;
        border-top: 1px solid rgba(255, 255, 255, 0.05);
    }
    .act {
        display: inline-flex; align-items: center; gap: 7px;
        padding: 7px 13px;
        border-radius: 999px;
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.03);
        color: var(--muted);
        font: inherit; font-size: 0.78rem; font-weight: 700;
        cursor: pointer;
        text-decoration: none;
        transition: all 0.2s ease;
    }
    .act code { font-family: var(--mono); font-size: 0.74rem; color: inherit; }
    .act:hover { color: var(--text); border-color: rgba(255, 255, 255, 0.2); background: rgba(255, 255, 255, 0.07); transform: translateY(-1px); }
    .act-copy:hover { color: var(--cyan); border-color: rgba(34, 211, 238, 0.4); background: rgba(34, 211, 238, 0.09); }
    .act-changelog { color: var(--amber); }
    .act-changelog:hover { color: #fde047; border-color: rgba(251, 191, 36, 0.4); background: rgba(251, 191, 36, 0.09); }
    .act-home:hover { color: var(--indigo); border-color: rgba(129, 140, 248, 0.4); background: rgba(99, 102, 241, 0.09); }

    /* ---------- empty states ---------- */
    .empty {
        text-align: center;
        padding: 64px 24px;
        border: 1px dashed rgba(255, 255, 255, 0.14);
        border-radius: var(--r-lg);
        background: rgba(255, 255, 255, 0.02);
        animation: rise 0.5s cubic-bezier(0.16, 1, 0.3, 1) both;
    }
    .empty .e-ico { font-size: 3rem; display: block; margin-bottom: 14px; }
    .empty h3 { font-size: 1.25rem; font-weight: 800; margin-bottom: 6px; }
    .empty p { color: var(--muted); font-size: 0.92rem; line-height: 1.6; }
    .empty.party {
        border-style: solid;
        border-color: rgba(52, 211, 153, 0.28);
        background: linear-gradient(180deg, rgba(16, 185, 129, 0.08), rgba(255, 255, 255, 0.015));
        box-shadow: 0 0 70px -24px rgba(16, 185, 129, 0.35);
    }
    .empty.party .e-ico {
        font-size: 3.4rem;
        filter: drop-shadow(0 8px 22px rgba(52, 211, 153, 0.55));
        animation: floaty 3s ease-in-out infinite;
    }
    @keyframes floaty { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-7px); } }

    /* ---------- footer + toast ---------- */
    .foot { margin-top: 52px; text-align: center; color: #5b6379; font-size: 0.78rem; font-weight: 600; }
    .toast {
        position: fixed; left: 50%; bottom: 28px;
        transform: translate(-50%, 16px);
        display: flex; align-items: center; gap: 9px;
        padding: 11px 20px;
        border-radius: 999px;
        background: rgba(15, 18, 30, 0.92);
        border: 1px solid var(--border-hi);
        box-shadow: 0 18px 40px -12px rgba(0, 0, 0, 0.7);
        font-size: 0.86rem; font-weight: 700;
        opacity: 0;
        pointer-events: none;
        transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
        z-index: 100;
        backdrop-filter: blur(14px);
        -webkit-backdrop-filter: blur(14px);
        max-width: calc(100vw - 32px);
    }
    .toast.show { opacity: 1; transform: translate(-50%, 0); }

    @media (max-width: 640px) {
        .brand-sub { display: none; }
        .stats-row { grid-template-columns: repeat(2, 1fr); }
        .donut-card { justify-content: center; text-align: center; }
        .legend { justify-content: center; }
    }
    @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after { animation: none !important; transition: none !important; }
    }
</style>
</head>
<body>
<div class="orb orb-a" aria-hidden="true"></div>
<div class="orb orb-b" aria-hidden="true"></div>
<div class="orb orb-c" aria-hidden="true"></div>

<header class="topbar">
    <div class="brand">
        <div class="brand-logo">🍺</div>
        <div class="brand-text">
            <span class="brand-name">Brew Update Tracker</span>
            <span class="brand-sub">Homebrew Dashboard</span>
        </div>
    </div>
    <div class="topbar-actions">
        <span class="chip"><span class="dot"></span><span id="chip-time">syncing…</span></span>
        <button class="btn-ghost" id="copy-all" type="button" title="Copy every upgrade/install command">⧉ Copy all commands</button>
    </div>
</header>

<main class="container">
    <section class="hero">
        <h1 class="hero-title">What&rsquo;s <span class="grad">brewing?</span></h1>
        <p class="hero-sub" id="hero-sub">Preparing your report…</p>
    </section>

    <section class="stats-row">
        <div class="stat-card c-amber">
            <div class="stat-icon">📦</div>
            <div class="stat-value" id="stat-update">0</div>
            <div class="stat-label">To Upgrade</div>
        </div>
        <div class="stat-card c-cyan">
            <div class="stat-icon">🆕</div>
            <div class="stat-value" id="stat-new">0</div>
            <div class="stat-label">New Packages</div>
        </div>
        <div class="stat-card c-indigo">
            <div class="stat-icon">🧪</div>
            <div class="stat-value" id="stat-formula">0</div>
            <div class="stat-label">Formulae</div>
        </div>
        <div class="stat-card c-violet">
            <div class="stat-icon">🍷</div>
            <div class="stat-value" id="stat-cask">0</div>
            <div class="stat-label">Casks</div>
        </div>
    </section>

    <section class="donut-card" id="donut-card">
        <div class="donut-wrap">
            <svg width="108" height="108" viewBox="0 0 120 120" aria-hidden="true">
                <circle cx="60" cy="60" r="52" fill="none" stroke="rgba(255,255,255,0.07)" stroke-width="15"/>
                <g id="donut-segs"></g>
            </svg>
            <div class="donut-center">
                <div class="donut-total" id="donut-total">0</div>
                <div class="donut-cap">packages</div>
            </div>
        </div>
        <div class="legend" id="legend"></div>
    </section>

    <section class="controls" id="controls">
        <div class="search-box">
            <span class="s-ico">🔍</span>
            <input type="text" id="search" placeholder="Search by name or description…" autocomplete="off" spellcheck="false">
            <kbd>/</kbd>
        </div>
        <div class="pills" id="pills">
            <button class="pill active" data-filter="all" type="button">All <b id="cnt-all">0</b></button>
            <button class="pill" data-filter="outdated" type="button">📦 Upgrade <b id="cnt-outdated">0</b></button>
            <button class="pill" data-filter="new" type="button">🆕 New <b id="cnt-new">0</b></button>
            <button class="pill" data-filter="formula" type="button">🧪 Formulae <b id="cnt-formula">0</b></button>
            <button class="pill" data-filter="cask" type="button">🍷 Casks <b id="cnt-cask">0</b></button>
        </div>
    </section>

    <section id="feed" class="feed" aria-live="polite"></section>

    <footer class="foot">Generated by Brew Update Tracker · <span id="foot-time"></span></footer>
</main>

<div id="toast" class="toast" role="status">✨ <span id="toast-msg">Done</span></div>

<script id="brew-data" type="application/json">
BREW_HTML_HEAD
        printf '%s\n' "$json_data" | sed 's|</|<\\/|g'
        cat << 'BREW_HTML_TAIL'
</script>
<script>
(function () {
    'use strict';

    var byId = function (id) { return document.getElementById(id); };
    var REDUCED = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    var DATA = (function () {
        try { return JSON.parse(byId('brew-data').textContent || '{}'); }
        catch (e) { return {}; }
    })();

    function arr(x) { return Array.isArray(x) ? x : []; }
    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }
    function changelogUrl(hp) {
        if (!hp) return null;
        var m = hp.match(/^https?:\/\/github\.com\/([^\/#?]+)\/([^\/#?]+)/);
        return m ? 'https://github.com/' + m[1] + '/' + m[2] + '/releases' : null;
    }
    function hashCode(s) {
        var h = 0, i;
        for (i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; }
        return Math.abs(h);
    }

    /* ---------- build the package list ---------- */
    var fMap = new Map(), cMap = new Map();
    arr(DATA.formulae).forEach(function (f) {
        if (f.name) fMap.set(f.name, f);
        if (f.full_name) fMap.set(f.full_name, f);
    });
    arr(DATA.casks).forEach(function (c) {
        if (c.token) cMap.set(c.token, c);
        if (c.full_token) cMap.set(c.full_token, c);
    });
    var oF = new Map();
    arr(DATA.outdated && DATA.outdated.formulae).forEach(function (f) { oF.set(f.name, f); });
    var oC = new Map();
    arr(DATA.outdated && DATA.outdated.casks).forEach(function (c) { oC.set(c.name, c); });

    var packages = [];
    arr(DATA.outdated_formulae).forEach(function (name) {
        var info = fMap.get(name) || {}, v = oF.get(name) || {};
        packages.push({
            name: name, type: 'formula', typeLabel: 'Formula', status: 'update',
            desc: info.desc || 'No description available.',
            homepage: info.homepage || '',
            installed: (v.installed_versions || []).join(', '),
            current: v.current_version || ''
        });
    });
    arr(DATA.outdated_casks).forEach(function (token) {
        var info = cMap.get(token) || {}, v = oC.get(token) || {};
        packages.push({
            name: token, type: 'cask', typeLabel: 'Cask', status: 'update',
            desc: info.desc || 'No description available.',
            homepage: info.homepage || '',
            installed: (v.installed_versions || []).join(', '),
            current: v.current_version || ''
        });
    });
    arr(DATA.new_formulae).forEach(function (name) {
        var info = fMap.get(name) || {};
        packages.push({
            name: name, type: 'formula', typeLabel: 'Formula', status: 'new',
            desc: info.desc || 'No description available.',
            homepage: info.homepage || ''
        });
    });
    arr(DATA.new_casks).forEach(function (token) {
        var info = cMap.get(token) || {};
        packages.push({
            name: token, type: 'cask', typeLabel: 'Cask', status: 'new',
            desc: info.desc || 'No description available.',
            homepage: info.homepage || ''
        });
    });

    var counts = {
        update:  packages.filter(function (p) { return p.status === 'update'; }).length,
        new:     packages.filter(function (p) { return p.status === 'new'; }).length,
        formula: packages.filter(function (p) { return p.type === 'formula'; }).length,
        cask:    packages.filter(function (p) { return p.type === 'cask'; }).length
    };
    counts.total = packages.length;

    /* ---------- header / hero / footer ---------- */
    var ts = DATA.timestamp || '';
    byId('chip-time').textContent = ts || '—';
    byId('foot-time').textContent = ts || '—';
    document.title = '🍺 Brew Update Tracker — ' + counts.total + ' package' + (counts.total === 1 ? '' : 's');

    var sub = byId('hero-sub');
    if (counts.total === 0) {
        sub.innerHTML = 'You’re all caught up — everything is <b>up to date</b>. 🎉';
        byId('donut-card').style.display = 'none';
        byId('controls').style.display = 'none';
    } else {
        var parts = [];
        if (counts.update) parts.push('<b>' + counts.update + '</b> upgrade' + (counts.update === 1 ? '' : 's') + ' pending');
        if (counts.new) parts.push('<b>' + counts.new + '</b> new package' + (counts.new === 1 ? '' : 's'));
        sub.innerHTML = parts.join(' · ') + ' · synced ' + esc(ts);
    }

    /* ---------- animated metric counters ---------- */
    function countUp(el, target) {
        if (REDUCED || target === 0) { el.textContent = String(target); return; }
        var t0 = null, dur = 900;
        function step(t) {
            if (t0 === null) t0 = t;
            var k = Math.min((t - t0) / dur, 1);
            var e = 1 - Math.pow(1 - k, 3);
            el.textContent = String(Math.round(target * e));
            if (k < 1) requestAnimationFrame(step);
        }
        requestAnimationFrame(step);
    }
    countUp(byId('stat-update'), counts.update);
    countUp(byId('stat-new'), counts.new);
    countUp(byId('stat-formula'), counts.formula);
    countUp(byId('stat-cask'), counts.cask);

    byId('cnt-all').textContent = String(counts.total);
    byId('cnt-outdated').textContent = String(counts.update);
    byId('cnt-new').textContent = String(counts.new);
    byId('cnt-formula').textContent = String(counts.formula);
    byId('cnt-cask').textContent = String(counts.cask);

    /* ---------- donut breakdown ---------- */
    (function () {
        var segs = [
            { label: 'Upgrade · Formulae', n: arr(DATA.outdated_formulae).length, color: '#fbbf24' },
            { label: 'Upgrade · Casks',    n: arr(DATA.outdated_casks).length,    color: '#fb7185' },
            { label: 'New · Formulae',     n: arr(DATA.new_formulae).length,      color: '#22d3ee' },
            { label: 'New · Casks',        n: arr(DATA.new_casks).length,         color: '#a78bfa' }
        ].filter(function (s) { return s.n > 0; });

        byId('donut-total').textContent = String(counts.total);
        var NS = 'http://www.w3.org/2000/svg';
        var g = byId('donut-segs');
        var R = 52, CIRC = 2 * Math.PI * R, acc = 0;

        segs.forEach(function (s) {
            var len = s.n / Math.max(counts.total, 1) * CIRC;
            var c = document.createElementNS(NS, 'circle');
            c.setAttribute('cx', '60'); c.setAttribute('cy', '60'); c.setAttribute('r', String(R));
            c.setAttribute('fill', 'none'); c.setAttribute('stroke', s.color); c.setAttribute('stroke-width', '15');
            c.setAttribute('stroke-dasharray', len + ' ' + (CIRC - len));
            c.setAttribute('stroke-dashoffset', String(-acc));
            g.appendChild(c);
            acc += len;
        });

        var legend = byId('legend');
        segs.forEach(function (s) {
            var li = document.createElement('div');
            li.className = 'legend-item';
            li.innerHTML = '<span class="swatch" style="background:' + s.color + '"></span>' + esc(s.label) + ' <b>' + s.n + '</b>';
            legend.appendChild(li);
        });
    })();

    /* ---------- rendering ---------- */
    var feed = byId('feed');
    var search = byId('search');
    var filter = 'all';
    var query = '';

    function matches(p) {
        if (filter === 'outdated' && p.status !== 'update') return false;
        if (filter === 'new' && p.status !== 'new') return false;
        if (filter === 'formula' && p.type !== 'formula') return false;
        if (filter === 'cask' && p.type !== 'cask') return false;
        if (query) {
            var q = query.toLowerCase();
            return p.name.toLowerCase().indexOf(q) > -1 || p.desc.toLowerCase().indexOf(q) > -1;
        }
        return true;
    }
    function commandFor(p) { return (p.status === 'update' ? 'brew upgrade ' : 'brew install ') + p.name; }

    function cardHtml(p, i) {
        var cl = p.homepage ? changelogUrl(p.homepage) : null;
        var cmd = commandFor(p);
        var grad = 'g' + (hashCode(p.name) % 6);
        var initial = esc(p.name.charAt(0).toUpperCase());
        var nameEl = p.homepage
            ? '<a class="pkg-name" href="' + esc(p.homepage) + '" target="_blank" rel="noopener">' + esc(p.name) + '</a>'
            : '<span class="pkg-name">' + esc(p.name) + '</span>';
        var verBar = (p.status === 'update' && p.installed)
            ? '<div class="ver"><span class="ver-old">' + esc(p.installed) + '</span><span class="ver-arrow">⟶</span><span class="ver-new">' + esc(p.current || 'latest') + '</span></div>'
            : '';
        var actions = '<button class="act act-copy" data-cmd="' + esc(cmd) + '" type="button">⚡ <code>' + esc(cmd) + '</code></button>'
            + (cl ? '<a class="act act-changelog" href="' + esc(cl) + '" target="_blank" rel="noopener">📋 Changelog</a>' : '')
            + (p.homepage ? '<a class="act act-home" href="' + esc(p.homepage) + '" target="_blank" rel="noopener">🏠 Homepage</a>' : '');
        return '<article class="card" style="animation-delay:' + Math.min(i * 35, 420) + 'ms">'
            + '<div class="card-main">'
            + '<div class="avatar ' + grad + '" aria-hidden="true">' + initial + '</div>'
            + '<div class="card-body">'
            + '<div class="card-top">' + nameEl
            + '<span class="badge b-' + p.type + '">' + p.typeLabel + '</span>'
            + '<span class="badge ' + (p.status === 'new' ? 'b-new' : 'b-update') + '">' + (p.status === 'new' ? 'New' : 'Update') + '</span>'
            + '</div>' + verBar
            + '<p class="pkg-desc">' + esc(p.desc) + '</p>'
            + '<div class="card-actions">' + actions + '</div>'
            + '</div></div></article>';
    }

    function render() {
        if (counts.total === 0) {
            feed.innerHTML = '<div class="empty party"><span class="e-ico">✨</span>'
                + '<h3>Everything is up to date!</h3>'
                + '<p>No upgrades pending and nothing new to explore.<br>Synced ' + esc(ts) + '</p>'
                + '</div>';
            return;
        }
        var list = packages.filter(matches);
        if (list.length === 0) {
            feed.innerHTML = '<div class="empty"><span class="e-ico">🔍</span><h3>No matches</h3><p>Try a different search or switch filter.</p></div>';
            return;
        }
        feed.innerHTML = list.map(cardHtml).join('');
    }

    /* ---------- interactions ---------- */
    search.addEventListener('input', function () {
        query = search.value.trim();
        render();
    });

    Array.prototype.forEach.call(document.querySelectorAll('.pill'), function (btn) {
        btn.addEventListener('click', function () {
            document.querySelectorAll('.pill').forEach(function (b) { b.classList.remove('active'); });
            btn.classList.add('active');
            filter = btn.getAttribute('data-filter');
            render();
        });
    });

    feed.addEventListener('click', function (e) {
        var btn = e.target.closest('.act-copy');
        if (btn) copyText(btn.getAttribute('data-cmd'), 'Command copied ✓');
    });

    byId('copy-all').addEventListener('click', function () {
        if (counts.total === 0) { toast('Nothing to copy — already up to date 🎉'); return; }
        var seen = {}, cmds = [];
        packages.forEach(function (p) {
            var c = commandFor(p);
            if (!seen[c]) { seen[c] = 1; cmds.push(c); }
        });
        copyText(cmds.join('\n'), cmds.length + ' command' + (cmds.length === 1 ? '' : 's') + ' copied ✓');
    });

    window.addEventListener('keydown', function (e) {
        var ae = document.activeElement;
        if (e.key === '/' && ae !== search && !(ae && ae.tagName === 'INPUT')) {
            e.preventDefault();
            search.focus();
        }
        if (e.key === 'Escape' && ae === search) {
            search.value = '';
            query = '';
            render();
            search.blur();
        }
    });

    /* ---------- clipboard + toast ---------- */
    var toastTimer = null;
    function toast(msg) {
        byId('toast-msg').textContent = msg;
        var t = byId('toast');
        t.classList.add('show');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(function () { t.classList.remove('show'); }, 2200);
    }
    function copyText(text, okMsg) {
        function fallback() {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'fixed';
            ta.style.top = '-1000px';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            var ok = false;
            try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
            document.body.removeChild(ta);
            toast(ok ? (okMsg || 'Copied ✓') : 'Copy failed 😕');
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(function () {
                toast(okMsg || 'Copied ✓');
            }, fallback);
        } else {
            fallback();
        }
    }

    render();
})();
</script>
</body>
</html>
BREW_HTML_TAIL
    } > "$landing_file"

    if [[ -f "$landing_file" ]]; then
        if command -v open >/dev/null 2>&1; then
            if open "$landing_file" 2>>"$LOG_FILE"; then
                printf '%b✅ Dashboard opened in browser: %s%b\n' "$GREEN" "$landing_file" "$RESET"
            else
                # Common case: SSH / headless session (no WindowServer).
                # Don't claim success — just point the user at the file.
                log_error "Could not auto-open the dashboard (no GUI session?). File is at: $landing_file"
                printf '%b📄 Dashboard generated (browser auto-open unavailable): %s%b\n' "$CYAN" "$landing_file" "$RESET"
            fi
        else
            printf '%b📄 Dashboard generated (no %sopen%s command on this system): %s%b\n' "$CYAN" "open" "$RESET" "$landing_file" "$RESET"
        fi
    fi
}

# Step 5: Check upgrade availability & prompt
outdated_f_count=$(jq 'length' <<< "$(get_names_json "$TEMP_DIR/outdated_formulae.txt")")
outdated_c_count=$(jq 'length' <<< "$(get_names_json "$TEMP_DIR/outdated_casks.txt")")
total_updates=$((outdated_f_count + outdated_c_count))

if [[ $total_updates -gt 0 ]]; then
    # Be explicit about formulae vs casks: a plain `brew upgrade` upgrades
    # only formulae, so users with casks outdated need to know.
    if [[ $outdated_c_count -gt 0 && $outdated_f_count -eq 0 ]]; then
        printf '\n%b🚀 Found %s outdated cask(s). (Note: '\''brew upgrade'\'' alone does not touch casks — we will pass '\''--greedy'\''.)%b\n' \
            "$BRIGHT_GREEN" "$outdated_c_count" "$RESET"
    elif [[ $outdated_c_count -gt 0 ]]; then
        printf '\n%b🚀 Found %s outdated formulae and %s outdated cask(s) that can be upgraded.%b\n' \
            "$BRIGHT_GREEN" "$outdated_f_count" "$outdated_c_count" "$RESET"
    else
        printf '\n%b🚀 Found %s outdated formulae that can be upgraded.%b\n' \
            "$BRIGHT_GREEN" "$outdated_f_count" "$RESET"
    fi

    do_upgrade=false
    if [[ "$AUTO_UPGRADE" == true ]]; then
        do_upgrade=true
    elif [[ -t 0 ]]; then
        printf '%bDo you want to perform '\''brew upgrade'\'' now? (y/n): %b' "$YELLOW" "$RESET"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            do_upgrade=true
        fi
    else
        printf '%bNon-interactive session detected. Skipping '\''brew upgrade'\'' (use -y to force).%b\n' "$YELLOW" "$RESET"
    fi

    if [[ "$do_upgrade" == true ]]; then
        # If only casks are outdated, `brew upgrade` (no args) won't touch
        # them. `--greedy` upgrades casks as well; it's a no-op when no
        # casks need an upgrade, so it's safe to pass unconditionally in
        # the cask-only case.
        upgrade_flags=()
        if [[ $outdated_c_count -gt 0 && $outdated_f_count -eq 0 ]]; then
            upgrade_flags=(--greedy)
        fi
        printf '\n%b⬆️ Running '\''brew upgrade %s'\''...%b\n' "$CYAN" "${upgrade_flags[*]}" "$RESET"
        brew upgrade -y "${upgrade_flags[@]}"
        printf '%b✅ Upgrade completed!%b\n' "$GREEN" "$RESET"
    else
        printf '\n%b✋ Upgrade skipped.%b\n' "$YELLOW" "$RESET"
    fi
else
    printf '\n%b✅ No packages to upgrade!%b\n' "$GREEN" "$RESET"
fi

# Step 6: Generate Landing Page (unless --no-dashboard)
if [[ "$NO_DASHBOARD" == true ]]; then
    printf '\n%b📝 Dashboard skipped (--no-dashboard).%b\n' "$CYAN" "$RESET"
else
    generate_landing_page
fi

# Step 7: Log cleanup / summary
# Runs AFTER the dashboard build on purpose: generate_landing_page can append
# errors to $LOG_FILE (e.g. failed `brew info --json=v2` bulk fetches), so this
# summary/cleanup must happen last or those errors would never be reported.
if [[ -f "$LOG_FILE" ]] && ! grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    rm -f "$LOG_FILE"
elif [[ -f "$LOG_FILE" ]]; then
    printf '\n%bSome non-critical warnings or errors occurred. See log: %s%b\n' "$YELLOW" "$LOG_FILE" "$RESET"
fi

printf '\n%b🍺 Brew Update Tracker completed!%b\n' "$BRIGHT_GREEN" "$RESET"
exit 0
