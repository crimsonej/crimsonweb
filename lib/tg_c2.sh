#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §6.5  TELEGRAM C2 BRIDGE (Unified & Modular)
# ═══════════════════════════════════════════════════════════════════════════════

# Internal variables (imported from config via main entry)
# TELEGRAM_BOT_TOKEN
# TELEGRAM_CHAT_ID

# Unified HTML-based sender
tg_send() {
    local msg="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    
    local clean_token; clean_token=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
    local clean_id; clean_id=$(echo "$TELEGRAM_CHAT_ID" | tr -d '[:space:]')
    
    # Use HTML parse mode for better control over "High Alert" data
    curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot${clean_token}/sendMessage" \
        -d "chat_id=${clean_id}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 &
}

# Aliases for backward compatibility
send_telegram() { tg_send "$@"; }

tg_send_file() {
    local file_path="$1"
    local caption="$2"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file_path" ]] && return
    
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
    curl -s --connect-timeout 10 --max-time 60 -X POST "$url" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}" \
        -F "parse_mode=HTML" >/dev/null 2>&1 &
}

tg_send_photo() {
    local file="$1" desc="${2:-Photo}"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file" ]] && return
    
    curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "photo=@${file}" \
        -F "caption=📸 ${desc}" \
        -F "parse_mode=HTML" >/dev/null 2>&1 &
}

tg_send_video() {
    local file="$1" desc="${2:-Video}"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || ! -f "$file" ]] && return
    
    curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVideo" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "video=@${file}" \
        -F "caption=🎬 ${desc}" \
        -F "parse_mode=HTML" >/dev/null 2>&1 &
}

# ─── INTERACTIVE INPUT (Wait-Lock) ───────────────────────────────────────────
get_input() {
    local prompt="$1" opts="$2" timeout="${3:-0}"
    tg_send "❓ <b>Wait-Lock Activated</b>\n${prompt}\nOptions: <code>${opts}</code>"
    
    local wait_file="/tmp/crimson_waiting"
    local ans_file="/tmp/crimson_answer"
    
    mkdir -p /tmp 2>/dev/null
    touch "$wait_file"
    rm -f "$ans_file"
    
    [[ -p "$INPUT_FIFO" ]] || mkfifo "$INPUT_FIFO" 2>/dev/null || true
    exec 3<> "$INPUT_FIFO" 2>/dev/null || true
    
    local ans=""
    local elapsed=0
    while [[ ! -f "$ans_file" ]]; do
        if read -r -t 1 local_ans < /dev/tty; then
            [[ -n "$local_ans" ]] && { ans="$local_ans"; break; }
        fi
        
        if read -r -t 0.2 fifo_ans <&3 2>/dev/null; then
            [[ -n "$fifo_ans" ]] && { ans="$fifo_ans"; break; }
        fi
        
        if (( timeout > 0 )); then
            (( elapsed++ )) || true
            if (( elapsed >= timeout )); then break; fi
        fi
    done
    
    exec 3>&- 2>/dev/null || true
    [[ -z "$ans" && -f "$ans_file" ]] && ans=$(cat "$ans_file")
    rm -f "$wait_file" "$ans_file"
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

# C2 Heartbeat / Verification
check_c2() {
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
    if curl -s --connect-timeout 5 "$url" | grep -q '"ok":true'; then
        log OK "Telegram C2: ${BGR}Verified & Synchronized${RST}"
    else
        log WARN "Telegram C2: Verification Failed. Check Token/Network."
    fi
}

# ─── TELEGRAM C2 ENGINE ──────────────────────────────────────────────────────
telegram_listener() {
    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && return
    local offset=0
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
    
    while true; do
        local resp; resp=$(curl -s --connect-timeout 10 "${url}?offset=${offset}&timeout=30")
        [[ -z "$resp" ]] && { sleep 5; continue; }
        
        # Process each message
        local count; count=$(echo "$resp" | jq '.result | length' 2>/dev/null || echo 0)
        for ((i=0; i<count; i++)); do
            local msg; msg=$(echo "$resp" | jq -r ".result[$i].message.text" 2>/dev/null)
            local chat_id; chat_id=$(echo "$resp" | jq -r ".result[$i].message.chat.id" 2>/dev/null)
            local update_id; update_id=$(echo "$resp" | jq -r ".result[$i].update_id" 2>/dev/null)
            offset=$((update_id + 1))

            # Security: Only respond to authorized Chat ID
            if [[ "$chat_id" == "$TELEGRAM_CHAT_ID" ]]; then
                if [[ "$msg" == /* ]]; then
                    echo "$msg" > "$INPUT_FIFO"
                fi
            fi
        done
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

tg_executor() {
    [[ -p "$INPUT_FIFO" ]] || mkfifo "$INPUT_FIFO" 2>/dev/null
    while true; do
        if read -r cmd < "$INPUT_FIFO"; then
            case "$cmd" in
                /help) tg_send "<b>Crimson C2 Help</b>\n/status - Realtime Telemetry\n/ls - Vault Tree\n/shot - Screen Snapshot\n/live - 10s Screen Video\n/log - Last 20 logs\n/skip - Remote Batch Kill\n/sys - PC System Info" ;;
                /status) 
                    local uptime; uptime=$(($(date +%s) - START_EPOCH))
                    tg_send "📊 <b>Mission Status</b>\nTarget: <code>${TARGET}</code>\nPhase: <b>${CURRENT_PHASE}</b>\nTool: <code>${CURRENT_TOOL}</code>\n\n📈 <b>Pulse</b>\nSubs: <code>${CNT_SUBS}</code>\nPorts: <code>${CNT_PORTS}</code>\nURLs: <code>${CNT_URLS}</code>\nVulns: <code>${CNT_VULNS}</code>\n\n⏱️ Uptime: <code>${uptime}s</code>" 
                    ;;
                /ls) 
                    local tree; tree=$(ls -F "$TARGET_DIR" 2>/dev/null | head -n 20)
                    tg_send "📁 <b>Vault Contents</b>\n<code>${tree}</code>" 
                    ;;
                /log) 
                    local logs; logs=$(tail -n 20 "${TARGET_DIR}/logs/session.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[mK]//g')
                    tg_send "📝 <b>Latest Logs</b>\n<code>${logs}</code>" 
                    ;;
                /skip) 
                    touch /tmp/crimson_answer
                    tg_send "⚠️ <b>Skip Signal</b> injected into framework."
                    ;;
                /shot|/snap)
                    if declare -f tg_snap >/dev/null; then
                        tg_snap
                    else
                        tg_send "📸 Snapshot engine not initialized."
                    fi
                    ;;
                /live|/stream)
                    if declare -f tg_stream >/dev/null; then
                        tg_stream
                    else
                        tg_send "🎬 Stream engine not initialized."
                    fi
                    ;;
                /sys)
                    local sys_info; sys_info=$(uname -a | cut -d' ' -f1-3)
                    local load; load=$(uptime | awk -F'load average:' '{ print $2 }')
                    tg_send "🖥️ <b>System Info</b>\nOS: <code>${sys_info}</code>\nLoad: <code>${load}</code>"
                    ;;
            esac
        fi
    done
}
