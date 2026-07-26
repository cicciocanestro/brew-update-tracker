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
# brew update announces new packages added to taps — parse them directly
# Uses awk flags to collect lines between section headers
awk 'p{print} /^==> New Formulae$/{p=1; next} /^==> [a-zA-Z]/{p=0}' "$TEMP_DIR/brew_update_output.txt" \
    | sed '/^==>/d; /^$/d; s/:.*//' \
    > "$TEMP_DIR/new_formulae.txt"

awk 'p{print} /^==> New Casks$/{p=1; next} /^==> [a-zA-Z]/{p=0}' "$TEMP_DIR/brew_update_output.txt" \
    | sed '/^==>/d; /^$/d; s/:.*//' \
    > "$TEMP_DIR/new_casks.txt"

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

# --- LANDING PAGE GENERATION ---
generate_landing_page() {
    local landing_file="/tmp/brew-update-landing.html"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    printf '\n%b🌐 Generating landing page...%b\n' "$CYAN" "$RESET"

    # Combine all package names, separated by type to avoid mixing
    local f_list="$TEMP_DIR/all_formulae.txt"
    local c_list="$TEMP_DIR/all_casks.txt"
    < "$TEMP_DIR/outdated_formulae.txt" cat > "$f_list" 2>/dev/null
    < "$TEMP_DIR/new_formulae.txt" cat >> "$f_list" 2>/dev/null
    < "$TEMP_DIR/outdated_casks.txt" cat > "$c_list" 2>/dev/null
    < "$TEMP_DIR/new_casks.txt" cat >> "$c_list" 2>/dev/null

    # Fetch JSON data — separate calls per type, jq -s to merge xargs batches
    local formulae_json="[]"
    local casks_json="[]"
    if [[ -s "$f_list" ]]; then
        formulae_json=$(< "$f_list" xargs brew info --json=v2 2>/dev/null | jq -s '[.[].formulae[]?]' 2>/dev/null)
        [[ -z "$formulae_json" ]] && formulae_json="[]"
    fi
    if [[ -s "$c_list" ]]; then
        casks_json=$(< "$c_list" xargs brew info --json=v2 2>/dev/null | jq -s '[.[].casks[]?]' 2>/dev/null)
        [[ -z "$casks_json" ]] && casks_json="[]"
    fi

    # Merge into a single JSON object
    local json_data=""
    json_data=$(jq -n --argjson f "$formulae_json" --argjson c "$casks_json" '{formulae: $f, casks: $c}' 2>/dev/null)

    # Load outdated.json as a lookup map for version info
    local outdated_json_data=""
    [[ -s "$TEMP_DIR/outdated.json" ]] && outdated_json_data=$(< "$TEMP_DIR/outdated.json" cat)
    [[ -z "$outdated_json_data" ]] && outdated_json_data='{"formulae":[],"casks":[]}'

    # Start building the HTML page
    cat > "$landing_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🍺 Brew Update Tracker</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');

        * { margin: 0; padding: 0; box-sizing: border-box; }

        :root {
            --bg: #0a0a0f;
            --surface: #14141f;
            --surface-hover: #1c1c2e;
            --border: rgba(255,255,255,0.06);
            --text: #e4e4ec;
            --text-muted: #87879e;
            --accent: #6366f1;
            --accent-glow: rgba(99,102,241,0.35);
            --green: #34d399;
            --green-glow: rgba(52,211,153,0.35);
            --orange: #fb923c;
            --orange-glow: rgba(251,146,60,0.35);
            --red: #f87171;
            --purple: #c084fc;
            --radius: 16px;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg);
            background-image:
                radial-gradient(ellipse 80% 50% at 50% -20%, rgba(99,102,241,0.12), transparent),
                radial-gradient(ellipse 60% 40% at 100% 100%, rgba(99,102,241,0.06), transparent);
            color: var(--text);
            line-height: 1.6;
            min-height: 100vh;
            -webkit-font-smoothing: antialiased;
        }

        .container { max-width: 860px; margin: 0 auto; padding: 48px 24px; }

        /* Header */
        header {
            text-align: center;
            margin-bottom: 44px;
            animation: fadeDown 0.6s ease-out;
        }
        @keyframes fadeDown {
            from { opacity: 0; transform: translateY(-12px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        .logo {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 64px; height: 64px;
            font-size: 2rem;
            border-radius: 18px;
            background: linear-gradient(135deg, rgba(99,102,241,0.2), rgba(99,102,241,0.05));
            border: 1px solid rgba(99,102,241,0.15);
            margin-bottom: 16px;
            backdrop-filter: blur(12px);
        }
        header h1 {
            font-size: 2.2rem;
            font-weight: 800;
            letter-spacing: -0.5px;
            background: linear-gradient(135deg, #e4e4ec 0%, #a5a5c0 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 6px;
        }
        .timestamp {
            color: var(--text-muted);
            font-size: 0.9rem;
            font-weight: 500;
            letter-spacing: 0.2px;
        }

        /* Summary Bar */
        .summary-bar {
            display: flex;
            gap: 16px;
            justify-content: center;
            margin-bottom: 40px;
            flex-wrap: wrap;
            animation: fadeUp 0.6s ease-out 0.1s both;
        }
        @keyframes fadeUp {
            from { opacity: 0; transform: translateY(12px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        .summary-item {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            padding: 22px 32px;
            text-align: center;
            min-width: 150px;
            transition: transform 0.2s, border-color 0.2s;
            backdrop-filter: blur(8px);
        }
        .summary-item:hover {
            transform: translateY(-2px);
            border-color: rgba(255,255,255,0.12);
        }
        .summary-item .count {
            font-size: 2.6rem;
            font-weight: 800;
            letter-spacing: -1px;
            line-height: 1;
            margin-bottom: 6px;
        }
        .summary-item .label {
            font-size: 0.82rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.8px;
        }
        .count-new {
            background: linear-gradient(135deg, var(--accent), #818cf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .count-updated {
            background: linear-gradient(135deg, var(--orange), #fbbf24);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .label-new { color: #818cf8; }
        .label-updated { color: #fbbf24; }

        /* Sections */
        section {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            padding: 32px;
            margin-bottom: 24px;
            backdrop-filter: blur(12px);
            animation: fadeUp 0.6s ease-out 0.2s both;
        }
        section:nth-child(4) { animation-delay: 0.3s; }
        section h2 {
            font-size: 1.2rem;
            font-weight: 700;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        section h2 .icon { font-size: 1.4rem; }
        .section-count {
            margin-left: auto;
            font-size: 0.8rem;
            font-weight: 600;
            padding: 3px 12px;
            border-radius: 20px;
            background: rgba(255,255,255,0.04);
            color: var(--text-muted);
        }

        /* Package Cards */
        .package {
            padding: 18px 20px;
            margin-bottom: 8px;
            border-radius: 12px;
            background: rgba(255,255,255,0.015);
            border: 1px solid transparent;
            transition: all 0.2s ease;
        }
        .package:last-child { margin-bottom: 0; }
        .package:hover {
            background: var(--surface-hover);
            border-color: var(--border);
            transform: translateX(4px);
        }
        .package-name {
            font-size: 1.05rem;
            font-weight: 700;
            margin-bottom: 4px;
            display: flex;
            align-items: center;
            gap: 8px;
            flex-wrap: wrap;
        }
        .package-name a {
            color: var(--text);
            text-decoration: none;
            transition: color 0.2s;
        }
        .package-name a:hover { color: var(--accent); }
        .package-desc {
            color: var(--text-muted);
            font-size: 0.9rem;
            margin-bottom: 8px;
            line-height: 1.5;
        }
        .package-meta {
            display: flex;
            gap: 14px;
            flex-wrap: wrap;
            font-size: 0.82rem;
            font-weight: 500;
        }
        .package-meta a {
            display: inline-flex;
            align-items: center;
            gap: 5px;
            color: var(--accent);
            text-decoration: none;
            padding: 4px 12px;
            border-radius: 8px;
            background: rgba(99,102,241,0.08);
            border: 1px solid rgba(99,102,241,0.12);
            transition: all 0.2s;
        }
        .package-meta a:hover {
            background: rgba(99,102,241,0.16);
            border-color: rgba(99,102,241,0.25);
            color: #a5b4fc;
        }
        .package-meta a.changelog {
            color: var(--orange);
            background: rgba(251,146,60,0.08);
            border-color: rgba(251,146,60,0.12);
        }
        .package-meta a.changelog:hover {
            background: rgba(251,146,60,0.16);
            border-color: rgba(251,146,60,0.25);
            color: #fbbf24;
        }

        /* Version pill */
        .version-info {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            font-size: 0.82rem;
            font-weight: 600;
            margin-bottom: 6px;
            padding: 3px 0;
        }
        .version-old {
            background: rgba(248,113,113,0.12);
            color: var(--red);
            padding: 2px 10px;
            border-radius: 6px;
            font-family: 'SF Mono', 'Fira Code', monospace;
            font-size: 0.78rem;
        }
        .version-arrow { color: var(--text-muted); }
        .version-new {
            background: rgba(52,211,153,0.12);
            color: var(--green);
            padding: 2px 10px;
            border-radius: 6px;
            font-family: 'SF Mono', 'Fira Code', monospace;
            font-size: 0.78rem;
        }

        /* Badges */
        .badge {
            display: inline-flex;
            align-items: center;
            font-size: 0.7rem;
            padding: 3px 10px;
            border-radius: 8px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .badge-formula {
            background: rgba(99,102,241,0.12);
            color: #a5b4fc;
            border: 1px solid rgba(99,102,241,0.2);
        }
        .badge-cask {
            background: rgba(192,132,252,0.12);
            color: #d8b4fe;
            border: 1px solid rgba(192,132,252,0.2);
        }

        /* Empty state */
        .empty {
            color: var(--text-muted);
            font-style: italic;
            padding: 20px;
            text-align: center;
            font-size: 0.95rem;
        }

        /* Footer */
        .footer {
            text-align: center;
            padding: 24px;
            color: var(--text-muted);
            font-size: 0.8rem;
            font-weight: 500;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="logo">🍺</div>
            <h1>Brew Update Tracker</h1>
            <p class="timestamp">TIMESTAMP_PLACEHOLDER</p>
        </header>
HTMLEOF

    # Replace timestamp placeholder
    /usr/bin/sed -i '' "s/TIMESTAMP_PLACEHOLDER/$timestamp/" "$landing_file"

    # Generate summary counts
    local new_count=0
    local outdated_count=0
    [[ -s "$TEMP_DIR/new_formulae.txt" ]] && new_count=$((new_count + $(< "$TEMP_DIR/new_formulae.txt" wc -l | tr -d ' ')))
    [[ -s "$TEMP_DIR/new_casks.txt" ]] && new_count=$((new_count + $(< "$TEMP_DIR/new_casks.txt" wc -l | tr -d ' ')))
    [[ -s "$TEMP_DIR/outdated_formulae.txt" ]] && outdated_count=$((outdated_count + $(< "$TEMP_DIR/outdated_formulae.txt" wc -l | tr -d ' ')))
    [[ -s "$TEMP_DIR/outdated_casks.txt" ]] && outdated_count=$((outdated_count + $(< "$TEMP_DIR/outdated_casks.txt" wc -l | tr -d ' ')))

    cat >> "$landing_file" << HTMLEOF
        <div class="summary-bar">
            <div class="summary-item">
                <div class="count count-new">$new_count</div>
                <div class="label label-new">New Packages</div>
            </div>
            <div class="summary-item">
                <div class="count count-updated">$outdated_count</div>
                <div class="label label-updated">To Update</div>
            </div>
        </div>
HTMLEOF

    # Debug: save json_data to a temp file for inspection
    echo "$json_data" > /tmp/brew-landing-debug.json 2>/dev/null

    # --- NEW PACKAGES SECTION ---
    cat >> "$landing_file" << 'HTMLEOF'
        <section id="new-packages">
            <h2><span class="icon">🆕</span> New Packages <span class="section-count">NEW_COUNT_PLACEHOLDER</span></h2>
HTMLEOF

    local has_new_content=false

    if [[ -s "$TEMP_DIR/new_formulae.txt" ]]; then
        local nf_html
        nf_html=$(echo "$json_data" | jq -r --arg names "$(< "$TEMP_DIR/new_formulae.txt" paste -sd '|' -)" '
            def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
            .formulae[]? | select(.name as $n | $names | split("|") | index($n)) |
            "<div class=\"package\">" +
            "<div class=\"package-name\"><a href=\"\(.homepage // "#")\">\(.name | esc)</a><span class=\"badge badge-formula\">Formula</span></div>" +
            "<div class=\"package-desc\">\((.desc // "No description available.") | esc)</div>" +
            "<div class=\"package-meta\"><a href=\"\(.homepage // "#")\">🏠 Homepage</a></div>" +
            "</div>"
        ' 2>/dev/null)
        if [[ -n "$nf_html" ]]; then
            echo "$nf_html" >> "$landing_file"
            has_new_content=true
        fi
    fi

    if [[ -s "$TEMP_DIR/new_casks.txt" ]]; then
        local nc_html
        nc_html=$(echo "$json_data" | jq -r --arg names "$(< "$TEMP_DIR/new_casks.txt" paste -sd '|' -)" '
            def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
            .casks[]? | select(.token as $t | $names | split("|") | index($t)) |
            "<div class=\"package\">" +
            "<div class=\"package-name\"><a href=\"\(.homepage // "#")\">\(.token | esc)</a><span class=\"badge badge-cask\">Cask</span></div>" +
            "<div class=\"package-desc\">\((.desc // "No description available.") | esc)</div>" +
            "<div class=\"package-meta\"><a href=\"\(.homepage // "#")\">🏠 Homepage</a></div>" +
            "</div>"
        ' 2>/dev/null)
        if [[ -n "$nc_html" ]]; then
            echo "$nc_html" >> "$landing_file"
            has_new_content=true
        fi
    fi

    if [[ "$has_new_content" == false ]]; then
        echo '<p class="empty">No new packages available.</p>' >> "$landing_file"
    fi

    cat >> "$landing_file" << 'HTMLEOF'
        </section>
HTMLEOF

    # --- UPDATED (OUTDATED) PACKAGES SECTION ---
    cat >> "$landing_file" << 'HTMLEOF'
        <section id="updated-packages">
            <h2><span class="icon">📦</span> Updated Packages <span class="section-count">UPDATED_COUNT_PLACEHOLDER</span></h2>
HTMLEOF

    local has_outdated_content=false

    # Load outdated.json as a lookup map for version info
    local outdated_json_data=""
    [[ -s "$TEMP_DIR/outdated.json" ]] && outdated_json_data=$(< "$TEMP_DIR/outdated.json" cat)

    # Outdated Formulae
    if [[ -s "$TEMP_DIR/outdated_formulae.txt" ]]; then
        local outdated_f_html
        outdated_f_html=$(echo "$json_data" | jq -r \
            --arg names "$(< "$TEMP_DIR/outdated_formulae.txt" paste -sd '|' -)" \
            --argjson outdated "$outdated_json_data" '
            def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
            def changelog_url:
                if (.homepage // "") | test("github\\.com") then
                    ((.homepage // "") | capture("https?://github\\.com/(?<owner>[^/]+)/(?<repo>[^/]+)") | "https://github.com/\(.owner)/\(.repo)/releases")
                else
                    .homepage // ""
                end;
            def find_version($name; $arr):
                ($arr // []) | map(select(.name == $name)) | first // null;
            .formulae[]? | select(.name as $n | $names | split("|") | index($n)) |
            . as $pkg |
            (find_version($pkg.name; $outdated.formulae) // {}) as $ver |
            "<div class=\"package\">" +
            "<div class=\"package-name\"><a href=\"\($pkg.homepage // "#")\">\($pkg.name | esc)</a><span class=\"badge badge-formula\">Formula</span></div>" +
            (if ($ver.installed_versions and $ver.current_version) then
                "<div class=\"version-info\"><span class=\"version-old\">\($ver.installed_versions | join(", "))</span> <span class=\"version-arrow\">→</span> <span class=\"version-new\">\($ver.current_version)</span></div>"
            else "" end) +
            "<div class=\"package-desc\">\(($pkg.desc // "") | esc)</div>" +
            "<div class=\"package-meta\">" +
            (if ($pkg.homepage // "") | test("github\\.com") then "<a class=\"changelog\" href=\"\($pkg | changelog_url)\">📋 Changelog</a>" else "" end) +
            " <a href=\"\($pkg.homepage // "#")\">🏠 Homepage</a>" +
            "</div>" +
            "</div>"
        ' 2>/dev/null)
        if [[ -n "$outdated_f_html" ]]; then
            echo "$outdated_f_html" >> "$landing_file"
            has_outdated_content=true
        fi
    fi

    # Outdated Casks
    if [[ -s "$TEMP_DIR/outdated_casks.txt" ]]; then
        local outdated_c_html
        outdated_c_html=$(echo "$json_data" | jq -r \
            --arg names "$(< "$TEMP_DIR/outdated_casks.txt" paste -sd '|' -)" \
            --argjson outdated "$outdated_json_data" '
            def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
            def changelog_url:
                if (.homepage // "") | test("github\\.com") then
                    ((.homepage // "") | capture("https?://github\\.com/(?<owner>[^/]+)/(?<repo>[^/]+)") | "https://github.com/\(.owner)/\(.repo)/releases")
                else
                    .homepage // ""
                end;
            def find_version($token; $arr):
                ($arr // []) | map(select(.name == $token)) | first // null;
            .casks[]? | select(.token as $t | $names | split("|") | index($t)) |
            . as $pkg |
            (find_version($pkg.token; $outdated.casks) // {}) as $ver |
            "<div class=\"package\">" +
            "<div class=\"package-name\"><a href=\"\($pkg.homepage // "#")\">\($pkg.token | esc)</a><span class=\"badge badge-cask\">Cask</span></div>" +
            (if ($ver.installed_versions and $ver.current_version) then
                "<div class=\"version-info\"><span class=\"version-old\">\($ver.installed_versions | join(", "))</span> <span class=\"version-arrow\">→</span> <span class=\"version-new\">\($ver.current_version)</span></div>"
            else "" end) +
            "<div class=\"package-desc\">\(($pkg.desc // "") | esc)</div>" +
            "<div class=\"package-meta\">" +
            (if ($pkg.homepage // "") | test("github\\.com") then "<a class=\"changelog\" href=\"\($pkg | changelog_url)\">📋 Changelog</a>" else "" end) +
            " <a href=\"\($pkg.homepage // "#")\">🏠 Homepage</a>" +
            "</div>" +
            "</div>"
        ' 2>/dev/null)
        if [[ -n "$outdated_c_html" ]]; then
            echo "$outdated_c_html" >> "$landing_file"
            has_outdated_content=true
        fi
    fi

    if [[ "$has_outdated_content" == false ]]; then
        echo '<p class="empty">No packages to update.</p>' >> "$landing_file"
    fi

    cat >> "$landing_file" << 'HTMLEOF'
        </section>
        <div class="footer">🍺 Brew Update Tracker</div>
    </div>
</body>
</html>
HTMLEOF

    # Replace placeholders
    local new_formulae_count=0 new_casks_count=0
    [[ -s "$TEMP_DIR/new_formulae.txt" ]] && new_formulae_count=$(< "$TEMP_DIR/new_formulae.txt" wc -l | tr -d ' ')
    [[ -s "$TEMP_DIR/new_casks.txt" ]] && new_casks_count=$(< "$TEMP_DIR/new_casks.txt" wc -l | tr -d ' ')
    local new_total=$((new_formulae_count + new_casks_count))

    local outdated_f_count=0 outdated_c_count=0
    [[ -s "$TEMP_DIR/outdated_formulae.txt" ]] && outdated_f_count=$(< "$TEMP_DIR/outdated_formulae.txt" wc -l | tr -d ' ')
    [[ -s "$TEMP_DIR/outdated_casks.txt" ]] && outdated_c_count=$(< "$TEMP_DIR/outdated_casks.txt" wc -l | tr -d ' ')
    local updated_total=$((outdated_f_count + outdated_c_count))

    /usr/bin/sed -i '' "s/NEW_COUNT_PLACEHOLDER/$new_total packages/" "$landing_file"
    /usr/bin/sed -i '' "s/UPDATED_COUNT_PLACEHOLDER/$updated_total packages/" "$landing_file"

    # Open the landing page in default browser
    if [[ -f "$landing_file" ]]; then
        open "$landing_file"
        printf '%b✅ Landing page opened in browser: %s%b\n' "$GREEN" "$landing_file" "$RESET"
    fi
}

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

# Step 12: Generate landing page
generate_landing_page

printf '\n%b🍺 Brew Update Tracker completed!%b\n' "$BRIGHT_GREEN" "$RESET"
exit 0
