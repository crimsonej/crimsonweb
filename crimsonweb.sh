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
# Constants
readonly VERSION="10.0"
readonly VAULT_ROOT="CrimsonWeb_Vault"
readonly UA_STEALTH="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
# Start the main recon pipeline (separated for audit->execution flow)
start_recon_pipeline() {
    # Delegate to main() to ensure a single unified entrypoint and avoid duplicate prompts
    main "$@"
}
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
OPERATOR_NAME=""
TELEGRAM_C2_STARTED=0
USER_HEADER=""
USE_PROXY=false
MAX_JOBS=$(nproc 2>/dev/null || echo 4)
[[ $MAX_JOBS -gt 4 ]] && MAX_JOBS=4

# Counters
CNT_SUBS=0; CNT_PORTS=0; CNT_URLS=0; CNT_JS=0; CNT_VULNS=0
CNT_PARAMS=0; CNT_JS_ANALYSIS=0; CNT_XSS=0; CNT_SQLI=0
CNT_SCREENSHOTS=0; HUD_PULSE="●"; CURRENT_PHASE="INIT"; CURRENT_TOOL=""
START_EPOCH=$(date +%s)

# ── Modular Sourcing (Order is Critical) ───────────────────────────────
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${BASE_DIR}"

# Provide safe defaults so sourced libraries (which may run at load-time)
# referencing `TARGET_DIR` or `TARGET` do not fail under `set -u`.
export TARGET=""
export TARGET_DIR="${BASE_DIR}/${VAULT_ROOT}"
mkdir -p "${TARGET_DIR}" 2>/dev/null || true

# --- [ CORE LIBRARIES ] ---
source "${BASE_DIR}/lib/ansi.sh"       # HUD colors
source "${BASE_DIR}/lib/jobs.sh"       # Job control and logging mechanisms
source "${BASE_DIR}/lib/ui.sh"         # Centralized UI output logic
source "${BASE_DIR}/lib/tg_c2.sh"      # Telegram C2 integration
source "${BASE_DIR}/lib/intelligence.sh" # Vault management
# --- [ CORE LIBRARIES ] ---
source "${BASE_DIR}/lib/utils.sh"      # Common utilities and ASCII tools
source "${BASE_DIR}/lib/framework.sh"  # Core orchestration & utilities

# Phase Modules
source "${BASE_DIR}/core/recon.sh"      # Phase 1
source "${BASE_DIR}/core/surface.sh"    # Phase 2
source "${BASE_DIR}/core/crawl.sh"      # Phase 3
source "${BASE_DIR}/core/analyze.sh"    # Phase 4
source "${BASE_DIR}/core/vulns.sh"      # Phase 5
source "${BASE_DIR}/core/high_alert.sh"  # Pipeline

export PATH="${HOME}/go/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:${HOME}/.local/bin"
# Soft-fail mode: don't abort on non-zero commands; keep nounset checks
set +e
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
trap master_cleanup SIGTERM EXIT

# Lightweight environment check — all version probes run in parallel
check_environment() {
    log PHASE "Auditing environment & dependencies..."
    local tools=(naabu nmap httpx subfinder assetfinder amass gau curl jq python3 go git)

    # §PERF: Run every version check in the background into tmp files
    local tmp_dir; tmp_dir=$(mktemp -d /tmp/.spw_env_XXXXXX)
    for t in "${tools[@]}"; do
        (
            local bin ver path_val
            bin=$(command -v "$t" 2>/dev/null || true)
            path_val=${bin:-"Not found"}
            ver="Not found"
            if [[ -n "$bin" ]]; then
                ver=$("$bin" --version 2>&1 | head -n 1 2>/dev/null) \
                    || ver=$("$bin" -V 2>&1 | head -n 1 2>/dev/null) \
                    || ver=$("$bin" -v 2>&1 | head -n 1 2>/dev/null) \
                    || true
                ver=${ver:-"version unknown"}
            fi
            printf "| %-11s | %-40s | %s\n" "$t" "$path_val" "$ver" > "${tmp_dir}/${t}"
        ) &
    done
    # Wait for all parallel probes to finish
    wait

    # Print header + results in original tool order
    printf "| %-11s | %-40s | %s\n" "TOOL" "PATH" "VERSION" || true
    printf "| %-11s | %-40s | %s\n" "----" "----------------------------------------" "-------" || true
    for t in "${tools[@]}"; do
        [[ -f "${tmp_dir}/${t}" ]] && cat "${tmp_dir}/${t}"
    done
    # Ensure we use the proper fallback default or an empty string
    local target_ip=""
    local ts; ts=$(date '+%H:%M:%S' 2>/dev/null || date +%T)
    printf "[%s] [ %s ] SYS_MONITOR: ACTIVE\n" "$ts" "$HUD_PULSE" || true
}

# Initialization pipeline: best-effort setup and preflight
initialize_pipeline() {
    echo "--- [ SYSTEM INIT ] ---"
    mkdir -p "${BASE_DIR}/tmp" 2>/dev/null || true
    mkdir -p "${HOME}/go/bin" 2>/dev/null || true

    # §PERF: Pre-cache Subjack fingerprints so vulns.sh doesn't block on GitHub at runtime
    local fp_cache="${BASE_DIR}/tmp/fingerprints.json"
    if [[ ! -s "$fp_cache" ]]; then
        wget -q --timeout=15 \
            https://raw.githubusercontent.com/haccer/subjack/master/fingerprints.json \
            -O "$fp_cache" 2>/dev/null || true
        [[ -s "$fp_cache" ]] && log OK "Subjack fingerprints cached to ${fp_cache}" || \
            log WARN "Could not cache Subjack fingerprints (offline?); runtime fallback will be used."
    else
        log OK "Subjack fingerprints already cached."
    fi
    export SUBJACK_FP_CACHE="$fp_cache"

    echo "--- [ INIT COMPLETE ] ---"
}

# Wrapper to launch all Telegram C2 services cleanly
start_telegram_listener() {
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 1
    
    # Launch services and record PIDs
    telegram_listener >/dev/null 2>&1 &
    register_pid $!
    
    ( while true; do tg_executor; sleep 0.5; done ) >/dev/null 2>&1 &
    register_pid $!
    
    error_streamer >/dev/null 2>&1 &
    register_pid $!
    
    TELEGRAM_C2_STARTED=1
    export TELEGRAM_C2_STARTED
    return 0
}

# ── Main Entry Point ──────────────────────────────────────────────────────
main() {
    # Ensure a clean terminal and show ASCII logo / web art first
    clear
    print_header

    # Step 1: Environment Audit and Pipeline Init
    check_environment || true
    initialize_pipeline || true

    # Step 2: Path and tool sanity
    path_fix
    check_tools || true
    check_all_tools

    # Step 3: HUD + system audit
    hud_init
    detect_system
    session_init
    cmd_setup

    # Baseline arguments and settings
    parse_args "$@"
    init_settings
    init_high_alert_keywords

    # Step 4: Vault load (vault.env) to get Telegram credentials
    local VAULT_DIR="${BASE_DIR}/${VAULT_ROOT}"
    local VAULT_FILE="${VAULT_DIR}/vault.env"
    if [[ -f "${VAULT_FILE}" ]]; then
        source "${VAULT_FILE}" 2>/dev/null || true
        log OK "Vault loaded: ${WH}${VAULT_FILE}${RST}"
    fi

    # Ensure OPERATOR_NAME has a safe default if not in vault
    [[ -z "$OPERATOR_NAME" ]] && OPERATOR_NAME="$(whoami)@$(hostname)"

    # --- C2 VAULT SELF-HEAL ---
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        printf "[%s] [ \033[1;33m!\033[0m ] Telegram credentials missing or corrupted.\n" "$(date +%T)"
        printf "[%s] [ \033[1;33m!\033[0m ] Initiating Vault Self-Heal...\n" "$(date +%T)"
        
        mkdir -p "$(dirname "$VAULT_FILE")"
        
        # Prompt operator for missing keys and identity
        read -r -p "   [>] Enter Operator Handle (Name): " INPUT_OP_NAME
        read -r -p "   [>] Enter Telegram Bot Token: " INPUT_TOKEN
        read -r -p "   [>] Enter Telegram Chat ID: " INPUT_CHAT_ID
        
        # Append to vault (create if missing)
        echo "export OPERATOR_NAME=\"$INPUT_OP_NAME\"" >> "$VAULT_FILE"
        echo "export TELEGRAM_BOT_TOKEN=\"$INPUT_TOKEN\"" >> "$VAULT_FILE"
        echo "export TELEGRAM_CHAT_ID=\"$INPUT_CHAT_ID\"" >> "$VAULT_FILE"
        echo "export TG_TOKEN=\"$INPUT_TOKEN\"" >> "$VAULT_FILE"
        echo "export TG_CHAT_ID=\"$INPUT_CHAT_ID\"" >> "$VAULT_FILE"
        
        # Export for the immediate session
        export OPERATOR_NAME="$INPUT_OP_NAME"
        export TELEGRAM_BOT_TOKEN="$INPUT_TOKEN"
        export TELEGRAM_CHAT_ID="$INPUT_CHAT_ID"
        export TG_TOKEN="$INPUT_TOKEN"
        export TG_CHAT_ID="$INPUT_CHAT_ID"
        
        printf "[%s] [ \033[1;32m●\033[0m ] Vault patched successfully. Resuming boot...\n" "$(date +%T)"
        sleep 1
    fi
    # --------------------------

    # Step 5: bootstrap_system in background
    check_internet
    bootstrap_system > /dev/null 2>&1 &
    register_pid $!

    # Step 6: Visible Telegram Handshake
    printf "[%s] [ \033[1;33m○\033[0m ] Initializing Telegram C2 Bridge...\n" "$(date +%T)"

    check_telegram_bridge() {
        local status
        # Initial silent check
        status=$(curl -s -w "%{http_code}" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" -o /dev/null -m 5)

        if [[ "$status" != "200" ]]; then
            printf "[%s] [ \033[1;31m!\033[0m ] Telegram Bridge: OFFLINE (Status: $status)\n" "$(date +%T)"
            
            if [[ -t 0 ]]; then
                # --- START SAFE PROMPT BLOCK ---
                stop_control_listener 2>/dev/null || true
                while read -r -t 0.1; do :; done # Flush buffer
                stty sane 2>/dev/null
                
                echo -e "\n${YLW}[!] Telegram Connection Failed.${RST}"
                echo -e "Options: [r]etry current, [n]ew token, [s]kip and continue"
                
                local choice
                read -p "Selection [r/n/s]: " -n 1 -r choice < /dev/tty
                echo -e "\n"

                case "$choice" in
                    n|N)
                        local new_token new_id
                        read -p "Enter New Telegram Token: " new_token < /dev/tty
                        read -p "Enter New Chat ID: " new_id < /dev/tty
                        
                        # Update vault.env permanently
                        if [[ -f "${VAULT_FILE}" ]]; then
                            sed -i "s/TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=\"$new_token\"/" "${VAULT_FILE}"
                            sed -i "s/TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=\"$new_id\"/" "${VAULT_FILE}"
                            sed -i "s/TG_TOKEN=.*/TG_TOKEN=\"$new_token\"/" "${VAULT_FILE}"
                            sed -i "s/TG_CHAT_ID=.*/TG_CHAT_ID=\"$new_id\"/" "${VAULT_FILE}"
                        else
                            mkdir -p "$(dirname "$VAULT_FILE")"
                            echo "export TELEGRAM_BOT_TOKEN=\"$new_token\"" >> "$VAULT_FILE"
                            echo "export TELEGRAM_CHAT_ID=\"$new_id\"" >> "$VAULT_FILE"
                            echo "export TG_TOKEN=\"$new_token\"" >> "$VAULT_FILE"
                            echo "export TG_CHAT_ID=\"$new_id\"" >> "$VAULT_FILE"
                        fi
                        
                        export TELEGRAM_BOT_TOKEN="$new_token"
                        export TELEGRAM_CHAT_ID="$new_id"
                        export TG_TOKEN="$new_token"
                        export TG_CHAT_ID="$new_id"
                        
                        printf "[%s] [ \033[1;34m*\033[0m ] Token updated. Retrying...\n" "$(date +%T)"
                        check_telegram_bridge # Recursive retry
                        return
                        ;;
                    r|R)
                        printf "[%s] [ \033[1;34m*\033[0m ] Retrying with current token...\n" "$(date +%T)"
                        check_telegram_bridge
                        return
                        ;;
                    s|S|*)
                        printf "[%s] [ \033[1;33m-\033[0m ] Proceeding securely without Telegram notifications.\n" "$(date +%T)"
                        export TELEGRAM_ENABLED=false
                        ;;
                esac

                start_control_listener 2>/dev/null || true
                # --- END SAFE PROMPT BLOCK ---
            fi
        else
            # Success Path
            local tg_check bot_name
            tg_check=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" -m 5)
            bot_name=$(echo "$tg_check" | jq -r '.result.username' 2>/dev/null || echo "Bot")
            
            printf "[%s] [ \033[1;32m●\033[0m ] Telegram Bridge: ACTIVE (@%s)\n" "$(date +%T)" "$bot_name"
            export TELEGRAM_ENABLED=true
            
            # Launch the listener cleanly in the background
            start_telegram_listener > /dev/null 2>&1 &
        fi
    }

    # Execute the interactive bridge validation
    check_telegram_bridge

    sleep 1

    # Step 7: prompt_target (or uses /tmp/crimson_answer if set via Telegram)
    sleep 1
    [[ -z "$TARGET" ]] && prompt_target
    # Only send Telegram arming message if C2 is actually running
    if [[ "${TELEGRAM_C2_STARTED:-0}" -eq 1 ]]; then
        tg_send_msg "🚀 *CrimsonWeb Engine Armed* %0A🎯 Target: ${TARGET} %0A💻 Node: ${NODE_NAME:-Kampala_East}"
    fi

    # Step 8: init_vault → sets TARGET_DIR and creates standard dirs
    init_vault
    mkdir -p "${TARGET_DIR}/tools_used" "${TARGET_DIR}/vulnerabilities" "${TARGET_DIR}/screenshots" "${TARGET_DIR}/raw" 2>/dev/null || true
    touch "${TARGET_DIR}/RECON_results.txt"

    # Step 11: Active Job Control & Phase decision
    start_control_listener
    log PHASE "Initiating Crimson Web modular operation on: ${WH}${TARGET}${RST}"

    # Step 11: Decide whether to skip / re-run RECON based on websites/live_urls.txt
    if [[ -d "${TARGET_DIR}" && -s "${TARGET_DIR}/websites/live_urls.txt" ]]; then
        if [[ -t 0 ]]; then
            stop_control_listener 2>/dev/null || true
            
            # Clear the keyboard buffer so old keystrokes don't trigger the skip
            while read -r -t 0.1; do :; done 
            
            # Reset terminal to standard "sane" mode
            stty sane 2>/dev/null
            
            echo -e "\n${YLW}[?] Target data exists for ${WH}${TARGET}${RST}"
            # Explicitly read from /dev/tty and allow 20 seconds
            if read -r -p "Force fresh scan? [y/N]: " -t 20 force_scan < /dev/tty; then
                log INFO "Input received: $force_scan"
            else
                log WARN "No input detected within timeout. Defaulting to SKIP."
                force_scan="n"
            fi
            
            start_control_listener 2>/dev/null || true
            
            if [[ "$force_scan" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                log WARN "PERFORMING FRESH SCAN: Nuking ${TARGET_DIR}..."
                # Force removal and wait for disk to sync
                rm -rf "${TARGET_DIR}" 2>/dev/null && sync
                
                # Rebuild the core vault structure
                mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" "${TARGET_DIR}/loot" "${TARGET_DIR}/vulnerabilities" "${TARGET_DIR}/screenshots" "${TARGET_DIR}/raw" 2>/dev/null
                touch "${TARGET_DIR}/RECON_results.txt"
            else
                log SKIP "Using existing data. Skipping RECON phase."
                phase_complete "RECON" 2>/dev/null || true
            fi
        else
            log INFO "Non-interactive: forcing fresh scan (purging target vault)."
            rm -rf "${TARGET_DIR}" 2>/dev/null && sync
            mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" "${TARGET_DIR}/loot" "${TARGET_DIR}/vulnerabilities" "${TARGET_DIR}/screenshots" "${TARGET_DIR}/raw" 2>/dev/null
            touch "${TARGET_DIR}/RECON_results.txt"
        fi
    fi

    # Step 12: Phase execution sequence
    if [[ -s "${TARGET_DIR}/websites/live_urls.txt" ]]; then
        log SKIP "RECON — live_urls present and non-empty."
        phase_complete "RECON" || true
    else
        phase_recon
        # Wait until live_urls.txt is non-empty before proceeding
        local wait_secs=0; local max_wait=30
        while [[ ! -s "${TARGET_DIR}/websites/live_urls.txt" && $wait_secs -lt $max_wait ]]; do
            sleep 1
            wait_secs=$((wait_secs+1))
        done
        sync
    fi

    phase_surface
    phase_crawl
    if [[ -x "${SCRIPT_DIR}/lib/deep_scan.sh" ]]; then
        mkdir -p "${TARGET_DIR}" 2>/dev/null || true
        nohup "${SCRIPT_DIR}/lib/deep_scan.sh" "$TARGET" "${TARGET_DIR}" > /dev/null 2>&1 &
        register_pid $!
    fi
    if command -v crimson_gate_main >/dev/null 2>&1; then
        crimson_gate_main || true
    fi
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
