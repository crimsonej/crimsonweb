# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE — RECON (Modularized)
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"
source "$(dirname "$LIB_PATH")/core/high_alert.sh"

phase_recon() {
    if [[ "${FORCE_RECON:-0}" -eq 1 ]]; then
        log INFO "FORCE_RECON=1 — Forcing RECON phase despite resume state."
    else
        phase_should_run "RECON" || { log SKIP "RECON — already completed (session resume)."; return; }
    fi
    CURRENT_PHASE="RECON"
    print_phase_map; print_loot
    # Check for existing results to resume/skip
    if [ -f "${TARGET_DIR}/${CURRENT_PHASE}_results.txt" ]; then
        printf "  ${BCY}[?]${RST} Existing data found for this phase. [S]kip to next phase, [R]e-scan, or [A]ppend new results? (15s timeout) "
        [[ -n "${HUD_PID:-}" ]] && kill -STOP "$HUD_PID" 2>/dev/null || true
        resume_choice=$(get_input "Existing data found for Phase ${CURRENT_PHASE}. [S]kip, [R]e-scan, or [A]ppend?" "S/R/A" 15)
        [[ -z "$resume_choice" ]] && resume_choice="A"
        echo "$resume_choice"
        [[ -n "${HUD_PID:-}" ]] && kill -CONT "$HUD_PID" 2>/dev/null || true
        case "$resume_choice" in
            [Ss]* ) log SKIP "Skipping to next phase."; phase_complete "$CURRENT_PHASE"; return ;;
            [Rr]* ) log INFO "Re-scanning phase." ;;
            [Aa]* | "" ) log INFO "Appending new results." ;;
        esac
    fi

    check_phase_tools "RECON" subfinder assetfinder amass || true
    section "PHASE 1: RECON — Subdomain Enumeration + Smart Diff Engine" "🔍"
    check_c2

    local rd="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local all="${rd}/all_subdomains.txt"
    local hist="${rd}/subdomain_history.txt"
    local ua; ua=$(ua_rand)
    
    mkdir -p "$rd" "$raw"
    touch "$all" "$hist"

    log INFO "Launching parallel reconnaissance engine (MAX_JOBS=${MAX_JOBS:-3})..."
    hud_event "+" "User-Agent Rotation: ACTIVE | Adaptive Rate Limiting: ${ADAPTIVE_DELAY}s delay"
    
    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for recon_tool in subfinder assetfinder amass; do
        if ! tool_exists "$recon_tool"; then
            lazy_install_tool "$recon_tool" || log WARN "Skipping ${recon_tool} (not available)"
        fi
    done
    
    # Launch tools in background and register PIDs
    start_phase_streamer "RECON" "${raw}/*.txt ${raw}/*.log"
    if tool_exists subfinder; then
        job_limiter
        check_c2
        eval "subfinder -d '${TARGET}' -silent -t 150 -all -recursive -o '${raw}/subfinder.txt'" 2>&1 | tee -a "${raw}/subfinder.log" &
        register_batch_pid $!
        rate_limit  # Apply adaptive delay
    fi

    if tool_exists assetfinder; then
        job_limiter
        run_live "assetfinder --subs-only '${TARGET}'" "${raw}/assetfinder.log" "ASSETFINDER" &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists amass; then
        local total_ram; total_ram=$(free -m | awk '/^Mem:/{print $2}')
        local avail_ram; avail_ram=$(free -m | awk '/^Mem:/{print $7}')
        [[ -z "$avail_ram" ]] && avail_ram=$(free -m | awk '/^Mem:/{print $4+$6}')
        
        local amass_flags="-passive -timeout 10"
        
        check_resources "amass"
        job_limiter
        mkdir -p "$raw"
        local amass_dir="/tmp/amass_session_$$"
        mkdir -p "$amass_dir"
        run_live "amass enum $amass_flags -d '${TARGET}' -dir '${amass_dir}' -o '${raw}/amass.txt'" "${raw}/amass.log" "AMASS" &
        register_batch_pid $!
        rate_limit
    fi

    if tool_exists gau; then
        job_limiter
        check_c2
        eval "gau --subs --threads ${THREADS:-50} --timeout 30 --providers wayback,commoncrawl,otx '${TARGET}'" 2>&1 | tee -a "${raw}/gau.log" &
        register_batch_pid $!
        # §FIX: Immediate High Alert Trigger
        process_high_alert_links "${raw}/gau.log" &
        register_pid $!
    fi

    if tool_exists waybackurls; then
        job_limiter
        run_live "echo '${TARGET}' | waybackurls" "${raw}/wayback.log" "WAYBACK" &
        register_batch_pid $!
        # §FIX: Immediate High Alert Trigger
        process_high_alert_links "${raw}/wayback.log" &
        register_pid $!
    fi
    
    monitor_jobs "RECON"
    stop_phase_streamer
    
    # §FIX: Sort Safety
    [[ -s "${raw}/gau.log" ]] && sort -u "${raw}/gau.log" -o "${raw}/gau.log"
    [[ -s "${raw}/wayback.log" ]] && sort -u "${raw}/wayback.log" -o "${raw}/wayback.log"
    
    log INFO "Consolidating results into Master Target List..."
    hud_event "*" "Consolidating subdomain results with intelligent deduplication..."

    # Stream inputs directly to avoid large in-memory variables
    {
        cat "${raw}/subfinder.txt" "${raw}/assetfinder.log" "${raw}/amass.txt" 2>/dev/null || true
        # Extract purely domains from gau and waybackurls to avoid dropping thousands of hostnames
        cat "${raw}/gau.log" "${raw}/wayback.log" 2>/dev/null | grep -Eo 'https?://[^/]+' | sed -e 's|^[^/]*://||' || true
    } | grep -v '*' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u > "${rd}/new_assets.txt"

    if tool_exists anew; then
        # Use anew if available for smart deduplication
        cat "${rd}/new_assets.txt" | anew "$all" > "${rd}/new_assets_added.txt" 2>/dev/null || {
            # §FIX: Safe fallback — write to tmp first to avoid self-overwrite truncation
            cat "${rd}/new_assets.txt" >> "$all"
            sort -u -o "$all" "$all"
        }
    else
        # §ENHANCED: Robust fallback without anew - ensure proper newline handling
        {
            cat "$all" 2>/dev/null || true
            cat "${rd}/new_assets.txt"
        } | sort -u > "${all}.tmp"
        mv "${all}.tmp" "$all"

        hud_event "+" "Anew tool missing, used safe fallback deduplication ($(wc -l < "$all") unique entries)"
    fi
    
    # Update History
    cat "$all" >> "$hist"
    sort -u -o "$hist" "$hist"
    
    CNT_SUBS=$(wc -l < "$all" 2>/dev/null || echo 0)
    hb_log "RECON" "Recon Complete: ${BGR}${CNT_SUBS} unique subdomains${RST} in the vault."
    hud_event "+" "Subdomains discovered: ${CNT_SUBS}"
    
    # Handshake for Phase 2
    cp "$all" "${TARGET_DIR}/RECON_results.txt"
    phase_complete "RECON"
}
