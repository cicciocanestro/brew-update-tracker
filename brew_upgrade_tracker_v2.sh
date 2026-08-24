#!/bin/zsh

# brew_upgrade_tracker_v2.sh
#
# Optimized & Modernized Brew Update Tracker (v2):
# 1. Runs 'brew update' with visual spinner
# 2. Parses outdated packages and newly added formulae/casks
# 3. Fetches package metadata in bulk using 'brew info --json=v2' & 'jq'
# 4. Generates a state-of-the-art interactive HTML dashboard (Dark Mode, Search, Filters, Copy Commands)
# 5. Prompts for 'brew upgrade' (with non-interactive -y/--yes support)

set +e

# Parse Options / Flags
AUTO_UPGRADE=false

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            AUTO_UPGRADE=true
            ;;
        -h|--help)
            printf "Usage: %s [-y|--yes] [-h|--help]\n" "$0"
            printf "  -y, --yes    Perform 'brew upgrade' automatically without prompting\n"
            printf "  -h, --help   Show this help message\n"
            exit 0
            ;;
    esac
done

# Color definitions for terminal output
GREEN="\033[0;32m"
BRIGHT_GREEN="\033[1;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RESET="\033[0m"

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
trap "rm -rf '$TEMP_DIR'" EXIT

printf '%b🍺 Brew Update Tracker (v2)%b\n' "$BRIGHT_GREEN" "$RESET"
printf '%b============================%b\n' "$BRIGHT_GREEN" "$RESET"

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
process_packages() {
    local file="$1"
    local title="$2"
    local jq_query="$3"

    printf '\n%b📊 %s:%b\n' "$BRIGHT_GREEN" "$title" "$RESET"

    if [[ ! -s "$file" ]]; then
        printf "  %bNo packages available.%b\n" "$GREEN" "$RESET"
        return
    fi

    < "$file" xargs brew info --json=v2 2>>"$LOG_FILE" | jq -r "$jq_query" 2>/dev/null
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
    local landing_file="${TMP_BASE}/brew-update-landing.html"
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
        formulae_json=$(< "$f_list" xargs brew info --json=v2 2>>"$LOG_FILE" | jq -s '[.[].formulae[]?]' 2>/dev/null)
        [[ -z "$formulae_json" ]] && formulae_json="[]"
    fi
    if [[ -s "$c_list" ]]; then
        casks_json=$(< "$c_list" xargs brew info --json=v2 2>>"$LOG_FILE" | jq -s '[.[].casks[]?]' 2>/dev/null)
        [[ -z "$casks_json" ]] && casks_json="[]"
    fi

    local outdated_json_data="{}"
    if [[ -s "$TEMP_DIR/outdated.json" ]]; then
        outdated_json_data=$(< "$TEMP_DIR/outdated.json" cat)
    else
        outdated_json_data='{"formulae":[],"casks":[]}'
    fi

    local new_f_names=$(get_names_json "$TEMP_DIR/new_formulae.txt")
    local new_c_names=$(get_names_json "$TEMP_DIR/new_casks.txt")
    local out_f_names=$(get_names_json "$TEMP_DIR/outdated_formulae.txt")
    local out_c_names=$(get_names_json "$TEMP_DIR/outdated_casks.txt")

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

    # Counts
    local new_f_count=$(jq 'length' <<< "$new_f_names")
    local new_c_count=$(jq 'length' <<< "$new_c_names")
    local out_f_count=$(jq 'length' <<< "$out_f_names")
    local out_c_count=$(jq 'length' <<< "$out_c_names")

    local updated_total=$((out_f_count + out_c_count))
    local new_total=$((new_f_count + new_c_count))

    cat > "$landing_file" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🍺 Brew Update Tracker</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }

        :root {
            --bg: #090a0f;
            --surface: rgba(18, 20, 29, 0.75);
            --surface-hover: rgba(26, 29, 43, 0.85);
            --border: rgba(255, 255, 255, 0.08);
            --border-hover: rgba(99, 102, 241, 0.35);
            --text: #f1f5f9;
            --text-muted: #94a3b8;
            --accent: #6366f1;
            --accent-light: #818cf8;
            --cyan: #06b6d4;
            --emerald: #10b981;
            --amber: #f59e0b;
            --rose: #f43f5e;
            --purple: #a855f7;
            --radius-lg: 16px;
            --radius-md: 10px;
            --radius-sm: 6px;
        }

        body {
            font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
            background-color: var(--bg);
            background-image:
                radial-gradient(circle at 50% -10%, rgba(99, 102, 241, 0.15), transparent 45%),
                radial-gradient(circle at 90% 60%, rgba(6, 182, 212, 0.08), transparent 40%),
                radial-gradient(circle at 10% 90%, rgba(168, 85, 247, 0.08), transparent 40%);
            background-attachment: fixed;
            color: var(--text);
            line-height: 1.6;
            min-height: 100vh;
            padding-bottom: 60px;
            -webkit-font-smoothing: antialiased;
        }

        .container {
            max-width: 960px;
            margin: 0 auto;
            padding: 40px 20px;
        }

        /* Header */
        header {
            text-align: center;
            margin-bottom: 36px;
            animation: fadeInDown 0.6s cubic-bezier(0.16, 1, 0.3, 1);
        }

        @keyframes fadeInDown {
            from { opacity: 0; transform: translateY(-16px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .logo-wrapper {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 72px;
            height: 72px;
            font-size: 2.2rem;
            border-radius: 22px;
            background: linear-gradient(135deg, rgba(99, 102, 241, 0.25), rgba(6, 182, 212, 0.1));
            border: 1px solid rgba(99, 102, 241, 0.3);
            box-shadow: 0 8px 24px -6px rgba(99, 102, 241, 0.3);
            margin-bottom: 16px;
            backdrop-filter: blur(12px);
        }

        header h1 {
            font-size: 2.4rem;
            font-weight: 800;
            letter-spacing: -0.8px;
            background: linear-gradient(135deg, #ffffff 0%, #cbd5e1 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 8px;
        }

        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 4px 14px;
            border-radius: 20px;
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid var(--border);
            font-size: 0.85rem;
            color: var(--text-muted);
            font-weight: 500;
        }

        .pulse-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background-color: var(--emerald);
            box-shadow: 0 0 10px var(--emerald);
            animation: pulse 2s infinite;
        }

        @keyframes pulse {
            0% { opacity: 1; transform: scale(1); }
            50% { opacity: 0.4; transform: scale(0.85); }
            100% { opacity: 1; transform: scale(1); }
        }

        /* Metrics Bar */
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
            gap: 16px;
            margin-bottom: 32px;
            animation: fadeInUp 0.6s cubic-bezier(0.16, 1, 0.3, 1) 0.1s both;
        }

        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(16px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .metric-card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            padding: 20px 24px;
            backdrop-filter: blur(16px);
            transition: all 0.25s ease;
            position: relative;
            overflow: hidden;
        }

        .metric-card:hover {
            transform: translateY(-3px);
            border-color: var(--border-hover);
            box-shadow: 0 12px 28px -10px rgba(0, 0, 0, 0.4);
        }

        .metric-card .icon-box {
            font-size: 1.5rem;
            margin-bottom: 12px;
        }

        .metric-card .number {
            font-size: 2.2rem;
            font-weight: 800;
            line-height: 1;
            margin-bottom: 6px;
            letter-spacing: -1px;
        }

        .metric-card .label {
            font-size: 0.78rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.8px;
            color: var(--text-muted);
        }

        .val-amber { color: var(--amber); }
        .val-cyan { color: var(--cyan); }
        .val-indigo { color: var(--accent-light); }
        .val-purple { color: var(--purple); }

        /* Controls Section (Search & Filter Tabs) */
        .controls-wrapper {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            padding: 16px 20px;
            margin-bottom: 28px;
            backdrop-filter: blur(16px);
            display: flex;
            flex-direction: column;
            gap: 16px;
            animation: fadeInUp 0.6s cubic-bezier(0.16, 1, 0.3, 1) 0.2s both;
        }

        @media (min-width: 640px) {
            .controls-wrapper {
                flex-direction: row;
                align-items: center;
                justify-content: space-between;
            }
        }

        .search-box {
            position: relative;
            flex: 1;
            max-width: 380px;
        }

        .search-box input {
            width: 100%;
            padding: 10px 16px 10px 40px;
            border-radius: var(--radius-md);
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid var(--border);
            color: var(--text);
            font-family: inherit;
            font-size: 0.9rem;
            outline: none;
            transition: all 0.2s ease;
        }

        .search-box input:focus {
            border-color: var(--accent);
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.25);
            background: rgba(0, 0, 0, 0.5);
        }

        .search-icon {
            position: absolute;
            left: 14px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-muted);
            font-size: 0.9rem;
            pointer-events: none;
        }

        .filter-tabs {
            display: flex;
            gap: 6px;
            overflow-x: auto;
            padding-bottom: 4px;
        }

        @media (min-width: 640px) {
            .filter-tabs { padding-bottom: 0; }
        }

        .tab-btn {
            padding: 8px 14px;
            border-radius: var(--radius-md);
            border: 1px solid transparent;
            background: transparent;
            color: var(--text-muted);
            font-family: inherit;
            font-size: 0.82rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
            white-space: nowrap;
        }

        .tab-btn:hover {
            color: var(--text);
            background: rgba(255, 255, 255, 0.05);
        }

        .tab-btn.active {
            color: var(--text);
            background: rgba(99, 102, 241, 0.18);
            border-color: rgba(99, 102, 241, 0.35);
        }

        /* Package Feed */
        .package-feed {
            display: flex;
            flex-direction: column;
            gap: 12px;
            animation: fadeInUp 0.6s cubic-bezier(0.16, 1, 0.3, 1) 0.3s both;
        }

        .card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            padding: 20px 24px;
            backdrop-filter: blur(16px);
            transition: all 0.25s cubic-bezier(0.16, 1, 0.3, 1);
            position: relative;
        }

        .card:hover {
            transform: translateY(-2px);
            border-color: var(--border-hover);
            box-shadow: 0 12px 30px -10px rgba(0, 0, 0, 0.4);
        }

        .card-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            margin-bottom: 8px;
            flex-wrap: wrap;
        }

        .card-title-group {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }

        .card-title {
            font-size: 1.15rem;
            font-weight: 700;
            color: var(--text);
            text-decoration: none;
            transition: color 0.2s;
        }

        .card-title:hover {
            color: var(--accent-light);
        }

        .badge-list {
            display: flex;
            gap: 6px;
            align-items: center;
        }

        .badge {
            font-size: 0.72rem;
            font-weight: 700;
            padding: 3px 10px;
            border-radius: 20px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            display: inline-flex;
            align-items: center;
            gap: 4px;
        }

        .badge-formula {
            background: rgba(99, 102, 241, 0.12);
            color: var(--accent-light);
            border: 1px solid rgba(99, 102, 241, 0.25);
        }

        .badge-cask {
            background: rgba(168, 85, 247, 0.12);
            color: var(--purple);
            border: 1px solid rgba(168, 85, 247, 0.25);
        }

        .badge-outdated {
            background: rgba(245, 158, 11, 0.12);
            color: var(--amber);
            border: 1px solid rgba(245, 158, 11, 0.25);
        }

        .badge-new {
            background: rgba(6, 182, 212, 0.12);
            color: var(--cyan);
            border: 1px solid rgba(6, 182, 212, 0.25);
        }

        /* Version Transition Bar */
        .version-bar {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: rgba(0, 0, 0, 0.25);
            border: 1px solid rgba(255, 255, 255, 0.05);
            padding: 4px 12px;
            border-radius: var(--radius-md);
            margin-bottom: 10px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
        }

        .ver-old {
            color: var(--rose);
            background: rgba(244, 63, 94, 0.12);
            padding: 2px 8px;
            border-radius: var(--radius-sm);
        }

        .ver-arrow {
            color: var(--text-muted);
            font-size: 0.75rem;
        }

        .ver-new {
            color: var(--emerald);
            background: rgba(16, 185, 129, 0.12);
            padding: 2px 8px;
            border-radius: var(--radius-sm);
        }

        .card-desc {
            color: var(--text-muted);
            font-size: 0.92rem;
            line-height: 1.5;
            margin-bottom: 14px;
        }

        .card-actions {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
            padding-top: 10px;
            border-top: 1px solid rgba(255, 255, 255, 0.04);
        }

        .action-btn {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 6px 12px;
            border-radius: var(--radius-md);
            font-size: 0.8rem;
            font-weight: 600;
            text-decoration: none;
            color: var(--text-muted);
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid var(--border);
            cursor: pointer;
            transition: all 0.2s ease;
        }

        .action-btn:hover {
            color: var(--text);
            background: rgba(255, 255, 255, 0.08);
            border-color: rgba(255, 255, 255, 0.15);
        }

        .action-btn.btn-copy:hover {
            color: var(--accent-light);
            background: rgba(99, 102, 241, 0.12);
            border-color: rgba(99, 102, 241, 0.3);
        }

        .action-btn.btn-changelog {
            color: var(--amber);
            background: rgba(245, 158, 11, 0.08);
            border-color: rgba(245, 158, 11, 0.2);
        }

        .action-btn.btn-changelog:hover {
            color: #fde047;
            background: rgba(245, 158, 11, 0.16);
            border-color: rgba(245, 158, 11, 0.35);
        }

        .empty-state {
            text-align: center;
            padding: 48px 24px;
            background: var(--surface);
            border: 1px dashed var(--border);
            border-radius: var(--radius-lg);
            color: var(--text-muted);
        }

        .empty-state .icon {
            font-size: 2.5rem;
            margin-bottom: 12px;
            display: block;
        }

        /* Toast Notification */
        .toast {
            position: fixed;
            bottom: 24px;
            right: 24px;
            background: rgba(15, 23, 42, 0.95);
            border: 1px solid var(--accent);
            color: var(--text);
            padding: 12px 20px;
            border-radius: var(--radius-md);
            font-size: 0.88rem;
            font-weight: 600;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,0.5);
            display: flex;
            align-items: center;
            gap: 10px;
            z-index: 1000;
            opacity: 0;
            transform: translateY(20px);
            transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
            pointer-events: none;
            backdrop-filter: blur(12px);
        }

        .toast.show {
            opacity: 1;
            transform: translateY(0);
        }

        footer {
            text-align: center;
            margin-top: 40px;
            color: var(--text-muted);
            font-size: 0.85rem;
            font-weight: 500;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="logo-wrapper">🍺</div>
            <h1>Brew Update Tracker</h1>
            <div class="status-badge">
                <span class="pulse-dot"></span>
                <span>Report Generated • ${timestamp}</span>
            </div>
        </header>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="icon-box">📦</div>
                <div class="number val-amber">${updated_total}</div>
                <div class="label">To Upgrade</div>
            </div>
            <div class="metric-card">
                <div class="icon-box">🆕</div>
                <div class="number val-cyan">${new_total}</div>
                <div class="label">New Packages</div>
            </div>
            <div class="metric-card">
                <div class="icon-box">🧪</div>
                <div class="number val-indigo">$((out_f_count + new_f_count))</div>
                <div class="label">Formulae</div>
            </div>
            <div class="metric-card">
                <div class="icon-box">🍷</div>
                <div class="number val-purple">$((out_c_count + new_c_count))</div>
                <div class="label">Casks</div>
            </div>
        </div>

        <div class="controls-wrapper">
            <div class="search-box">
                <span class="search-icon">🔍</span>
                <input type="text" id="search-input" placeholder="Filter by package name or description..." />
            </div>
            <div class="filter-tabs">
                <button class="tab-btn active" data-filter="all">All (${$((updated_total + new_total))})</button>
                <button class="tab-btn" data-filter="outdated">📦 To Upgrade (${updated_total})</button>
                <button class="tab-btn" data-filter="new">🆕 New (${new_total})</button>
                <button class="tab-btn" data-filter="formula">🧪 Formulae</button>
                <button class="tab-btn" data-filter="cask">🍷 Casks</button>
            </div>
        </div>

        <main id="package-feed" class="package-feed">
            <!-- Dynamic package cards rendered by JS -->
        </main>

        <footer>
            🍺 Brew Update Tracker v2 • Modern Dashboard Output
        </footer>
    </div>

    <div id="toast" class="toast">
        <span>✨</span>
        <span class="toast-msg">Copied command!</span>
    </div>

    <script id="brew-data" type="application/json">
${json_data}
    </script>

    <script>
    (function() {
        const rawData = JSON.parse(document.getElementById('brew-data').textContent || '{}');
        const packages = [];

        const formulaeMap = new Map((rawData.formulae || []).map(f => [f.name, f]));
        const casksMap = new Map((rawData.casks || []).map(c => [c.token, c]));

        const outdatedFormulaeMap = new Map(((rawData.outdated && rawData.outdated.formulae) || []).map(f => [f.name, f]));
        const outdatedCasksMap = new Map(((rawData.outdated && rawData.outdated.casks) || []).map(c => [c.name, c]));

        function getChangelogUrl(homepage) {
            if (!homepage) return null;
            const match = homepage.match(/^https?:\/\/github\.com\/([^\/]+)\/([^\/]+)/);
            if (match) {
                return \`https://github.com/\${match[1]}/\${match[2]}/releases\`;
            }
            return null;
        }

        // 1. Process Outdated Formulae
        (rawData.outdated_formulae || []).forEach(name => {
            const info = formulaeMap.get(name) || {};
            const ver = outdatedFormulaeMap.get(name) || {};
            packages.push({
                name: name,
                type: 'formula',
                status: 'outdated',
                desc: info.desc || 'No description available.',
                homepage: info.homepage || '#',
                installed_version: (ver.installed_versions || []).join(', '),
                current_version: ver.current_version || 'latest',
                changelog: getChangelogUrl(info.homepage)
            });
        });

        // 2. Process Outdated Casks
        (rawData.outdated_casks || []).forEach(token => {
            const info = casksMap.get(token) || {};
            const ver = outdatedCasksMap.get(token) || {};
            packages.push({
                name: token,
                type: 'cask',
                status: 'outdated',
                desc: info.desc || 'No description available.',
                homepage: info.homepage || '#',
                installed_version: (ver.installed_versions || []).join(', '),
                current_version: ver.current_version || 'latest',
                changelog: getChangelogUrl(info.homepage)
            });
        });

        // 3. Process New Formulae
        (rawData.new_formulae || []).forEach(name => {
            const info = formulaeMap.get(name) || {};
            packages.push({
                name: name,
                type: 'formula',
                status: 'new',
                desc: info.desc || 'No description available.',
                homepage: info.homepage || '#',
                changelog: getChangelogUrl(info.homepage)
            });
        });

        // 4. Process New Casks
        (rawData.new_casks || []).forEach(token => {
            const info = casksMap.get(token) || {};
            packages.push({
                name: token,
                type: 'cask',
                status: 'new',
                desc: info.desc || 'No description available.',
                homepage: info.homepage || '#',
                changelog: getChangelogUrl(info.homepage)
            });
        });

        let activeFilter = 'all';
        let searchQuery = '';

        const feedEl = document.getElementById('package-feed');
        const searchInput = document.getElementById('search-input');
        const tabBtns = document.querySelectorAll('.tab-btn');
        const toast = document.getElementById('toast');

        function escapeHtml(str) {
            return (str || '').replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
        }

        function showToast(msg) {
            toast.querySelector('.toast-msg').textContent = msg;
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 2500);
        }

        window.copyCommand = function(cmd) {
            navigator.clipboard.writeText(cmd).then(() => {
                showToast(\`Copied: "\${cmd}"\`);
            }).catch(() => {
                showToast(\`Failed to copy: \${cmd}\`);
            });
        };

        function render() {
            const filtered = packages.filter(pkg => {
                if (activeFilter === 'outdated' && pkg.status !== 'outdated') return false;
                if (activeFilter === 'new' && pkg.status !== 'new') return false;
                if (activeFilter === 'formula' && pkg.type !== 'formula') return false;
                if (activeFilter === 'cask' && pkg.type !== 'cask') return false;

                if (searchQuery) {
                    const q = searchQuery.toLowerCase();
                    const matchName = pkg.name.toLowerCase().includes(q);
                    const matchDesc = pkg.desc.toLowerCase().includes(q);
                    return matchName || matchDesc;
                }

                return true;
            });

            if (filtered.length === 0) {
                feedEl.innerHTML = \`
                    <div class="empty-state">
                        <span class="icon">🔍</span>
                        <h3>No packages found</h3>
                        <p>Try adjusting your search query or filter tabs.</p>
                    </div>
                \`;
                return;
            }

            feedEl.innerHTML = filtered.map(pkg => {
                const isOutdated = pkg.status === 'outdated';
                const cmd = isOutdated ? \`brew upgrade \${pkg.name}\` : \`brew install \${pkg.name}\`;

                const versionHtml = isOutdated && pkg.installed_version && pkg.current_version
                    ? \`<div class="version-bar">
                            <span class="ver-old">\${escapeHtml(pkg.installed_version)}</span>
                            <span class="ver-arrow">→</span>
                            <span class="ver-new">\${escapeHtml(pkg.current_version)}</span>
                       </div>\`
                    : '';

                const changelogHtml = pkg.changelog
                    ? \`<a class="action-btn btn-changelog" href="\${escapeHtml(pkg.changelog)}" target="_blank">📋 Changelog</a>\`
                    : '';

                const homepageHtml = pkg.homepage && pkg.homepage !== '#'
                    ? \`<a class="action-btn" href="\${escapeHtml(pkg.homepage)}" target="_blank">🏠 Homepage</a>\`
                    : '';

                return \`
                    <div class="card">
                        <div class="card-header">
                            <div class="card-title-group">
                                <a class="card-title" href="\${escapeHtml(pkg.homepage)}" target="_blank">\${escapeHtml(pkg.name)}</a>
                                <div class="badge-list">
                                    <span class="badge badge-\${pkg.type}">\${pkg.type}</span>
                                    <span class="badge badge-\${pkg.status}">\${pkg.status}</span>
                                </div>
                            </div>
                        </div>
                        \${versionHtml}
                        <p class="card-desc">\${escapeHtml(pkg.desc)}</p>
                        <div class="card-actions">
                            <button class="action-btn btn-copy" onclick="copyCommand('\${escapeHtml(cmd)}')">
                                ⚡ <code>\${escapeHtml(cmd)}</code>
                            </button>
                            \${changelogHtml}
                            \${homepageHtml}
                        </div>
                    </div>
                \`;
            }).join('');
        }

        searchInput.addEventListener('input', (e) => {
            searchQuery = e.target.value.trim();
            render();
        });

        tabBtns.forEach(btn => {
            btn.addEventListener('click', () => {
                tabBtns.forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                activeFilter = btn.dataset.filter;
                render();
            });
        });

        render();
    })();
    </script>
</body>
</html>
HTMLEOF

    if [[ -f "$landing_file" ]]; then
        open "$landing_file"
        printf '%b✅ Landing page opened in browser: %s%b\n' "$GREEN" "$landing_file" "$RESET"
    fi
}

# Step 5: Check upgrade availability & prompt
outdated_f_count=$(jq 'length' <<< "$(get_names_json "$TEMP_DIR/outdated_formulae.txt")")
outdated_c_count=$(jq 'length' <<< "$(get_names_json "$TEMP_DIR/outdated_casks.txt")")
total_updates=$((outdated_f_count + outdated_c_count))

if [[ $total_updates -gt 0 ]]; then
    printf '\n%b🚀 Found %s package(s) that can be upgraded.%b\n' "$BRIGHT_GREEN" "$total_updates" "$RESET"

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
        printf '\n%b⬆️ Running '\''brew upgrade'\''...%b\n' "$CYAN" "$RESET"
        brew upgrade -y
        printf '%b✅ Upgrade completed!%b\n' "$GREEN" "$RESET"
    else
        printf '\n%b✋ Upgrade skipped.%b\n' "$YELLOW" "$RESET"
    fi
else
    printf '\n%b✅ No packages to upgrade!%b\n' "$GREEN" "$RESET"
fi

# Step 6: Log cleanup / summary
if [[ -f "$LOG_FILE" ]] && ! grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    rm -f "$LOG_FILE"
elif [[ -f "$LOG_FILE" ]]; then
    printf '\n%bSome non-critical warnings or errors occurred. See log: %s%b\n' "$YELLOW" "$LOG_FILE" "$RESET"
fi

# Step 7: Generate Landing Page
generate_landing_page

printf '\n%b🍺 Brew Update Tracker completed!%b\n' "$BRIGHT_GREEN" "$RESET"
exit 0
