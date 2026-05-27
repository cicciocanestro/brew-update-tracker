#!/bin/zsh

# brew_update_tracker.sh
# 
# This script:
# 1. Records installed Homebrew formulae and casks
# 2. Runs 'brew update'
# 3. Identifies updated and new packages
# 4. Shows the homepages for each package
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
    printf "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: $msg\n" >> "$LOG_FILE"
    printf "${YELLOW}Warning: $msg (See $LOG_FILE for details)${RESET}\n" >&2
}

# Set error handling - continue on errors but track them
set +e

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    printf "${RED}Error: Homebrew is not installed${RESET}\n" >&2
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    printf "${RED}Error: jq is not installed${RESET}\n"
    printf "${CYAN}Please install it with: brew install jq${RESET}\n"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d /tmp/brew-update-tracker.XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

printf "${BRIGHT_GREEN}🍺 Brew Update Tracker${RESET}\n"
printf "${BRIGHT_GREEN}=======================${RESET}\n"

# Step 1: Record current packages before update
printf "\n${CYAN}📋 Recording current package lists...${RESET}\n"
brew list --formula > "$TEMP_DIR/formulae_before.txt"
brew list --cask > "$TEMP_DIR/casks_before.txt"

# Step 2: Run brew update and capture output with progress indicator
printf "\n${CYAN}🔄 Updating Homebrew...${RESET}\n"
(brew update > "$TEMP_DIR/brew_update_output.txt" 2>&1 &
 pid=$!
 while kill -0 $pid 2>/dev/null; do
     printf "."
     sleep 0.5
 done
 printf "\n") 2>/dev/null
cat "$TEMP_DIR/brew_update_output.txt"

# Step 3: Extract new formulae and casks from brew update output
printf "Parsing brew update output for new packages...\n" >> "$LOG_FILE"

sed -n '/^==> New Formulae/,/^==>/p' "$TEMP_DIR/brew_update_output.txt" | \
    sed -n '2,/^==>/p' | grep -v "^==>" | sed '/^[[:space:]]*$/d' | awk '{print $1}' | sed 's/:$//' > "$TEMP_DIR/new_formulae_from_update.txt" 2>> "$LOG_FILE"

sed -n '/^==> New Casks/,/^==>/p' "$TEMP_DIR/brew_update_output.txt" | \
    sed -n '2,/^==>/p' | grep -v "^==>" | sed '/^[[:space:]]*$/d' | awk -F: '{print $1}' | sed 's/:$//' | sed 's/^[[:space:]]*//' | grep -v "^$" > "$TEMP_DIR/new_casks_from_update.txt" 2>> "$LOG_FILE"

sort -u "$TEMP_DIR/new_casks_from_update.txt" -o "$TEMP_DIR/new_casks_from_update.txt"

# Step 4: Record packages after update
brew list --formula > "$TEMP_DIR/formulae_after.txt"
brew list --cask > "$TEMP_DIR/casks_after.txt"

# Step 5: Find outdated packages using JSON (Più sicuro e pulito)
printf "\n${CYAN}🔍 Finding outdated packages...${RESET}\n"
brew outdated --json=v2 > "$TEMP_DIR/outdated.json"

# Estraiamo i nomi direttamente dal JSON senza usare sed
jq -r '.formulae[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_formulae.txt" 2>/dev/null
jq -r '.casks[].name' "$TEMP_DIR/outdated.json" > "$TEMP_DIR/outdated_casks.txt" 2>/dev/null


# --- FUNZIONE DI SUPPORTO PER L'ELABORAZIONE IN BLOCCO ---
# Questa funzione accetta una lista di pacchetti, li passa a brew info tutti in una volta,
# e usa jq per formattare l'output. È incredibilmente più veloce di un ciclo while.
process_packages() {
    local type="$1"       # "formulae" o "casks"
    local file="$2"       # File contenente i nomi dei pacchetti
    local title="$3"      # Titolo da stampare
    local jq_query="$4"   # Query jq per formattare l'output

    printf "\n${CYAN}📊 Processing ${title}...${RESET}\n"
    if [[ -s "$file" ]]; then
        printf "\n${BRIGHT_GREEN}${title}:${RESET}\n"
        # Usiamo xargs per passare tutti i nomi a brew info in un solo comando
        cat "$file" | xargs brew info --json=v2 2>/dev/null | jq -r "$jq_query"
    else
        printf "  ${GREEN}No packages available.${RESET}\n"
    fi
}

# Query JQ per formattare l'output di Formulae e Casks
JQ_FORMULAE_QUERY='.formulae[] | "  - \(.name):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'
JQ_CASKS_QUERY='.casks[] | "  - \(.token):\n      Homepage: \(.homepage // "Unable to retrieve homepage")\n      Description: \(.desc // "Unable to retrieve description")"'

# Step 6 & 7: Process outdated packages (Bulk)
process_packages "formulae" "$TEMP_DIR/outdated_formulae.txt" "📦 Updated Formulae" "$JQ_FORMULAE_QUERY"
process_packages "casks" "$TEMP_DIR/outdated_casks.txt" "📦 Updated Casks" "$JQ_CASKS_QUERY"

# Step 8 & 9: Process new packages (Bulk)
# Puliamo i cask nuovi da eventuali tap per sicurezza prima di passarli a brew info
if [[ -s "$TEMP_DIR/new_casks_from_update.txt" ]]; then
    sed -i '' 's/.*:://' "$TEMP_DIR/new_casks_from_update.txt"
fi

process_packages "formulae" "$TEMP_DIR/new_formulae_from_update.txt" "🆕 New Formulae" "$JQ_FORMULAE_QUERY"
process_packages "casks" "$TEMP_DIR/new_casks_from_update.txt" "🆕 New Casks" "$JQ_CASKS_QUERY"


# Step 10: Check if there are any updates available
total_updates=$(cat "$TEMP_DIR/outdated_formulae.txt" "$TEMP_DIR/outdated_casks.txt" | wc -l | tr -d ' ')

if [[ $total_updates -gt 0 ]]; then
    # Step 11: Ask if user wants to upgrade
    printf "\n${BRIGHT_GREEN}🚀 Found $total_updates package(s) that can be upgraded.${RESET}\n"
    printf "${YELLOW}Do you want to perform 'brew upgrade' now? (y/n): ${RESET}"
    read -r answer
    
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        printf "\n${CYAN}⬆️ Running 'brew upgrade'...${RESET}\n"
        brew upgrade
        printf "${GREEN}✅ Upgrade completed!${RESET}\n"
    else
        printf "\n${YELLOW}✋ Upgrade skipped.${RESET}\n"
    fi
else
    printf "\n${GREEN}✅ No packages to upgrade!${RESET}\n"
fi

# Check if there were any errors during execution
if grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    echo -e "\n${YELLOW}Some non-critical errors occurred during execution.${RESET}"
    echo -e "${YELLOW}See log file for details: $LOG_FILE${RESET}"
else
    rm -f "$LOG_FILE"
fi

if [[ -f "$LOG_FILE" ]]; then
    echo -e "${CYAN}Log file created at: $LOG_FILE${RESET}"
fi

echo -e "\n${BRIGHT_GREEN}🍺 Brew Update Tracker completed!${RESET}"
exit 0