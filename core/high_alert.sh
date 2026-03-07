#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §DEEP HUNT: HIGH ALERT SENSITIVE DATA PIPELINE (Modularized)
# ═══════════════════════════════════════════════════════════════════════════════

process_high_alert_links() {
    local input_file="$1"
    local alert_dir="${TARGET_DIR}/HIGH_ALERTS"
    local history_file="${alert_dir}/processed_history.log"
    local hits_file="${alert_dir}/secrets_found.txt"
    local temp_urls="${TARGET_DIR}/tools_used/high_alert_temp.txt"
    local temp_filtered="${TARGET_DIR}/tools_used/high_alert_filtered.txt"
    
    mkdir -p "$alert_dir"
    touch "$history_file" "$hits_file"

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
        local px; px=$(proxy_prefix)
        local pf; pf=$(proxy_flag)
        local nuclei_out="${alert_dir}/.temp_nuclei_alerts.txt"
        
        spin_start "Scanning ${match_count} targets for active secrets..."
        mkdir -p "$alert_dir"
        ${px} ~/go/bin/httpx -list "$temp_filtered" -status-code -mc 200 -silent -threads 50 ${pf:+-http-proxy '${pf}'} \
        | awk '{print $1}' \
        | ${px} xargs -I {} -P 50 nuclei -u "{}" -t exposures/ -t tokens/ -silent -o "${nuclei_out}" ${pf:+-proxy '${pf}'} >/dev/null 2>&1
        spin_stop
        
        if [[ -s "$nuclei_out" ]]; then
            cat "$nuclei_out" >> "$hits_file"
            while IFS= read -r line; do
                printf "\n\033[5;31m  [☢️  HIGH ALERT ☢️ ] \033[0m\n"
                printf "  ${BYL}Secret Discovered:${RST} ${line}\n"
                tg_send "🚨 <b>HIGH PRIORITY ALERT</b> 🚨\n\nTarget: <code>${TARGET}</code>\nFound: <code>$(echo "$line" | cut -c1-100)...</code>"
            done < "$nuclei_out"
            rm -f "$nuclei_out"
        fi
    fi
}
