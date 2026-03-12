# ═══════════════════════════════════════════════════════════════════════════════
#  §PHASE 2 — SURFACE: Asset Validation & Surface Mapping
# ═══════════════════════════════════════════════════════════════════════════════

# Vault initialization is per-target; avoid creating hard-coded target vaults at source time
# Per-target directories are created during phase execution using ${TARGET_DIR}

# Ensure internal libraries are visible to the module
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_PATH/ui.sh"
source "$LIB_PATH/framework.sh"
source "$LIB_PATH/utils.sh"
source "$LIB_PATH/jobs.sh"
source "$LIB_PATH/tg_c2.sh"

# Force ProjectDiscovery httpx binary to avoid Python httpx collision
PD_HTTPX="${PD_HTTPX:-${HOME}/go/bin/httpx}"

phase_surface() {
    phase_should_run "SURFACE" || { log SKIP "SURFACE — already completed."; return; }
    CURRENT_PHASE="SURFACE"
    print_phase_map
    
    check_phase_tools "SURFACE" naabu httpx cloudkiller nmap || true
    # Ensure cloudkiller/subdomain helper file exists to avoid crashes
    [ -f subl.txt ] || touch subl.txt
    # Ensure SURFACE results file exists (avoid downstream missing file errors)
    mkdir -p "${TARGET_DIR}" 2>/dev/null || true
    touch "${TARGET_DIR}/SURFACE_results.txt"
    section "PHASE 2: SURFACE — Asset Validation & Surface Mapping" "🔌"

    local in_recon="${TARGET_DIR}/RECON_results.txt"
    local out="${TARGET_DIR}/websites"
    local raw="${TARGET_DIR}/tools_used"
    local vuln_dir="${TARGET_DIR}/vulnerabilities"
    local ua; ua=$(ua_rand)
    # Use PD_HTTPX (ProjectDiscovery binary) when available; fallback to which
    local HTTPX_BIN
    if [[ -x "${PD_HTTPX}" ]]; then
        HTTPX_BIN="${PD_HTTPX}"
    else
        HTTPX_BIN=$(which httpx 2>/dev/null || true)
        if [[ -z "$HTTPX_BIN" && -x "${HOME}/go/bin/httpx" ]]; then
            HTTPX_BIN="${HOME}/go/bin/httpx"
        fi
    fi
    # Use the globally enforced HTTPX_BIN (set in crimsonweb.sh). If not executable, warn later.
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

    # ----------------------- Tier 1: Discovery (naabu + assetfinder) -----------------------
    mkdir -p "${TARGET_DIR}" "${raw}" "${out}" 2>/dev/null || true
    local subs_file="${TARGET_DIR}/subs.txt"
    rm -f "${raw}/naabu_passive.txt" "${raw}/assetfinder_subs.txt" 2>/dev/null || true
    touch "${in_recon}" "${subs_file}"

    # Launch naabu (passive) and assetfinder in parallel
    if tool_exists naabu; then
        log INFO "naabu (passive) starting..."
        CURRENT_TOOL="naabu-passive"
        run_live "naabu -silent -passive -list '${in_recon}' -o '${raw}/naabu_passive.txt'" "${raw}/naabu_passive.log" "NAABU_PASSIVE" &
        register_batch_pid $!
    fi

    if tool_exists assetfinder; then
        log INFO "assetfinder starting..."
        CURRENT_TOOL="assetfinder"
        run_live "assetfinder --subs-only '${TARGET}'" "${raw}/assetfinder.log" "ASSETFINDER" &
        register_batch_pid $!
    fi

    # Wait for discovery tools to finish
    monitor_jobs "SURFACE_DISCO"

    # Merge discovery outputs into subs.txt (ensure uniqueness)
    cat "${raw}/assetfinder.log" "${raw}/naabu_passive.txt" "${in_recon}" 2>/dev/null | sed '/^\s*$/d' | sort -u > "${subs_file}" || true

    # Fallback: if subs.txt empty, seed with TARGET
    if [[ ! -s "${subs_file}" ]]; then
        echo "${TARGET}" > "${subs_file}"
        echo "[!] Asset discovery found nothing; force-seeded ${subs_file} with TARGET to continue" >&2
    fi

    # Expose the loot: print discovered subdomains
    echo -e "\n[\033[1;32m+\033[0m] \033[1;37mTARGETS ACQUIRED:\033[0m"
    sed -n '1,200p' "${subs_file}" | sed 's/^/  -> /' || true

    # ----------------------- Tier 2: Validation (httpx) -----------------------
    local live_file="${TARGET_DIR}/live_hosts.txt"
    rm -f "${live_file}" 2>/dev/null || true
    touch "${live_file}" "${raw}/httpx.log"
    
    # Use the globally resolved HTTPX_BIN if available, otherwise fallback
    local httpx_bin="${HTTPX_BIN:-${PD_HTTPX}}"
    [[ ! -x "$httpx_bin" ]] && httpx_bin=$(command -v httpx 2>/dev/null || true)
    
    if [[ -n "${httpx_bin}" && -x "${httpx_bin}" ]]; then
        log INFO "httpx validating subs (tech-detect active)..."
        CURRENT_TOOL="httpx-validation"
        start_phase_streamer "SURFACE" "${live_file}"
        run_live "'${httpx_bin}' -l '${subs_file}' -silent -sr -follow-redirects -tech-detect -status-code -timeout 15 -rl 30 -H 'User-Agent: ${ua}' -o '${live_file}'" "${raw}/httpx.log" "HTTPX_VALID" &
        register_batch_pid $!
    else
        log WARN "httpx not available; treating subs as live hosts"
        cp "${subs_file}" "${live_file}" 2>/dev/null || true
    fi

    monitor_jobs "SURFACE_VAL"
    stop_phase_streamer

    # Expose the live hosts

    echo -e "\n[\033[1;32m+\033[0m] \033[1;37mLIVE HOSTS IDENTIFIED:\033[0m"
    sed -n '1,200p' "${live_file}" | sed 's/^/  -> /' || true

    # Persist validated live URLs into the target's websites directory
    cp "${live_file}" "${out}/live_urls.txt" 2>/dev/null || echo "${TARGET}" > "${out}/live_urls.txt"

    # ----------------------- Tier 3: Cloud Hunt (cloudkiller) -----------------------
    local ck_out="${TARGET_DIR}/websites/cloud_results.txt"
    local ck_log="${raw}/cloudkiller.log"
    rm -f "${ck_out}" "${ck_log}" 2>/dev/null || true
    touch "${ck_out}" "${ck_log}"
    if tool_exists cloudkiller; then
        log INFO "Launching Parallel Cloud Hunt (Timeout: 20s)..."
        if [[ -s "${live_file}" ]]; then
            CURRENT_TOOL="cloudkiller"
            while IFS= read -r host; do
                [[ -f "/tmp/crimson_skip" ]] && { log WARN "Skip signal detected. Terminating Cloud Hunt."; break; }
                [[ -z "${host}" ]] && continue
                job_limiter
                # Force non-interactive mode and sanitize banners
                yes "" | timeout 20s python3 -W ignore "/root/go/bin/cloudkiller" <<< "${host}" 2>>"${ck_log}" | grep -vE '_____|From FD|Enter Target' >> "${TARGET_DIR}/websites/cloud_results.txt" &
                register_batch_pid $!
            done < "${live_file}"
            monitor_jobs "SURFACE_CLOUD"
        else
            # fallback: run once against TARGET
            yes "" | timeout 20s python3 -W ignore "/root/go/bin/cloudkiller" <<< "${TARGET}" 2>>"${ck_log}" | grep -vE '_____|From FD|Enter Target' >> "${TARGET_DIR}/websites/cloud_results.txt"
        fi
    else
        echo "[!] cloudkiller not available; skipping cloud hunt" >> "${ck_log}"
    fi

    # Expose cloud results
    echo -e "\n[\033[1;32m+\033[0m] \033[1;37mCLOUD FINDINGS:\033[0m"
    sed -n '1,200p' "${ck_out}" | sed 's/^/  -> /' || true

    # Normalize naabu output into a simple open_ports list for downstream consumption
    if [[ -s "${out}/naabu_active_raw.txt" ]]; then
        awk -F':' '{print $1":"$2}' "${out}/naabu_active_raw.txt" 2>/dev/null | sort -u > "${out}/open_ports_raw.txt" || true
        awk -F':' '{print $1}' "${out}/open_ports_raw.txt" 2>/dev/null | sort -u > "${out}/open_ports.txt" || true
    fi
    
    # Consolidation (use raw logs as source)
    hud_event "*" "Consolidating SURFACE results..."
    # If live_file exists and is non-empty, use it for live_urls.txt
    if [[ -s "${live_file}" ]]; then
        cat "${live_file}" | sort -u > "${out}/live_urls.txt"
    else
        # Fallback to the TARGET if everything else failed
        echo "${TARGET}" > "${out}/live_urls.txt"
    fi
    sed 's|https\?://||; s|/.*||' "${out}/live_urls.txt" 2>/dev/null | sort -u > "${out}/live_domains.txt"

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
        log INFO "Tier 3: Launching batched Nmap fingerprinting per host"
        CURRENT_TOOL="nmap"
        declare -A HOST_PORTS=()
        
        while IFS=":" read -r host port; do
            [[ -z "$host" || -z "$port" ]] && continue
            HOST_PORTS["$host"]+="${port},"
        done < "${out}/open_ports_raw.txt"

        for host in "${!HOST_PORTS[@]}"; do
            [[ -f "/tmp/crimson_skip" ]] && { log WARN "Skip signal detected. Terminating Nmap scan."; break; }
            local ports="${HOST_PORTS[$host]%,}"
            [[ -z "$ports" ]] && continue
            job_limiter
            local safe_host; safe_host=${host//\//_}
            local out_file="${raw}/nmap_${safe_host}.txt"
            
            # Use connect scan (-sT) as requested for speed/compat
            local nmap_cmd="nmap -sT -sV -sC --version-intensity 3 -p ${ports} --open ${host} -oN '${out_file}'"
            if sudo -n true 2>/dev/null; then
                nmap_cmd="sudo ${nmap_cmd}"
            fi
            
            # Execute in background and stream logs
            eval "$nmap_cmd" 2>&1 | tee >(awk '{print "[\033[1;34mNMAP\033[0m] " $0}' >> "${raw}/nmap_${safe_host}.log") >/dev/null &
            register_batch_pid $!
        done
        monitor_jobs "SURFACE_NMAP"
        unset HOST_PORTS
    fi
    stop_phase_streamer
    phase_complete "SURFACE"
}
