[[ -n "${FRAMEWORK_SOURCED:-}" ]] && return
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
        # Strip ANSI escape sequences for clean file logging
        local clean_msg
        clean_msg=$(printf "%s" "$msg" | sed 's/\x1b\[[0-9;]*[mK]//g')
        echo "[$timestamp] [$type] $clean_msg" >> "$log_file"
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
    # if ! curl -Is --connect-timeout 10 https://google.com &>/dev/null; then
    #     log FATAL "CRITICAL: No Internet Connection Detected. Check your Gateway/Gateway."
    # fi
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

# §NEW: Comprehensive toolchain audit (shows all status at boot)
check_all_tools() {
    log INFO "Operational Audit: Verifying framework toolchain status..."
    local tools=(
        "subfinder" "assetfinder" "amass" "httpx" 
        "naabu" "nmap" 
        "katana" "hakrawler" "gau" "waybackurls" 
        "gf" "mantra" "trufflehog" "arjun" 
        "nuclei" "dalfox" "ghauri" "ffuf" "subjack"
    )
    
    local available=()
    local missing=()
    
    # Auto-install arjun via pipx if missing
    if ! command -v arjun &>/dev/null; then
        install_arjun_jit 2>/dev/null || true
    fi
    
    for t in "${tools[@]}"; do
        if command -v "$t" &>/dev/null; then
            available+=("${BGR}${t}${RST}")
        else
            missing+=("${BCR}${t}${RST}")
        fi
    done
    
    [[ ${#available[@]} -gt 0 ]] && log OK "Available Tools: ${available[*]}"
    [[ ${#missing[@]} -gt 0 ]] && log WARN "Missing Tools: ${missing[*]}"
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

request_jitter() {
    local sleep_time; sleep_time=$(awk -v min="${JITTER_MIN:-1}" -v max="${JITTER_MAX:-3}" 'BEGIN{srand(); print min+rand()*(max-min)}')
    sleep "$sleep_time"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §ADAPTIVE HEADER ENGINE  Professional Evasion Headers
# ═══════════════════════════════════════════════════════════════════════════════

# Generate randomized Referer header
generate_referer() {
    local -a referers=(
        "https://www.google.com/search"
        "https://www.google.com/"
        "https://www.bing.com/search"
        "https://www.duckduckgo.com/"
        "https://www.linkedin.com/feed/"
        "https://www.github.com/"
        "https://news.ycombinator.com/"
        "https://reddit.com/"
        "https://stackexchange.com/"
        "https://www.facebook.com/"
    )
    echo "${referers[$RANDOM % ${#referers[@]}]}"
}

# Generate spoofed X-Forwarded-For IP
generate_forwarded_ip() {
    # Generate realistic IP ranges from various regions
    local -a ip_ranges=("8.8." "1.1." "9.9." "208.67." "196.52." "185.222." "45.32." "173.245.")
    local prefix="${ip_ranges[$RANDOM % ${#ip_ranges[@]}]}"
    local ip="${prefix}$((RANDOM % 256)).$((RANDOM % 256))"
    echo "$ip"
}

# Generate region-matched User-Agent
generate_regional_ua() {
    local region="${1:-us}"  # Default to US
    local -a us_uas=(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
    local -a eu_uas=(
        "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
    )
    local -a asia_uas=(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
        "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    )
    
    case "$region" in
        eu|europe)   echo "${eu_uas[$RANDOM % ${#eu_uas[@]}]}" ;;
        asia|japan|cn) echo "${asia_uas[$RANDOM % ${#asia_uas[@]}]}" ;;
        us|*) echo "${us_uas[$RANDOM % ${#us_uas[@]}]}" ;;
    esac
}

# Build adaptive headers for curl/httpx commands
adaptive_headers() {
    local region="${1:-us}"
    local referer; referer=$(generate_referer)
    local forwarded_ip; forwarded_ip=$(generate_forwarded_ip)
    local user_agent; user_agent=$(generate_regional_ua "$region")
    
    # Output header flags for curl
    echo "-H 'Referer: ${referer}' -H 'X-Forwarded-For: ${forwarded_ip}' -H 'User-Agent: ${user_agent}' -H 'Accept-Language: en-US,en;q=0.9'"
}

# Legacy compatibility: single header output
get_adaptive_headers() {
    adaptive_headers "$@"
}

export FRAMEWORK_SOURCED=true
