[[ -n "${UI_SOURCED:-}" ]] && return
export UI_SOURCED=true
# ═══════════════════════════════════════════════════════════════════════════════
#  §1  COLOUR PALETTE
# ═══════════════════════════════════════════════════════════════════════════════
CR='\033[0;31m'    BCR='\033[1;31m'    # Crimson / Bold Crimson
CY='\033[0;36m'    BCY='\033[1;36m'    # Cyan    / Bold Cyan
GR='\033[0;32m'    BGR='\033[1;32m'    # Green   / Bold Green
YL='\033[0;33m'    BYL='\033[1;33m'    # Yellow  / Bold Yellow
WH='\033[1;37m'    DIM='\033[2m'       # White   / Dim
BWHT='\033[1;37m'                      # Bold White (alias for WH)
MAG='\033[0;35m'   BMAG='\033[1;35m'   # Magenta / Bold Magenta
BLU='\033[0;34m'   BBLU='\033[1;34m'   # Blue    / Bold Blue
RST='\033[0m'      BLINK='\033[5m'     # Reset   / Blink
UL='\033[4m'

# Box-drawing (double)
DTL='╔' DTR='╗' DBL='╚' DBR='╝' DH='═' DV='║' MLT='╠' MRT='╣'
# Box-drawing (single)
STL='┌' STR='┐' SBL='└' SBR='┘' SH='─' SV='│'

# ─── terminal dimensions ───────────────────────────────────────────────────
tw() { 
    local c; c=$(tput cols 2>/dev/null || echo 120)
    [[ $c -lt 80 ]] && echo 100 || echo "$c" 
}
th() { tput lines 2>/dev/null || echo 40;  }

# Center a string
center_str() {
    local term_width; term_width=$(tw)
    local raw="$1"
    local vis
    vis=$(printf '%b' "$raw" \
        | sed 's/\x1b\[[0-9;]*[mK]//g' \
        | sed 's/\x1b\]8;;[^\x1b]*\x1b\\//g' \
        | sed 's/\x1b\]8;;\x1b\\//g')
    local len=${#vis}
    local pad=$(( (term_width - len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf "%${pad}s" ""
    printf '%b\n' "$raw"
}
center() { center_str "$1"; }

# Horizontal rule
hrule() {
    local term_width; term_width=$(tw)
    local c="${1:-─}" col="${2:-$BCR}"
    local line; line=$(printf '%*s' "$term_width" '' | tr ' ' "$c")
    printf '%b%s%b\n' "$col" "$line" "$RST"
}

# OSC 8 clickable link
osc_link() {
    local text="$1" url="$2"
    if [[ "${TERM:-}" == *"xterm"* ]] || [[ "${TERM:-}" == *"256color"* ]] \
       || [[ -n "${TERM_PROGRAM:-}" ]] || [[ "${COLORTERM:-}" == "truecolor" ]]; then
        printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$url" "$text"
    else
        printf '%s  (%s)' "$text" "$url"
    fi
}

# Section Header
section() {
    local msg="$1" icon="${2:-●}"
    local term_width; term_width=$(tw)
    local iw=$(( term_width - 10 ))
    local pad_w=$(( iw - ${#msg} ))
    [[ $pad_w -lt 0 ]] && pad_w=0
    echo ""
    printf "  ${BCR}${DTL}${DH}${DH}${RST} [ ${icon} ${BWHT}${msg}${RST} ] ${BCR}%s${DTR}${RST}\n" \
        "$(printf '%*s' "$pad_w" '' | tr ' ' "${DH}")"
}

# Main Branding Header
print_web_art() {
    local r="${BCR}" c="${CY}" d="${DIM}" s="${RST}"
    local cols; cols=$(tw)
    echo ""
    if (( cols >= 140 )); then
        center "${r}     *═══════════════════════════════════════════════════════*${s}"
        center "${r}    ╱${c}·${r}╲        ╲        ${c}·│·${r}        ╱        ╱${c}·${r}╲${s}"
        center "${r}   ╱ ${c}·${r}  ╲─────────╲────────${c}·│·${r}────────╱─────────╱  ${c}·${r} ╲${s}"
        center "${r}  ╱  ${c}·${r}  ╱╲       ╲      ╱${c}·│·${r}╲      ╱       ╱╲  ${c}·${r}  ╲${s}"
        center "${r} ╱  ${c}·${r}  ╱  ╲────────╲──────╱ ${c}│${r} ╲──────╱────────╱  ╲  ${c}·${r}  ╲${s}"
        center "${r}*──${c}·${r}──*────────────────────── ${c}◈${r} ──────────────────────*──${c}·${r}──*${s}"
        center "${r} ╲  ${c}·${r}  ╲  ╱────────╱──────╲ ${c}│${r} ╱──────╲────────╲  ╱  ${c}·${r}  ╱${s}"
        center "${r}  ╲  ${c}·${r}  ╲╱       ╱      ╲${c}·│·${r}╱      ╲       ╲╱  ${c}·${r}  ╱${s}"
        center "${r}   ╲ ${c}·${r}  ╱─────────╱────────${c}·│·${r}────────╲─────────╲  ${c}·${r} ╱${s}"
        center "${r}    ╲${c}·${r}╱        ╱        ${c}·│·${r}        ╲        ╲${c}·${r}╱${s}"
        center "${r}     *═══════════════════════════════════════════════════════*${s}"
    elif (( cols >= 100 )); then
        center "${r}   *══════════════════════════════════════════════*${s}"
        center "${r}  ╱${c}·${r}╲     ${c}·│·${r}      ╱      ╱${c}·${r}╲${s}"
        center "${r} ╱ ${c}·${r} ╲──────╱────── ${c}◈${r} ──────╱─────╲ ${c}·${r} ╲${s}"
        center "${r}*──${c}·${r}──*───────────── ${c}◈${r} ───────────*──${c}·${r}──*${s}"
        center "${r} ╲ ${c}·${r} ╱──────╲────── ${c}◈${r} ──────╲─────╱ ${c}·${r} ╱${s}"
        center "${r}  ╲${c}·${r}╱     ${c}·│·${r}      ╲      ╲${c}·${r}╱${s}"
    else
        center "${r} *════════════════════════════*${s}"
        center "${r}* ${c}·${r}  ${c}◈${r}  ${c}·${r} *${s}"
        center "${r} *════════════════════════════*${s}"
    fi
    echo ""
}

# High-impact Crimson ASCII banner


# Spinner (visual pulse) - start/stop
spinner_start() {
    local msg="${1:-Processing}"
    local _spinfile="/tmp/.crimson_spinner_$$"
    printf "  %s " "${msg}"
    ( while true; do for c in '-' '\\' '|' '/'; do printf "%s" "\b$c"; sleep 0.15; done; done ) >"${_spinfile}" 2>&1 &
    export CRIMSON_SPINNER_PID=$!
}

spinner_stop() {
    local pid="${CRIMSON_SPINNER_PID:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        unset CRIMSON_SPINNER_PID
        printf "\b %s\n" "DONE"
    fi
}

print_logo() {
    local cols; cols=$(tw)
    if (( cols >= 120 )); then
        center "${BCR}  ██████ ██████  ██ ███    ███ ███████  ██████  ███    ██     ██      ██ ███████ ██████  ${RST}"
        center "${BCR} ██      ██   ██ ██ ████  ████ ██      ██    ██ ████   ██     ██      ██ ██      ██   ██ ${RST}"
        center "${BCR} ██      ██████  ██ ██ ████ ██ ███████ ██    ██ ██ ██  ██     ██  █   ██ █████   ██████  ${RST}"
        center "${BCR} ██      ██   ██ ██ ██  ██  ██      ██ ██    ██ ██  ██ ██     ██ ███  ██ ██      ██   ██ ${RST}"
        center "${BCR}  ██████ ██   ██ ██ ██      ██ ███████  ██████  ██   ████      ███ ███   ███████ ██████  ${RST}"
    elif (( cols >= 90 )); then
        center "${BCR}  ██████ ██████  ██ ███    ███ █████  ██████  ███   ██ ${RST}"
        center "${BCR} ██      ██   ██ ██ ████  ████ ██    ██    ██ ████  ██ ${RST}"
        center "${BCR} ██      ██████  ██ ██ ████ ██ █████ ██    ██ ██ ██ ██ ${RST}"
        center "${BCR} ██      ██   ██ ██ ██  ██  ██    ██ ██    ██ ██  ████ ${RST}"
        center "${BCR}  ██████ ██   ██ ██ ██      ██ █████  ██████  ██   ███ ${RST}"
    else
        center "${BCR} CRIMSON WEB ${RST}"
    fi
}

print_header() {
    hrule "═" "$BCR"
    print_web_art
    print_logo
    echo ""
    local dev_link; dev_link=$(osc_link "[ DEVELOPER: crimsonej ]" "https://github.com/crimsonej")
    center "${DIM}Bug Bounty Automation Framework ${WH}v${VERSION}${RST}${DIM}  ·  ${RST}${BCY}${dev_link}${RST}"
    hrule "═" "$BCR"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §RAW INTEL FEED: Discovery Window (Real-Time Asset Streaming)
# ═══════════════════════════════════════════════════════════════════════════════

# Display raw discovered assets in real-time with clean formatting
show_discovery_window() {
    [[ -z "${TARGET_DIR:-}" ]] && return
    
    local raw_dir="${TARGET_DIR}/raw"
    mkdir -p "$raw_dir" 2>/dev/null
    
    echo ""
    section "DISCOVERY WINDOW" "🔍"
    echo ""
    
    # Continuous tail of discovered assets with clean formatting (no bloat)
    # Filters out tool output noise and shows only actual discovered data
    tail -q -f "${raw_dir}"/*.txt 2>/dev/null | grep -v '^$' | while read -r line; do
        # Skip tool metadata bloat
        [[ "$line" =~ ^Processed\ |^Found\ |^Total\ |^\\[.*\\]$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Display raw discovered data cleanly with type detection
        if [[ "$line" =~ \\.(api|dev|test|staging|backup|admin|internal|prod|live)\\. ]]; then
            printf "  ${BCR}[SUBDOMAIN]${RST} ${WH}%s${RST}\\n" "$line"
        elif [[ "$line" =~ ^https?:// ]]; then
            printf "  ${BYL}[URL]${RST} ${WH}%s${RST}\\n" "$line"
        elif [[ "$line" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3} ]]; then
            printf "  ${BGR}[IP]${RST} ${WH}%s${RST}\\n" "$line"
        else
            printf "  ${BCY}[ASSET]${RST} ${WH}%s${RST}\\n" "$line"
        fi
    done &
}

# Progress Map
print_phase_map() {
    local p="${CURRENT_PHASE:-INIT}"
    local dim="${DIM}" rst="${RST}" bcr="${BCR}" bgr="${BGR}"
    
    echo ""
    printf "  ${dim}Pipeline:${rst} "
    
    # Recon
    if [[ "$p" == "RECON" ]]; then printf "${bcr}[▶ RECON]${rst} "; 
    elif [[ "$CNT_SUBS" -gt 0 ]]; then printf "${bgr}[✓ RECON]${rst} "; 
    else printf "${dim}[○ RECON]${rst} "; fi
    printf "${dim}══${rst} "

    # Surface
    if [[ "$p" == "SURFACE" ]]; then printf "${bcr}[▶ SURFACE]${rst} "; 
    elif [[ "$CNT_URLS" -gt 0 ]]; then printf "${bgr}[✓ SURFACE]${rst} "; 
    else printf "${dim}[○ SURFACE]${rst} "; fi
    printf "${dim}══${rst} "

    # Crawl
    if [[ "$p" == "CRAWL" ]]; then printf "${bcr}[▶ CRAWL]${rst} "; 
    elif [[ "$CNT_JS" -gt 0 ]]; then printf "${bgr}[✓ CRAWL]${rst} "; 
    else printf "${dim}[○ CRAWL]${rst} "; fi
    printf "${dim}══${rst} "

    # Analyze
    if [[ "$p" == "ANALYZE" ]]; then printf "${bcr}[▶ ANALYZE]${rst} "; 
    elif [[ -f "${TARGET_DIR}/filtered/secrets.txt" ]]; then printf "${bgr}[✓ ANALYZE]${rst} "; 
    else printf "${dim}[○ ANALYZE]${rst} "; fi
    printf "${dim}══${rst} "

    # Vulns
    if [[ "$p" == "VULNS" ]]; then printf "${bcr}[▶ VULNS]${rst}"; 
    elif [[ "$CNT_VULNS" -gt 0 ]]; then printf "${bgr}[✓ VULNS]${rst}"; 
    else printf "${dim}[○ VULNS]${rst}"; fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §2  PERSISTENT HUD (Dynamic Status Bar)
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize HUD state
export HUD_ENABLED=true
export HUD_ROW=0
export HUD_LAST_PHASE=""
export HUD_LAST_TARGET=""
export HUD_LAST_PROGRESS=0
export HUD_LAST_JOBS=0
export HUD_LAST_LOOT=0
export HUD_LAST_VULNS=0

# Clear lines and position cursor at bottom
hud_init() {
    # Save cursor position and clear screen
    tput civis 2>/dev/null || true  # Hide cursor
    tput sc 2>/dev/null || true     # Save cursor
}

# Render persistent HUD (locked to bottom)
hud_render() {
    local phase="${CURRENT_PHASE:-INIT}"
    local target="${TARGET:-unknown}"
    local jobs="${1:-0}"
    local loot="${2:-0}"
    local vulns="${3:-0}"
    local progress="${4:-0}"
    
    [[ "$HUD_ENABLED" != "true" ]] && return
    
    # Build progress bar [██████░░░░] 
    local bar_width=12
    local filled=$((progress * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar_str="["
    bar_str+="$(printf '%*s' "$filled" '' | tr ' ' '█')"
    bar_str+="$(printf '%*s' "$empty" '' | tr ' ' '░')"
    bar_str+="]"
    
    # Construct HUD line (lockable to bottom)
    local hud_line=""
    hud_line="${BCR}[PHASE: ${phase}]${RST} | "
    hud_line+="${BCY}[Target: ${target}]${RST} | "
    hud_line+="${YL}Progress: ${bar_str} ${progress}%${RST} | "
    hud_line+="${BGR}[Live Jobs: ${jobs}]${RST} | "
    hud_line+="${BCY}[Loot: ${loot}]${RST} | "
    hud_line+="${BCR}[Vulns: ${vulns}]${RST}"
    
    # Save current cursor position and move to bottom row
    tput sc 2>/dev/null || true
    tput cup $(( $(tput lines 2>/dev/null || echo 30) - 1 )) 0 2>/dev/null || true
    
    # Clear line and print HUD
    tput el 2>/dev/null || true
    printf '%b\n' "$hud_line"
    
    # Restore cursor position
    tput rc 2>/dev/null || true
}

# Print actionable events (suppress spam)
hud_event() {
    local severity="$1"  # [+], [!], [*], [!] for HIGH ALERT
    local msg="$2"
    
    [[ -z "$msg" ]] && return
    
    case "$severity" in
        "+")  printf "  ${BGR}[+]${RST} %s\n" "$msg" ;;
        "!")  printf "  ${BCR}[!]${RST} %s\n" "$msg" ;;
        "*")  printf "  ${BYL}[*]${RST} %s\n" "$msg" ;;
        "high") printf "  ${BLINK}${BCR}[!!!]${RST} %s\n" "$msg" ;;
        *)    printf "  %s\n" "$msg" ;;
    esac
}

# Loot Counter Display
print_loot() {
    printf "  ${DIM}Loot:${RST} "
    printf "${BCY}Subs:${RST} ${CNT_SUBS:-0} | "
    printf "${BCY}Ports:${RST} ${CNT_PORTS:-0} | "
    printf "${BCY}URLs:${RST} ${CNT_URLS:-0} | "
    printf "${BCY}Vulns:${RST} ${BCR}${CNT_VULNS:-0}${RST}\n"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §3  LIVE LOG STREAMER (Real-time Output Merger)
# ═══════════════════════════════════════════════════════════════════════════════

# Enhanced raw data live-feed with actual asset discovery
stream_logs() {
    local log_dir="${TARGET_DIR}/logs"
    local tool_logs="${TARGET_DIR}/tools_used"
    local data_files="${TARGET_DIR}/websites"
    [[ ! -d "$log_dir" ]] && return
    
    # Create named pipe for log streaming
    local log_fifo="/tmp/log_stream_$$"
    mkfifo "$log_fifo" 2>/dev/null || return
    
    # Merge all active logs with LIVE INTEL display (actual discovered assets)
    {
        # Continuously tail all tool logs with type detection AND asset discovery
        while true; do
            if [[ -d "$tool_logs" ]]; then
                # RECON phase: Show discovered subdomains in real-time
                tail -f "$tool_logs"/subfinder.txt "$tool_logs"/assetfinder.txt "$tool_logs"/amass.txt 2>/dev/null | grep -v '^$' | head -5 | while read -r domain; do
                    printf "  ${BCY}[RECON-LIVE]${RST} 🎯 Subdomain: ${WH}%s${RST}\n" "$domain" 2>/dev/null
                done &
                
                # SURFACE phase: Show live/responsive hosts
                [[ -f "$data_files/live_urls.txt" ]] && tail -f "$data_files/live_urls.txt" 2>/dev/null | grep -v '^$' | head -3 | while read -r url; do
                    printf "  ${BYL}[SURFACE-LIVE]${RST} ✓ Live Target: ${WH}%s${RST}\n" "$url" 2>/dev/null
                done &
                
                # CRAWL phase: Show discovered URLs/endpoints
                [[ -f "$data_files/master_urls.txt" ]] && tail -f "$data_files/master_urls.txt" 2>/dev/null | grep -v '^$' | head -5 | while read -r endpoint; do
                    printf "  ${BGR}[CRAWL-LIVE]${RST} 🔗 Endpoint: ${WH}%s${RST}\n" "$endpoint" 2>/dev/null
                done &
                
                # VULN phase: Show vulnerabilities found
                tail -f "$tool_logs"/nuclei.log 2>/dev/null | grep -iE 'matched|found|vulnerability' | head -3 | while read -r vuln; do
                    printf "  ${BCR}[VULN-LIVE]${RST} ⚠️  Vulnerability: ${WH}%s${RST}\n" "$vuln" 2>/dev/null
                done &
                
                # ANALYZE phase: Show secrets/credentials discovered
                tail -f "$tool_logs"/mantra.log "$tool_logs"/trufflehog.log 2>/dev/null | grep -iE 'secret|key|credential|token|leak' | head -3 | while read -r secret; do
                    printf "  ${BMAG}[ANALYZE-LIVE]${RST} 🔐 Credential: ${WH}%s${RST}\n" "$secret" 2>/dev/null
                done &
            fi
            sleep 3
            wait
        done > "$log_fifo" 2>/dev/null
    } &
    
    # Read from the fifo and display
    timeout 0 cat "$log_fifo" 2>/dev/null &
    rm -f "$log_fifo"
}

# Start log streaming in background
start_log_stream() {
    [[ -z "$TARGET_DIR" ]] && return
    mkdir -p "${TARGET_DIR}/logs" 2>/dev/null
    
    # Launch log streaming in background (silent)
    nohup bash -c '
        log_dir="${TARGET_DIR:-/tmp}/tools_used"
        while true; do
            [[ ! -d "$log_dir" ]] && { sleep 2; continue; }
            
            # Tail with type-specific formatting
            tail -f "$log_dir"/*.log 2>/dev/null | while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                
                # Detect tool type from filename context
                if [[ "$line" =~ (subfinder|assetfinder|amass) ]]; then
                    echo "[RECON-FLOW] $line"
                elif [[ "$line" =~ (httpx|naabu) ]]; then
                    echo "[SURFACE-PROBE] $line"
                elif [[ "$line" =~ (katana|hakrawler|gau) ]]; then
                    echo "[CRAWL-DATA] $line"
                elif [[ "$line" =~ (nuclei|dalfox|ghauri) ]]; then
                    echo "[VULN-PROBE] $line"
                elif [[ "$line" =~ (mantra|trufflehog|subjs) ]]; then
                    echo "[ANALYZE-DEEP] $line"
                else
                    echo "[TOOL-LOG] $line"
                fi
            done
            sleep 1
        done
    ' >> "${TARGET_DIR}/logs/streaming.log" 2>&1 &
    
    export LOG_STREAM_PID=$!
}

# Stop log streaming
stop_log_stream() {
    [[ -n "$LOG_STREAM_PID" ]] && kill -9 "$LOG_STREAM_PID" 2>/dev/null || true
}

# Print Final Session Report
print_final_report() {
    print_web_art
    print_logo
    echo ""
    section "FINAL MISSION REPORT" "🏆"
    
    local uptime; uptime=$(($(date +%s) - START_EPOCH))
    
    center_str "${BWHT}Target: ${BCY}${TARGET}${RST}"
    center_str "${DIM}Duration: ${uptime}s${RST}"
    echo ""
    
    printf "  ${BCR}╔══════════════════════════════════════════════════════════════════════╗${RST}\n"
    printf "  ${BCR}║${RST}  %-30s %10d  ${BCR}║${RST}\n" "Subdomains Discovered:" "$CNT_SUBS"
    printf "  ${BCR}║${RST}  %-30s %10d  ${BCR}║${RST}\n" "Live Web Targets:" "$CNT_URLS"
    printf "  ${BCR}║${RST}  %-30s %10d  ${BCR}║${RST}\n" "Open Ports Found:" "$CNT_PORTS"
    printf "  ${BCR}║${RST}  %-30s %10d  ${BCR}║${RST}\n" "JS Files Analyzed:" "$CNT_JS"
    printf "  ${BCR}║${RST}  %-30s %10d  ${BCR}║${RST}\n" "CONFIRMED VULNS:" "$CNT_VULNS"
    printf "  ${BCR}╚══════════════════════════════════════════════════════════════════════╝${RST}\n"
    
    echo ""
    if [[ "$CNT_VULNS" -gt 0 ]]; then
        center_str "${BLINK}${BCR}☢ CRITICAL FINDINGS IDENTIFIED ☢${RST}"
    else
        center_str "${BGR}● Scan Complete: No immediate critical vulns ●${RST}"
    fi
    echo ""
    hrule '═' "$BCR"
}

print_welcome() {
    # Lethality Welcome Screen - boxed
    echo ""
    printf "  ${BCR}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RST}\n"
    printf "  ${BCR}┃ ${BWHT}%-60s ${RST} ${BCR}┃${RST}\n" "[ STATUS ] System Arming..."
    printf "  ${BCR}┃ ${BWHT}%-60s ${RST} ${BCR}┃${RST}\n" "[ ACCESS ] Authorized: Joachim Elijah"
    printf "  ${BCR}┃ ${BWHT}%-60s ${RST} ${BCR}┃${RST}\n" "[ REGION ] Node: Kampala_East"
    printf "  ${BCR}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RST}\n"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §BOOTSTRAP UI  System Integrity Audit & Hardware Specs Display
# ═══════════════════════════════════════════════════════════════════════════════

# Display hardware specifications with lethality assessment
show_hardware_specs() {
    local cpu_cores ram distro os_info
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    ram=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "Unknown")
    distro=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    os_info=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || uname -s -r)
    
    echo ""
    section "SYSTEM SPECIFICATIONS" "⚙"
    
    # Color code lethality
    local lethality_color="$GR"
    local lethality_label="HIGH"
    
    # RAM assessment
    if [[ "$ram" == "1G"* ]] || [[ "$ram" == "512M"* ]]; then
        lethality_color="$BCR"
        lethality_label="LOW (1GB RAM - limited concurrency)"
    elif [[ "$ram" == "2G"* ]]; then
        lethality_color="$BYL"
        lethality_label="MEDIUM (2GB RAM)"
    fi
    
    # CPU assessment
    if [[ $cpu_cores -lt 2 ]]; then
        lethality_color="$BCR"
        lethality_label="LOW (1 CPU Core)"
    elif [[ $cpu_cores -lt 4 ]]; then
        lethality_color="$BYL"
        lethality_label="MEDIUM ($cpu_cores cores)"
    fi
    
    # Build spec table
    printf "  ${BWHT}%-20s${RST} : %s\n" "CPU Cores" "$cpu_cores"
    printf "  ${BWHT}%-20s${RST} : %s\n" "Total RAM" "$ram"
    printf "  ${BWHT}%-20s${RST} : %s\n" "Distribution" "$distro"
    printf "  ${BWHT}%-20s${RST} : %s\n" "OS Version" "$os_info"
    printf "  ${BWHT}%-20s${RST} : ${lethality_color}${lethality_label}${RST}\n" "Deployment Lethality"
    echo ""
}

# Display tool status in tabular format
display_bootstrap_table() {
    local -a all_tools=(
        "subfinder:RECON"
        "assetfinder:RECON"
        "amass:RECON"
        "httpx:SURFACE"
        "katana:CRAWL"
        "hakrawler:CRAWL"
        "gau:CRAWL"
        "waybackurls:CRAWL"
        "nuclei:VULNS"
        "dalfox:VULNS"
        "ghauri:VULNS"
        "trufflehog:ANALYZE"
        "gf:ANALYZE"
        "mantra:ANALYZE"
        "arjun:ANALYZE"
        "subjack:VULNS"
        "ffuf:VULNS"
        "anew:UTILITY"
        "cloudkiller:ANALYZE"
    )
    
    echo ""
    section "SYSTEM INTEGRITY AUDIT" "🔍"
    
    # Print header (modern box style)
    printf "  ${BCR}┏${RST}%s${BCR}┓${RST}\n" "$(printf '%-67s' '' | tr ' ' '━')"
    printf "  ${BCR}┃ ${BWHT}%-16s ${RST} ${BWHT}%-18s ${RST} ${BWHT}%-10s ${RST} ${BWHT}%-15s ${RST} ┃\n" "TOOL" "STATUS" "ACTION" "PHASE"
    printf "  ${BCR}┣${RST}%s${BCR}┫${RST}\n" "$(printf '%-67s' '' | tr ' ' '━')"
    
    local installed=0
    local missing=0
    
    # Check each tool
    for tool_info in "${all_tools[@]}"; do
        local tool="${tool_info%:*}"
        local phase="${tool_info#*:}"
        local status_col status_text action_col action_text
        
        if command -v "$tool" &>/dev/null || [[ -x "${HOME}/go/bin/${tool}" ]]; then
            status_col="$BGR"
            status_text="INSTALLED"
            action_col="$GR"
            action_text="IDLE"
            ((installed++))
        else
            status_col="$BYL"
            status_text="MISSING"
            action_col="$BCY"
            action_text="SYNCING..."
            ((missing++))
        fi
        
        # Print row
        printf "  %-18s ${status_col}%-20s${RST} ${action_col}%-12s${RST} %-15s\n" \
            "$tool" "$status_text" "$action_text" "$phase"
    done
    
    # Summary footer
    printf "  ${BCR}┗${RST}%s${BCR}┛${RST}\n" "$(printf '%-67s' '' | tr ' ' '━')"
    printf "  ${GR}Installed: %d${RST} | ${BYL}Missing: %d${RST} | ${BWHT}Total: %d${RST}\n\n" \
        "$installed" "$missing" "$((installed + missing))"
}

# Comprehensive system audit display
audit_system_integrity() {
    echo ""
    hrule '═' "$BCR"
    center_str "${BCR}🕷️  CRIMSON WEB - SYSTEM BOOTUP AUDIT 🕷️${RST}"
    hrule '═' "$BCR"
    
    # Show hardware specs
    show_hardware_specs
    
    # Show tool status table
    display_bootstrap_table
    
    # Final notes
    center_str "${DIM}Tools are syncing in the background. Audit will be displayed below.${RST}"
    echo ""
}
