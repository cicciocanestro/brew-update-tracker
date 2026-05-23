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

# Helper function to safely parse JSON with jq
# Usage: safe_jq_parse "json_string" ".path.to.field" ["default_value"]
safe_jq_parse() {
    local json="$1"
    local query="$2"
    local default="${3:-N/A}"
    
    # Remove control characters that can cause jq to fail
    local sanitized_json=$(echo "$json" | tr -d '\000-\037')
    
    # Try to parse with jq, with error handling
    local result
    result=$(echo "$sanitized_json" | jq -r "$query" 2>/dev/null) || result="$default"
    
    # Check if result is null or empty
    if [[ "$result" == "null" || -z "$result" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

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

# Get all formulae and casks before update
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
# Look for "==> New Formulae" and "==> New Casks" sections
printf "Parsing brew update output for new packages...\n" >> "$LOG_FILE"

# Extract new formulae from brew update output
sed -n '/^==> New Formulae/,/^==> New Casks/p' "$TEMP_DIR/brew_update_output.txt" | \
    grep -v "^==>" | sed '/^[[:space:]]*$/d' | awk '{print $1}' | sed 's/:$//' > "$TEMP_DIR/new_formulae_from_update.txt" 2>> "$LOG_FILE"

# Extract new casks from brew update output
sed -n '/^==> New Casks/,$p' "$TEMP_DIR/brew_update_output.txt" | \
    grep -v "^==>" | sed '/^[[:space:]]*$/d' | awk '{print $1}' | sed 's/:$//' | grep -v "^$" > "$TEMP_DIR/new_casks_from_update.txt" 2>> "$LOG_FILE"

# Also extract casks that have descriptions after colon (format: "cask-name: description")
sed -n '/^==> New Casks/,$p' "$TEMP_DIR/brew_update_output.txt" | \
    grep -v "^==>" | sed '/^[[:space:]]*$/d' | grep ":" | awk -F: '{print $1}' | sed 's/^[[:space:]]*//' >> "$TEMP_DIR/new_casks_from_update.txt" 2>> "$LOG_FILE"

# Remove duplicates
sort -u "$TEMP_DIR/new_casks_from_update.txt" -o "$TEMP_DIR/new_casks_from_update.txt"

# Step 4: Record packages after update
# Get all formulae and casks after update
brew list --formula > "$TEMP_DIR/formulae_after.txt"
brew list --cask > "$TEMP_DIR/casks_after.txt"

# Step 5: Find outdated packages
printf "\n${CYAN}🔍 Finding outdated packages...${RESET}\n"
brew outdated --formula > "$TEMP_DIR/outdated_formulae.txt"
brew outdated --cask > "$TEMP_DIR/outdated_casks.txt"

# Clean outdated package names (remove version info in parentheses)
sed -i '' 's/ ([^)]*)$//' "$TEMP_DIR/outdated_formulae.txt"
sed -i '' 's/ ([^)]*)$//' "$TEMP_DIR/outdated_casks.txt"

# Step 6: Process formulae (simplified approach)
printf "\n${CYAN}📊 Processing updated formulae...${RESET}\n"
if [[ -s "$TEMP_DIR/outdated_formulae.txt" ]]; then
    printf "\n${BRIGHT_GREEN}📦 Updated Formulae:${RESET}\n"
    
    while read -r formula; do
        [[ -z "$formula" ]] && continue
        # Get info directly for each formula
        homepage=$(brew info --json=v2 "$formula" 2>/dev/null | jq -r '.formulae[0].homepage // "Unable to retrieve homepage"')
        desc=$(brew info --json=v2 "$formula" 2>/dev/null | jq -r '.formulae[0].desc // "Unable to retrieve description"')
        echo "  - $formula:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/outdated_formulae.txt"
else
    printf "  ${GREEN}No formula updates available.${RESET}\n"
fi

# Step 7: Process casks (simplified approach)
printf "\n${CYAN}📊 Processing updated casks...${RESET}\n"
if [[ -s "$TEMP_DIR/outdated_casks.txt" ]]; then
    printf "\n${BRIGHT_GREEN}📦 Updated Casks:${RESET}\n"
    
    while read -r cask; do
        [[ -z "$cask" ]] && continue
        cask_clean="${cask%%::*}"
        # Get info directly for each cask
        homepage=$(brew info --json=v2 "$cask_clean" 2>/dev/null | jq -r '.casks[0].homepage // "Unable to retrieve homepage"')
        desc=$(brew info --json=v2 "$cask_clean" 2>/dev/null | jq -r '.casks[0].desc // "Unable to retrieve description"')
        echo "  - $cask:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/outdated_casks.txt"
else
    printf "  ${GREEN}No cask updates available.${RESET}\n"
fi

# Step 8: Process new formulae (optimized with parallel requests)
printf "\n${CYAN}📊 Processing new formulae in repositories...${RESET}\n"
if [[ -s "$TEMP_DIR/new_formulae_from_update.txt" ]]; then
    printf "\n${BRIGHT_GREEN}🆕 New Formulae:${RESET}\n"
    
    # Fetch all info and store in a single JSON array
    {
        echo "["
        first=true
        cat "$TEMP_DIR/new_formulae_from_update.txt" | while read -r formula; do
            [[ -z "$formula" ]] && continue
            if [[ "$first" == false ]]; then echo ","; fi
            first=false
            brew info --json=v2 "$formula" 2>/dev/null | jq '.formulae[0] // {"homepage":"Error","desc":"Could not retrieve info"}' || echo '{"homepage":"Error","desc":"Could not retrieve info"}'
        done
        echo "]"
    } > "$TEMP_DIR/new_formulae_info_cache.json"
    
    # Parse cached JSON data
    while read -r formula; do
        [[ -z "$formula" ]] && continue
        info=$(jq ".[] | select(.name==\"$formula\")" "$TEMP_DIR/new_formulae_info_cache.json" 2>/dev/null | head -1)
        [[ -z "$info" ]] && info='{"homepage":"Error","desc":"Could not retrieve info"}'
        homepage=$(safe_jq_parse "$info" '.homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.desc' "Unable to retrieve description")
        echo "  - $formula:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/new_formulae_from_update.txt"
else
    printf "  ${GREEN}No new formulae available.${RESET}\n"
fi

# Step 9: Process new casks (optimized with parallel requests)
printf "\n${CYAN}📊 Processing new casks in repositories...${RESET}\n"
if [[ -s "$TEMP_DIR/new_casks_from_update.txt" ]]; then
    printf "\n${BRIGHT_GREEN}🆕 New Casks:${RESET}\n"
    
    # Fetch all info and store in a single JSON array
    {
        echo "["
        first=true
        cat "$TEMP_DIR/new_casks_from_update.txt" | while read -r cask; do
            [[ -z "$cask" ]] && continue
            # Remove :: suffix if present
            cask_clean="${cask%%::*}"
            if [[ "$first" == false ]]; then echo ","; fi
            first=false
            brew info --json=v2 "$cask_clean" 2>/dev/null | jq '.casks[0] // {"homepage":"Error","desc":"Could not retrieve info"}' || echo '{"homepage":"Error","desc":"Could not retrieve info"}'
        done
        echo "]"
    } > "$TEMP_DIR/new_casks_info_cache.json"
    
    # Parse cached JSON data
    while read -r cask; do
        [[ -z "$cask" ]] && continue
        cask_clean="${cask%%::*}"
        info=$(jq ".[] | select(.name==\"$cask_clean\")" "$TEMP_DIR/new_casks_info_cache.json" 2>/dev/null | head -1)
        [[ -z "$info" ]] && info='{"homepage":"Error","desc":"Could not retrieve info"}'
        homepage=$(safe_jq_parse "$info" '.homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.desc' "Unable to retrieve description")
        echo "  - $cask:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/new_casks_from_update.txt"
else
    printf "  ${GREEN}No new casks available.${RESET}\n"
fi

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
# Check if there were any actual errors (containing the word "ERROR") during execution
if grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    echo -e "\n${YELLOW}Some non-critical errors occurred during execution.${RESET}"
    echo -e "${YELLOW}See log file for details: $LOG_FILE${RESET}"
else
    # Remove log file if no errors occurred, only normal messages
    rm -f "$LOG_FILE"
fi

# Notify about log file if it still exists
if [[ -f "$LOG_FILE" ]]; then
    echo -e "${CYAN}Log file created at: $LOG_FILE${RESET}"
fi

echo -e "\n${BRIGHT_GREEN}🍺 Brew Update Tracker completed!${RESET}"
exit 0
