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
    # Ensure target website directories and a live_urls file exist (avoid crashes when missing)
    mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" 2>/dev/null || true
    touch "${TARGET_DIR}/websites/live_urls.txt"
    # Sanity check: ensure SURFACE results exist before crawling
    if [[ ! -s "${TARGET_DIR}/SURFACE_results.txt" ]]; then
        log WARN "CRAWL: SURFACE results missing at ${TARGET_DIR}/SURFACE_results.txt"

        # Notify operator via Telegram and local prompt; ask whether to Retry Surface, Ignore & Crawl, or Abort
        tg_send "⚠️ Surface results missing for ${TARGET}. Should I [1] Retry Surface, [2] Ignore & Crawl, or [3] Abort?"

        local decision=""
        if type get_user_decision >/dev/null 2>&1; then
            decision=$(get_user_decision "Surface results missing for ${TARGET}. Retry / Skip / Abort?" 5)
        else
            # Fallback: short self-heal attempt if no decision function available
            decision="selfheal"
        fi

        case "${decision}" in
            rerun)
                log INFO "Operator requested: Retry SURFACE phase"
                # Attempt to re-run surface phase synchronously
                if type phase_surface >/dev/null 2>&1; then
                    phase_surface
                fi
                # Re-evaluate; if still missing, fall through to self-heal attempt
                ;;
            abort)
                log FATAL "Operator requested abort due to missing SURFACE results."
                ;;
            skip)
                log WARN "Operator requested: Skip CRAWL and proceed to ANALYZE"
                return 0
                ;;
            selfheal)
                log INFO "Attempting quick self-heal: running assetfinder/subfinder to bootstrap SURFACE results"
                mkdir -p "${TARGET_DIR}" 2>/dev/null || true
                touch "${TARGET_DIR}/SURFACE_results.txt"
                if command -v assetfinder >/dev/null 2>&1; then
                    assetfinder --subs-only "${TARGET}" > "${TARGET_DIR}/SURFACE_results.txt" 2>/dev/null || true
                elif command -v subfinder >/dev/null 2>&1; then
                    subfinder -silent -d "${TARGET}" -o "${TARGET_DIR}/SURFACE_results.txt" 2>/dev/null || true
                fi
                ;;
            *)
                # After retry or selfheal, if still missing, proceed but warn
                ;;
        esac

        if [[ ! -s "${TARGET_DIR}/SURFACE_results.txt" ]]; then
            log WARN "SURFACE results still missing after intervention. Proceeding with best-effort inputs or skipping CRAWL as requested."
        else
            log OK "SURFACE results available: ${TARGET_DIR}/SURFACE_results.txt"
        fi
    fi
    
    check_phase_tools "CRAWL" katana hakrawler gau waybackurls || true
    section "PHASE 3: CRAWL — URL & Endpoint Extraction" "🕷️"

    local in_surface="${TARGET_DIR}/SURFACE_results.txt"
    # If SURFACE produced no results, seed it with TARGET to avoid idle pipeline
    if [[ ! -s "${in_surface}" ]]; then
        echo "${TARGET}" > "${in_surface}"
        echo "[!] No SURFACE results; force-seeded ${in_surface} with TARGET to continue" >&2
    fi
    # Fallback if Phase 2 skipped or failed to produce results
    [[ ! -s "$in_surface" ]] && in_surface="${TARGET_DIR}/websites/live_urls.txt"
    
    local cdir="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local out_urls="${cdir}/master_urls.txt"
    local ua; ua=$(ua_rand)
    
    # Ensure the SURFACE input is correctly referenced and populate TARGETS
    local in_surface="${TARGET_DIR}/SURFACE_results.txt"
    if [[ ! -s "${in_surface}" ]]; then
        log WARN "SURFACE results missing; falling back to websites/live_urls.txt"
        in_surface="${TARGET_DIR}/websites/live_urls.txt"
    fi
    
    if [[ ! -s "${in_surface}" ]]; then
        log WARN "No validated URLs found; bootstrapping with TARGET: ${TARGET}"
        echo "${TARGET}" > "${in_surface}"
    fi

    local TARGETS
    TARGETS=$(awk 'NF' "${in_surface}" 2>/dev/null || true)
    log INFO "CRAWL: Seeding from $(wc -l < \"${in_surface}\" 2>/dev/null || echo \"0\") SURFACE-validated targets."

    # Display evasion status
    hud_event "*" "Crawl Phase: UA Rotation + Rate Limiting (${ADAPTIVE_DELAY}s delay) ACTIVE"

    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for crawl_tool in katana hakrawler gau waybackurls; do
        if ! tool_exists "$crawl_tool"; then
            lazy_install_tool "$crawl_tool" || log WARN "Skipping ${crawl_tool} (not available)"
        fi
    done

    # 1. KATANA & HAKRAWLER (Active Spidering)
    start_phase_streamer "CRAWL" "${raw}/*.txt"
    if tool_exists katana; then
        log INFO "Katana \u2014 Headless deep crawl with UA rotation (depth 6)..."
        hud_event "*" "Starting Katana crawl on $(wc -l < \"${in_surface}\" 2>/dev/null || echo \"?\") targets..."
        CURRENT_TOOL="katana"
        job_limiter
        local katana_log="${raw}/katana.log"
        rm -f "${katana_log}" 2>/dev/null || true
        eval "katana -list '${in_surface}' -hl -d 6 -jc -kf all -c '${THREADS}' -o '${raw}/katana.txt'" 2>&1 | tee >(awk '{print "[\033[1;34mKATANA\033[0m] " $0}' >> "${katana_log}") >/dev/null &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists hakrawler; then
        log INFO "hakrawler \u2014 active discovery with evasion..."
        CURRENT_TOOL="hakrawler"
        job_limiter
        local hak_log="${raw}/hakrawler.log"
        rm -f "${hak_log}" 2>/dev/null || true
        cat "${in_surface}" | hakrawler -d 3 2>&1 | tee >(awk '{print "[\033[1;34mHAKRAWLER\033[0m] " $0}' >> "${hak_log}") > "${raw}/hakrawler.txt" &
        register_batch_pid $!
        rate_limit
    fi

    # 2. GAU & WAYBACKURLS (Historical/Passive)
    if tool_exists gau; then
        log INFO "gau \u2014 Passive URL harvest with evasion..."
        hud_event "*" "Running GAU (passive discovery) on $(wc -l < \"${in_surface}\" 2>/dev/null || echo \"?\") domains..."
        job_limiter
        local gau_log="${raw}/gau.log"
        rm -f "${gau_log}" 2>/dev/null || true
        eval "gau --subs --threads '${THREADS:-50}' --timeout 30 --providers wayback,otx,commoncrawl '${TARGET}'" 2>&1 | tee >(awk '{print "[\033[1;34mGAU\033[0m] " $0}' >> "${gau_log}") > "${raw}/gau.txt" &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists waybackurls; then
        log INFO "waybackurls \u2014 pulling historical data..."
        job_limiter
        local wayback_log="${raw}/wayback.log"
        rm -f "${wayback_log}" 2>/dev/null || true
        echo "${TARGET}" | waybackurls 2>&1 | tee >(awk '{print "[\033[1;34mWAYBACK\033[0m] " $0}' >> "${wayback_log}") > "${raw}/wayback.txt" &
        register_batch_pid $!
        rate_limit
    fi
    
    # Wait for all background crawl tools to finish before consolidation
    wait
    stop_phase_streamer

    # 3. THE SIEVE: anew deduplication & classification
    log INFO "The Sieve: Merging and classifying URL corpus..."
    hud_event "*" "Consolidating crawl results with intelligent deduplication..."

    # Stream inputs directly to avoid large in-memory variables
    {
        cat "${raw}"/katana.txt "${raw}"/hakrawler.log "${raw}"/gau.log "${raw}"/wayback.log 2>/dev/null || true
    } | sort -u > "${out_urls}.tmp"

    # THE SIEVE: High-performance deduplication and classification
    hud_event "*" "[THE SIEVE] Starting merge & deduplication..."
    # Use RAM-backed workspace if available
    SIEVE_TMP="/dev/shm/crimson_sieve_${TARGET//[^a-zA-Z0-9]/_}"
    if [[ -d "/dev/shm" && $(df --output=avail -k /dev/shm | tail -n1) -gt 524288 ]]; then
        mkdir -p "${SIEVE_TMP}" 2>/dev/null || SIEVE_TMP="$(mktemp -d)"
    else
        SIEVE_TMP="$(mktemp -d)"
    fi

    # Merge raw inputs into tmp file
    cat "${raw}/katana.txt" "${raw}/hakrawler.txt" "${raw}/gau.txt" "${raw}/wayback.txt" 2>/dev/null | sed '/^$/d' > "${SIEVE_TMP}/all_urls.txt"

    # Deduplicate using anew if present, else use parallel sort fallback
    if command -v anew >/dev/null 2>&1; then
        cat "${SIEVE_TMP}/all_urls.txt" | anew "${out_urls}" >/dev/null 2>/dev/null || true
    else
        # Fallback: high-performance sort using multiple cores
        LC_ALL=C sort -u --parallel=$(nproc) "${SIEVE_TMP}/all_urls.txt" -o "${SIEVE_TMP}/sorted_urls.txt"
        mv "${SIEVE_TMP}/sorted_urls.txt" "${out_urls}" || true
    fi

    # Live count output
    local total_count; total_count=$(wc -l < "${out_urls}" 2>/dev/null || echo 0)
    echo "[THE SIEVE] Processing ${total_count} URLs..." | awk '{print "[\033[1;36mSIEVE\033[0m] " $0}'

    # Classification: use ripgrep if available for high-speed parallel matching, else egrep
    mkdir -p "${cdir}" 2>/dev/null || true
    if command -v rg >/dev/null 2>&1; then
        rg -i --no-messages "api|v1|v2|graphql" "${out_urls}" | sort -u > "${cdir}/api_endpoints.txt" || true
        rg -i --no-messages "\\.js(\?|$)|\.jsx(\?|$)" "${out_urls}" | sort -u > "${cdir}/js_urls.txt" || true
        rg -i --no-messages "password|secret|token|auth|key|credentials" "${out_urls}" | sort -u > "${cdir}/sensitive_urls.txt" || true
    else
        egrep -i "api|v1|v2|graphql" "${out_urls}" 2>/dev/null | sort -u > "${cdir}/api_endpoints.txt" || true
        egrep -i "\\.js(\?|$)|\.jsx(\?|$)" "${out_urls}" 2>/dev/null | sort -u > "${cdir}/js_urls.txt" || true
        egrep -i "password|secret|token|auth|key|credentials" "${out_urls}" 2>/dev/null | sort -u > "${cdir}/sensitive_urls.txt" || true
    fi

    # Parameterized URLs for phase 5 (use rg or grep)
    if command -v rg >/dev/null 2>&1; then
        rg "\?.*=" "${out_urls}" --no-messages | sort -u > "${cdir}/parameterized_urls.txt" || true
    else
        grep -E '\?.*=' "${out_urls}" 2>/dev/null | sort -u > "${cdir}/parameterized_urls.txt" || true
    fi

    CNT_JS=$(wc -l < "${cdir}/js_urls.txt" 2>/dev/null || echo 0)
    CNT_URLS=$(wc -l < "${out_urls}" 2>/dev/null || echo 0)
    
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
