#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §JOBS  Concurrency & Execution Engine
# ═══════════════════════════════════════════════════════════════════════════════

# Job Limiter (CPU-Aware)
job_limiter() {
    local max_jobs=${MAX_JOBS:-$(nproc 2>/dev/null || echo 4)}
    while true; do
        local running=0
        for pid in "${CURRENT_BATCH_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                ((running++))
            fi
        done
        (( running < max_jobs )) && break
        sleep 1
    done
}

# Ensure Go-installed binaries are visible in background jobs
if command -v go >/dev/null 2>&1; then
    GOPATH=$(go env GOPATH 2>/dev/null || echo "${HOME}/go")
    export PATH="$PATH:${GOPATH}/bin"
fi

# Live Execution Wrapper (ENHANCED: Suppress spam, only print actionable events)
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
    # If a previous log exists, offer the operator a chance to redo and overwrite
    if [[ -f "$log_file" && -s "$log_file" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "[?] Log exists for ${tag} at ${log_file}. Redo and overwrite? [y/N]: " _redo
            if [[ "${_redo}" =~ ^[Yy] ]]; then
                : > "$log_file"
                log INFO "Overwriting existing log: ${log_file}"
            else
                hb_log "$tag" "Skipping ${tag} (existing log preserved)."
                # Print a short preview of existing findings for operator visibility
                printf "  ${BCY}[${tag}] Existing findings preview:${RST}\n"
                tail -n 20 "$log_file" 2>/dev/null | sed 's/^/    /'
                return 0
            fi
        else
            # Non-interactive: append by default
            touch "$log_file"
        fi
    else
        touch "$log_file"
    fi

    # ── MAIN TOOL EXECUTION (Real-time streaming) ──
    # Stream output to BOTH terminal AND log file in real-time
    local exit_code=0
    local start_time; start_time=$(date +%s)
    # Execute with output streamed to terminal AND log file in realtime.
    # Use bash -lc to avoid fragile single-quote wrapping (proxychains and nested quotes)
    if command -v stdbuf &>/dev/null; then
        if stdbuf -oL -eL bash -lc "$cmd" 2>&1 | tee -a "$log_file"; then
            exit_code=0
        else
            exit_code=${PIPESTATUS[0]:-1}
        fi
    else
        if bash -lc "$cmd" 2>&1 | tee -a "$log_file"; then
            exit_code=0
        else
            exit_code=${PIPESTATUS[0]:-1}
        fi
    fi
    local end_time; end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    local count; count=$(wc -l < "$log_file" 2>/dev/null || echo 0)

    # Rate-limit / WAF detection: if logs show Cloudflare 1015 or 429, increase jitter and rotate proxy
    if grep -E "1015|\b429\b|rate limit|error 1015|error 429|HTTP/1.[01] 403" "$log_file" >/dev/null 2>&1; then
        log WARN "Rate-limit detected in ${tag} output. Increasing jitter and rotating proxy..."
        # Increase local jitter window
        export JITTER_MIN=3
        export JITTER_MAX=8
        # Attempt simple proxy rotation if proxies enabled
        if [[ "${USE_PROXY:-false}" == "true" ]]; then
            proxy_prefix >/dev/null 2>&1 || true
        fi
        # Sleep a random backoff between 3-8s
        sleep $((RANDOM % 6 + 3))
    fi

    # §FIX: Graceful Exit Code 1 handling (No results found should not be a FATAL failure)
    if [[ $exit_code -eq 0 ]]; then
        hb_log "$tag" "${tag} finished. Processed ${BCY}${count}${RST} results."
        # Print a brief findings preview for operator
        printf "  ${BCY}[${tag}] Findings preview (last 20 lines):${RST}\n"
        tail -n 20 "$log_file" 2>/dev/null | sed 's/^/    /'
    elif [[ $exit_code -eq 1 && ! -s "$log_file" ]]; then
        hb_log "$tag" "${tag} finished. ${BCY}0 results found.${RST}"
    else
        hb_log "$tag" "${BCR}${tag} failed with exit code ${exit_code}.${RST}"
        printf "  ${BCR}[ERROR LOG - ${tag}]${RST}\n"
        _tail 5 "$log_file" | sed 's/^/    /'
        printf "\n"
        tg_send "⚠️ <b>TOOL FAILURE alert</b>\nTool: <code>${tag}</code>\nCode: <code>${exit_code}</code>"
    fi

    # Pulse Check: If a tool exited very quickly (<2s) with an error, capture tail and notify
    if [[ $exit_code -ne 0 && $elapsed -lt 2 ]]; then
        local tail_out; tail_out=$(tail -n 5 "$log_file" 2>/dev/null || echo "(no log output)")
        log WARN "${tag} terminated quickly (<=2s). Sending pulse diagnostics to C2."
        tg_send "⚠️ <b>Quick Failure</b>\nTool: <code>${tag}</code>\nExit: <code>${exit_code}</code>\nLast lines:\n<pre>${tail_out}</pre>"
    fi
}

# Glass Engine Monitor (ENHANCED: Integrated persistent HUD)
monitor_jobs() {
    local phase="$1"
    local start_time; start_time=$(date +%s)
    
    # §FIX: Monitor CURRENT_BATCH_PIDS array instead of generic 'jobs'
    while true; do
        local running_pids=()
        for pid in "${CURRENT_BATCH_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                running_pids+=("$pid")
            fi
        done
        
        local running=${#running_pids[@]}
        [[ $running -eq 0 ]] && break
        
        local elapsed; elapsed=$(($(date +%s) - start_time))
        
        # Live Stats for Loot
        local cur_loot=0
        case "$phase" in
            # §FIX: HUD Sync - Count from live raw files
            RECON)   cur_loot=$(cat "${TARGET_DIR}/tools_used/"*.log 2>/dev/null | wc -l || echo 0) ;;
            SURFACE) cur_loot=$(wc -l < "${TARGET_DIR}/tools_used/httpx.log" 2>/dev/null || echo 0) ;;
            CRAWL)   cur_loot=$(cat "${TARGET_DIR}/tools_used/"*.log 2>/dev/null | wc -l || echo 0) ;;
            VULNS)   cur_loot=$(find "${TARGET_DIR}/vulnerabilities" -type f -exec cat {} + 2>/dev/null | wc -l || echo 0) ;;
        esac

        # Calculate progress percentage (based on elapsed time as a proxy)
        local progress=0
        case "$phase" in
            RECON)   progress=$(( elapsed * 100 / 120 )) ;;
            SURFACE) progress=$(( elapsed * 100 / 180 )) ;;
            CRAWL)   progress=$(( elapsed * 100 / 240 )) ;;
            VULNS)   progress=$(( elapsed * 100 / 300 )) ;;
        esac
        [[ $progress -gt 100 ]] && progress=100

        # ENHANCED HUD: Persistent status bar using ANSI escape codes
        hud_render "$running" "$cur_loot" "${CNT_VULNS:-0}" "$progress"
        
        local remote_skip=false
        [[ -f /tmp/crimson_answer ]] && remote_skip=true
        
        if (read -r -t 1 -n 1 key && [[ -z "$key" ]]) || [[ "$remote_skip" == "true" ]]; then
            log WARN "Skip Signal received. Terminating batch..."
            rm -f /tmp/crimson_answer
            for pid in "${running_pids[@]}"; do
                kill -TERM "$pid" 2>/dev/null || true
            done
            CURRENT_BATCH_PIDS=()
            break
        fi
        sleep 0.5
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

# ═══════════════════════════════════════════════════════════════════════════════
#  §SILENT SENTRY  Background Error Monitor & Recovery Engine
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize error tracking
export SENTRY_HEALTH_LOG="${TARGET_DIR}/logs/system_health.log"
export SENTRY_ENABLED=true
export -a FAILED_TOOLS=()
export ENGINE_WARNING=false

# Start the Silent Sentry monitoring loop
start_sentry() {
    [[ -z "$TARGET_DIR" ]] && return
    mkdir -p "${TARGET_DIR}/logs" 2>/dev/null
    
    # Launch sentry in background
    nohup bash -c '
        target_dir="${TARGET_DIR:-/tmp}"
        health_log="${target_dir}/logs/system_health.log"
        touch "$health_log"
        
        # Failure keywords to grep for
        failure_keywords="error|connection refused|permission denied|invalid flag|timeout|failed|fatal|exception|crashed|segmentation"
        
        while true; do
            [[ ! -d "$target_dir/logs" ]] && { sleep 3; continue; }
            
            # Scan all logs for failures
            for log_file in "$target_dir"/logs/*.log "$target_dir"/tools_used/*.log 2>/dev/null; do
                [[ ! -f "$log_file" ]] && continue
                
                # Check for failure keywords
                if grep -qi "$failure_keywords" "$log_file" 2>/dev/null; then
                    local error_msg; error_msg=$(grep -i "$failure_keywords" "$log_file" 2>/dev/null | head -1)
                    local tool_name; tool_name=$(basename "$log_file" .log)
                    
                    # Log to health file
                    echo "[$(date +%H:%M:%S)] [ERROR] ${tool_name}: ${error_msg:0:100}" >> "$health_log"
                    
                    # Mark in engine state
                    echo "[!] ENGINE WARNING: ${tool_name} encountered error" >> "$health_log"
                fi
            done
            
            sleep 5
        done
    ' >> "${TARGET_DIR}/logs/sentry.log" 2>&1 &
    
    export SENTRY_PID=$!
}

# Soft restart a failed tool with different proxy
tool_soft_restart() {
    local tool_name="$1"
    local original_cmd="$2"
    local log_file="$3"
    
    [[ -z "$tool_name" ]] && return 1
    
    log WARN "Attempting soft restart of ${tool_name} with alternate config..."
    
    # Try with different proxy if available
    local alt_proxy
    if [[ "$USE_PROXY" == "true" ]]; then
        alt_proxy=$(proxy_select 2>/dev/null) || alt_proxy=""
    fi
    
    # Modify command to use alternate proxy
    local restart_cmd="$original_cmd"
    [[ -n "$alt_proxy" ]] && restart_cmd=$(echo "$restart_cmd" | sed "s|proxychains4.*|proxychains4 -f /tmp/proxy_alt_$$.conf|g")
    
    # Execute restart
    local restart_log="/tmp/restart_${tool_name}_$$.log"
    if eval "$restart_cmd" > "$restart_log" 2>&1; then
        log OK "${tool_name} soft restart successful"
        cat "$restart_log" >> "$log_file"
        rm -f "$restart_log"
        return 0
    else
        log ERROR "${tool_name} soft restart failed"
        echo "[FAILED RESTART] ${tool_name}" >> "${TARGET_DIR}/logs/system_health.log"
        FAILED_TOOLS+=("$tool_name")
        ENGINE_WARNING=true
        rm -f "$restart_log"
        return 1
    fi
}

# Monitor tool exit codes and trigger recovery
monitor_tool_health() {
    local tool_name="$1"
    local log_file="$2"
    local cmd="$3"
    
    [[ -z "$tool_name" || -z "$log_file" || -z "$cmd" ]] && return
    
    # Wait for tool to complete
    wait $! 2>/dev/null
    local exit_code=$?
    
    if [[ $exit_code -gt 0 ]]; then
        log WARN "Tool ${tool_name} exited with code ${exit_code}"
        hud_event "!" "ENGINE WARNING: ${tool_name} failed (code: ${exit_code})"
        
        # Attempt one soft restart
        if tool_soft_restart "$tool_name" "$cmd" "$log_file"; then
            log OK "${tool_name} recovered"
        else
            # Mark tool as failed if restart fails
            echo "[FAILED] ${tool_name}" >> "${TARGET_DIR}/logs/system_health.log"
            hud_event "!" "ENGINE WARNING: ${tool_name} marked FAILED after restart attempt"
            ENGINE_WARNING=true
        fi
    fi
}

# Periodic health check report
generate_health_report() {
    local health_log="${TARGET_DIR}/logs/system_health.log"
    [[ ! -f "$health_log" ]] && return
    
    local error_count; error_count=$(grep -c "\[ERROR\]" "$health_log" 2>/dev/null || echo 0)
    local failed_count; failed_count=$(grep -c "\[FAILED\]" "$health_log" 2>/dev/null || echo 0)
    
    if [[ $error_count -gt 0 || $failed_count -gt 0 ]]; then
        hud_event "!" "Health Report: ${error_count} errors, ${failed_count} failed tools"
        printf "  ${BCR}System Health Status:${RST} ${error_count} errors | ${failed_count} failures\n"
    fi
}

# Stop sentry monitoring
stop_sentry() {
    [[ -n "$SENTRY_PID" ]] && kill -9 "$SENTRY_PID" 2>/dev/null || true
}
