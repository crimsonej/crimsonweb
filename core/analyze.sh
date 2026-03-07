# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE 4 — ANALYZE: Analysis & Secret Hunting
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"

phase_analyze() {
    phase_should_run "ANALYZE" || { log SKIP "ANALYZE — already completed."; return; }
    CURRENT_PHASE="ANALYZE"
    print_phase_map; print_loot
    
    check_phase_tools "ANALYZE" subjs gf mantra trufflehog arjun || true
    section "PHASE 4: ANALYZE — Secrets & JS Analysis" "🔑"
    check_proxy

    local in_crawl="${TARGET_DIR}/CRAWL_results.txt"
    local js_list="${TARGET_DIR}/websites/js_urls.txt"
    local raw="${TARGET_DIR}/tools_used"
    local out_dir="${TARGET_DIR}/websites"
    mkdir -p "$out_dir" "$raw"
    local px; px=$(proxy_prefix)

    # 1. SUBJS (Extract JS from URL corpus)
    if tool_exists subjs; then
        log INFO "subjs — extracting Javascript files from URL corpus..."
        CURRENT_TOOL="subjs"
        run_live "cat '${in_crawl}' | ${px} subjs | tee -a '${js_list}'" "${raw}/subjs.log" "SUBJS" &
        register_batch_pid $!
        monitor_jobs "ANALYZE-SUBJS"
    fi

    # 2. JS Deep Scan (Mantra + TruffleHog)
    if [[ -s "$js_list" ]]; then
        log INFO "Downloading JS corpus for deep analysis..."
        local dl_dir="${out_dir}/js_corpus"
        mkdir -p "$dl_dir"
        
        # Download unique JS files (limit to top 100 for balance)
        export -f ua_rand 2>/dev/null || true
        sort -u "$js_list" | head -n 100 | xargs -P "${THREADS}" -I {} bash -c '
            url="{}"
            hash=$(printf "%s" "$url" | sha1sum | cut -d" " -f1)
            ua=$(ua_rand 2>/dev/null || echo "Mozilla/5.0")
            curl -fsS -L "$url" -H "User-Agent: $ua" --connect-timeout 10 --max-time 15 2>/dev/null > "'"${dl_dir}"'/${hash}.js" || true
        '
        
        if tool_exists mantra; then
            log INFO "Mantra: Background secret hunt..."
            run_live "ls '${dl_dir}'/*.js 2>/dev/null | xargs -P '${THREADS}' -I {} mantra -s {}" "${raw}/mantra.log" "MANTRA" &
            register_batch_pid $!
        fi
        
        if tool_exists trufflehog; then
            log INFO "TruffleHog: Filesystem entropy scan..."
            run_live "trufflehog filesystem '${dl_dir}/' --only-verified --json" "${raw}/trufflehog.log" "TRUFFLEHOG" &
            register_batch_pid $!
        fi
    fi

    # 3. GF PATTERNS (Secrets, AWS, etc.)
    if tool_exists gf; then
        log INFO "gf — scanning URL corpus for secrets and leak patterns..."
        for pattern in secrets aws s3-buckets servers base64; do
            gf "$pattern" "$in_crawl" 2>/dev/null >> "${out_dir}/gf_findings.txt" || true
        done
        log OK "GF: Patterns processed and saved."
    fi

    # 4. ARJUN (Hidden Parameter Mining)
    if tool_exists arjun; then
        log INFO "Arjun — mining hidden parameters..."
        CURRENT_TOOL="arjun"
        job_limiter
        run_live "head -n 25 '$in_crawl' | xargs -P 5 -I {} arjun -u '{}' -t ${THREADS} -oJ '${out_dir}/arjun_params.json'" "${raw}/arjun.log" "ARJUN" &
        register_batch_pid $!
    fi

    monitor_jobs "ANALYZE"
    
    CNT_PARAMS=$(wc -l < "${out_dir}/arjun_params.json" 2>/dev/null || echo 0)
    CNT_JS_ANALYSIS=$(wc -l < "${raw}/mantra.log" 2>/dev/null || echo 0)
    
    hb_log "ANALYZE" "Analysis Complete: Secrets and Parameters identified. (${BCY}${CNT_PARAMS}${RST} params, ${BCY}${CNT_JS_ANALYSIS}${RST} JS scans)"
    cp "${out_dir}/arjun_params.json" "${TARGET_DIR}/ANALYZE_results.txt" 2>/dev/null
    phase_complete "ANALYZE"
}
