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
    local px; px=$(proxy_prefix)
    local ua; ua=$(ua_rand)
    
    # Display evasion status
    hud_event "*" "Crawl Phase: UA Rotation + Rate Limiting (${ADAPTIVE_DELAY}s delay) ACTIVE"

    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for crawl_tool in katana hakrawler gau waybackurls; do
        if ! tool_exists "$crawl_tool"; then
            lazy_install_tool "$crawl_tool" || log WARN "Skipping ${crawl_tool} (not available)"
        fi
    done

    # 1. KATANA & HAKRAWLER (Active Spidering)
    if tool_exists katana; then
        log INFO "Katana \u2014 Headless deep crawl with UA rotation (depth 6)..."
        hud_event "*" "Starting Katana crawl on $(wc -l < \"${in_surface}\" 2>/dev/null || echo \"?\") targets..."
        CURRENT_TOOL="katana"
        job_limiter
        run_live "${px} katana -list '${in_surface}' -hl -d 6 -jc -kf all -c ${THREADS} -o '${raw}/katana.txt'" "${raw}/katana.log" "KATANA" &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists hakrawler; then
        log INFO "hakrawler \u2014 active discovery with evasion..."
        CURRENT_TOOL="hakrawler"
        job_limiter
        run_live "cat '${in_surface}' | ${px} hakrawler -d 3" "${raw}/hakrawler.log" "HAKRAWLER" &
        register_batch_pid $!
        rate_limit
    fi

    # 2. GAU & WAYBACKURLS (Historical/Passive)
    if tool_exists gau; then
        log INFO "gau \u2014 Passive URL harvest with evasion..."
        hud_event "*" "Running GAU (passive discovery) on $(wc -l < \"${in_surface}\" 2>/dev/null || echo \"?\") domains..."
        job_limiter
        run_live "${px} gau --subs --threads ${THREADS:-50} --timeout 30 --providers wayback,otx,commoncrawl '${TARGET}'" "${raw}/gau.log" "GAU" &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists waybackurls; then
        log INFO "waybackurls \u2014 pulling historical data..."
        job_limiter
        run_live "echo '${TARGET}' | ${px} waybackurls" "${raw}/wayback.log" "WAYBACK" &
        register_batch_pid $!
        rate_limit
    fi
    
    monitor_jobs "CRAWL"

    # 3. THE SIEVE: anew deduplication & classification
    log INFO "The Sieve: Merging and classifying URL corpus..."
    hud_event "*" "Consolidating crawl results with intelligent deduplication..."

    # Stream inputs directly to avoid large in-memory variables
    {
        cat "${raw}"/katana.txt "${raw}"/hakrawler.log "${raw}"/gau.log "${raw}"/wayback.log 2>/dev/null || true
    } | sort -u > "${out_urls}.tmp"

    if tool_exists anew; then
        cat "${out_urls}.tmp" | anew "$out_urls" > /dev/null 2>/dev/null || {
            cat "${out_urls}.tmp" >> "$out_urls"
            sort -u -o "$out_urls" "$out_urls"
        }
    else
        if [[ -f "$out_urls" ]]; then
            cat "$out_urls" >> "${out_urls}.tmp"
        fi
        sort -u -o "$out_urls" "${out_urls}.tmp"
        rm -f "${out_urls}.tmp"
        hud_event "+" "Anew fallback: $(wc -l < \"$out_urls\") unique URLs consolidated"
    fi
    
    # Extension Sort
    local url_count=0
    for ext in js php asp aspx jsp json xml; do
        grep -iE "\\.${ext}([?#].*)?$" "$out_urls" 2>/dev/null | sort -u > "${cdir}/${ext}_urls.txt" || true
        local ext_count; ext_count=$(wc -l < "${cdir}/${ext}_urls.txt" 2>/dev/null || echo 0)
        [[ $ext_count -gt 0 ]] && hud_event "+" "${ext^^} files: ${ext_count}" && ((url_count += ext_count))
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

    # Account discovery: grep for login/signup/account-related endpoints
    local account_links_file="${cdir}/user_account_links.txt"
    grep -Ei "login|signup|account|profile|dashboard|register|auth|signin|user|member" "$out_urls" 2>/dev/null | sort -u > "$account_links_file" || true
    if [[ -s "$account_links_file" ]]; then
        local acct_count; acct_count=$(wc -l < "$account_links_file" 2>/dev/null || echo 0)
        hud_event "!" "Account Surface Found: ${acct_count} endpoints"
        tg_send "⚠️ <b>Account Surface Found</b>\nTarget: <code>${TARGET}</code>\nCount: <code>${acct_count}</code>\nFile: ${account_links_file}"
    fi

    hb_log "CRAWL" "Crawl Complete: ${BGR}${CNT_URLS} unique endpoints${RST} classified. (${BCY}${CNT_JS}${RST} JS files)"
    cp "$out_urls" "${TARGET_DIR}/CRAWL_results.txt"
    phase_complete "CRAWL"
}
