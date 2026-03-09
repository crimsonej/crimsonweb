[[ -n "${TG_C2_SOURCED:-}" ]] && return
export TG_C2_SOURCED=true
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

# Unified HTML-based sender
tg_send() {
    local msg="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local clean_token; clean_token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local clean_id; clean_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${clean_token}/sendMessage"

    # Clean message: strip ANSI color codes and escape HTML brackets
    local CLEAN_BODY
    CLEAN_BODY=$(echo -e "$msg" | sed 's|\x1b\[[0-9;]*m||g' | sed 's|<|\&lt;|g; s|>|\&gt;|g')

    # Prefix header with Node IP (HTML safe) and assemble final message (use URL-encoded newlines)
    local CURRENT_IP
    CURRENT_IP=$(curl -s --max-time 5 http://ifconfig.me || echo "unknown")
    local HEADER
    HEADER="<b>🌍 [Node]:</b> <code>${CURRENT_IP}</code>"
    local FINAL_MESSAGE
    FINAL_MESSAGE="${HEADER}%0A%0A${CLEAN_BODY}"

    # Perform a strict POST with short timeouts and capture response for diagnostics (HTML mode)
    local resp
    resp=$(curl -sS --connect-timeout 5 --max-time 15 -X POST "$url" \
        -d "chat_id=${clean_id}" \
        --data-urlencode "text=${FINAL_MESSAGE}" \
        -d "parse_mode=HTML") || {
        log WARN "Telegram send failed: network/connectivity error"
        return 1
    }

    # Inspect API response
    if echo "$resp" | grep -q '"ok":true'; then
        hb_log "C2" "Telegram message delivered"
        return 0
    else
        log WARN "Telegram API error: ${resp}"
        return 2
    fi
}

# Aliases for backward compatibility
send_telegram() { tg_send "$@"; }

tg_send_file() {
    local file_path="$1"
    local caption="$2"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file_path" ]] && return
    
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local chat_id; chat_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${token}/sendDocument"
    
    curl -s --connect-timeout 10 --max-time 60 -X POST "$url" \
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
    
    curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot${token}/sendPhoto" \
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
    
    curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot${token}/sendVideo" \
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
        # Non-blocking read with 0.5s timeout per attempt
        if timeout 0.5 cat "$fifo" 2>/dev/null | head -1 | grep -q .; then
            ans=$(timeout 0.5 cat "$fifo" 2>/dev/null | head -1)
            if [[ -n "${ans}" ]]; then
                log OK "C2 Response: ${WH}${ans}${RST} (Telegram)"
                break
            fi
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
    tail -f "$err_log" | while read -r line; do
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
    if timeout 0.5 cat "$INPUT_FIFO" 2>/dev/null | head -1 | grep -q .; then
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
                tg_send "⏭️  Skipped current phase."
                touch /tmp/crimson_skip
                log PHASE "C2: SKIP command executed"
                ;;
            retry)
                tg_send "🔄 Retrying current phase."
                log PHASE "C2: RETRY command executed"
                ;;
            abort)
                tg_send "🛑 Aborted scan. Cleaning up..."
                log FATAL "C2: ABORT command - terminating"
                exit 1
                ;;
            continue)
                tg_send "▶️  Continuing to next phase."
                log PHASE "C2: CONTINUE command executed"
                ;;
            pause)
                tg_send "⏸️  Scan paused."
                log WARN "C2: PAUSE command"
                ;;
            resume)
                tg_send "▶️  Scan resumed."
                log PHASE "C2: RESUME command"
                ;;
            logs)
                # Send last 10 lines of /tmp/crimson_sync.log
                local logs; logs=$(tail -n 10 /tmp/crimson_sync.log 2>/dev/null || echo "No logs available")
                tg_send "*Last 10 lines of /tmp/crimson_sync.log*\n\n\`\`\`${logs}\n\`\`\`"
                ;;
            websites)
                local livef="${TARGET_DIR}/websites/live_urls.txt"
                if [[ -f "$livef" && -s "$livef" ]]; then
                    tg_send_file "$livef" "Live URLs for ${TARGET}"
                else
                    tg_send "ℹ️ No live URLs found yet."
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
                        tg_send "ℹ️ No vulnerability artifacts to send."
                    fi
                else
                    tg_send "ℹ️ Vulnerabilities directory not present."
                fi
                ;;
            stop)
                tg_send "🛑 Stop signal received. Terminating current operations..."
                touch /tmp/crimson_stop
                log PHASE "C2: STOP signal issued"
                ;;
            status)
                local phase="${CURRENT_PHASE:-INIT}"
                local target="${TARGET:-none}"
                tg_send "📊 <b>Status Report</b>\\nPhase: ${phase}\\nTarget: ${target}"
                ;;
            *)
                # Unknown command - log it
                [[ -n "$cmd" ]] && log WARN "C2: Unknown command: ${cmd}"
                ;;
        esac
    fi
}

# C2 Heartbeat / Verification
check_c2() {
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local url="https://api.telegram.org/bot${token}/getMe"
    if curl -s --connect-timeout 10 --max-time 30 "$url" | grep -q '"ok":true'; then
        log OK "Telegram C2: ${BGR}Verified & Synchronized${RST}"
    else
        log WARN "Telegram C2: Verification Failed. Check Token/Network."
    fi
}

# ─── TELEGRAM C2 ENGINE (Persistent Bidirectional Command Polling) ────────────
telegram_listener() {
    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && return
    local token; token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local offset=0
    local url="https://api.telegram.org/bot${token}/getUpdates"
    local fifo="${INPUT_FIFO}"
    
    # Ensure FIFO exists with proper permissions
    [[ -p "$fifo" ]] || { rm -f "$fifo"; mkfifo "$fifo"; chmod 666 "$fifo"; } 2>/dev/null || true
    
    # PERSISTENT LOOP: Never exits, polls continuously
    while true; do
        local resp
        # Long-polling with 30s timeout for instant C2 responsiveness
        resp=$(curl -s --connect-timeout 10 --max-time 60 "${url}?offset=${offset}&timeout=30" 2>/dev/null)
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

                # For other recognized commands, write to FIFO (remove leading /)
                if [[ "$msg" =~ ^/([a-zA-Z0-9_]+)([[:space:]]|$) ]]; then
                    local cmd; cmd="${msg:1}"
                    { echo "$cmd" > "$fifo"; } 2>/dev/null &
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
