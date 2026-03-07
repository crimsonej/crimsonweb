# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE 3 — CRAWL: Deep Crawl & URL Extraction
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"
source "$(dirname "$LIB_PATH")/core/high_alert.sh"

phase_crawl() {
    phase_should_run "CRAWL" || { log SKIP "CRAWL — already completed."; return; }
    CURRENT_PHASE="CRAWL"
    print_phase_map; print_loot
    
    check_phase_tools "CRAWL" katana hakrawler gau waybackurls || true
    section "PHASE 3: CRAWL — URL & Endpoint Extraction" "🕷️"
    check_proxy

    local in_surface="${TARGET_DIR}/SURFACE_results.txt"
    # Fallback if Phase 2 skipped or failed to produce results
    [[ ! -s "$in_surface" ]] && in_surface="${TARGET_DIR}/websites/live_urls.txt"
    
    local cdir="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local out_urls="${cdir}/master_urls.txt"
    mkdir -p "$cdir" "$raw"
    local px; px=$(proxy_prefix)

    # 1. KATANA & HAKRAWLER (Active Spidering)
    if tool_exists katana; then
        log INFO "Katana — Headless deep crawl (depth 6)..."
        CURRENT_TOOL="katana"
        job_limiter
        run_live "${px} katana -list '${in_surface}' -hl -d 6 -jc -kf all -c ${THREADS} -o '${raw}/katana.txt'" "${raw}/katana.log" "KATANA" &
        register_batch_pid $!
    fi

    if tool_exists hakrawler; then
        log INFO "hakrawler — active discovery..."
        CURRENT_TOOL="hakrawler"
        job_limiter
        run_live "cat '${in_surface}' | ${px} hakrawler -d 3 | tee '${raw}/hakrawler.txt'" "${raw}/hakrawler.log" "HAKRAWLER" &
        register_batch_pid $!
    fi

    # 2. GAU & WAYBACKURLS (Historical/Passive)
    if tool_exists gau; then
        log INFO "gau — Passive URL harvest..."
        job_limiter
        run_live "${px} gau --subs --threads ${THREADS:-50} --timeout 30 --providers wayback,otx,commoncrawl '${TARGET}' | tee '${raw}/gau.txt'" "${raw}/gau.log" "GAU" &
        register_batch_pid $!
    fi

    if tool_exists waybackurls; then
        log INFO "waybackurls — pulling historical data..."
        job_limiter
        run_live "echo '${TARGET}' | ${px} waybackurls | tee '${raw}/wayback.txt'" "${raw}/wayback.log" "WAYBACK" &
        register_batch_pid $!
    fi
    
    monitor_jobs "CRAWL"

    # 3. THE SIEVE: anew deduplication & classification
    log INFO "The Sieve: Merging and classifying URL corpus..."
    cat "${raw}"/katana.txt "${raw}"/hakrawler.txt "${raw}"/gau.txt "${raw}"/wayback.txt 2>/dev/null \
        | sort -u | anew "$out_urls" > /dev/null
    
    # Extension Sort
    for ext in js php asp aspx jsp json xml; do
        grep -iE "\.${ext}(\?[^\"]*)?$" "$out_urls" 2>/dev/null | sort -u > "${cdir}/${ext}_urls.txt" || true
    done
    # Parameterized URLs for phase 5
    grep -E '\?.*=' "$out_urls" 2>/dev/null | sort -u > "${cdir}/parameterized_urls.txt" || true

    CNT_JS=$(wc -l < "${cdir}/js_urls.txt" 2>/dev/null || echo 0)
    CNT_URLS=$(wc -l < "$out_urls" 2>/dev/null || echo 0)
    
    # Trigger High Alert Pipeline
    if [[ -s "$out_urls" ]]; then
        process_high_alert_links "$out_urls" &
        register_pid $!
    fi

    hb_log "CRAWL" "Crawl Complete: ${BGR}${CNT_URLS} unique endpoints${RST} classified. (${BCY}${CNT_JS}${RST} JS files)"
    cp "$out_urls" "${TARGET_DIR}/CRAWL_results.txt"
    phase_complete "CRAWL"
}
