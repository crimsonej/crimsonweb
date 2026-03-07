#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §JOBS  Concurrency & Execution Engine
# ═══════════════════════════════════════════════════════════════════════════════

# Job Limiter (CPU-Aware)
job_limiter() {
    local max_jobs=${MAX_JOBS:-$(nproc 2>/dev/null || echo 4)}
    while (( $(jobs -p | wc -l) >= max_jobs )); do
        sleep 1
    done
}

# Live Execution Wrapper
run_live() {
    local cmd="$1"
    local log_file="$2"
    local tag="$3"
    
    # Ensure environment is sane
    path_fix
    
    # Ensure output directory exists
    local log_dir; log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null
    
    # Heartbeat: Start
    hb_log "$tag" "Launching ${WH}${tag}${RST}..."
    touch "$log_file"

    # ── LOG TAILER (Background) ──
    # We launch the tailer separately and capture its PID to kill it later
    (
        tail -f "$log_file" 2>/dev/null | awk 'NR % 25 == 0' 2>/dev/null | while read -r line; do
            printf "  ${DIM}[%s] %s${RST}\n" "$tag" "$line" 2>/dev/null
        done
    ) &
    local tailer_pid=$!

    # ── MAIN TOOL EXECUTION ──
    local stream_cmd
    if command -v stdbuf &>/dev/null; then
        stream_cmd="stdbuf -oL -eL bash -c '$cmd' 2>&1"
    else
        stream_cmd="bash -c '$cmd' 2>&1"
    fi

    eval "$stream_cmd" >> "$log_file"
    local exit_code=${PIPESTATUS[0]}

    # Explicitly kill the tailer so the job queue clears
    kill "$tailer_pid" 2>/dev/null || true

    if [[ $exit_code -eq 0 ]]; then
        local count; count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        hb_log "$tag" "${tag} finished. Processed ${BCY}${count}${RST} results."
    else
        hb_log "$tag" "${BCR}${tag} failed with exit code ${exit_code}.${RST}"
        printf "  ${BCR}[ERROR LOG - ${tag}]${RST}\n"
        _tail 5 "$log_file" | sed 's/^/    /'
        printf "\n"
        tg_send "⚠️ <b>TOOL FAILURE alert</b>\nTool: <code>${tag}</code>\nCode: <code>${exit_code}</code>"
    fi
}

# Glass Engine Monitor
monitor_jobs() {
    local phase="$1"
    local start_time; start_time=$(date +%s)
    
    while [[ -n $(jobs -p) ]]; do
        local running; running=$(jobs -p | wc -l)
        local elapsed; elapsed=$(($(date +%s) - start_time))
        
        # Live Stats for Loot
        local cur_loot=0
        case "$phase" in
            RECON)   cur_loot=$(wc -l < "${TARGET_DIR}/RECON_results.txt" 2>/dev/null || echo 0) ;;
            SURFACE) cur_loot=$(wc -l < "${TARGET_DIR}/SURFACE_results.txt" 2>/dev/null || echo 0) ;;
            CRAWL)   cur_loot=$(wc -l < "${TARGET_DIR}/CRAWL_results.txt" 2>/dev/null || echo 0) ;;
            VULNS)   cur_loot=$(wc -l < "${TARGET_DIR}/VULNS_results.txt" 2>/dev/null || echo 0) ;;
        esac

        # HUD Status Line
        printf "\r  ${BCR}[●]${RST} ${BWHT}${phase}${RST} | Jobs: ${BCY}${running}${RST} | Loot: ${BGR}${cur_loot}${RST} | Time: ${WH}${elapsed}s${RST} | [Enter] Skip "
        
        local remote_skip=false
        [[ -f /tmp/crimson_answer ]] && remote_skip=true
        
        if (read -r -t 1 -n 1 key && [[ -z "$key" ]]) || [[ "$remote_skip" == "true" ]]; then
            log WARN "Skip Signal received. Terminating batch..."
            rm -f /tmp/crimson_answer
            for pid in "${CURRENT_BATCH_PIDS[@]}"; do
                kill -TERM "$pid" 2>/dev/null || true
            done
            CURRENT_BATCH_PIDS=()
            break
        fi
    done
    printf "\n"
    CURRENT_BATCH_PIDS=()
}

# Progress Utilities
update_global_progress() {
    local label="$1" current="$2" total="$3"
    # Logic to update persistent progress trackers
}

progress_bar() {
    local label="$1" current="$2" total="$3" color="$4"
    local percent; percent=$(( total > 0 ? current * 100 / total : 0 ))
    local width=40
    local done; done=$(( percent * width / 100 ))
    local missing; missing=$(( width - done ))
    printf "  ${color}%-15s${RST} [$(printf '%*s' "$done" '' | tr ' ' '█')$(printf '%*s' "$missing" '' | tr ' ' '░')] ${percent}%%\n" "$label"
}
