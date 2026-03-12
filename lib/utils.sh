[[ -n "${UTILS_SOURCED:-}" ]] && return
export UTILS_SOURCED=true
# ═══════════════════════════════════════════════════════════════════════════════
#  §UTILS  Framework Utilities & Process Management
# ═══════════════════════════════════════════════════════════════════════════════

# Global PID Registry
declare -a RUNNING_PIDS=()
declare -a CURRENT_BATCH_PIDS=()
declare -a UI_STREAMER_PIDS=()

# Register a PID for tracking (standalone/background tasks)
register_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
}

# Register a PID specifically for the current tool batch (monitored by HUD)
register_batch_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && CURRENT_BATCH_PIDS+=("$pid") && RUNNING_PIDS+=("$pid")
}

# Register a PID specifically for UI streamers/tailers (ignored by monitor_jobs)
register_streamer_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && UI_STREAMER_PIDS+=("$pid") && RUNNING_PIDS+=("$pid")
}

# Master Cleanup Handler
master_cleanup() {
    # Idempotent cleanup guard
    if [[ "${CLEANED:-0}" == "1" ]]; then
        return 0
    fi
    export CLEANED=1

    # 1. Restore terminal cursor and sane state (do NOT clear the buffer)
    tput cnorm 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    stty sane 2>/dev/null || true

    # 2. Terminate tracked background workers
    log WARN "Master Cleanup: Terminating tracked processes..."
    stop_control_listener 2>/dev/null || true
    for pid in "${RUNNING_PIDS[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    # Force kill streamers if they didn't catch the TERM
    for pid in "${UI_STREAMER_PIDS[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done

    # 3. Clean temporary artifacts (do not wipe terminal output)
    rm -rf "${TEMP_DIR:-/tmp/.spw_null}" 2>/dev/null || true
    rm -f /tmp/crimson_waiting /tmp/crimson_answer 2>/dev/null || true
    [[ -p "$INPUT_FIFO" ]] && rm -f "$INPUT_FIFO" 2>/dev/null || true

    # 4. Context-aware exit messaging
    if [[ "${ABORTED:-0}" == "1" ]]; then
        printf "\n  %b[!] MANUAL OVERRIDE: Spider Web has retracted.%b\n\n" "${BCR}" "${RST}"
        trap '' EXIT TERM INT
        exit 130
    else
        # Successful completion: append After-Action Report (AAR)
        local uptime=$(( $(date +%s) - ${START_EPOCH:-0} ))
        local sub_count=${CNT_SUBS:-0}
        local live_count=${CNT_URLS:-0}
        local vuln_count=${CNT_VULNS:-0}
        local output_path="${TARGET_DIR:-${VAULT_ROOT}/${TARGET:-unknown}}"

        printf "\n  %b[★] OPERATION COMPLETE: Target fully mapped and analyzed%b\n\n" "${BGR}" "${RST}"
        printf "  Total Time Elapsed: %ds\n" "$uptime"
        printf "  Total Subdomains Found: %d\n" "$sub_count"
        printf "  Total Live URLs Extracted: %d\n" "$live_count"
        printf "  Critical Vulnerabilities / Secrets Found: %d\n" "$vuln_count"
        printf "  Results saved to: %s\n\n" "$output_path"

        if [[ -d "${TARGET_DIR:-}" && -d "${TARGET_DIR}/HIGH_ALERTS" ]]; then
            printf "  High Alerts Directory Contents:\n"
            ls -1 "${TARGET_DIR}/HIGH_ALERTS" 2>/dev/null | sed 's/^/    - /'
            echo ""
        fi

        trap '' EXIT TERM INT
        exit 0
    fi
}

# Fallback for tail if missing
_tail() {
    local n="${1:-1}"
    local file="${2:-/dev/stdin}"
    if command -v tail &>/dev/null; then
        tail -n "$n" "$file"
    else
        # Robust awk-based tail-n
        awk -v n="$n" '{lines[NR % n] = $0} END {start = (NR < n) ? 1 : NR + 1; for (i = 0; i < (NR < n ? NR : n); i++) print lines[(start + i) % n]}' "$file"
    fi
}

# §NEW: Fallback for tail -f (Long-polling mode)
_tailf() {
    local pattern="$1"
    # Basic emulation of tail -f using bash+dd+sleep
    # Supports globbing patterns and single files
    declare -A offsets
    while true; do
        for f in $pattern; do
            [[ -f "$f" ]] || continue
            local current_size=$(wc -c < "$f" 2>/dev/null || echo 0)
            local last_size="${offsets["$f"]:-$current_size}"
            
            if [[ $current_size -gt $last_size ]]; then
                # Found new data! Use dd to extract starting from previous offset
                dd if="$f" bs=1 skip="$last_size" 2>/dev/null
                offsets["$f"]=$current_size
            elif [[ $current_size -lt $last_size ]]; then
                # File was truncated or rotated
                offsets["$f"]=0
            else
                # No change: initialize offset if first time seeing this file
                [[ -z "${offsets["$f"]}" ]] && offsets["$f"]=$current_size
            fi
        done
        sleep 1
    done
}

# Path fixing utility
path_fix() {
    unalias -a 2>/dev/null || true
    local go_bin="${HOME}/go/bin"
    local local_bin="${HOME}/.local/bin"
    export PATH="${go_bin}:${local_bin}:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
    if command -v go &>/dev/null; then
        local goos; goos=$(go env GOOS 2>/dev/null || echo "linux")
        local goarch; goarch=$(go env GOARCH 2>/dev/null || echo "amd64")
        export PATH="${go_bin}/${goos}_${goarch}:${PATH}"
    fi
}

# Pre-flight tool check and self-healing installer
check_tools() {
    log INFO "Pre-flight: Verifying Go and Python toolchain and essential binaries..."

    # Ensure Go-installed tools (best-effort; non-fatal)
    if command -v go >/dev/null 2>&1; then
        log INFO "Ensuring naabu and httpx Go binaries are installed (go install)"
        (go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest 2>&1) || true
        (go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest 2>&1) || true
    fi

    # Ensure Python httpx library is reasonably up-to-date (non-fatal)
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --upgrade httpx >/dev/null 2>&1 || true
    elif command -v pip >/dev/null 2>&1; then
        pip install --upgrade httpx >/dev/null 2>&1 || true
    fi

    # Validate ProjectDiscovery httpx binary path (PD_HTTPX); create symlink if possible
    PD_HTTPX="${PD_HTTPX:-${HOME}/go/bin/httpx}"
    if [[ ! -x "${PD_HTTPX}" ]]; then
        local found
        found=$(command -v httpx 2>/dev/null || true)
        if [[ -n "$found" && -x "$found" ]]; then
            log INFO "Found httpx at ${found}; attempting to symlink to ${PD_HTTPX} (best-effort, may require privileges)"
            local pd_dir
            pd_dir=$(dirname "${PD_HTTPX}")
            if [[ ! -d "$pd_dir" ]]; then
                mkdir -p "$pd_dir" 2>/dev/null || true
            fi
            ln -sf "$found" "${PD_HTTPX}" 2>/dev/null || true
        else
            log WARN "httpx binary not found in PATH and ${PD_HTTPX} not executable. Some probes may fail." 
        fi
    fi

    # Attempt an automated sed patch for cloudkiller banner (best-effort)
    if [[ -f "${HOME}/go/bin/cloudkiller" ]]; then
        sed -i '56s/"/r"/' "${HOME}/go/bin/cloudkiller" 2>/dev/null || true
    fi
}
# ═══════════════════════════════════════════════════════════════════════════════
#  §EVASION UTILITIES: User-Agent Rotation & Rate Limiting
# ═══════════════════════════════════════════════════════════════════════════════

# User-Agent Rotation (50+ Browser Strings)
ua_rand() {
    local -a user_agents=(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
        "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1.2 Mobile/15E148 Safari/604.1"
        "Mozilla/5.0 (iPad; CPU OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1.1 Mobile/15E148 Safari/604.1"
        "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:99.0) Gecko/20100101 Firefox/99.0"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; PPC Mac OS X 10_5_8) AppleWebKit/534.50 (KHTML, like Gecko) Version/5.1 Safari/534.50"
        "Mozilla/5.0 (Windows; U; Windows NT 5.2; en-US) AppleWebKit/534.4 (KHTML, like Gecko) Chrome/6.0.472.53 Safari/534.4"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.150 Safari/537.36"
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/95.0.4638.69 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_6_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/95.0.4638.69 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.93 Safari/537.36"
        "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/85.0.4183.121 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.141 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:91.0) Gecko/20100101 Firefox/91.0"
        "Mozilla/5.0 (X11; Linux x86_64; rv:89.0) Gecko/20100101 Firefox/89.0"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.125 Safari/537.36"
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.1 Mobile/15E148 Safari/604.1"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_5_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/109.0"
        "Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/105.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36"
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        "Mozilla/5.0 (Linux; Android 11; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36"
        "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/102.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Linux; Android 10; SM-G973F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.84 Safari/537.36"
    )
    
    # Select random user-agent
    local index; index=$((RANDOM % ${#user_agents[@]}))
    echo "${user_agents[$index]}"
}

# Decoy IPs for logging robustness tests (used with Nmap -D RND:10)
DECOY_IPS=(
    "192.0.2.1"
    "198.51.100.2"
    "203.0.113.3"
)


# Adaptive Rate Limiting (respects WAF thresholds)
export ADAPTIVE_DELAY="${ADAPTIVE_DELAY:-0}"
rate_limit() {
    [[ -z "$ADAPTIVE_DELAY" || "$ADAPTIVE_DELAY" == "0" ]] && return
    local jitter; jitter=$((RANDOM % 3 + 1))  # 1-3 second jitter
    sleep "$(echo "$ADAPTIVE_DELAY + $jitter" | bc -l 2>/dev/null || echo "$ADAPTIVE_DELAY")" 2>/dev/null || sleep "$ADAPTIVE_DELAY"
}

# Detect and apply adaptive rate limiting based on environment
set_adaptive_rate() {
    if [[ "$USE_PROXY" == "true" ]]; then
        # Higher delay when using proxies to respect proxy provider limits
        export ADAPTIVE_DELAY=2
    else
        # Lower delay for direct requests
        export ADAPTIVE_DELAY=1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §DOMAIN VALIDATION: Accept domains, subdomains, URLs, and IPs
# ═══════════════════════════════════════════════════════════════════════════════

# Comprehensive domain validator - accepts various input formats
validate_domain() {
    local input="$1"
    [[ -z "$input" ]] && return 1
    
    # Strip protocol (https://, http://, ftp://, etc.)
    local target; target=$(echo "$input" | sed -e 's|^[^/]*://||' -e 's|/.*$||')
    
    # Domain regex: accepts domains.tld, subdomains.domain.tld, multiple levels
    # IP regex: accepts standard IPv4 addresses
    local DOMAIN_REGEX='^([a-zA-Z0-9]{1,63}\.)+[a-zA-Z]{2,63}$|^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ "$target" =~ $DOMAIN_REGEX ]]; then
        echo "$target"  # Return cleaned target
        return 0
    else
        return 1
    fi
}

# Strip protocol from URL
strip_protocol() {
    local url="$1"
    echo "$url" | sed -e 's|^[^/]*://||' -e 's|/.*$||'
}

# Check if string is valid domain
is_valid_domain() {
    local target="${1//\//}"  # Remove slashes
    target="${target##*://}"  # Remove protocol
    target="${target%%/*}"    # Remove path
    
    # Domain check
    if [[ "$target" =~ ^([a-zA-Z0-9]{1,63}\.)+[a-zA-Z]{2,63}$ ]]; then
        return 0
    fi
    
    # IP check
    if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    
    return 1
}