#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║        PROJECT CRIMSON WEB  ·  Bug Bounty Automation Framework  v10.0        ║
# ║        Black-Box Penetration Testing · Recon · Exploit · Report              ║
# ║        DEVELOPER: crimsonej  ·  https://github.com/crimsonej                 ║
# ╚═══════════════════════════════════════════════════════════════════════════════

# §FIX: Immediate Buffer Restoration
tput rmcup 2>/dev/null || true
stty sane 2>/dev/null || true

# ── Global Constants ──────────────────────────────────────────────────────
readonly VERSION="10.0"
readonly VAULT_ROOT="CrimsonWeb_Vault"
readonly TOOLS_DIR="${HOME}/.crimsonweb/bin"
readonly TEMP_DIR="/tmp/.spw_$$"
export INPUT_FIFO="/tmp/crimson_c2"

# ── Global State (set -u protection) ─────────────────────────────────────
TARGET=""
THREADS=50
RATE_LIMIT=10
JITTER_MIN=1
JITTER_MAX=3
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
USER_HEADER=""
USE_PROXY=false
MAX_JOBS=$(nproc 2>/dev/null || echo 4)

# Counters
CNT_SUBS=0; CNT_PORTS=0; CNT_URLS=0; CNT_JS=0; CNT_VULNS=0
CNT_PARAMS=0; CNT_JS_ANALYSIS=0; CNT_XSS=0; CNT_SQLI=0
CNT_SCREENSHOTS=0; HUD_PULSE="●"; CURRENT_PHASE="INIT"; CURRENT_TOOL=""
START_EPOCH=$(date +%s)

# ── Modular Sourcing (Order is Critical) ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/ui.sh"            # Colors & Display
source "${SCRIPT_DIR}/lib/framework.sh"     # Logging & Heartbeats
source "${SCRIPT_DIR}/lib/utils.sh"         # Process & File Utils
source "${SCRIPT_DIR}/lib/jobs.sh"          # Concurrency engine
source "${SCRIPT_DIR}/lib/tg_c2.sh"         # Telegram & Input
source "${SCRIPT_DIR}/lib/proxy.sh"         # Ghost Layer
source "${SCRIPT_DIR}/lib/intelligence.sh"  # Initialization & IQ

# Phase Modules
source "${SCRIPT_DIR}/core/recon.sh"      # Phase 1
source "${SCRIPT_DIR}/core/surface.sh"    # Phase 2
source "${SCRIPT_DIR}/core/crawl.sh"      # Phase 3
source "${SCRIPT_DIR}/core/analyze.sh"    # Phase 4
source "${SCRIPT_DIR}/core/vulns.sh"      # Phase 5
source "${SCRIPT_DIR}/core/high_alert.sh"  # Pipeline

export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:${HOME}/go/bin:${HOME}/.local/bin"
set -uo pipefail
IFS=$'\n\t'

# Register Master Cleanup Trap
trap master_cleanup EXIT TERM INT

# ── Main Entry Point ──────────────────────────────────────────────────────
main() {
    path_fix
    
    # Initial UI setup
    print_header
    check_internet
    
    if [[ $EUID -ne 0 ]]; then
        printf "  ${BCR}[ERROR]${RST} This script requires root/sudo.\n"
        exit 1
    fi
    
    parse_args "$@"
    init_settings
    init_high_alert_keywords
    
    [[ -z "$TARGET" ]] && prompt_target
    init_vault
    
    # Launch Telegram Background Services
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        nohup telegram_listener >/dev/null 2>&1 &
        register_pid $!
        nohup tg_executor >/dev/null 2>&1 &
        register_pid $!
        nohup error_streamer >/dev/null 2>&1 &
        register_pid $!
        tg_send "🚀 <b>Crimson Web v${VERSION} Modular Active</b>"
        check_c2
    fi

    detect_system
    session_init
    proxy_load
    check_proxy
    cmd_setup

    print_welcome # Shows the final splash before hunting
    log PHASE "Initiating Crimson Web modular operation on: ${WH}${TARGET}${RST}"
    
    phase_recon
    phase_surface
    phase_crawl
    phase_analyze
    phase_vuln
    
    print_final_report
    print_loot
    
    echo ""
    hrule '═' "$BCR"
    center_str "${BCR}  🕸   Crimson Web Modularized Session Complete   🕸${RST}"
    hrule '═' "$BCR"
}

main "$@"
