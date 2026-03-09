#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §PROXY  Ghost Layer & Fallback Engine (Enhanced with proxychains4)
# ═══════════════════════════════════════════════════════════════════════════════

declare -a PROXY_LIST=()
USE_PROXY=false
CURRENT_PROXY=""

proxy_load() {
    local px_file="proxies_template.txt"
    if [[ -f "$px_file" ]]; then
        mapfile -t PROXY_LIST < <(grep -v '^#' "$px_file" | grep -v '^$')
        if [[ ${#PROXY_LIST[@]} -gt 0 ]]; then
            log OK "Ghost Layer: Loaded ${#PROXY_LIST[@]} proxies."
            USE_PROXY=true
            if [[ ${#PROXY_LIST[@]} -lt 20 ]]; then
                log WARN "Loaded fewer than 20 proxies (${#PROXY_LIST[@]}). Consider updating proxies_template.txt for better rotation resilience."
            fi
        fi
    fi
}

proxy_auto_refresh() { :; }

check_proxy() {
    if [[ "$USE_PROXY" == true ]]; then
        if [[ ${#PROXY_LIST[@]} -eq 0 ]]; then
            log WARN "Ghost Layer: No proxies loaded. Please check proxies_template.txt."
            return
        fi
        log INFO "Ghost Layer: Verifying random proxy health..."
        # Basic check logic could go here
    fi
}

# Select a random proxy from the loaded list
proxy_select() {
    if [[ ${#PROXY_LIST[@]} -gt 0 ]]; then
        local idx; idx=$((RANDOM % ${#PROXY_LIST[@]}))
        CURRENT_PROXY="${PROXY_LIST[$idx]}"
        echo "$CURRENT_PROXY"
    fi
}

proxy_prefix() {
    if [[ "$USE_PROXY" == true && -f "proxies_template.txt" ]]; then
        # Select random proxy
        local px; px=$(proxy_select)
        if [[ -z "$px" ]]; then
            px=$(grep -v '^#' "proxies_template.txt" | grep -v '^$' | shuf -n 1)
        fi
        
        if [[ -n "$px" ]]; then
            # §ENHANCED: Dynamically generate proxychains config for the selected proxy
            local conf="/tmp/proxychains_${RANDOM}_$$.conf"
            local proto; proto=$(echo "$px" | awk -F'://' '{print $1}')
            local addr; addr=$(echo "$px" | awk -F'://' '{print $2}')
            local host; host=$(echo "$addr" | cut -d: -f1)
            local port; port=$(echo "$addr" | cut -d: -f2)
            local user; user=$(echo "$addr" | awk -F'@' '{print $1}' | awk -F':' 'NF>1 {print $1}')
            local pass; pass=$(echo "$addr" | awk -F':' 'NF>1 && NF<3 {print $2}' | awk -F'@' '{print $1}')
            
            [[ -z "$proto" ]] && proto="http" # Fallback
            [[ -z "$port" ]] && port=8080    # Fallback port
            
            # Create proxychains4 config
            cat > "$conf" <<EOF
dynamic_chain
proxy_dns
remote_dns_resolver
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
$proto $host $port $([ -n "$user" ] && echo "$user $pass" || echo "")
EOF
            # Return the proxychains4 command with config file
            echo "proxychains4 -f $conf"
        fi
    fi
}

proxy_flag() {
    if [[ "$USE_PROXY" == true && -f "proxies_template.txt" ]]; then
        local px; px=$(grep -v '^#' "proxies_template.txt" | grep -v '^$' | shuf -n 1)
        [[ -n "$px" ]] && echo "$px"
    fi
}
