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
    mkdir -p "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used" "${TARGET_DIR}/vulnerabilities" "${TARGET_DIR}/filtered"
    if [[ ! -d "$TARGET_DIR" ]]; then
        log FATAL "Vault setup failed. Directory not found: ${WH}${TARGET_DIR}${RST}"
        exit 1
    fi

    phase_should_run "RECON" || { log SKIP "RECON — already completed (session resume)."; return; }
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
    check_c2; check_proxy

    local rd="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local all="${rd}/all_subdomains.txt"
    local hist="${rd}/subdomain_history.txt"
    local ua; ua=$(ua_rand)
    local px; px=$(proxy_prefix)
    
    mkdir -p "$rd" "$raw"
    touch "$all" "$hist"

    log INFO "Launching parallel reconnaissance engine (MAX_JOBS=${MAX_JOBS:-3})..."
    
    # Launch tools in background and register PIDs
    if tool_exists subfinder; then
        job_limiter
        check_c2
        run_live "${px} subfinder -d '${TARGET}' -silent -t 150 -all -recursive -o '${raw}/subfinder.txt'" "${raw}/subfinder.log" "SUBFINDER" &
        register_batch_pid $!
    fi

    if tool_exists assetfinder; then
        job_limiter
        run_live "${px} assetfinder --subs-only '${TARGET}' | tee '${raw}/assetfinder.txt'" "${raw}/assetfinder.log" "ASSETFINDER" &
        register_batch_pid $!
    fi

    if tool_exists amass; then
        check_resources "amass"
        job_limiter
        mkdir -p "$raw"
        local amass_dir="/tmp/amass_session_$$"
        mkdir -p "$amass_dir"
        run_live "${px} amass enum -passive -d '${TARGET}' -timeout 30 -dir '${amass_dir}' -o '${raw}/amass.txt'" "${raw}/amass.log" "AMASS" &
        register_batch_pid $!
    fi

    if tool_exists gau; then
        job_limiter
        check_c2
        run_live "${px} gau --subs --threads ${THREADS:-50} --timeout 30 --providers wayback,commoncrawl,otx '${TARGET}' | tee '${raw}/gau.txt'" "${raw}/gau.log" "GAU" &
        register_batch_pid $!
        # §FIX: Immediate High Alert Trigger
        process_high_alert_links "${raw}/gau.txt" &
        register_pid $!
    fi

    if tool_exists waybackurls; then
        job_limiter
        run_live "echo '${TARGET}' | ${px} waybackurls | tee '${raw}/wayback.txt'" "${raw}/wayback.log" "WAYBACK" &
        register_batch_pid $!
        # §FIX: Immediate High Alert Trigger
        process_high_alert_links "${raw}/wayback.txt" &
        register_pid $!
    fi
    
    monitor_jobs "RECON"
    
    log INFO "Consolidating results into Master Target List..."
    cat "${raw}/subfinder.txt" "${raw}/assetfinder.txt" "${raw}/amass.txt" 2>/dev/null \
        | grep -v '*' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sort -u | anew "$all" > "${rd}/new_assets.txt"
    
    # Update History
    cat "$all" >> "$hist"
    sort -u -o "$hist" "$hist"
    
    CNT_SUBS=$(wc -l < "$all" 2>/dev/null || echo 0)
    hb_log "RECON" "Recon Complete: ${BGR}${CNT_SUBS} unique subdomains${RST} in the vault."
    
    # Handshake for Phase 2
    cp "$all" "${TARGET_DIR}/RECON_results.txt"
    phase_complete "RECON"
}
