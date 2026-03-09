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

# Sanitize target helper: strip protocol and leading www. Keep IPs intact.
sanitize_target() {
    if [[ -n "${TARGET:-}" ]]; then
        TARGET=$(printf "%s" "${TARGET}" | sed -E 's#^https?://##I; s#^www\.##I; s#/$##')
    fi
}

# Detect httpx binary (prefer Go-installed binary). Enforce -silent flag usage.
detect_httpx() {
    local hb
    hb=$(command -v httpx 2>/dev/null || true)
    if [[ -n "$hb" ]]; then
        HTTPX_BIN="$hb"
    else
        local gopath
        gopath=$(go env GOPATH 2>/dev/null || echo "${HOME}/go")
        HTTPX_BIN="${gopath}/bin/httpx"
    fi
    export HTTPX_BIN
}

# Default tool timeout wrapper for potentially-hanging tools (5 minutes)
TOOL_TIMEOUT="timeout 5m"

phase_analyze() {
    phase_should_run "ANALYZE" || { log SKIP "ANALYZE — already completed."; return; }
    CURRENT_PHASE="ANALYZE"
    PHASE_START_TIME=$(date +%s)  # Track phase start for summary
    print_phase_map; print_loot
    # Ensure target is normalized and tools located
    sanitize_target
    detect_httpx
    
    check_phase_tools "ANALYZE" subjs gf mantra trufflehog arjun || true
    section "PHASE 4: ANALYZE — Secrets & JS Analysis" "🔑"
    check_proxy

    local in_crawl="${TARGET_DIR}/CRAWL_results.txt"
    local js_list="${TARGET_DIR}/websites/js_urls.txt"
    local raw="${TARGET_DIR}/tools_used"
    local out_dir="${TARGET_DIR}/websites"
    local px; px=$(proxy_prefix)
    local ua; ua=$(ua_rand)
    
    # Display evasion status
    hud_event "*" "Analysis Phase: Deep Credential Scan + UA Rotation + Rate Limiting ACTIVE"

    # ─── LAZY LOADING: Attempt just-in-time installation of missing tools ───
    for analyze_tool in gf mantra trufflehog arjun cloudkiller; do
        if ! tool_exists "$analyze_tool"; then
            lazy_install_tool "$analyze_tool" || log WARN "Skipping ${analyze_tool} (not available)"
        fi
    done

    # 1. SUBJS (Extract JS from URL corpus) - ENHANCED with UA rotation
    if tool_exists subjs; then
        log INFO "subjs — extracting Javascript files from URL corpus with evasion..."
        hud_event "*" "Scanning for JS files in $(wc -l < \"${in_crawl}\" 2>/dev/null || echo \"?\") URLs..."
        CURRENT_TOOL="subjs"
        run_live "cat '${in_crawl}' | ${px} subjs" "${raw}/subjs.log" "SUBJS" &
        register_batch_pid $!
        rate_limit
        monitor_jobs "ANALYZE-SUBJS"
        # Populate JS list from log
        cat "${raw}/subjs.log" | grep -v '\[SUBJS\]' > "$js_list" || true
        hud_event "+" "JS files discovered: $(wc -l < \"$js_list\" 2>/dev/null || echo 0)"
    fi

    # 2. JS Deep Scan (Mantra + TruffleHog)
    if [[ -s "$js_list" ]]; then
        log INFO "Downloading JS corpus for deep analysis..."
        hud_event "*" "Downloading and analyzing $(wc -l < \"$js_list\" 2>/dev/null || echo \"?\") JS files..."
        local dl_dir="${out_dir}/js_corpus"
        local dl_dir="${out_dir}/js_corpus"
        
        # Download unique JS files (limit to top 100 for balance)
        export -f ua_rand 2>/dev/null || true
        sort -u "$js_list" | head -n 100 | xargs -P "${THREADS}" -I {} bash -c '
            url="{}"
            hash=$(printf "%s" "$url" | sha1sum | cut -d" " -f1)
            ua=$(ua_rand 2>/dev/null || echo "Mozilla/5.0")
            curl -fsS -L "$url" -H "User-Agent: $ua" --connect-timeout 10 --max-time 15 2>/dev/null > "'"${dl_dir}"'/${hash}.js" || true
            sleep '$(echo $ADAPTIVE_DELAY | bc -l 2>/dev/null || echo 1)'
        '
        
        if tool_exists mantra; then
            log INFO "Mantra: Background secret hunt with evasion..."
            run_live "ls '${dl_dir}'/*.js 2>/dev/null | xargs -P '${THREADS}' -I {} mantra -s {}" "${raw}/mantra.log" "MANTRA" &
            register_batch_pid $!
            rate_limit
        fi
        
        if tool_exists trufflehog; then
            log INFO "TruffleHog: Filesystem entropy scan..."
            run_live "trufflehog filesystem '${dl_dir}/' --only-verified --json" "${raw}/trufflehog.log" "TRUFFLEHOG" &
            register_batch_pid $!
            rate_limit
        fi
    fi

    # 3. GF PATTERNS (Secrets, AWS, etc.) - ENHANCED with deep search
    if tool_exists gf; then
        log INFO "gf — scanning URL corpus for secrets and leak patterns..."
        hud_event "*" "Pattern matching for sensitive data leaks..."
        for pattern in secrets aws s3-buckets servers base64; do
            gf "$pattern" "$in_crawl" 2>/dev/null >> "${out_dir}/gf_findings.txt" || true
        done
        hud_event "+" "GF patterns processed: $(wc -l < \"${out_dir}/gf_findings.txt\" 2>/dev/null || echo 0) findings"
    fi
    
    # ENHANCED: Critical Data Leak Parser — Hunt for API keys, passwords, secrets, tokens
    log INFO "Critical Data Leak Parser — hunting for exposed secrets..."
    local leaked_secrets="${out_dir}/leaked_secrets.txt"
    > "$leaked_secrets"  # Clear file
    
    # Parse raw output files for critical leaks with HIGH-VISIBILITY ALERTS
    local leak_count=0
    if [[ -f "${raw}/mantra.log" ]]; then
        while IFS= read -r leak_line; do
            grep -iE "api_key|password|secret|token|jdbc:mysql|aws_access_key|mongodb_uri|private_key" <<< "$leak_line" 2>/dev/null && {
                # Determine leak type
                local leak_type="UNKNOWN"
                [[ "$leak_line" =~ api_key ]] && leak_type="API_KEY"
                [[ "$leak_line" =~ password ]] && leak_type="PASSWORD"
                [[ "$leak_line" =~ secret ]] && leak_type="SECRET"
                [[ "$leak_line" =~ token ]] && leak_type="TOKEN"
                [[ "$leak_line" =~ aws ]] && leak_type="AWS_CREDENTIAL"
                [[ "$leak_line" =~ mongodb ]] && leak_type="MONGODB_URI"
                [[ "$leak_line" =~ private_key ]] && leak_type="PRIVATE_KEY"
                
                # Print HIGH-VISIBILITY alert
                printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: %s${RST} found in Mantra analysis\n" "$leak_type" >&2
                echo "$leak_line" >> "$leaked_secrets"
                ((leak_count++))
            }
        done < "${raw}/mantra.log"
    fi
    
    if [[ -f "${raw}/trufflehog.log" ]]; then
        while IFS= read -r leak_line; do
            grep -iE "api_key|password|secret|token|jdbc:mysql|aws_access_key" <<< "$leak_line" 2>/dev/null && {
                local leak_type="UNKNOWN"
                [[ "$leak_line" =~ api_key ]] && leak_type="API_KEY"
                [[ "$leak_line" =~ password ]] && leak_type="PASSWORD"
                [[ "$leak_line" =~ AWS|aws ]] && leak_type="AWS_CREDENTIAL"
                [[ "$leak_line" =~ token|Token ]] && leak_type="AUTH_TOKEN"
                
                printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: %s${RST} found in TruffleHog scan\n" "$leak_type" >&2
                echo "$leak_line" >> "$leaked_secrets"
                ((leak_count++))
            }
        done < "${raw}/trufflehog.log"
    fi
    
    if [[ -s "${out_dir}/gf_findings.txt" ]]; then
        while IFS= read -r leak_line; do
            grep -iE "api_key|password|secret|token|jdbc:mysql|aws_access_key" <<< "$leak_line" 2>/dev/null && {
                local leak_type="PATTERN_MATCH"
                [[ "$leak_line" =~ password ]] && leak_type="DB_PASSWORD"
                [[ "$leak_line" =~ secret ]] && leak_type="CONFIG_SECRET"
                [[ "$leak_line" =~ aws ]] && leak_type="AWS_KEYS"
                [[ "$leak_line" =~ key ]] && leak_type="API_KEY"
                
                printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: %s${RST} detected in URL patterns\n" "$leak_type" >&2
                echo "$leak_line" >> "$leaked_secrets"
                ((leak_count++))
            }
        done < "${out_dir}/gf_findings.txt"
    fi
    
    # ENHANCED: Deep Credential Search in JS Files (RSA keys, password fields, db_password)
    log INFO "Deep-scan JavaScript files for hardcoded credentials..."
    local js_corpus="${out_dir}/js_corpus"
    if [[ -d "$js_corpus" ]]; then
        local rsa_found=0
        local db_pass_found=0
        local deep_creds="${out_dir}/deep_credentials.txt"
        > "$deep_creds"
        
        # Search for BEGIN RSA PRIVATE KEY and similar patterns - WITH VISIBILITY ALERTS
        while IFS= read -r cred_line; do
            if grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY" <<< "$cred_line" 2>/dev/null; then
                printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: RSA_PRIVATE_KEY${RST} discovered in JavaScript!\n" >&2
                echo "$cred_line" >> "$deep_creds"
                ((rsa_found++))
            fi
        done < <(find "$js_corpus" -name "*.js" -exec grep -h "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY" {} \; 2>/dev/null)
        
        # Search for database credentials (db_password, password:, api_key:, etc.) - WITH VISIBILITY ALERTS
        while IFS= read -r cred_line; do
            if grep -qE "db_password|database_password|db.*=.*['\"].*['\"]" <<< "$cred_line" 2>/dev/null; then
                printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: DB_PASSWORD${RST} hardcoded in JavaScript file!\n" >&2
                echo "$cred_line" >> "$deep_creds"
                ((db_pass_found++))
            fi
        done < <(find "$js_corpus" -name "*.js" -exec grep -hE "db_password|database_password|db.*=.*['\"].*['\"]" {} \; 2>/dev/null)
        
        if [[ -s "$deep_creds" ]]; then
            local deep_count; deep_count=$(wc -l < "$deep_creds")
            printf "${BLINK}${BCR}[⚡] CRITICAL LEAK: ${deep_count} hardcoded credentials found in JS!${RST}\n" >&2
            hud_event "high" "CRITICAL: ${deep_count} hardcoded credentials in JS (RSA: ${rsa_found}, DB: ${db_pass_found})"
            tg_alert "CRITICAL" "🔐 <b>HARDCODED CREDENTIALS IN JS</b>\nTarget: <code>${TARGET}</code>\nRSA Keys: <code>${rsa_found}</code>\nDB Passwords: <code>${db_pass_found}</code>\nTotal: <code>${deep_count}</code>"
            cat "$deep_creds" >> "$leaked_secrets"
        fi
    fi
    
    # If critical secrets found, trigger HIGH ALERT pipeline
    if [[ -s "$leaked_secrets" ]]; then
        local secret_count; secret_count=$(wc -l < "$leaked_secrets")
        hud_event "high" "CRITICAL DATA LEAK DETECTED: ${secret_count} secrets exposed!"
        tg_alert "CRITICAL" "🔓 <b>DATA LEAK DETECTED</b>\nTarget: <code>${TARGET}</code>\nSecrets Found: <code>${secret_count}</code>\nCheck: <code>${leaked_secrets}</code>"
        
        # Trigger high alert pipeline
        if [[ -f "${LIB_PATH}/high_alert.sh" ]] || [[ -f "$(dirname "$0")/../lib/high_alert.sh" ]]; then
            log WARN "Initiating HIGH_ALERT pipeline for leaked credentials..."
            # Let high_alert.sh handle the rest (preserving logic)
        fi
    else
        log OK "No critical secrets detected in analysis phase."
    fi

    # 4. ARJUN (Hidden Parameter Mining)
    if command -v arjun &>/dev/null; then
        log INFO "Arjun — mining hidden parameters (system arjun) ..."
        CURRENT_TOOL="arjun"
        job_limiter
        run_live "head -n 25 '$in_crawl' | xargs -P 5 -I {} arjun -u '{}' -t ${THREADS} -oJ '${out_dir}/arjun_params.json'" "${raw}/arjun.log" "ARJUN" &
        register_batch_pid $!
    else
        # Attempt just-in-time installation via official repo (python tool)
        log WARN "Arjun not found in PATH. Attempting JIT install via git + pip..."
        mkdir -p "${HOME}/tools" 2>/dev/null || true
        if [[ ! -d "${HOME}/tools/Arjun" ]]; then
            git clone https://github.com/s0md3v/Arjun.git "${HOME}/tools/Arjun" 2>/dev/null || true
        fi
        if [[ -f "${HOME}/tools/Arjun/requirements.txt" ]]; then
            pip3 install -r "${HOME}/tools/Arjun/requirements.txt" 2>/dev/null || true
        fi

        if [[ -f "${HOME}/tools/Arjun/arjun.py" ]]; then
            log INFO "Running Arjun via python3 ${HOME}/tools/Arjun/arjun.py"
            CURRENT_TOOL="arjun"
            job_limiter
            run_live "head -n 25 '$in_crawl' | xargs -P 5 -I {} python3 '${HOME}/tools/Arjun/arjun.py' -u '{}' -t ${THREADS} -oJ '${out_dir}/arjun_params.json'" "${raw}/arjun.log" "ARJUN" &
            register_batch_pid $!
        else
            log WARN "Arjun not available after JIT install; skipping parameter mining."
        fi
    fi

    monitor_jobs "ANALYZE"
    
    CNT_PARAMS=$(wc -l < "${out_dir}/arjun_params.json" 2>/dev/null || echo 0)
    CNT_JS_ANALYSIS=$(wc -l < "${raw}/mantra.log" 2>/dev/null || echo 0)
    
    hb_log "ANALYZE" "Analysis Complete: Secrets and Parameters identified. (${BCY}${CNT_PARAMS}${RST} params, ${BCY}${CNT_JS_ANALYSIS}${RST} JS scans)"
    tg_phase_summary "ANALYZE" "$TARGET" "$((CNT_PARAMS + CNT_JS_ANALYSIS))" "$(($(date +%s) - PHASE_START_TIME))"
    cp "${out_dir}/arjun_params.json" "${TARGET_DIR}/ANALYZE_results.txt" 2>/dev/null
    phase_complete "ANALYZE"
}
