#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §UTILS  Framework Utilities & Process Management
# ═══════════════════════════════════════════════════════════════════════════════

# Global PID Registry
declare -a RUNNING_PIDS=()
declare -a CURRENT_BATCH_PIDS=()

# Register a PID for tracking
register_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
}

# Register a PID specifically for the current tool batch
register_batch_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && CURRENT_BATCH_PIDS+=("$pid") && RUNNING_PIDS+=("$pid")
}

# Master Cleanup Handler
master_cleanup() {
    # 1. Force terminal back to normal state
    tput rmcup 2>/dev/null || true
    tput csr 0 $(tput lines 2>/dev/null || echo 999) 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    stty sane 2>/dev/null || true
    tput cup $(tput lines 2>/dev/null || echo 40) 0 2>/dev/null || true

    # 2. Terminate tracked background workers
    log WARN "Master Cleanup: Terminating tracked processes..."
    for pid in "${RUNNING_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # 3. Clean environment
    rm -rf "${TEMP_DIR:-/tmp/.spw_null}" 2>/dev/null || true
    rm -f /tmp/crimson_waiting /tmp/crimson_answer 2>/dev/null || true
    [[ -p "$INPUT_FIFO" ]] && rm -f "$INPUT_FIFO" 2>/dev/null || true
    
    echo -e "\n  ${BCR}● MASTER SESSION TERMINATED${RST}  ${DIM}Spider Web has retracted.${RST}\n"
    # Scoped exit
    trap '' EXIT TERM INT
    exit 0
}

# Fallback for tail if missing
_tail() {
    local n="${1:-1}"
    local file="${2:-/dev/stdin}"
    if command -v tail &>/dev/null; then
        tail -n "$n" "$file"
    else
        awk -v n="$n" '{lines[NR % n] = $0} END {start = (NR < n) ? 1 : NR + 1; for (i = 0; i < (NR < n ? NR : n); i++) print lines[(start + i) % n]}' "$file"
    fi
}

# Path fixing utility
path_fix() {
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:${HOME}/go/bin:${HOME}/.local/bin"
    if command -v go &>/dev/null; then
        local goos; goos=$(go env GOOS 2>/dev/null || echo "linux")
        local goarch; goarch=$(go env GOARCH 2>/dev/null || echo "amd64")
        export PATH="${PATH}:${HOME}/go/bin/${goos}_${goarch}"
    fi
}
