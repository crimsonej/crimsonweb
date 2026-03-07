#!/usr/bin/env bash
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
tw() { tput cols  2>/dev/null || echo 120; }
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
    (( pad < 0 )) && pad=0
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
    echo ""
    printf "  ${BCR}${DTL}${DH}${DH}${RST} [ ${icon} ${BWHT}${msg}${RST} ] ${BCR}%s${DTR}${RST}\n" \
        "$(printf '%*s' $((iw - ${#msg})) '' | tr ' ' "${DH}")"
}

# Main Branding Header
print_web_art() {
    local r="${BCR}" c="${CY}" d="${DIM}" s="${RST}"
    echo ""
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
    echo ""
}

print_logo() {
    center "${BCR}  ██████ ██████  ██ ███    ███ ███████  ██████  ███    ██     ██      ██ ███████ ██████  ${RST}"
    center "${BCR} ██      ██   ██ ██ ████  ████ ██      ██    ██ ████   ██     ██      ██ ██      ██   ██ ${RST}"
    center "${BCR} ██      ██████  ██ ██ ████ ██ ███████ ██    ██ ██ ██  ██     ██  █   ██ █████   ██████  ${RST}"
    center "${BCR} ██      ██   ██ ██ ██  ██  ██      ██ ██    ██ ██  ██ ██     ██ ███  ██ ██      ██   ██ ${RST}"
    center "${BCR}  ██████ ██   ██ ██ ██      ██ ███████  ██████  ██   ████      ███ ███   ███████ ██████  ${RST}"
}

print_header() {
    clear
    hrule "═" "$BCR"
    print_web_art
    print_logo
    echo ""
    local dev_link; dev_link=$(osc_link "[ DEVELOPER: crimsonej ]" "https://github.com/crimsonej")
    center "${DIM}Bug Bounty Automation Framework ${WH}v${VERSION}${RST}${DIM}  ·  ${RST}${BCY}${dev_link}${RST}"
    hrule "═" "$BCR"
    echo ""
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

# Loot Counter Display
print_loot() {
    printf "  ${DIM}Loot:${RST} "
    printf "${BCY}Subs:${RST} ${CNT_SUBS:-0} | "
    printf "${BCY}Ports:${RST} ${CNT_PORTS:-0} | "
    printf "${BCY}URLs:${RST} ${CNT_URLS:-0} | "
    printf "${BCY}Vulns:${RST} ${BCR}${CNT_VULNS:-0}${RST}\n"
}

# Print Final Session Report
print_final_report() {
    clear
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
