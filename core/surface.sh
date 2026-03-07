# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE 2 — SURFACE: Asset Validation & Surface Mapping
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"
source "$LIB_PATH/proxy.sh"

phase_surface() {
    phase_should_run "SURFACE" || { log SKIP "SURFACE — already completed."; return; }
    CURRENT_PHASE="SURFACE"
    print_phase_map
    
    check_phase_tools "SURFACE" naabu httpx cloudkiller || true
    section "PHASE 2: SURFACE — Asset Validation & Surface Mapping" "🔌"
    check_proxy

    local in_recon="${TARGET_DIR}/RECON_results.txt"
    local out="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    mkdir -p "$out" "$raw"
    local px; px=$(proxy_prefix)
    local pf; pf=$(proxy_flag)

    # 1. NAABU (Port Scan)
    if tool_exists naabu; then
        log INFO "naabu — scanning for non-standard ports..."
        CURRENT_TOOL="naabu"
        mkdir -p "$out" "$raw"
        run_live "${px} naabu -l '${in_recon}' -c 50 -rate 1000 -top-ports 1000 -silent -o '${out}/open_ports.txt'" "${raw}/naabu.log" "NAABU" &
        register_batch_pid $!
    fi

    # 2. HTTPX (Probing)
    if tool_exists httpx; then
        log INFO "httpx — probing for status, titles, and fingerprints..."
        CURRENT_TOOL="httpx"
        mkdir -p "$out" "$raw"
        local httpx_cmd="${px} ~/go/bin/httpx -list '${in_recon}' -status-code -tech-detect -title -follow-redirects -random-agent -threads ${THREADS} -rate-limit ${RATE_LIMIT} -stream -at -td -server -ip -cname -cdn ${USER_HEADER:+-H '${USER_HEADER}'} ${pf:+-proxy '${pf}'} -o '${out}/httpx_results.txt'"
        run_live "$httpx_cmd" "${raw}/httpx.log" "HTTPX" &
        register_batch_pid $!
    fi

    # 3. CLOUDKILLER (S3/Cloud check)
    if tool_exists cloudkiller; then
        log INFO "cloudkiller — hunting for misconfigured cloud storage..."
        CURRENT_TOOL="cloudkiller"
        run_live "${px} cloudkiller -d '${TARGET}' | tee '${out}/cloud_findings.txt'" "${raw}/cloudkiller.log" "CLOUDKILLER" &
        register_batch_pid $!
    fi

    monitor_jobs "SURFACE"
    
    # Consolidation
    awk '{print $1}' "${out}/httpx_results.txt" 2>/dev/null | sort -u > "${out}/live_urls.txt"
    sed 's|https\?://||; s|/.*||' "${out}/httpx_results.txt" 2>/dev/null | sort -u > "${out}/live_domains.txt"
    
    CNT_PORTS=$(wc -l < "${out}/open_ports.txt" 2>/dev/null || echo 0)
    CNT_URLS=$(wc -l < "${out}/live_urls.txt" 2>/dev/null || echo 0)
    
    hb_log "SURFACE" "Surface Mapping Complete: ${BGR}${CNT_URLS} live hosts${RST} and ${BGR}${CNT_PORTS} ports${RST} confirmed."
    cp "${out}/live_urls.txt" "${TARGET_DIR}/SURFACE_results.txt"
    phase_complete "SURFACE"
}
