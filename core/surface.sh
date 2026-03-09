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
    
    check_phase_tools "SURFACE" naabu httpx cloudkiller nmap || true
    section "PHASE 2: SURFACE — Asset Validation & Surface Mapping" "🔌"
    check_proxy

    local in_recon="${TARGET_DIR}/RECON_results.txt"
    local out="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local vuln_dir="${TARGET_DIR}/vulnerabilities"
    local px; px=$(proxy_prefix)
    local pf; pf=$(proxy_flag)
    local ua; ua=$(ua_rand)
    local HTTPX_BIN="${HOME}/go/bin/httpx"
    # Detect if TARGET is an IP (IPv4) to skip subdomain logic
    local IS_IP=false
    if [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IS_IP=true
    fi

    # Display evasion status
    hud_event "*" "Evasion Active: User-Agent Rotation + Rate Limiting (${ADAPTIVE_DELAY}s delay)"

    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for surface_tool in httpx naabu cloudkiller; do
        if ! tool_exists "$surface_tool"; then
            lazy_install_tool "$surface_tool" || log WARN "Skipping ${surface_tool} (not available)"
        fi
    done

    # ----------------------- Tier 1: Passive Baseline Aggregation -----------------------
    if tool_exists naabu; then
        log INFO "naabu (Tier 1) — Passive baseline aggregation (no active probes)"
        CURRENT_TOOL="naabu-passive"
        job_limiter
        # Use RECON results as source for passive metadata queries
        run_live "${px} naabu -silent -passive -list '${in_recon}' -o '${raw}/naabu_passive.txt'" "${raw}/naabu_passive.log" "NAABU-PASSIVE" &
        register_batch_pid $!
        rate_limit
    fi

    # ----------------------- Tier 2: Low-Impact Active Verification --------------------
    if tool_exists naabu; then
        log INFO "naabu (Tier 2) — Low-impact active verification (Top 1000 ports, throttled)"
        CURRENT_TOOL="naabu-active"
        job_limiter
        # Input: prefer passive baseline if available, else fall back to recon list
        local naabu_input="${raw}/naabu_passive.txt"
        [[ ! -s "$naabu_input" ]] && naabu_input="${in_recon}"

        # If target is an IP, scan the IP directly; otherwise scan list/top-1000
        if [[ "$IS_IP" == true ]]; then
            log INFO "Target detected as IP; scanning IP directly: ${TARGET}"
            run_live "${px} naabu -top-1000 -rate 1000 -wait 1 -host '${TARGET}' -o '${out}/naabu_active_raw.txt'" "${raw}/naabu_active.log" "NAABU-ACTIVE" &
        else
            run_live "${px} naabu -top-1000 -rate 1000 -wait 1 -list '${naabu_input}' -o '${out}/naabu_active_raw.txt'" "${raw}/naabu_active.log" "NAABU-ACTIVE" &
        fi
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists assetfinder; then
        log INFO "assetfinder — asset hunting with UA rotation..."
        CURRENT_TOOL="assetfinder"
        run_live "${px} assetfinder --subs-only '${TARGET}'" "${raw}/assetfinder.log" "ASSETFINDER" &
        register_batch_pid $!
        rate_limit
        # Save final results from log file after phase
    fi

    # 2. HTTPX (Probing) - ENHANCED with UA rotation
    if tool_exists httpx; then
        log INFO "httpx — probing for status, titles, and fingerprints (UA rotation enabled)..."
        CURRENT_TOOL="httpx"
        hud_event "*" "Starting HTTPX validation on $(wc -l < "${in_recon}" 2>/dev/null || echo "?") targets..."
        # Use long flags: -header for custom header, -silent instead of -s
        local httpx_cmd="cat '${in_recon}' | xargs -P 20 -I {} ${px} ${HTTPX_BIN} -header \"User-Agent: ${ua}\" -silent --follow-redirects --timeout 15 -rl 30 -t 10 {}"
        run_live "$httpx_cmd" "${raw}/httpx.log" "HTTPX" &
        register_batch_pid $!
        rate_limit
    fi

    # 3. CLOUDKILLER (S3/Cloud check)
    if tool_exists cloudkiller; then
        log INFO "cloudkiller — hunting for misconfigured cloud storage with evasion..."
        CURRENT_TOOL="cloudkiller"
        # Ensure cloudkiller (python) is invoked with python3 to avoid shell execution errors
        local ck_path; ck_path=$(command -v cloudkiller 2>/dev/null || echo "${HOME}/tools/cloud-killer/cloud_killer.py")
        run_live "python3 \"${ck_path}\" -d '${TARGET}'" "${raw}/cloudkiller.log" "CLOUDKILLER" &
        register_batch_pid $!
        rate_limit
    fi

    monitor_jobs "SURFACE"
    # Normalize naabu output into a simple open_ports list for downstream consumption
    if [[ -s "${out}/naabu_active_raw.txt" ]]; then
        awk -F':' '{print $1":"$2}' "${out}/naabu_active_raw.txt" 2>/dev/null | sort -u > "${out}/open_ports_raw.txt" || true
        awk -F':' '{print $1}' "${out}/open_ports_raw.txt" 2>/dev/null | sort -u > "${out}/open_ports.txt" || true
    fi
    
    # Consolidation (use raw logs as source)
    hud_event "*" "Consolidating SURFACE results..."
    awk '{print $1}' "${raw}/httpx.log" 2>/dev/null | sort -u > "${out}/live_urls.txt"
    sed 's|https\?://||; s|/.*||' "${raw}/httpx.log" 2>/dev/null | sort -u > "${out}/live_domains.txt"

    # Optional: keep copies for reference
    cp "${raw}/assetfinder.log" "${raw}/assetfinder.txt" 2>/dev/null || true
    cp "${raw}/cloudkiller.log" "${out}/cloud_findings.txt" 2>/dev/null || true
    
    CNT_PORTS=$(wc -l < "${out}/open_ports.txt" 2>/dev/null || echo 0)
    CNT_URLS=$(wc -l < "${out}/live_urls.txt" 2>/dev/null || echo 0)
    
    hb_log "SURFACE" "Surface Mapping Complete: ${BGR}${CNT_URLS} live hosts${RST} and ${BGR}${CNT_PORTS} ports${RST} confirmed."
    hud_event "+" "Live URLs identified: ${CNT_URLS} targets validated"
    cp "${out}/live_urls.txt" "${TARGET_DIR}/SURFACE_results.txt"

    # ----------------------- Tier 3: High-Intensity Service Analysis -------------------
    # Parse naabu active output to extract host and port pairs
    if [[ -s "${out}/naabu_active_raw.txt" ]]; then
        awk -F':' '{print $1":"$2}' "${out}/naabu_active_raw.txt" 2>/dev/null | sort -u > "${out}/open_ports_raw.txt" || true
    fi

    if [[ -s "${out}/open_ports_raw.txt" && $(command -v nmap >/dev/null 2>&1; echo $?) -eq 0 ]]; then
        log INFO "Tier 3: Launching targeted Nmap fingerprinting on discovered ports"
        CURRENT_TOOL="nmap"
        while IFS=":" read -r host port; do
            [[ -z "$host" || -z "$port" ]] && continue
            job_limiter
            local safe_host; safe_host=${host//\//_}
            local out_file="${raw}/nmap_${safe_host}_${port}.txt"
            # Use connect scan (-sT) to be compatible with SOCKS5 proxy layers
            run_live "nmap -sT -sV -sC --version-intensity 5 -p ${port} -D RND:10 --source-port 53 ${host} -oN '${out_file}'" "${raw}/nmap_${safe_host}_${port}.log" "NMAP" &
            register_batch_pid $!
            rate_limit
        done < "${out}/open_ports_raw.txt"
        monitor_jobs "SURFACE-NMAP"
    fi
    phase_complete "SURFACE"
}
