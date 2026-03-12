#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §DEEP HUNT: HIGH ALERT SENSITIVE DATA PIPELINE (Modularized)
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure libraries are sourced for proxy_prefix, ua_rand, etc.
source "$(dirname "$0")/../lib/utils.sh" 2>/dev/null || true

# Locate HTTPX binary if not already set
if [[ -z "${HTTPX_BIN:-}" ]]; then
    export HTTPX_BIN=$(command -v httpx 2>/dev/null || echo "")
fi

process_high_alert_links() {
    local input_file="$1"
    local alert_dir="${TARGET_DIR}/HIGH_ALERTS"
    local history_file="${alert_dir}/processed_history.log"
    local hits_file="${alert_dir}/secrets_found.txt"
    local temp_urls="${TARGET_DIR}/tools_used/high_alert_temp.txt"
    local temp_filtered="${TARGET_DIR}/tools_used/high_alert_filtered.txt"
    
    # Guard against unset variables when running under set -u
    [[ -z "${TARGET_DIR:-}" ]] && return
    [[ -z "${HIGH_INTEREST_KEYWORDS:-}" ]] && return

    mkdir -p "$alert_dir"
    touch "$history_file" "$hits_file"

    # §FIX: Early return if input is missing or empty
    [[ ! -s "$input_file" ]] && return

    # Verify HTTPX is available before proceeding
    if [[ -z "${HTTPX_BIN:-}" || ! -x "${HTTPX_BIN}" ]]; then
        log ERR "HTTPX not found in PATH. High Alert Pipeline aborted."
        return 1
    fi

    log INFO "High Alert Pipeline: Scanning for sensitive endpoints..."

    # 1. Deduplicate against history
    comm -23 <(sort -u "$input_file") <(sort -u "$history_file") > "$temp_urls"
    cat "$temp_urls" >> "$history_file"

    # 2. Filter for HIGH_INTEREST_KEYWORDS
    grep -iE "($HIGH_INTEREST_KEYWORDS)" "$temp_urls" > "$temp_filtered" || true
    
    local match_count; match_count=$(wc -l < "$temp_filtered" 2>/dev/null || echo 0)
    [[ "$match_count" -eq 0 ]] && return
    
    log WARN "High Alert Pipeline: Found ${match_count} suspicious URLs. Probing..."

    if tool_exists httpx && tool_exists nuclei; then
        local px; px=$(proxy_prefix 2>/dev/null || echo "")
        local pf; pf=$(proxy_flag 2>/dev/null || echo "")
        local ua; ua=$(ua_rand)
        local nuclei_out="${alert_dir}/.temp_nuclei_alerts.txt"
        
        spin_start "Scanning ${match_count} targets for active secrets..."
        mkdir -p "$alert_dir"

        # §FIX: Normalize all URLs to absolute before httpx processing
        local httpx_raw="${alert_dir}/httpx_high_alert.log"
        local urls_with_protocol="${alert_dir}/.temp_urls_with_protocol.txt"
        sed -E 's|^([^/])|http://\1|; s|^http://http|http|; s|^http://https|https|' "$temp_filtered" > "$urls_with_protocol"

        # Preferred high-alert httpx flags: -silent -sc -title -cl -ct -location -fc 403
        run_live "cat '$urls_with_protocol' | xargs -I {} ${px} ${HTTPX_BIN} -header \"User-Agent: ${ua}\" -silent -sc -title -cl -ct -location -fc 403 -rl 30 -t 10 {}" "$httpx_raw" "HIGH-ALERT-HTTPX"
        grep -v "\[HIGH-ALERT-HTTPX\]" "$httpx_raw" | awk 'NF>1 {print $1}' > "${alert_dir}/.temp_targets.txt" || true
        
        if [[ -s "${alert_dir}/.temp_targets.txt" ]]; then
            # §FIX: Removed trailing slashes from Nuclei -t paths
            run_live "${px} nuclei -ut -t /root/nuclei-templates/ -l '${alert_dir}/.temp_targets.txt' -t exposures -t tokens -silent -o '${nuclei_out}' ${pf:+-proxy '${pf}'}" "${alert_dir}/nuclei_high_alert.log" "HIGH-ALERT-NUCLEI"
        fi
        spin_stop
        
        if [[ -s "$nuclei_out" ]]; then
            cat "$nuclei_out" >> "$hits_file"
            while IFS= read -r line; do
                printf "\n\033[5;31m  [☢️  HIGH ALERT ☢️ ] \033[0m\n"
                printf "  ${BYL}Secret Discovered:${RST} ${line}\n"
                tg_send "🚨 <b>HIGH PRIORITY ALERT</b> 🚨%0ATarget: <code>${TARGET}</code>%0AFound: <code>$(echo "$line" | cut -c1-100)...</code>" "ALERT"
            done < "$nuclei_out"
            rm -f "$nuclei_out"
        fi
    fi
}
