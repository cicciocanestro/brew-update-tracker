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

# Exit on error
set -e

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
    echo -e "${RED}Error: Homebrew is not installed${RESET}" >&2
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${RESET}"
    echo -e "${CYAN}Please install it with: brew install jq${RESET}"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d /tmp/brew-update-tracker.XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${BRIGHT_GREEN}🍺 Brew Update Tracker${RESET}"
echo -e "${BRIGHT_GREEN}=======================${RESET}"

# Step 1: Record current packages before update
echo -e "\n${CYAN}📋 Recording current package lists...${RESET}"

# Get all formulae and casks before update
brew list --formula > "$TEMP_DIR/formulae_before.txt"
brew list --cask > "$TEMP_DIR/casks_before.txt"

# Get all available formulae and casks in repos before update
brew search --formula '' > "$TEMP_DIR/available_formulae_before.txt"
brew search --cask '' > "$TEMP_DIR/available_casks_before.txt"

# Step 2: Run brew update
echo -e "\n${CYAN}🔄 Updating Homebrew...${RESET}"
brew update

# Step 3: Record packages after update
# Get all formulae and casks after update
brew list --formula > "$TEMP_DIR/formulae_after.txt"
brew list --cask > "$TEMP_DIR/casks_after.txt"

# Get all available formulae and casks in repos after update
brew search --formula '' > "$TEMP_DIR/available_formulae_after.txt"
brew search --cask '' > "$TEMP_DIR/available_casks_after.txt"

# Step 4: Find outdated packages
echo -e "\n${CYAN}🔍 Finding outdated packages...${RESET}"
brew outdated --formula > "$TEMP_DIR/outdated_formulae.txt"
brew outdated --cask > "$TEMP_DIR/outdated_casks.txt"

# Step 5: Find new packages in repos
echo -e "\n${CYAN}🆕 Finding new packages in repositories...${RESET}"
comm -13 "$TEMP_DIR/available_formulae_before.txt" "$TEMP_DIR/available_formulae_after.txt" > "$TEMP_DIR/new_formulae.txt"
comm -13 "$TEMP_DIR/available_casks_before.txt" "$TEMP_DIR/available_casks_after.txt" > "$TEMP_DIR/new_casks.txt"

# Step 6: Process formulae
echo -e "\n${CYAN}📊 Processing updated formulae...${RESET}"
if [[ -s "$TEMP_DIR/outdated_formulae.txt" ]]; then
    echo -e "\n${BRIGHT_GREEN}📦 Updated Formulae:${RESET}"
    while read -r formula; do
        # Get formula info with error handling
        info=$(brew info --json=v2 "$formula" 2>/dev/null || echo '{"formulae":[{"homepage":"Error","desc":"Could not retrieve info"}]}')
        homepage=$(safe_jq_parse "$info" '.formulae[0].homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.formulae[0].desc' "Unable to retrieve description")
        echo "  - $formula:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/outdated_formulae.txt"
else
    echo -e "  ${GREEN}No formula updates available.${RESET}"
fi

# Step 7: Process casks
echo -e "\n${CYAN}📊 Processing updated casks...${RESET}"
if [[ -s "$TEMP_DIR/outdated_casks.txt" ]]; then
    echo -e "\n${BRIGHT_GREEN}📦 Updated Casks:${RESET}"
    while read -r cask; do
        # Get cask info with error handling
        info=$(brew info --json=v2 "$cask" 2>/dev/null || echo '{"casks":[{"homepage":"Error","desc":"Could not retrieve info"}]}')
        homepage=$(safe_jq_parse "$info" '.casks[0].homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.casks[0].desc' "Unable to retrieve description")
        echo "  - $cask:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/outdated_casks.txt"
else
    echo -e "  ${GREEN}No cask updates available.${RESET}"
fi

# Step 8: Process new formulae
echo -e "\n${CYAN}📊 Processing new formulae in repositories...${RESET}"
if [[ -s "$TEMP_DIR/new_formulae.txt" ]]; then
    echo -e "\n${BRIGHT_GREEN}🆕 New Formulae:${RESET}"
    while read -r formula; do
        # Get formula info with error handling
        info=$(brew info --json=v2 "$formula" 2>/dev/null || echo '{"formulae":[{"homepage":"Error","desc":"Could not retrieve info"}]}')
        homepage=$(safe_jq_parse "$info" '.formulae[0].homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.formulae[0].desc' "Unable to retrieve description")
        echo "  - $formula:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/new_formulae.txt"
else
    echo -e "  ${GREEN}No new formulae available.${RESET}"
fi

# Step 9: Process new casks
echo -e "\n${CYAN}📊 Processing new casks in repositories...${RESET}"
if [[ -s "$TEMP_DIR/new_casks.txt" ]]; then
    echo -e "\n${BRIGHT_GREEN}🆕 New Casks:${RESET}"
    while read -r cask; do
        # Get cask info with error handling
        info=$(brew info --json=v2 "$cask" 2>/dev/null || echo '{"casks":[{"homepage":"Error","desc":"Could not retrieve info"}]}')
        homepage=$(safe_jq_parse "$info" '.casks[0].homepage' "Unable to retrieve homepage")
        desc=$(safe_jq_parse "$info" '.casks[0].desc' "Unable to retrieve description")
        echo "  - $cask:"
        echo "      Homepage: $homepage"
        echo "      Description: $desc"
    done < "$TEMP_DIR/new_casks.txt"
else
    echo -e "  ${GREEN}No new casks available.${RESET}"
fi

# Step 10: Check if there are any updates available
total_updates=$(cat "$TEMP_DIR/outdated_formulae.txt" "$TEMP_DIR/outdated_casks.txt" | wc -l | tr -d ' ')

if [[ $total_updates -gt 0 ]]; then
    # Step 11: Ask if user wants to upgrade
    echo -e "\n${BRIGHT_GREEN}🚀 Found $total_updates package(s) that can be upgraded.${RESET}"
    echo -en "${YELLOW}Do you want to perform 'brew upgrade' now? (y/n): ${RESET}"
    read -r answer
    
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}⬆️ Running 'brew upgrade'...${RESET}"
        brew upgrade
        echo -e "${GREEN}✅ Upgrade completed!${RESET}"
    else
        echo -e "\n${YELLOW}✋ Upgrade skipped.${RESET}"
    fi
else
    echo -e "\n${GREEN}✅ No packages to upgrade!${RESET}"
fi

echo -e "\n${BRIGHT_GREEN}🍺 Brew Update Tracker completed!${RESET}"
exit 0
