if [[ -n "${TG_C2_SOURCED:-}" ]]; then
    # If guard variable set but functions aren't present (e.g., exported in env), allow re-sourcing
    if declare -F check_c2 >/dev/null 2>&1; then
        return
    else
        unset TG_C2_SOURCED
    fi
fi
export TG_C2_SOURCED=true
export C2_PROXY_FLAG=""
# Use array for curl options to avoid quoting/word-splitting issues
declare -a TELEGRAM_CURL_OPTS=( --noproxy '*' -4 --connect-timeout 15 --max-time 30 --retry 2 )
# ═══════════════════════════════════════════════════════════════════════════════
#  §6.5  TELEGRAM C2 BRIDGE (Unified & Modular)
# ═══════════════════════════════════════════════════════════════════════════════

# Severity-based notification system
export TG_SEVERITY_LOG="${TARGET_DIR:-/tmp}/logs/tg_severity.log"

# Internal variables (imported from config via main entry)
# TELEGRAM_BOT_TOKEN
# TELEGRAM_CHAT_ID

# Severity-based alert sender (ENHANCED)
tg_alert() {
    local severity="$1"  # INFO, LOW, MEDIUM, HIGH, CRITICAL
    local msg="$2"
    
    [[ -z "$msg" ]] && return
    
    # Log to local severity log regardless
    mkdir -p "$(dirname "$TG_SEVERITY_LOG")" 2>/dev/null
    printf "[%s] %s: %s\n" "$(date +%Y-%m-%d\ %H:%M:%S)" "$severity" "$msg" >> "$TG_SEVERITY_LOG"
    
    # Only send MEDIUM/HIGH/CRITICAL to Telegram
    case "$severity" in
        INFO|LOW)
            # Save to logs only, do NOT send to Telegram for LOW/INFO; use ℹ️ for logs
            tg_send "ℹ️ *INFO*: ${msg}"
            ;;
        MEDIUM)
            tg_send "⚠️ *MEDIUM ALERT*\n${msg}"
            ;;
        HIGH)
            tg_send "🚨 *HIGH*\n${msg}"
            ;;
        CRITICAL)
            tg_send "🚨 *CRITICAL*\n${msg}"
            ;;
    esac
}

# Phase completion summary
tg_phase_summary() {
    local phase="$1"
    local target="${2:-unknown}"
    local asset_count="${3:-0}"
    local duration_seconds="${4:-0}"
    
    # Format duration
    local mins=$((duration_seconds / 60))
    local secs=$((duration_seconds % 60))
    
    local summary="🕷️ <b>PHASE COMPLETE: ${phase}</b>\n"
    summary+="🎯 Target: <code>${target}</code>\n"
    summary+="📦 Total Assets: <code>${asset_count}</code>\n"
    summary+="⏱️ Time: <code>${mins}m ${secs}s</code>"
    
    tg_send "$summary"
}

# Unified HTML-based sender with mode-based visual templates
tg_send() {
    local msg="$1"
    local mode="${2:-INFO}"  # INFO, ALERT, or SYSTEM
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local clean_token; clean_token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local clean_id; clean_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${clean_token}/sendMessage"

    # Clean message: strip ANSI color codes
    local CLEAN_BODY
    CLEAN_BODY=$(printf "%b" "$msg" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')

    # Mode-based icon/header
    local icon
    case "$mode" in
        ALERT)  icon="🔥 <b>[CRITICAL FINDING]</b>" ;;
        SYSTEM) icon="⚙️ <b>[SYSTEM]</b>" ;;
        *)      icon="🌐 <b>[NODE]</b>" ;;
    esac

    # Resolve Node IP (cached for session to avoid repeated lookups)
    if [[ -z "${_CACHED_NODE_IP:-}" ]]; then
        _CACHED_NODE_IP=$(curl -s "${TELEGRAM_CURL_OPTS[@]}" http://ifconfig.me 2>/dev/null || echo "unknown")
        export _CACHED_NODE_IP
    fi

    # Assemble high-fidelity sentinel message
    local FINAL_MESSAGE="${icon} <code>${_CACHED_NODE_IP}</code>%0A━━━━━━━━━━━━━━━%0A${CLEAN_BODY}"

    # Perform a strict POST with short timeouts (HTML mode)
    local resp
    resp=$(curl -s "${TELEGRAM_CURL_OPTS[@]}" -X POST "$url" \
        -d "chat_id=${clean_id}" \
        --data-urlencode "text=${FINAL_MESSAGE}" \
        -d "parse_mode=HTML") || {
        # Fallback for local logging when curl fails
        mkdir -p "${TARGET_DIR:-/tmp}/logs" 2>/dev/null
        printf "[%s] [TELEGRAM_FAIL] %s\n" "$(date +%Y-%m-%d\ %H:%M:%S)" "$CLEAN_BODY" >> "${TARGET_DIR:-/tmp}/logs/tg_fallback.log"
        return 1
    }

    # Inspect API response
    if echo "$resp" | grep -q '"ok":true'; then
        return 0
    else
        log WARN "Telegram API error: ${resp}"
        return 2
    fi
}

# Backward-compatible wrappers (old callers pass 1 arg)
send_telegram() { tg_send "$@"; }
tg_send_msg() { tg_send "$@"; }

# System telemetry for /status command
get_sys_info() {
    local ram cpu bat loc
    ram=$(free -m 2>/dev/null | awk '/Mem:/ { printf("%3.1f%%", $3/$2*100) }' || echo "N/A")
    cpu=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{printf "%.1f%%", $2 + $4}' || echo "N/A")
    bat=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null || echo "N/A")
    loc=$(curl -s --max-time 3 https://ipapi.co/json/ 2>/dev/null | jq -r '.city + ", " + .country_name' 2>/dev/null || echo "Unknown")
    
    if [[ -z "${_CACHED_NODE_IP:-}" ]]; then
        _CACHED_NODE_IP=$(curl -s http://ifconfig.me 2>/dev/null || echo "unknown")
        export _CACHED_NODE_IP
    fi

    echo "🛰 <b>Phase:</b> ${CURRENT_PHASE:-INIT}%0A🔋 <b>Battery:</b> ${bat}%%0A🧠 <b>RAM:</b> ${ram}%0A⚡ <b>CPU:</b> ${cpu}%0A📍 <b>Loc:</b> ${loc}%0A🌐 <b>IP:</b> ${_CACHED_NODE_IP}"
}

# (send_telegram and tg_send_msg aliases are now defined directly after tg_send above)

tg_send_file() {
    local file_path="$1"
    local caption="$2"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file_path" ]] && return
    
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local chat_id; chat_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${token}/sendDocument"
    
        curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} -X POST "$url" \
            -F "chat_id=${chat_id}" \
            -F "document=@${file_path}" \
            -F "caption=${caption}" \
            -F "parse_mode=Markdown" >/dev/null 2>&1 &
}

tg_send_photo() {
    local file="$1" desc="${2:-Photo}"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file" ]] && return
    
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local chat_id; chat_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    
        curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} -X POST "https://api.telegram.org/bot${token}/sendPhoto" \
            -F "chat_id=${chat_id}" \
            -F "photo=@${file}" \
            -F "caption=📸 ${desc}" \
            -F "parse_mode=Markdown" >/dev/null 2>&1 &
}

tg_send_video() {
    local file="$1" desc="${2:-Video}"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file" ]] && return
    
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local chat_id; chat_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    
        curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} -X POST "https://api.telegram.org/bot${token}/sendVideo" \
            -F "chat_id=${chat_id}" \
            -F "video=@${file}" \
            -F "caption=🎬 ${desc}" \
            -F "parse_mode=Markdown" >/dev/null 2>&1 &
}

# ─── UNIFIED BIDIRECTIONAL INPUT (Local + Telegram Simultaneous) ────────────
get_input() {
    local prompt="$1" opts="$2" timeout="${3:-0}"  # 0 = wait indefinitely (critical)
    local fifo="${INPUT_FIFO}"
    
    # Announce wait-lock to operator via Telegram
    tg_send "❓ <b>Wait-Lock Activated</b>\n${prompt}\nOptions: <code>${opts}</code>"
    
    # Ensure FIFO exists before reading
    [[ -p "$fifo" ]] || { rm -f "$fifo"; mkfifo "$fifo"; chmod 666 "$fifo"; } 2>/dev/null || true
    
    local ans=""
    local start_time; start_time=$(date +%s)
    
    # Validate timeout boundary
    [[ ${timeout} -lt 0 ]] && timeout=0
    
    # DUAL-MONITOR LOOP: Reads from BOTH Telegram (FIFO) and local terminal simultaneously
    # This ensures instant responsiveness to /skip commands typed on phone or in VS Code
    while true; do
        # ==== PRIORITY 1: Check Telegram C2 (FIFO) ====
        # Non-blocking read with 0.5s timeout per attempt; read once into variable
        ans=$(timeout 0.5 cat "$fifo" 2>/dev/null | head -1)
        if [[ -n "$ans" ]]; then
            log OK "C2 Response: ${WH}${ans}${RST} (Telegram)"
            break
        fi
        
        # ==== PRIORITY 2: Check local terminal input ====
        # Only if terminal is interactive
        if [[ -t 0 ]]; then
            if read -r -t 0.5 -p "" local_ans 2>/dev/null; then
                if [[ -n "${local_ans}" ]]; then
                    ans="${local_ans}"
                    log OK "Local Response: ${WH}${ans}${RST} (Terminal)"
                    break
                fi
            fi
        fi
        
        # ==== PRIORITY 3: Check overall timeout ====
        # Only enforce timeout if explicitly set (> 0)
        if (( timeout > 0 )); then
            local current_time; current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            if (( elapsed >= timeout )); then
                log WARN "Input timeout (${timeout}s). Proceeding with no response."
                break
            fi
        fi
        
        # Brief sleep to prevent busy-waiting
        sleep 0.1
    done
    
    echo "$ans"
}

# Dual-source decision helper: returns one of: rerun|skip|abort
get_user_decision() {
    local prompt="${1:-Proceed?}" timeout_sec="${2:-5}"
    # Friendly prompt options presented to operator and C2
    local options="[Y] Rerun | [N] Skip | [A] Abort"
    # Send an actionable message to C2 (telegram) and wait for a response via FIFO or local stdin
    tg_send "⚠️ <b>Action Required</b>\n${prompt}\nOptions: ${options}"

    # Use existing get_input() which listens to both FIFO (Telegram) and local stdin
    local raw_ans
    raw_ans=$(get_input "${prompt}" "Y/N/A" "${timeout_sec}")
    raw_ans=$(echo "${raw_ans}" | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true)

    # Normalize common telegram keywords as well
    case "${raw_ans}" in
        y|yes|r|retry|1)
            echo "rerun"
            return 0
            ;;
        n|no|skip|2)
            echo "skip"
            return 0
            ;;
        a|abort|3)
            echo "abort"
            return 0
            ;;
        '')
            # Timeout default: skip to maintain automation
            echo "skip"
            return 0
            ;;
        *)
            # Unknown input -> treat as skip
            echo "skip"
            return 0
            ;;
    esac
}

wait_for_telegram() {
    local prompt="$1"
    tg_send "🕹️ <b>ACTION REQUIRED</b>\n${prompt}\n\n[S]kip | [R]etry | [A]bort"
    touch /tmp/crimson_waiting
    rm -f /tmp/crimson_answer
    log WARN "Waiting for Telegram Intervention..."
    while [[ ! -f "/tmp/crimson_answer" ]]; do sleep 1; done
    local ans; ans=$(cat /tmp/crimson_answer)
    rm -f /tmp/crimson_waiting /tmp/crimson_answer
    echo "$ans"
}

# ─── BACKGROUND SERVICES ─────────────────────────────────────────────────────
error_streamer() {
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    local err_log="${TARGET_DIR}/logs/error.log"
    while [[ ! -f "$err_log" ]]; do sleep 5; done
    _tailf "$err_log" | while read -r line; do
        if [[ -n "$line" ]]; then
            local cl; cl=$(echo "$line" | sed 's/\x1b\[[0-9;]*[mK]//g')
            tg_send "⚠️ <b>ERROR</b>: <code>${cl:0:1000}</code>"
        fi
    done
}

# C2 Executor - processes commands from FIFO (including remote /target)
tg_executor() {
    [[ -z "${INPUT_FIFO:-}" ]] && return
    [[ ! -p "$INPUT_FIFO" ]] && return
    
    # Non-blocking read from FIFO
    local cmd
    # Use timeout to avoid blocking if the FIFO is empty; read once into variable
    cmd=$(timeout 0.5 cat "$INPUT_FIFO" 2>/dev/null | head -1)
    [[ -z "$cmd" ]] && return
    
    # Handle special commands
    # Format: /target syfe.com OR /target https://syfe.com
    if [[ "$cmd" =~ ^target[[:space:]]+ ]]; then
        local remote_target="${cmd#target[[:space:]]*}"
        # Strip protocol if present
        remote_target=$(echo "$remote_target" | sed -e 's|^[^/]*://||' -e 's|/.*$||')
        
        # Validate target format
        if is_valid_domain "$remote_target"; then
            # Write remote target to answer file for prompt_target to read
            echo "$remote_target" > /tmp/crimson_answer
            TARGET="$remote_target"
            tg_send "✅ <b>Remote Target Set</b>: <code>${remote_target}</code>"
            log PHASE "C2: Remote target received: ${WH}${remote_target}${RST}"
        else
            tg_send "❌ <b>Invalid Target Format</b>: <code>${remote_target}</code>"
            log WARN "C2: Invalid remote target format"
        fi
        return
    fi
        
        case "$cmd" in
            skip)
                tg_send "⏭ Phase skip command received." "SYSTEM"
                touch /tmp/crimson_skip
                log PHASE "C2: SKIP command executed"
                ;;
            retry)
                tg_send "🔄 Retrying current phase." "SYSTEM"
                log PHASE "C2: RETRY command executed"
                ;;
            abort)
                tg_send "🛑 Aborted scan. Cleaning up..." "SYSTEM"
                log FATAL "C2: ABORT command - terminating"
                exit 1
                ;;
            continue)
                tg_send "▶️  Continuing to next phase." "SYSTEM"
                log PHASE "C2: CONTINUE command executed"
                ;;
            pause)
                tg_send "⏸️  Scan paused." "SYSTEM"
                log WARN "C2: PAUSE command"
                ;;
            resume)
                tg_send "▶️  Scan resumed." "SYSTEM"
                log PHASE "C2: RESUME command"
                ;;
            logs)
                local logs; logs=$(_tail 10 /tmp/crimson_sync.log 2>/dev/null || echo "No logs available")
                tg_send "<b>Last 10 Log Lines:</b>%0A<code>${logs}</code>" "SYSTEM"
                ;;
            websites)
                local livef="${TARGET_DIR}/websites/live_urls.txt"
                if [[ -f "$livef" && -s "$livef" ]]; then
                    tg_send_file "$livef" "Live URLs for ${TARGET}"
                else
                    tg_send "ℹ️ No live URLs found yet." "INFO"
                fi
                ;;
            vulns)
                local vulndir="${TARGET_DIR}/vulnerabilities"
                if [[ -d "$vulndir" ]]; then
                    local tarf="/tmp/vulns_${TARGET}_$(date +%s).tar.gz"
                    tar -czf "$tarf" -C "$vulndir" . 2>/dev/null || true
                    if [[ -f "$tarf" ]]; then
                        tg_send_file "$tarf" "Vulnerabilities for ${TARGET}" && rm -f "$tarf"
                    else
                        tg_send "ℹ️ No vulnerability artifacts to send." "INFO"
                    fi
                else
                    tg_send "ℹ️ Vulnerabilities directory not present." "INFO"
                fi
                ;;
            stop)
                tg_send "🛑 Stop signal received. Terminating current operations..." "SYSTEM"
                touch /tmp/crimson_stop
                log PHASE "C2: STOP signal issued"
                ;;
            status)
                local stats
                stats=$(get_sys_info)
                tg_send "$stats" "SYSTEM"
                ;;
            help)
                tg_send "<b>Available Commands:</b>%0A/status — System Health%0A/shot — Terminal Screenshot%0A/skip — Skip Current Phase%0A/stop — Kill Active Scan%0A/logs — Last 10 Log Lines%0A/websites — Send Live URLs%0A/vulns — Send Vuln Archive%0A/target <domain> — Set Target%0A/help — This Menu" "SYSTEM"
                ;;
            shot)
                if command -v scrot &>/dev/null; then
                    scrot "/tmp/crimson_shot.png" 2>/dev/null || true
                    if [[ -f "/tmp/crimson_shot.png" ]]; then
                        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
                            -F "chat_id=${TELEGRAM_CHAT_ID}" \
                            -F "photo=@/tmp/crimson_shot.png" \
                            -F "caption=📸 Current Terminal State" > /dev/null 2>&1
                        rm -f "/tmp/crimson_shot.png"
                    else
                        tg_send "❌ Screenshot capture failed." "SYSTEM"
                    fi
                else
                    tg_send "❌ scrot not installed. Run: sudo apt install scrot" "SYSTEM"
                fi
                ;;
            *)
                [[ -n "$cmd" ]] && log WARN "C2: Unknown command: ${cmd}"
                ;;
        esac
}

# C2 Heartbeat / Verification
check_c2() {
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${token}/getMe"
    # Retry loop with short backoff to handle transient DNS/connectivity issues
    local attempt=0
    local max_attempts=3
    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        # Suppress curl stderr to avoid printing raw errors to terminal
            local resp
            resp=$(curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} "$url" 2>/dev/null) || resp=""
        if [[ -n "$resp" && $(echo "$resp" | grep -q '"ok":true'; echo $?) -eq 0 ]]; then
            log OK "Telegram C2: ${BGR}Verified & Synchronized${RST} (attempt ${attempt})"
            return 0
        fi
        # brief backoff
        sleep $((attempt * 2))
    done
        # If verification fails, write diagnostic and enable silent C2 mode to avoid blocking
        echo "[$(date +%Y-%m-%dT%H:%M:%S)] Telegram C2 verification FAILED after ${max_attempts} attempts" >> /tmp/c2_fail.log
        log WARN "Telegram C2: Verification Failed after ${max_attempts} attempts. Entering SILENT C2 mode (see /tmp/c2_fail.log)"
        export TELEGRAM_C2_SILENT=1
        return 1
}

# ─── TELEGRAM C2 ENGINE (Persistent Bidirectional Command Polling) ────────────
telegram_listener() {
    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && return
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local offset=0
    local url="https://api.telegram.org/bot${token}/getUpdates"
    local fifo="${INPUT_FIFO}"
    
    # Run C2 routing diagnostic to determine whether to use proxies or bypass them
    echo -e "\n[ 🔍 ] Running C2 Routing Diagnostic..."

    # Test A: Current Environment (Proxy)
    echo -n "   ├─ Testing via Ghost Proxies... "
    if curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} "https://api.telegram.org" > /dev/null 2>&1; then
        echo -e "\033[1;32m[OK]\033[0m"
        C2_PROXY_FLAG="" # Proxies work fine
    else
        echo -e "\033[1;31m[FAILED]\033[0m"
        # Test B: Direct Connection (No Proxy)
        echo -n "   ├─ Testing via Direct Routing... "
        if curl -s "${TELEGRAM_CURL_OPTS[@]}" ${CURL_OPTS[@]} "https://api.telegram.org" > /dev/null 2>&1; then
            echo -e "\033[1;32m[OK]\033[0m"
            echo -e "   \033[1;33m[!] DIAGNOSIS: Proxies are killing C2 traffic. Forcing split-tunnel for Telegram.\033[0m"
            C2_PROXY_FLAG='--noproxy "*"'
        else
            echo -e "\033[1;31m[FAILED]\033[0m"
            echo -e "   \033[1;31m[!] DIAGNOSIS: Total network/DNS block. Even direct routing failed.\033[0m"
            C2_PROXY_FLAG=""
        fi
    fi

    # Ensure proxy env vars are not leaked into C2 operations
    unset http_proxy; unset https_proxy; unset HTTP_PROXY; unset HTTPS_PROXY

    # Ensure FIFO exists with proper permissions and open it for non-blocking reads/writes
    [[ -p "$fifo" ]] || { rm -f "$fifo"; mkfifo "$fifo"; chmod 666 "$fifo"; } 2>/dev/null || true
    # Open an additional file descriptor to the FIFO for writes in read+write mode to avoid blocking
    # This keeps FD 3 available for quick, non-blocking writes to the FIFO from this process
    exec 3<>"$fifo" 2>/dev/null || true

    # Send a sign-of-life to Telegram so operator knows the listener is active
    tg_send "🛰 <b>Crimson Sentinel</b> — C2 Listener Online\nStatus: Listener active and polling for commands." || true
    
    # PERSISTENT LOOP: Never exits, polls continuously
    while true; do
        local resp
        # Long-polling with 30s timeout for instant C2 responsiveness; force direct Fast-Lane
        resp=$(curl -s "${TELEGRAM_CURL_OPTS[@]}" --connect-timeout 15 --max-time 60 "${url}?offset=${offset}&timeout=30" 2>/dev/null)
        [[ -z "$resp" ]] && { sleep 3; continue; }
        
        # Validate JSON response before processing
        if ! echo "$resp" | jq . >/dev/null 2>&1; then
            sleep 2
            continue
        fi
        
        # Extract the latest update using jq (reduce processing and focus on newest message)
        local latest; latest=$(echo "$resp" | jq -r '.result | last')
        if [[ "$latest" != "null" && -n "$latest" ]]; then
            local msg; msg=$(echo "$latest" | jq -r '.message.text // empty' 2>/dev/null)
            local chat_id; chat_id=$(echo "$latest" | jq -r '.message.chat.id // empty' 2>/dev/null)
            local update_id; update_id=$(echo "$latest" | jq -r '.update_id // empty' 2>/dev/null)

            # Update offset to mark message as processed
            if [[ -n "$update_id" && "$update_id" =~ ^[0-9]+$ ]]; then
                offset=$((update_id + 1))
            fi

            # Process only messages from authorized Chat ID
            if [[ -n "$chat_id" && -n "$TELEGRAM_CHAT_ID" && "$chat_id" == "$TELEGRAM_CHAT_ID" && -n "$msg" ]]; then
                # If message is /stop -> kill PID from /tmp/crimson.pid
                if [[ "$msg" =~ ^/stop ]]; then
                    local pidfile="/tmp/crimson.pid"
                    if [[ -f "$pidfile" ]]; then
                        local target_pid; target_pid=$(cat "$pidfile" 2>/dev/null || echo "")
                        if [[ -n "$target_pid" ]]; then
                            kill -9 "$target_pid" 2>/dev/null || true
                            tg_send "🛑 Killed process PID: ${target_pid}"
                            log PHASE "C2: /stop executed -> killed ${target_pid}"
                        else
                            tg_send "ℹ️ /stop received but PID file empty"
                        fi
                    else
                        tg_send "ℹ️ /stop received but PID file not found"
                    fi
                    # Continue to next poll
                    continue
                fi

                # Explicitly handle /help, /status, and /shot inline
                if [[ "$msg" == "/help" ]]; then
                    tg_send "<b>Available Commands:</b>%0A/status — System Health%0A/shot — Terminal Screenshot%0A/skip — Skip Current Phase%0A/stop — Kill Active Scan%0A/logs — Last 10 Log Lines%0A/websites — Send Live URLs%0A/vulns — Send Vuln Archive%0A/target <domain> — Set Target%0A/help — This Menu" "SYSTEM"
                    continue
                elif [[ "$msg" == "/status" ]]; then
                    local stats
                    stats=$(get_sys_info)
                    tg_send "$stats" "SYSTEM"
                    continue
                elif [[ "$msg" == "/shot" ]]; then
                    if command -v scrot &>/dev/null; then
                        scrot "/tmp/crimson_shot.png" 2>/dev/null || true
                        if [[ -f "/tmp/crimson_shot.png" ]]; then
                            local c_token; c_token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
                            local c_chatid; c_chatid=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
                            curl -s -X POST "https://api.telegram.org/bot${c_token}/sendPhoto" \
                                -F "chat_id=${c_chatid}" \
                                -F "photo=@/tmp/crimson_shot.png" \
                                -F "caption=📸 Current Terminal State" > /dev/null 2>&1
                            rm -f "/tmp/crimson_shot.png"
                        else
                            tg_send "❌ Screenshot capture failed." "SYSTEM"
                        fi
                    else
                        tg_send "❌ scrot not installed. Run: sudo apt install scrot" "SYSTEM"
                    fi
                    continue
                fi

                # For other recognized commands, write to FIFO (remove leading /)
                if [[ "$msg" =~ ^/([a-zA-Z0-9_]+)([[:space:]]|$) ]]; then
                    local cmd; cmd="${msg:1}"
                    # Prefer writing through FD 3 (opened above) to avoid blocking when no reader is present
                    if [[ -t 3 ]] || true; then
                        printf '%s\n' "$cmd" >&3 2>/dev/null || {
                            # Fallback: attempt a short timeout write to the FIFO
                            timeout 1 bash -c "printf '%s\n' \"${cmd}\" > \"${fifo}\"" 2>/dev/null || log WARN "C2: fifo write failed"
                        }
                    else
                        # If FD3 unavailable, attempt async write (best-effort)
                        { printf '%s\n' "$cmd" > "$fifo"; } 2>/dev/null &
                    fi
                    log PHASE "C2 Command Received: ${WH}${cmd}${RST} (source: Telegram)"
                fi
            fi
        fi
        
        # Short sleep to prevent API hammering
        sleep 1
    done
}

# C2 Logic for /snap and /stream
tg_snap() {
    local evidence_dir="${TARGET_DIR}/evidence"
    mkdir -p "$evidence_dir"
    if tool_exists scrot; then
        local file="${evidence_dir}/snap_$(date +%s).png"
        scrot "$file"
        tg_send_photo "$file" "Manual C2 Snapshot"
        rm -f "$file"
    fi
}

tg_stream() {
    local evidence_dir="${TARGET_DIR}/evidence"
    mkdir -p "$evidence_dir"
    if tool_exists ffmpeg; then
        local file="${evidence_dir}/stream_$(date +%s).mp4"
        tg_send "🎬 Starting 10s video stream..."
        
        # Detection of display resolution
        local res="1920x1080"
        if command -v xdpyinfo &>/dev/null; then
            res=$(xdpyinfo | grep dimensions | awk '{print $2}')
        fi

        # Record 10s of the screen
        ffmpeg -y -f x11grab -video_size "$res" -i :0.0 -t 10 -pix_fmt yuv420p "$file" >/dev/null 2>&1
        
        if [[ -f "$file" ]]; then
            tg_send_video "$file" "Live C2 Stream (${res})"
            rm -f "$file"
        else
            tg_send "❌ Video stream capture failed (Check X11/Display)."
        fi
    else
        tg_send "❌ ffmpeg not found. Install it for live streaming."
    fi
}

# Removed duplicate tg_executor (the FIFO-driven executor above is the canonical implementation)
