#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §FRAMEWORK  Core Logic & Global Utilities
# ═══════════════════════════════════════════════════════════════════════════════

# Core Logger
_wlog() {
    local type="$1" msg="$2"
    local timestamp; timestamp=$(date +"%H:%M:%S")
    # TARGET_DIR might not be set during early init
    if [[ -n "${TARGET_DIR:-}" ]]; then
        local log_file="${TARGET_DIR}/logs/session.log"
        mkdir -p "$(dirname "$log_file")" 2>/dev/null
        # Strip ANSI if possible, but for now just raw log
        echo "[$timestamp] [$type] $msg" >> "$log_file"
    fi
}

log() {
    local type="$1" msg="$2"
    local timestamp; timestamp=$(date +"%H:%M:%S")
    case "$type" in
        OK)    printf "[${timestamp}] [${BGR}  ●  ${RST}] %b\n" "$msg" ;;
        INFO)  printf "[${timestamp}] [${BCY}  ○  ${RST}] %b\n" "$msg" ;;
        WARN)  printf "[${timestamp}] [${BYL}  !  ${RST}] %b\n" "$msg" ;;
        ERROR) printf "[${timestamp}] [${BCR}  ✘  ${RST}] %b\n" "$msg" ;;
        FATAL) printf "[${timestamp}] [${BCR} FATAL ${RST}] %b\n" "$msg"; exit 1 ;;
        SKIP)  printf "[${timestamp}] [${DIM} SKIP ${RST}] %b\n" "$msg" ;;
        PHASE) printf "\n${BCR}═══[ ${BWHT}%s${BCR} ]${RST}\n" "$msg" ;;
        *)     printf "[${timestamp}] [%s] %b\n" "$type" "$msg" ;;
    esac
    _wlog "$type" "$msg"
}

# Heartbeat & Telegram Summary
hb_log() {
    local tag="$1" msg="$2"
    local timestamp; timestamp=$(date +"%H:%M:%S")
    local clean_msg; clean_msg=$(echo "$msg" | sed 's/\x1b\[[0-9;]*[mK]//g')
    
    # Terminal Output
    printf "[${timestamp}] [${BMAG}${tag}${RST}] %b\n" "$msg"
    
    # File Log
    _wlog "HEARTBEAT" "[$tag] $clean_msg"
    
    # Telegram Update (Optional: only if it contains 'finished' or 'failed' or 'found')
    if [[ "$msg" =~ (finished|failed|found|Launching) ]]; then
        tg_send "📡 <b>[${tag}]</b> ${clean_msg}"
    fi
}

# Internet Heartbeat
check_internet() {
    log INFO "Internet Heartbeat: Checking connectivity..."
    if ! curl -Is --connect-timeout 10 https://google.com &>/dev/null; then
        log FATAL "CRITICAL: No Internet Connection Detected. Check your Gateway/VPN."
    fi
    log OK "Internet Heartbeat: ${BGR}ACTIVE${RST}"
}

# ── Tool Utilities ─────────────────────────────────────────────────────────
tool_exists() { command -v "$1" &>/dev/null; }

check_phase_tools() {
    local phase="$1"
    shift
    local missing=()
    for tool in "$@"; do
        if ! tool_exists "$tool"; then missing+=("$tool"); fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log WARN "Phase ${phase}: Missing tools: ${missing[*]}"
    fi
}

# ── Resource Management ────────────────────────────────────────────────────
check_resources() {
    local tool="$1"
    # Basic RAM check for intensive tools like Amass
    local free_ram; free_ram=$(free -m | awk '/^Mem:/{print $4}')
    if [[ "$tool" == "amass" && "$free_ram" -lt 500 ]]; then
        log WARN "Low RAM detected ($free_ram MB). Amass might be unstable."
    fi
}

# ── Animation / UI Helpers ─────────────────────────────────────────────────
spin_start() {
    local msg="$1"
    printf "  ${CY}●${RST} %s " "$msg"
}
spin_stop() { printf "${BGR}DONE${RST}\n"; }

ua_rand() {
    local agents=("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.107 Safari/537.36")
    echo "${agents[$RANDOM % ${#agents[@]}]}"
}
export -f ua_rand

request_jitter() {
    local sleep_time; sleep_time=$(awk -v min="${JITTER_MIN:-1}" -v max="${JITTER_MAX:-3}" 'BEGIN{srand(); print min+rand()*(max-min)}')
    sleep "$sleep_time"
}
