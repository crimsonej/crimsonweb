# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE 5 — VULNS: Active Vulnerability Probing (The Muscle)
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"

phase_vuln() {
    phase_should_run "VULNS" || { log SKIP "VULNS — already completed."; return; }
    CURRENT_PHASE="VULNS"
    PHASE_START_TIME=$(date +%s)  # Track phase start for summary
    print_phase_map; print_loot
    # Ensure websites directory exists and live_urls file is present to avoid "No such file" errors
    mkdir -p "${TARGET_DIR}/websites/" "${TARGET_DIR}/tools_used" 2>/dev/null || true
    touch "${TARGET_DIR}/websites/live_urls.txt" 2>/dev/null || true
    
    check_phase_tools "VULNS" nuclei dalfox ghauri ffuf subjack || true
    section "PHASE 5: VULNS — Active Vulnerability Probing" "☢️"

    local cdir="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local vuln_dir="${TARGET_DIR}/vulnerabilities"
    local ua; ua=$(ua_rand)
    
    # Display evasion strategy
    hud_event "*" "Vuln Scanning: UA Rotation + Rate Limiting (${ADAPTIVE_DELAY}s) + Stealth Headers ACTIVE"

    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for vuln_tool in nuclei dalfox ghauri ffuf subjack; do
        if ! tool_exists "$vuln_tool"; then
            lazy_install_tool "$vuln_tool" || log WARN "Skipping ${vuln_tool} (not available)"
        fi
    done

    # 1. NUCLEI (Template Attack - ENHANCED: High-value templates targeting CVEs, exposed panels, takeovers)
    if tool_exists nuclei; then
        log INFO "Nuclei \u2014 High-intensity community templates with evasion (CVEs, exposure, takeovers)..."
        hud_event "*" "Starting Nuclei with stealth configuration on $(wc -l < \"${cdir}/live_urls.txt\" 2>/dev/null || echo \"?\") targets..."
        CURRENT_TOOL="nuclei"
        job_limiter
        # Ensure nuclei templates are updated and template path provided
        # Only run if input list exists and is non-empty
        # Ensure websites folder & live_urls file exist to avoid "No such file" errors
        mkdir -p "${TARGET_DIR}/websites/" 2>/dev/null || true
        touch "${TARGET_DIR}/websites/live_urls.txt" 2>/dev/null || true
        # Ensure the local LIVE_URLS dir exists in this shell before invoking Nuclei
    # Ensure the input list is populated from the Surface/Crawl results
    local live_urls_file="${cdir}/live_urls.txt"
    if [[ ! -s "${live_urls_file}" ]]; then
        log WARN "VULNS: live_urls.txt missing; falling back to SURFACE_results.txt"
        cp "${TARGET_DIR}/SURFACE_results.txt" "${live_urls_file}" 2>/dev/null || true
    fi

    if [[ -s "${live_urls_file}" ]]; then
        log INFO "VULNS: Seeding from $(wc -l < \"${live_urls_file}\" 2>/dev/null || echo \"0\") SURFACE-validated targets."
        run_live "nuclei -t /root/nuclei-templates/ -l '${live_urls_file}' -H 'User-Agent: ${ua}' -t cves/ -t exposed-panels/ -t takeovers/ -t vulnerabilities/ -as -bulk-size 150 -c 50 -rl 300 -timeout 15 -o '${vuln_dir}/nuclei_results.json'" "${raw}/nuclei.log" "NUCLEI" &
        register_batch_pid $!
    else
        log WARN "Nuclei skipped: No targets found in ${live_urls_file} or SURFACE_results.txt"
    fi
        rate_limit
    fi

    # 2. DALFOX (XSS Engine) - ENHANCED with evasion
    if tool_exists dalfox; then
        log INFO "Dalfox \u2014 Targeted polyglot XSS payloads with WAF evasion..."
        CURRENT_TOOL="dalfox"
        job_limiter
        if [[ -s "${cdir}/parameterized_urls.txt" ]]; then
            run_live "dalfox file '${cdir}/parameterized_urls.txt' --silence -w 50 -H 'User-Agent: ${ua}' --output '${vuln_dir}/dalfox_xss.txt'" "${raw}/dalfox.log" "DALFOX" &
            register_batch_pid $!
        else
            log WARN "Dalfox skipped: ${cdir}/parameterized_urls.txt is missing or empty"
        fi
        rate_limit
    fi

    # 3. GHAURI (SQLi Engine)
    if tool_exists ghauri; then
        log INFO "Ghauri \u2014 SQLi detection with User-Agent rotation..."
        if [[ -s "${cdir}/parameterized_urls.txt" ]]; then
            mkdir -p "${vuln_dir}" 2>/dev/null || true
            run_live "ghauri -m '${cdir}/parameterized_urls.txt' --batch --random-agent -H 'User-Agent: ${ua}' -o '${vuln_dir}/ghauri_results.txt'" "${raw}/ghauri.log" "GHAURI" &
            register_batch_pid $!
        else
            log WARN "Ghauri skipped: ${cdir}/parameterized_urls.txt is missing or empty"
        fi
        rate_limit
    fi

    # 4. FFUF (Fuzzing / Directory Discovery) - ENHANCED with evasion
    if tool_exists ffuf; then
        log INFO "ffuf \u2014 directory discovery on live hosts with evasion..."
        CURRENT_TOOL="ffuf"
        local wordlist="/usr/share/seclists/Discovery/Web-Content/common.txt"
        [[ ! -f "$wordlist" ]] && wordlist="/opt/seclists/Discovery/Web-Content/common.txt"
        if [[ -f "$wordlist" && -s "${cdir}/live_urls.txt" ]]; then
            job_limiter
            run_live "head -n 20 '${cdir}/live_urls.txt' | xargs -P 5 -I {} bash -c 'ffuf -H \"User-Agent: ${ua}\" -u '\''{}'/FUZZ'\'' -w \"${wordlist}\" -mc 200,301,403 -t 50 -o \"${vuln_dir}\"/ffuf_{}$(date +%s).json ; rate_limit'" "${raw}/ffuf.log" "FFUF" &
            register_batch_pid $!
            rate_limit
        else
            log WARN "FFUF skipped: wordlist or live_urls.txt missing/empty"
        fi
    fi

    # 5. SUBJACK (Subdomain Takeover)
    if tool_exists subjack; then
        log INFO "subjack \u2014 checking for unclaimed services with evasion..."
        CURRENT_TOOL="subjack"
        # §PERF: Use pre-cached fingerprints if available (set by initialize_pipeline)
        local fp_file="${SUBJACK_FP_CACHE:-${BASE_DIR}/tmp/fingerprints.json}"
        if [[ ! -s "$fp_file" ]]; then
            wget -q --timeout=15 https://raw.githubusercontent.com/haccer/subjack/master/fingerprints.json \
                -O "/tmp/fingerprints_$$" 2>/dev/null || true
            fp_file="/tmp/fingerprints_$$"
        fi
        job_limiter
        if [[ -s "${cdir}/all_subdomains.txt" ]]; then
            run_live "subjack -w '${cdir}/all_subdomains.txt' -t 100 -timeout 30 -o '${vuln_dir}/takeovers.txt' -ssl -c '${fp_file}'" "${raw}/subjack.log" "SUBJACK" &
            register_batch_pid $!
        else
            log WARN "Subjack skipped: ${cdir}/all_subdomains.txt missing or empty"
        fi
        rate_limit
    fi

    monitor_jobs "VULNS"
    
    # Count vulnerabilities from JSON output if available, fallback to txt
    local nuclei_count=0
    if [[ -f "${vuln_dir}/nuclei_results.json" ]]; then
        nuclei_count=$(grep -c '"template_id"' "${vuln_dir}/nuclei_results.json" 2>/dev/null || echo 0)
    else
        nuclei_count=$(wc -l < "${vuln_dir}/nuclei_results.txt" 2>/dev/null || echo 0)
    fi
    
    CNT_VULNS="$nuclei_count"
    CNT_XSS=$(wc -l < "${vuln_dir}/dalfox_xss.txt" 2>/dev/null || echo 0)
    local total_vulns=$((CNT_VULNS + CNT_XSS))
    
    hb_log "VULNS" "Vuln Audit Complete: ${BCR}${total_vulns} vulnerabilities${RST} confirmed. (Templates: ${CNT_VULNS}, XSS: ${CNT_XSS})"
    [[ $total_vulns -gt 0 ]] && tg_phase_summary "VULNS" "$TARGET" "$total_vulns" "$(($(date +%s) - PHASE_START_TIME))"
    
    # Backup results
    cp "${vuln_dir}/nuclei_results.json" "${TARGET_DIR}/VULNS_results.json" 2>/dev/null || cp "${vuln_dir}/nuclei_results.txt" "${TARGET_DIR}/VULNS_results.txt" 2>/dev/null
    phase_complete "VULNS"
}
