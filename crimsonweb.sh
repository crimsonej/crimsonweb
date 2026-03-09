#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║        PROJECT CRIMSON WEB  ·  Bug Bounty Automation Framework  v10.0        ║
# ║        Black-Box Penetration Testing · Recon · Exploit · Report              ║
# ║        DEVELOPER: crimsonej  ·  https://github.com/crimsonej                 ║
# ╚═══════════════════════════════════════════════════════════════════════════════

# §FIX: Immediate Buffer Restoration (preserve terminal buffer)
stty sane 2>/dev/null || true
export ABORTED=0
export CLEANED=0

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
TELEGRAM_C2_STARTED=0
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

export PATH="${HOME}/go/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:${HOME}/.local/bin"
set -uo pipefail
IFS=$'\n\t'

# Register signal handlers: SIGINT -> manual abort, EXIT/TERM -> cleanup
manual_abort() {
    export ABORTED=1
    log WARN "Manual abort (SIGINT) received. Initiating shutdown..."
    # Call cleanup immediately
    master_cleanup
    # If master_cleanup returns, ensure exit with distinct code
    exit 130
}

trap manual_abort SIGINT
trap master_cleanup EXIT TERM

# ── Main Entry Point ──────────────────────────────────────────────────────
main() {
    path_fix
    
    # Initialize persistent HUD (ANSI escape codes)
    hud_init
    
    # Initial UI setup
    print_header

    # Phase 1 (Input): Vault Setup (blocking, before any background PIDs)
    local VAULT_DIR="${HOME}/.crimson_vault"
    local VAULT_FILE="${VAULT_DIR}/vault.env"
    if [[ -f "${VAULT_FILE}" ]]; then
        local vault_abs
        vault_abs=$(readlink -f "${VAULT_FILE}" 2>/dev/null || echo "${VAULT_FILE}")
        printf "  🛡️  Vault located at: %s\n" "${vault_abs}"
        if [[ -t 0 ]]; then
            read -r -p "[?] Use existing Telegram credentials? [Y/n]: " use_existing
            if [[ "${use_existing}" =~ ^[Nn] ]]; then
                rm -f "${VAULT_FILE}" 2>/dev/null || true
                unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TG_TOKEN TG_CHAT_ID
                # Trigger setup wizard
                read -r -p "Enter Telegram Bot Token: " _bot
                read -r -p "Enter Telegram Chat ID: " _chat
                mkdir -p "${VAULT_DIR}" 2>/dev/null || true
                cat > "${VAULT_FILE}" <<EOF
export TELEGRAM_BOT_TOKEN="${_bot}"
export TELEGRAM_CHAT_ID="${_chat}"
export TG_TOKEN="${_bot}"
export TG_CHAT_ID="${_chat}"
EOF
                chmod 600 "${VAULT_FILE}" 2>/dev/null || true
                log OK "Vault recreated at ${WH}${VAULT_FILE}${RST}"
            fi
        fi
    else
        if [[ -t 0 ]]; then
            clear
            printf "Vault not found. Run setup now? [y/N]: "
            read -r _vault_enable
            if [[ "${_vault_enable}" =~ ^[Yy] ]]; then
                mkdir -p "${VAULT_DIR}" 2>/dev/null || true
                read -r -p "Enter Telegram Bot Token: " _bot
                read -r -p "Enter Telegram Chat ID: " _chat
                cat > "${VAULT_FILE}" <<EOF
export TELEGRAM_BOT_TOKEN="${_bot}"
export TELEGRAM_CHAT_ID="${_chat}"
export TG_TOKEN="${_bot}"
export TG_CHAT_ID="${_chat}"
EOF
                chmod 600 "${VAULT_FILE}" 2>/dev/null || true
                log OK "Vault created at ${WH}${VAULT_FILE}${RST}"
            else
                log INFO "Vault setup skipped by operator. Telegram C2 disabled unless env vars provided."
            fi
        fi
    fi

    # Phase 2 (Network): Internet Heartbeat -> Proxy Swarm -> Print IPs
    check_internet

    # Immediate C2 announcement so operator knows the bot is alive before target prompt
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        tg_send "🛡️ *Crimson Sentinel Online*"
        tg_send "🚀 *Crimson Web v${VERSION}* — C2 Active"
    fi

    # Visual pulse while proxy swarm initializes
    spinner_start "Building Proxy Swarm"
    proxy_load
    check_proxy
    spinner_stop

    # Phase 3 (Background): Launch Tool Sync (silent)
    bootstrap_system
    
    # if [[ $EUID -ne 0 ]]; then
    #     printf "  ${BCR}[ERROR]${RST} This script requires root/sudo.\n"
    #     exit 1
    # fi
    
    parse_args "$@"
    init_settings
    init_high_alert_keywords

    # Step 3: Setup/Load Vault (Telegram credentials)
    local VAULT_DIR="${HOME}/.crimson_vault"
    local VAULT_FILE="${VAULT_DIR}/vault.env"
    if [[ -f "${VAULT_FILE}" ]]; then
        # Source silently
        # shellcheck source=/dev/null
        source "${VAULT_FILE}" 2>/dev/null || true
        log OK "Vault loaded from ${WH}${VAULT_FILE}${RST}"
    else
        if [[ -t 0 ]]; then
            mkdir -p "${VAULT_DIR}" 2>/dev/null || true
            echo "" && printf "Vault not found. Run setup now? [y/N]: "
            read -r _vault_enable
            if [[ "${_vault_enable}" =~ ^[Yy] ]]; then
                read -r -p "Enter Telegram Bot Token: " _bot
                read -r -p "Enter Telegram Chat ID: " _chat
                cat > "${VAULT_FILE}" <<EOF
export TELEGRAM_BOT_TOKEN="${_bot}"
export TELEGRAM_CHAT_ID="${_chat}"
export TG_TOKEN="${_bot}"
export TG_CHAT_ID="${_chat}"
EOF
                chmod 600 "${VAULT_FILE}" 2>/dev/null || true
                log OK "Vault created at ${WH}${VAULT_FILE}${RST} (permissions: 600)"
                # shellcheck source=/dev/null
                source "${VAULT_FILE}" 2>/dev/null || true
            else
                log INFO "Vault setup skipped by operator. Telegram C2 disabled unless env vars provided."
            fi
        fi
    fi

    # Initialize adaptive rate limiting based on proxy usage
    set_adaptive_rate

    # Show absolute vault path when available (helps operator locate credentials)
    if [[ -f "${VAULT_FILE}" ]]; then
        local vault_abs
        vault_abs=$(readlink -f "${VAULT_FILE}" 2>/dev/null || echo "${VAULT_FILE}")
        log OK "Vault path: ${WH}${vault_abs}${RST}"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════════
    # CRITICAL: START TELEGRAM C2 LISTENER BEFORE TARGETING
    # This ensures remote /target commands are captured during target input phase
    # ═══════════════════════════════════════════════════════════════════════════════
    
    # Step 4: Start Telegram C2 Listener (pre-targeting) if credentials present
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        log PHASE "🚀 Launching Telegram C2 Listener (pre-targeting)..."

        # Start listener (creates FIFO) and register
        telegram_listener >/dev/null 2>&1 &
        register_pid $!

        # Start executor loop immediately so C2 commands are actionable at startup
        ( while true; do tg_executor; sleep 0.5; done ) >/dev/null 2>&1 &
        register_pid $!
        TELEGRAM_C2_STARTED=1
        export TELEGRAM_C2_STARTED

        log OK "C2 Listener active - ready for remote /target commands"

        # C2 Heartbeat: verify connectivity and send strict handshake via curl
        check_c2
        # Prefer TG_TOKEN/TG_CHAT_ID exported by vault but fallback to TELEGRAM_* vars
        TG_TOKEN="${TG_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
        TG_CHAT_ID="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
        if [[ -n "${TG_TOKEN}" && -n "${TG_CHAT_ID}" ]]; then
            MSG="🕷️ Crimson Sentinel Online.%0A[Node]: Kampala_East%0A[Status]: System Arming..."
            RESPONSE=$(curl -sS --connect-timeout 5 --max-time 15 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="${MSG}" -d parse_mode="HTML") || RESPONSE=""
            if [[ -z "${RESPONSE}" ]]; then
                log ERROR "[!] Telegram handshake failed (network/connectivity)."
                if [[ -t 0 ]]; then
                    read -r -p "[?] Telegram handshake failed. Continue in SILENT MODE? [y/N]: " _cont
                    if [[ ! "${_cont}" =~ ^[Yy] ]]; then
                        log FATAL "Operator aborted due to Telegram handshake failure."
                        exit 1
                    else
                        log WARN "Proceeding without Telegram C2 (silent mode)."
                        TELEGRAM_C2_STARTED=0
                    fi
                fi
            elif echo "${RESPONSE}" | grep -q '"error_code":403'; then
                log ERROR "[!] Telegram API returned 403 Forbidden — the bot is likely blocked or user hasn't started it."
                log ERROR "[!] ACTION REQUIRED: Open your Telegram Bot and click 'START' so it can send you notifications."
                if [[ -t 0 ]]; then
                    read -r -p "[?] Telegram is blocked. Continue without notifications? [y/N]: " _cont
                    if [[ ! "${_cont}" =~ ^[Yy] ]]; then
                        log FATAL "Operator aborted due to Telegram 403 Forbidden."
                        exit 1
                    else
                        log WARN "Proceeding without Telegram C2 (silent mode)."
                        TELEGRAM_C2_STARTED=0
                    fi
                fi
            elif echo "${RESPONSE}" | grep -q '"ok":false'; then
                log ERROR "[!] Telegram API Rejected the Token/Chat ID. Check credentials. Response: ${RESPONSE}"
                if [[ -t 0 ]]; then
                    read -r -p "[?] Credentials rejected. Continue in SILENT MODE? [y/N]: " _cont
                    if [[ ! "${_cont}" =~ ^[Yy] ]]; then
                        log FATAL "Operator aborted due to Telegram credential rejection."
                        exit 1
                    else
                        log WARN "Proceeding without Telegram C2 (silent mode)."
                        TELEGRAM_C2_STARTED=0
                    fi
                fi
            else
                log OK "Telegram handshake successful."
            fi
        else
            log WARN "TG_TOKEN or TG_CHAT_ID not set; skipping strict handshake."
        fi
    fi
    
    # CRITICAL: Operator has total control over target input
    # prompt_target now loops indefinitely with domain/IP validation
    # Accepts: syfe.com, www.syfe.com, https://syfe.com/path, 192.168.1.1
    [[ -z "$TARGET" ]] && prompt_target
    
    init_vault
    
    # §FIX: Mandatory Directory Initialization (Entry Point)
    local TARGET_VAULT="CrimsonWeb_Vault/${TARGET}"
    mkdir -p "$TARGET_VAULT/tools_used"
    mkdir -p "$TARGET_VAULT/vulnerabilities"
    mkdir -p "$TARGET_VAULT/screenshots"
    mkdir -p "$TARGET_VAULT/raw"  # For raw intel discovery feed
    touch "$TARGET_VAULT/RECON_results.txt"
    
    # ═══════════════════════════════════════════════════════════════════════════════
    # LAUNCH TELEGRAM BACKGROUND SERVICES (POST-TARGETING)
    # ═══════════════════════════════════════════════════════════════════════════════
    
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        # If executor not started at pre-target, start it now. Avoid duplicates.
        if [[ -z "${TELEGRAM_C2_STARTED:-}" || "${TELEGRAM_C2_STARTED}" != "1" ]]; then
            ( while true; do tg_executor; sleep 0.5; done ) >/dev/null 2>&1 &
            register_pid $!
            TELEGRAM_C2_STARTED=1
            export TELEGRAM_C2_STARTED
        fi

        # Start error stream monitor (runs as background function)
        error_streamer >/dev/null 2>&1 &
        register_pid $!

        # Verify C2 connectivity and announce availability
        check_c2
        tg_send "🚀 <b>Crimson Web v${VERSION} with 2-Way C2 Active</b>"
        tg_send "📡 <b>C2 Commands Available:</b> /skip | /retry | /abort | /continue | /resume | /pause | /status"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════════
    # ENABLE RAW INTEL STREAMING (Discovery Window)
    # ═══════════════════════════════════════════════════════════════════════════════
    
    # If raw intel directory exists, stream discoveries to terminal in background
    if [[ -d "$TARGET_VAULT/raw" ]]; then
        nohup bash -c "
            echo \"\"
            echo \"${BCY}[RAW INTEL STREAM] Waiting for asset discovery...${RST}\"
            # Tail raw/* files continuously, showing new discovered assets
            tail -f \"$TARGET_VAULT/raw\"/*.txt 2>/dev/null \\
            | while IFS= read -r asset; do
                [[ -z \"\$asset\" ]] && continue
                # Skip bloat
                [[ \"\$asset\" =~ ^Processed|^Found|^Total|^\\[.*\\] ]] && continue
                
                # Type detection
                if [[ \"\$asset\" =~ \\.(api|dev|test|staging|backup|admin)\\. ]]; then
                    echo \"  ${BCR}[SUBDOMAIN]${RST} ${WH}\$asset${RST}\"
                elif [[ \"\$asset\" =~ ^https?:// ]]; then
                    echo \"  ${BYL}[URL]${RST} ${WH}\$asset${RST}\"
                elif [[ \"\$asset\" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3} ]]; then
                    echo \"  ${BGR}[IP]${RST} ${WH}\$asset${RST}\"
                else
                    echo \"  ${BCY}[ASSET]${RST} ${WH}\$asset${RST}\"
                fi
            done
        " >> "$TARGET_VAULT/logs/discovery.log" 2>&1 &
        register_pid $!
    fi

    # Step 5: Display System Audit Table
    detect_system
    session_init
    cmd_setup

    print_welcome # Shows the final splash before hunting
    log PHASE "Initiating Crimson Web modular operation on: ${WH}${TARGET}${RST}"
    
    # Skip RECON only when a non-empty live_urls.txt already exists in the target vault
    if [[ -d "${TARGET_DIR}" && -s "${TARGET_DIR}/websites/live_urls.txt" ]]; then
        # Offer operator a force-rescan override (15s timeout). If no input, default to rescanning.
        if [[ -t 0 ]]; then
            read -t 15 -r -p "[?] Target data exists. Force fresh scan? [y/N]: " force_scan || true
            # If no input (timeout) treat as affirmative (rescan)
            if [[ -z "$force_scan" || "$force_scan" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                log INFO "Force rescan requested. Purging existing target vault: ${TARGET_DIR}"
                rm -rf "${TARGET_DIR}" || true
                mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" "${TARGET_DIR}/vulnerabilities" 2>/dev/null || true
            else
                log SKIP "RECON — live_urls present and non-empty; skipping recon as operator chose not to rescan."
                phase_complete "RECON" || true
            fi
        else
            # Non-interactive environment: proceed to rescan by default
            log INFO "Non-interactive: forcing fresh scan (purging target vault)."
            rm -rf "${TARGET_DIR}" || true
            mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" "${TARGET_DIR}/vulnerabilities" 2>/dev/null || true
        fi
    fi

    # If live_urls is now present and non-empty, skip; otherwise run RECON
    if [[ -s "${TARGET_DIR}/websites/live_urls.txt" ]]; then
        log SKIP "RECON — live_urls present and non-empty; skipping recon."
        phase_complete "RECON" || true
    else
        phase_recon

        # Ensure recon has written outputs before starting surface
        local wait_secs=0; local max_wait=30
        while [[ ! -s "${TARGET_DIR}/websites/live_urls.txt" && $wait_secs -lt $max_wait ]]; do
            sleep 1
            wait_secs=$((wait_secs+1))
        done
        if [[ ! -s "${TARGET_DIR}/websites/live_urls.txt" ]]; then
            log WARN "live_urls.txt still empty after recon (waited ${max_wait}s). Proceeding anyway."
        else
            # flush filesystem buffers
            sync
        fi
    fi

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
