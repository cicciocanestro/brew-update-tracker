#!/bin/zsh

# brew_upgrade_tracker.sh
#
# This script:
# 1. Records installed Homebrew formulae and casks
# 2. Runs 'brew update'
# 3. Parses "New Formulae" and "New Casks" from brew update output
# 4. Shows outdated and new packages with homepage and description
# 5. Prompts the user to perform 'brew upgrade'

# Color definitions
GREEN="\033[0;32m"
BRIGHT_GREEN="\033[1;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RESET="\033[0m"

# Create log file for errors
LOG_FILE="/tmp/brew-update-tracker-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"

# Custom error handling function
log_error() {
    local msg="$1"
    printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
    printf '%bWarning: %s (See %s for details)%b\n' "$YELLOW" "$msg" "$LOG_FILE" "$RESET" >&2
}

# Set error handling - continue on errors but track them
set +e

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    printf '%bError: Homebrew is not installed%b\n' "$RED" "$RESET" >&2
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    printf '%bError: jq is not installed%b\n' "$RED" "$RESET"
    printf '%bPlease install it with: brew install jq%b\n' "$CYAN" "$RESET"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d /tmp/brew-update-tracker.XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

printf '%b🍺 Brew Update Tracker%b\n' "$BRIGHT_GREEN" "$RESET"
printf '%b=======================%b\n' "$BRIGHT_GREEN" "$RESET"

# Step 1: Record current packages before update
printf '\n%b📋 Recording current package lists...%b\n' "$CYAN" "$RESET"
brew list --formula > "$TEMP_DIR/formulae_before.txt"
brew list --cask > "$TEMP_DIR/casks_before.txt"

# Step 2: Run brew update and capture output with progress indicator
printf '\n%b🔄 Updating Homebrew...%b\n' "$CYAN" "$RESET"
(
    brew update > "$TEMP_DIR/brew_update_output.txt" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '.'
        sleep 0.5
    done
    printf '\n'
) 2>/dev/null
< "$TEMP_DIR/brew_update_output.txt" cat

# Step 3: Record packages after update
printf '\n%b📋 Recording updated package lists...%b\n' "$CYAN" "$RESET"
brew list --formula > "$TEMP_DIR/formulae_after.txt"
brew list --cask > "$TEMP_DIR/casks_after.txt"

# Step 4: Extract "New Formulae" and "New Casks" from brew update output
clean_update_output="$TEMP_DIR/brew_update_clean.txt"
if command -v perl &>/dev/null; then
    perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g; s/\\033\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$TEMP_DIR/brew_update_output.txt" > "$clean_update_output" 2>/dev/null
else
    sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$TEMP_DIR/brew_update_output.txt" > "$clean_update_output" 2>/dev/null || cp "$TEMP_DIR/brew_update_output.txt" "$clean_update_output"
fi

extract_new_packages() {
    local section_title="$1"
    local input_file="$2"

    awk -v title="$section_title" '
        BEGIN { p = 0 }
        index($0, title) > 0 { p = 1; next }
        p && /^==>/ {
            if ($0 ~ /==>[[:space:]]*(New Formulae|New Casks|Updated Formulae|Updated Casks|Outdated|Deleted|Renamed)/) {
                p = 0
            }
            next
        }
        p { print }
    ' "$input_file" \
    | sed -e 's/([^)]*)//g' -e 's/:.*//' \
    | tr -s '[:space:]' '\n' \
    | sed -e 's#^.*/##' \
    | grep -E '^[a-zA-Z0-9@+._-]+$' \
    | sort -u
}

extract_new_packages "New Formulae" "$clean_update_output" > "$TEMP_DIR/new_formulae.txt"
extract_new_packages "New Casks" "$clean_update_output" > "$TEMP_DIR/new_casks.txt"

# Step 5: Find outdated packages using JSON
printf '\n%b🔍 Finding outdated packages...%b\n' "$CYAN" "$RESET"
brew outdated --json=v2 > "$TEMP_DIR/outdated.json"

jq -r '.formulae[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_formulae.txt" 2>/dev/null
jq -r '.casks[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_casks.txt" 2>/dev/null

# --- SUPPORT FUNCTION FOR BULK PROCESSING ---
# Passes all packages to brew info --json=v2 at once via xargs,
# then formats the output with jq. Much faster than a per-package loop.
process_packages() {
    local file="$1"
    local title="$2"
    local jq_query="$3"

    printf '\n%b📊 %s:%b\n' "$BRIGHT_GREEN" "$title" "$RESET"

    if [[ ! -s "$file" ]]; then
        printf "  %bNo packages available.%b\n" "$GREEN" "$RESET"
        return
    fi

    < "$file" xargs brew info --json=v2 2>/dev/null | jq -r "$jq_query"
}

# jq queries to format Formulae and Casks output
JQ_FORMULAE_QUERY='.formulae[] | "  - \(.name):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'
JQ_CASKS_QUERY='.casks[] | "  - \(.token):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'

# Step 6 & 7: Process outdated packages
process_packages "$TEMP_DIR/outdated_formulae.txt" "📦 Updated Formulae" "$JQ_FORMULAE_QUERY"
process_packages "$TEMP_DIR/outdated_casks.txt" "📦 Updated Casks" "$JQ_CASKS_QUERY"

# Step 8 & 9: Process new packages
process_packages "$TEMP_DIR/new_formulae.txt" "🆕 New Formulae" "$JQ_FORMULAE_QUERY"
process_packages "$TEMP_DIR/new_casks.txt" "🆕 New Casks" "$JQ_CASKS_QUERY"

# Step 10: Check if there are any updates available
total_updates=$(< "$TEMP_DIR/outdated_formulae.txt" wc -l | tr -d ' ')
total_updates=$(( total_updates + $(< "$TEMP_DIR/outdated_casks.txt" wc -l | tr -d ' ') ))

if [[ $total_updates -gt 0 ]]; then
    # Step 11: Ask if user wants to upgrade
    printf '\n%b🚀 Found %s package(s) that can be upgraded.%b\n' "$BRIGHT_GREEN" "$total_updates" "$RESET"
    printf '%bDo you want to perform '\''brew upgrade'\'' now? (y/n): %b' "$YELLOW" "$RESET"
    read -r answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        printf '\n%b⬆️ Running '\''brew upgrade'\''...%b\n' "$CYAN" "$RESET"
        brew upgrade -y
        printf '%b✅ Upgrade completed!%b\n' "$GREEN" "$RESET"
    else
        printf '\n%b✋ Upgrade skipped.%b\n' "$YELLOW" "$RESET"
    fi
else
    printf '\n%b✅ No packages to upgrade!%b\n' "$GREEN" "$RESET"
fi

# Log cleanup: remove log if no errors recorded
if [[ -f "$LOG_FILE" ]] && ! grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    rm -f "$LOG_FILE"
elif [[ -f "$LOG_FILE" ]]; then
    printf '\n%bSome non-critical errors occurred. See: %s%b\n' "$YELLOW" "$LOG_FILE" "$RESET"
fi

printf '\n%b🍺 Brew Update Tracker completed!%b\n' "$BRIGHT_GREEN" "$RESET"
exit 0
