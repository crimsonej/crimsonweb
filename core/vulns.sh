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
    phase_should_run "VULN" || { log SKIP "VULN — already completed."; return; }
    CURRENT_PHASE="VULN"
    print_phase_map; print_loot
    
    check_phase_tools "VULNS" nuclei dalfox ghauri ffuf subjack || true
    section "PHASE 5: VULNS — Active Vulnerability Probing" "☢️"
    check_proxy

    local cdir="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local vuln_dir="${TARGET_DIR}/vulnerabilities"
    mkdir -p "$vuln_dir" "$raw"
    local px; px=$(proxy_prefix)
    local pf; pf=$(proxy_flag)

    # 1. NUCLEI (Template Attack)
    if tool_exists nuclei; then
        log INFO "Nuclei — High-intensity community templates..."
        CURRENT_TOOL="nuclei"
        job_limiter
        run_live "${px} nuclei -l '${cdir}/live_urls.txt' -as -bulk-size 150 -c 50 -rl 300 -timeout 15 -o '${vuln_dir}/nuclei_results.txt' ${pf:+-proxy '${pf}'}" "${raw}/nuclei.log" "NUCLEI" &
        register_batch_pid $!
    fi

    # 2. DALFOX (XSS Engine)
    if tool_exists dalfox; then
        log INFO "Dalfox — Targeted polyglot XSS payloads..."
        CURRENT_TOOL="dalfox"
        job_limiter
        run_live "${px} dalfox file '${cdir}/parameterized_urls.txt' --silence -w 50 --output '${vuln_dir}/dalfox_xss.txt' ${pf:+-p '${pf}'}" "${raw}/dalfox.log" "DALFOX" &
        register_batch_pid $!
    fi

    # 3. GHAURI (SQLi Engine)
    if tool_exists ghauri; then
        run_live "${px} ghauri -m '${cdir}/parameterized_urls.txt' --batch --random-agent --out '${vuln_dir}/ghauri_results.txt' ${pf:+--proxy '${pf}'}" "${raw}/ghauri.log" "GHAURI" &
        register_batch_pid $!
    fi

    # 4. FFUF (Fuzzing / Directory Discovery)
    if tool_exists ffuf; then
        log INFO "ffuf — directory discovery on live hosts..."
        CURRENT_TOOL="ffuf"
        local wordlist="/usr/share/seclists/Discovery/Web-Content/common.txt"
        [[ ! -f "$wordlist" ]] && wordlist="/opt/seclists/Discovery/Web-Content/common.txt"
        if [[ -f "$wordlist" ]]; then
            job_limiter
            run_live "head -n 20 '${cdir}/live_urls.txt' | xargs -I {} ${px} ffuf -u '{}/FUZZ' -w '${wordlist}' -mc 200,301,403 -t 50 -o '${vuln_dir}/ffuf_results.json'" "${raw}/ffuf.log" "FFUF" &
            register_batch_pid $!
        fi
    fi

    # 5. SUBJACK (Subdomain Takeover)
    if tool_exists subjack; then
        log INFO "subjack — checking for unclaimed services..."
        CURRENT_TOOL="subjack"
        # Fetch latest fingerprints
        wget -q https://raw.githubusercontent.com/haccer/subjack/master/fingerprints.json -O /tmp/fingerprints_$$ 2>/dev/null
        job_limiter
        run_live "${px} subjack -w '${cdir}/all_subdomains.txt' -t 100 -timeout 30 -o '${vuln_dir}/takeovers.txt' -ssl -c '/tmp/fingerprints_$$'" "${raw}/subjack.log" "SUBJACK" &
        register_batch_pid $!
    fi

    monitor_jobs "VULNS"
    
    CNT_VULNS=$(wc -l < "${vuln_dir}/nuclei_results.txt" 2>/dev/null || echo 0)
    CNT_XSS=$(wc -l < "${vuln_dir}/dalfox_xss.txt" 2>/dev/null || echo 0)
    local total_vulns=$((CNT_VULNS + CNT_XSS))
    
    hb_log "VULNS" "Vuln Audit Complete: ${BCR}${total_vulns} vulnerabilities${RST} confirmed. (Templates: ${CNT_VULNS}, XSS: ${CNT_XSS})"
    [[ $total_vulns -gt 0 ]] && tg_send "🧨 <b>VULNERABILITIES FOUND</b> 🧨\nTarget: <code>${TARGET}</code>\nTotal: <code>${total_vulns}</code>\nCheck <code>${vuln_dir}</code>"
    
    cp "${vuln_dir}/nuclei_results.txt" "${TARGET_DIR}/VULNS_results.txt" 2>/dev/null
    phase_complete "VULNS"
}
