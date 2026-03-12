#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §PROXY  Ghost Layer & Fallback Engine (Enhanced with proxychains4)
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize sample proxy variable (avoid unbound variable usage)
proxy_sample=""
# Current selected proxy (initialized to avoid nounset errors)
CURRENT_PROXY=""
PROXY_LIST=()

proxy_select() {
    if [[ ${#PROXY_LIST[@]} -gt 0 ]]; then
        local idx; idx=$((RANDOM % ${#PROXY_LIST[@]}))
        CURRENT_PROXY="${PROXY_LIST[$idx]}"
        echo "$CURRENT_PROXY"
    fi
}

proxy_prefix() {
    # Return a proxychains4 command prefix if proxying is enabled and a proxy is available.
    # Output is safe to use as a no-op prefix when empty (i.e., tool will run directly).
    [[ "${USE_PROXY:-false}" != "true" ]] && return 0

    local proxy_file="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    [[ ! -s "$proxy_file" ]] && proxy_file="${BASE_DIR}/proxies.txt"
    [[ ! -s "$proxy_file" ]] && { log WARN "proxy_prefix: no proxy pool available — running without proxy"; return 0; }

    # Select random proxy
    local px; px=$(proxy_select)
    [[ -z "$px" ]] && px=$(grep -v '^#' "$proxy_file" | grep -v '^$' | shuf -n 1 2>/dev/null || true)
    [[ -z "$px" ]] && { log WARN "proxy_prefix: proxy pool empty — running without proxy"; return 0; }

    # Parse components safely
    local proto addr host port user pass
    proto=$(echo "$px" | grep -o '^[a-zA-Z0-9+.-]*' | head -1)
    addr=$(echo "$px" | sed 's|^[^:]*://||')
    # If there's auth: user:pass@host:port
    if echo "$addr" | grep -q '@'; then
        local auth; auth=$(echo "$addr" | cut -d@ -f1)
        addr=$(echo "$addr" | cut -d@ -f2)
        user=$(echo "$auth" | cut -d: -f1)
        pass=$(echo "$auth" | cut -d: -f2)
    fi
    host=$(echo "$addr" | cut -d: -f1)
    port=$(echo "$addr" | cut -d: -f2)

    [[ -z "$proto" ]] && proto="http"
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && port=8080
    [[ -z "$host" ]] && { log WARN "proxy_prefix: could not parse host from proxy '${px}'"; return 0; }

    # Generate temp proxychains4 config
    local conf="/tmp/proxychains_${RANDOM}_$$.conf"
    {
        echo "dynamic_chain"
        echo "proxy_dns"
        echo "remote_dns_resolver"
        echo "tcp_read_time_out 15000"
        echo "tcp_connect_time_out 8000"
        echo "[ProxyList]"
        if [[ -n "${user:-}" ]]; then
            echo "$proto $host $port $user $pass"
        else
            echo "$proto $host $port"
        fi
    } > "$conf"

    echo "proxychains4 -q -f $conf"
}

proxy_flag() {
    # Return a raw proxy URL (for tools that accept --proxy natively).
    [[ "${USE_PROXY:-false}" != "true" ]] && return 0
    local proxy_file="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    [[ ! -s "$proxy_file" ]] && proxy_file="${BASE_DIR}/proxies.txt"
    [[ ! -s "$proxy_file" ]] && return 0
    local px; px=$(grep -v '^#' "$proxy_file" | grep -v '^$' | shuf -n 1 2>/dev/null || true)
    [[ -n "$px" ]] && echo "$px"
}

# Load active proxies into memory (populate PROXY_LIST) and ensure daemon is running
proxy_load() {
    local ACTIVE_FILE="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    PROXY_LIST=()
    if [[ -f "${ACTIVE_FILE}" && -s "${ACTIVE_FILE}" ]]; then
        mapfile -t PROXY_LIST < "${ACTIVE_FILE}"
        USE_PROXY=true
        return 0
    fi

    # Bootstrap from master proxies.txt if available
    if [[ -f "${BASE_DIR}/proxies.txt" && -s "${BASE_DIR}/proxies.txt" ]]; then
        mkdir -p "${BASE_DIR}/lib/proxy_engine" 2>/dev/null || true
        head -n 10 "${BASE_DIR}/proxies.txt" > "${ACTIVE_FILE}" 2>/dev/null || true
        if [[ -s "${ACTIVE_FILE}" ]]; then
            mapfile -t PROXY_LIST < "${ACTIVE_FILE}"
            USE_PROXY=true
            return 0
        fi
    fi

    # As a last resort, launch the refueler engine in background (best-effort)
    start_refueler >/dev/null 2>&1 || true
    # Give the engine a moment to create the file
    sleep 1
    if [[ -f "${ACTIVE_FILE}" && -s "${ACTIVE_FILE}" ]]; then
        mapfile -t PROXY_LIST < "${ACTIVE_FILE}"
        USE_PROXY=true
        return 0
    fi

    USE_PROXY=false
    return 1
}

# Check proxy health/state and print identity information
check_proxy() {
    # prefer PROXY_LIST if populated
    if [[ ${#PROXY_LIST[@]} -gt 0 ]]; then
        show_identity || true
        return 0
    fi

    # Fallback: if active file exists, load and show identity
    local ACTIVE_FILE="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    if [[ -f "${ACTIVE_FILE}" && -s "${ACTIVE_FILE}" ]]; then
        mapfile -t PROXY_LIST < "${ACTIVE_FILE}"
        show_identity || true
        return 0
    fi

    log WARN "No proxies loaded; proxy functions will be skipped."
    return 2
}


# Refresh proxies by scraping public lists and validating responsiveness
refresh_proxies() {
    local out_file="${BASE_DIR}/proxies.txt"
    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    local tmpfile; tmpfile=$(mktemp)
    local atomic_out="${out_file}.tmp"

    # Sources: TheSpeedX (socks5 + http), Monosans
    local sources=(
        "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt"
        "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
        "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt"
        "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"
    )

    for src in "${sources[@]}"; do
        # Download source lists directly (bypass any environment proxies) and force IPv4
        curl -s -4 --noproxy "*" --connect-timeout 8 --max-time 15 "$src" >> "$tmpfile" 2>/dev/null || true
    done

    # Normalize lines and remove comments/empty
    grep -E '^[a-zA-Z0-9]+' "$tmpfile" | sed 's/\r//g' | sed '/^#/d' | sed '/^$/d' | sort -u > "$tmpfile.clean"

    # Validate proxies: quick 2s check against https://api.ipify.org using appropriate curl flags
    local goodfile; goodfile=$(mktemp)
    local max_check=200
    local kept=0
    while IFS= read -r px && [[ $kept -lt 100 ]]; do
        [[ -z "$px" ]] && continue
        # Determine protocol
        local proto; proto=$(echo "$px" | awk -F':\/\/' '{print $1}')
        local addr; addr=$(echo "$px" | awk -F':\/\/' '{print $2}')
        # Compose curl proxy arg
        local curl_proxy_args=""
        if [[ "$proto" =~ ^socks5 ]]; then
            curl_proxy_args="--socks5-hostname $addr"
        else
            curl_proxy_args="--proxy $addr"
        fi

        # Quick check (2s timeout) - force IPv4 when testing proxies
        if curl -s -4 $curl_proxy_args --connect-timeout 2 --max-time 4 https://ipconfig.io/ip >/dev/null 2>&1; then
            printf '%s\n' "$px" >> "$goodfile"
            kept=$((kept+1))
        fi
        max_check=$((max_check-1))
        [[ $max_check -le 0 ]] && break
    done < "$tmpfile.clean"

    # If we found good proxies, write them to the proxies file
        if [[ -s "$goodfile" ]]; then
        # Atomic move to avoid readers seeing a half-written file
        mv "$goodfile" "$atomic_out" 2>/dev/null || cp "$goodfile" "$atomic_out" 2>/dev/null || true
            mv -f "$atomic_out" "$out_file" 2>/dev/null || cp -f "$atomic_out" "$out_file" 2>/dev/null || true
        local count; count=$(wc -l < "$out_file" 2>/dev/null || echo 0)
        log OK "Proxy Scraper: Saved ${count} responsive proxies to ${out_file}"
        USE_PROXY=true
    else
        rm -f "$goodfile" 2>/dev/null || true
        log WARN "Proxy Scraper: No responsive proxies found; proxies file not updated"
        USE_PROXY=false
    fi

    rm -f "$tmpfile" "$tmpfile.clean" 2>/dev/null || true
}


## ghost_refueler has been moved into the isolated engine: lib/proxy_engine/engine.sh
## start_refueler will launch that worker as an independent process.

# Start refueler helper: launch ghost_refueler in background and persist PID
start_refueler() {
    mkdir -p "${BASE_DIR}/tmp" 2>/dev/null || true
    local pidfile="${BASE_DIR}/tmp/crimson_refueler.pid"
    # If a refueler pidfile exists and the process is alive, do not start another
    if [[ -f "$pidfile" ]]; then
        local existing; existing=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$existing" && $(kill -0 "$existing" 2>/dev/null; echo $?) -eq 0 ]]; then
            log INFO "Refueler already running (PID ${existing})"
            return 0
        fi
    fi
    # Launch isolated engine worker (refueler)
    "${BASE_DIR}/lib/proxy_engine/refueler.sh" > /tmp/refueler.log 2>&1 &
    local pid=$!
    echo "$pid" > "$pidfile" 2>/dev/null || true
    echo "$pid" > /tmp/refueler.pid 2>/dev/null || true
    return 0
}


# Display current public identity and proxy pool status
show_my_ip() {
    local info
    info=$(curl -s -4 --noproxy "*" ${CURL_OPTS[@]} "https://ipconfig.io/json" 2>/dev/null || true)
    local status country city ip
    if command -v jq >/dev/null 2>&1 && [[ -n "$info" ]]; then
        country=$(echo "$info" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")
        city=$(echo "$info" | jq -r '.city // .region // "Unknown"' 2>/dev/null || echo "Unknown")
        ip=$(echo "$info" | jq -r '.ip // "Unknown"' 2>/dev/null || echo "Unknown")
    else
        country=$(echo "$info" | grep -oP '"country"\s*:\s*"\K[^"]+' 2>/dev/null || echo "Unknown")
        city=$(echo "$info" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null || echo "Unknown")
        ip=$(echo "$info" | grep -oP '"ip"\s*:\s*"\K[^"]+' 2>/dev/null || echo "Unknown")
    fi

    local proxy_count=0
    if [[ -f "${BASE_DIR}/proxies.txt" ]]; then
        proxy_count=$(wc -l < "${BASE_DIR}/proxies.txt" 2>/dev/null || echo 0)
    fi

    echo -e "\n[🌐] CURRENT IDENTITY: ${city:-Unknown}, ${country:-Unknown}"
    echo -e "[🔒] EXIT IP: ${ip:-Unknown}"
    echo -e "[🛰] PROXY POOL: ${proxy_count} Active Nodes\n"
}


# Show both origin (direct) and an example proxy exit identity
show_identity() {
    # Implement stealth geolocation via proxy when GHOST_MODE is active.
    local GHOST_MODE
    if [[ "${USE_PROXIES:-${USE_PROXY:-false}}" == true ]]; then
        GHOST_MODE="ACTIVE"
    else
        GHOST_MODE="INACTIVE"
    fi

    # Default GHOST_EXIT
    GHOST_EXIT="[OFFLINE/WAITING]"

    # Use CURRENT_PROXY (normalize to host:port if proto present)
    local proxy_addr="${CURRENT_PROXY:-}"
    if [[ -n "$proxy_addr" && "$proxy_addr" == *"://"* ]]; then
        proxy_addr=${proxy_addr#*://}
    fi

    if [[ "$GHOST_MODE" == "ACTIVE" && -n "$proxy_addr" ]]; then
        # Use socks5h to force remote DNS resolution and 5s timeout to avoid hanging
        local IDENTITY
        IDENTITY=$(command curl -s --socks5-hostname "$proxy_addr" --connect-timeout 5 "https://ipconfig.io/json" 2>/dev/null || true)
        if [[ -n "$IDENTITY" ]]; then
            if command -v jq >/dev/null 2>&1; then
                IDENTITY=$(echo "$IDENTITY" | jq -r '"\(.city // .region), \(.country) (IP: \(.ip // .query // .ip_address))"' 2>/dev/null || echo "")
            else
                IDENTITY=$(echo "$IDENTITY" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null || true)
            fi
        fi

        if [[ -n "$IDENTITY" && "$IDENTITY" != "null, null"* && "$IDENTITY" != "" ]]; then
            GHOST_EXIT="$IDENTITY"
        else
            GHOST_EXIT="[!] ROUTING ERROR (Proxy Dead)"
        fi
    else
        GHOST_EXIT="[OFFLINE/WAITING]"
    fi

    # Print current routing info used by the project (non-fatal)
    printf "[🔁] CURRENT ROUTE: %s\n" "${CURRENT_PROXY:-${proxy_addr:-none}}" || true
    # Also print where traffic is routed through (city, country, IP) using the proxy
    local route_loc=""
    if [[ -n "${GHOST_EXIT:-}" && "${GHOST_EXIT}" != "[OFFLINE/WAITING]" ]]; then
        route_loc="${GHOST_EXIT}"
    else
        if [[ -n "$proxy_addr" ]]; then
            route_loc=""
            local rot_json
            rot_json=$(command curl -s --socks5-hostname "$proxy_addr" --connect-timeout 5 "https://ipconfig.io/json" 2>/dev/null || true)
            if [[ -n "$rot_json" ]]; then
                if command -v jq >/dev/null 2>&1; then
                    route_loc=$(echo "$rot_json" | jq -r '"\(.city // .region), \(.country) (IP: \(.ip // .query // .ip_address))"' 2>/dev/null || echo "")
                else
                    route_loc=$(echo "$rot_json" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null || true)
                fi
            fi
            if [[ -z "$route_loc" || "$route_loc" == "null, null (IP: null)" || "$route_loc" == "" ]]; then
                # Fallback to simple IP probe via ipconfig
                local probe_ip
                probe_ip=$(command curl -s4 --socks5-hostname "$proxy_addr" --connect-timeout 5 https://ipconfig.io/ip 2>/dev/null || true)
                if [[ -n "$probe_ip" ]]; then
                    route_loc="IP: ${probe_ip}"
                else
                    route_loc="[OFFLINE/WAITING]"
                fi
            fi
        else
            route_loc="[OFFLINE/WAITING]"
        fi
    fi
    printf "[🔍] ROUTE LOCATION: %s\n" "${route_loc}" || true
    
    # Also query ifconfig.co for additional routing info (IP, region) via proxy when possible
    local ifconf_info=""
    if [[ -n "${proxy_addr:-}" ]]; then
        ifconf_info=$(command curl -s --socks5-hostname "$proxy_addr" --connect-timeout 5 "https://ifconfig.co/json" 2>/dev/null || true)
    else
        ifconf_info=$(command curl -s --connect-timeout 5 "https://ifconfig.co/json" 2>/dev/null || true)
    fi
    if [[ -n "$ifconf_info" ]]; then
        if command -v jq >/dev/null 2>&1; then
            local ic_ip ic_country ic_region
            ic_ip=$(echo "$ifconf_info" | jq -r '.ip // "Unknown"' 2>/dev/null || echo "Unknown")
            ic_country=$(echo "$ifconf_info" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")
            ic_region=$(echo "$ifconf_info" | jq -r '.region // .city // "Unknown"' 2>/dev/null || echo "Unknown")
            printf "[🔎] IFCONFIG: %s, %s (IP: %s)\n" "$ic_region" "$ic_country" "$ic_ip" || true
        else
            # crude parse fallback
            local ic_ip_f
            ic_ip_f=$(echo "$ifconf_info" | grep -oP '"ip"\s*:\s*"\K[^"]+' 2>/dev/null || true)
            printf "[🔎] IFCONFIG: IP: %s\n" "${ic_ip_f:-Unknown}" || true
        fi
        fi

    return 0
}


# Monitor a given log file for excessive 403/429 responses and rotate proxies if needed
monitor_errors_and_rotate() {
    local logfile="$1"
    local threshold="${2:-10}"
    local window_lines="${3:-500}"
    [[ -z "$logfile" || ! -f "$logfile" ]] && return

    local hits
    hits=$(_tail "$window_lines" "$logfile" 2>/dev/null | grep -E ' 403| 429|HTTP/1.[01]" 4' | wc -l || echo 0)
    if [[ "$hits" -ge "$threshold" ]]; then
        log WARN "Proxy Rotation: Detected ${hits} 403/429 responses in ${logfile}; refreshing proxy pool..."
        refresh_proxies
    fi
}


# Pick a random proxy from the pool and test it for basic connectivity
proxy_health_check() {
    local proxy_file="${BASE_DIR}/proxies.txt"
    [[ ! -f "$proxy_file" ]] && return 1
    local test_proxy
    test_proxy=$(shuf -n1 "$proxy_file" 2>/dev/null || head -n1 "$proxy_file")
    [[ -z "$test_proxy" ]] && return 1

    # Translate proxy format for curl -x (if entry contains protocol://host:port use as-is)
    local proxy_arg
    if echo "$test_proxy" | grep -q '://'; then
        proxy_arg="$test_proxy"
    else
        proxy_arg="http://$test_proxy"
    fi

    # Quick connectivity check via google.com (use global TIMEOUT)
    if curl -s -4 -x "$proxy_arg" ${CURL_OPTS[@]} https://www.google.com/ >/dev/null 2>&1; then
        return 0
    else
        log WARN "Proxy Health Check: Proxy ${test_proxy} failed connectivity test"
        # Rotate by refreshing proxies (best-effort)
        refresh_proxies
        return 2
    fi
}


# Show machine origin and exit identity via direct and proxy lookups
show_location() {
    # Origin (direct, bypass proxies)
    local origin_json
    origin_json=$(curl -s -4 --noproxy "*" ${CURL_OPTS[@]} https://ipconfig.io/json 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1 && [[ -n "$origin_json" ]]; then
        local o_city; o_city=$(echo "$origin_json" | jq -r '.city // "Unknown"')
        local o_country; o_country=$(echo "$origin_json" | jq -r '.country // "Unknown"')
        local o_ip; o_ip=$(echo "$origin_json" | jq -r '.query // "Unknown"')
        echo -e "[🌐] ORIGIN: ${o_city}, ${o_country} | IP: ${o_ip}"
    else
        # Fallback parsing without jq
        local o_city o_country o_ip
        o_city=$(echo "$origin_json" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p' || echo "Unknown")
        o_country=$(echo "$origin_json" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p' || echo "Unknown")
        o_ip=$(echo "$origin_json" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p' || echo "Unknown")
        echo -e "[🌐] ORIGIN: ${o_city}, ${o_country} | IP: ${o_ip}"
    fi

    # Ghost exit via one random proxy
    local proxy_file="${BASE_DIR}/proxies.txt"
    if [[ -f "$proxy_file" && -s "$proxy_file" ]]; then
        local proxy_sample; proxy_sample=$(shuf -n1 "$proxy_file" 2>/dev/null || head -n1 "$proxy_file")
        local proto; proto=$(echo "$proxy_sample" | awk -F':\/\/' '{print $1}')
        local addr; addr=$(echo "$proxy_sample" | awk -F':\/\/' '{print $2}')
        local curl_proxy_args=""
        if [[ "$proto" =~ ^socks5 ]]; then
            curl_proxy_args="--socks5-hostname $addr"
        else
            curl_proxy_args="--proxy $addr"
        fi
        local proxy_json; proxy_json=$(curl -s -4 $curl_proxy_args ${CURL_OPTS[@]} https://ipconfig.io/json 2>/dev/null || true)
        if command -v jq >/dev/null 2>&1 && [[ -n "$proxy_json" ]]; then
            local p_city; p_city=$(echo "$proxy_json" | jq -r '.city // "Unknown"')
            local p_country; p_country=$(echo "$proxy_json" | jq -r '.country // "Unknown"')
            local p_ip; p_ip=$(echo "$proxy_json" | jq -r '.query // "Unknown"')
            echo -e "[🛰] GHOST EXIT: ${p_city}, ${p_country} (IP: ${p_ip})"
        else
            echo -e "[🛰] GHOST EXIT: Failed to query via proxy"
        fi
    else
        echo -e "[🛰] GHOST EXIT: No proxies available"
    fi

    # Proxy count
    local proxy_count=0
    if [[ -f "${BASE_DIR}/proxies.txt" ]]; then
        proxy_count=$(wc -l < "${BASE_DIR}/proxies.txt" 2>/dev/null || echo 0)
    fi
    echo -e "[📊] STATUS: ${proxy_count} Fresh Proxies Loaded."
}


# Sample N proxies and return number of responsive proxies (prints count and returns count)
proxy_sample_check() {
    local proxy_file="${BASE_DIR}/proxies.txt"
    local sample_size=5
    local responsive=0
    if [[ ! -f "$proxy_file" || ! -s "$proxy_file" ]]; then
        echo 0
        return 0
    fi
    local samples
    samples=$(shuf -n "$sample_size" "$proxy_file" 2>/dev/null || head -n "$sample_size" "$proxy_file")
    while IFS= read -r px; do
        [[ -z "$px" ]] && continue
        local proxy_arg
        if echo "$px" | grep -q '://'; then
            proxy_arg="$px"
        else
            proxy_arg="http://$px"
        fi
        if curl -s -4 -x "$proxy_arg" ${CURL_OPTS[@]} https://ipconfig.io/ip >/dev/null 2>&1; then
            responsive=$((responsive+1))
        fi
    done <<< "$samples"
    echo "$responsive"
    return 0
}

# Remove a failed/blocked proxy from the active list and pick a new one
rotate_and_purge() {
    # Deprecated in main process. Keep stub to avoid downstream callers
    # Real purge is handled asynchronously by the refueler reading blacklist.txt
    local failed_proxy="$1"
    if [[ -z "$failed_proxy" ]]; then
        return 1
    fi
    mkdir -p "${BASE_DIR}/lib/proxy_engine" 2>/dev/null || true
    local BLFILE="${BASE_DIR}/lib/proxy_engine/blacklist.txt"
    printf '%s\n' "$failed_proxy" >> "$BLFILE" 2>/dev/null || true
    return 0
}


# Rotate to a new proxy and export ALL_PROXY (socks5h), then perform a silent stealth check
rotate_proxy() {
    local active_file="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    if [[ ! -f "$active_file" || ! -s "$active_file" ]]; then
        return 1
    fi
    local new_entry; new_entry=$(shuf -n1 "$active_file" 2>/dev/null || head -n1 "$active_file" 2>/dev/null || true)
    [[ -z "$new_entry" ]] && return 2

    # Normalize address for export and curl check
    local addr
    if echo "$new_entry" | grep -q '://'; then
        addr=${new_entry#*://}
    else
        addr="$new_entry"
    fi

    # Export ALL_PROXY as socks5h://<host:port>
    export ALL_PROXY="socks5h://${addr}"
    # Also set CURRENT_PROXY to socks5://host:port for other wrappers that expect proto://addr
    CURRENT_PROXY="socks5://${addr}"

    # Announce current route immediately after rotation selection
    printf "[🔁] CURRENT ROUTE: %s\n" "${CURRENT_PROXY}" || true
    # Probe and print route location (city, country, IP) non-fatally
    local route_loc=""
    if [[ -n "${CURRENT_PROXY:-}" ]]; then
        local prov_addr
        prov_addr=${CURRENT_PROXY#*://}
        route_loc=""
        local rot_json
        rot_json=$(command curl -s --socks5-hostname "$prov_addr" --connect-timeout 5 "https://ipconfig.io/json" 2>/dev/null || true)
        if [[ -n "$rot_json" ]]; then
            if command -v jq >/dev/null 2>&1; then
                route_loc=$(echo "$rot_json" | jq -r '"\(.city // .region), \(.country) (IP: \(.ip // .query // .ip_address))"' 2>/dev/null || echo "")
            else
                route_loc=$(echo "$rot_json" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null || true)
            fi
        fi
        if [[ -z "$route_loc" || "$route_loc" == "null, null (IP: null)" || "$route_loc" == "" ]]; then
            local probe_ip
            probe_ip=$(command curl -s4 --socks5-hostname "$prov_addr" --connect-timeout 5 https://ipconfig.io/ip 2>/dev/null || true)
            if [[ -n "$probe_ip" ]]; then
                route_loc="IP: ${probe_ip}"
            else
                route_loc="[OFFLINE/WAITING]"
            fi
        fi
    else
        route_loc="[OFFLINE/WAITING]"
    fi
    printf "[🔍] ROUTE LOCATION: %s\n" "${route_loc}" || true

    # Silent stealth check via ipconfig (socks5-hostname)
    local NEW_IP
    NEW_IP=$(command curl -s4 --socks5-hostname "$addr" --connect-timeout 5 --max-time 6 https://ipconfig.io/ip 2>/dev/null || true)
    if [[ -n "$NEW_IP" ]]; then
        echo -e "[🔄] ROTATION SUCCESS: New Identity -> ${NEW_IP}"
        return 0
    else
        echo -e "[🔄] ROTATION FAILED: Proxy ${new_entry} did not return an IP"
        return 3
    fi
}

# Ensure a CURRENT_PROXY is available; if not, block until refueler repopulates active_proxies
ensure_current_proxy() {
    local active_file="${BASE_DIR}/lib/proxy_engine/active_proxies.txt"
    # If GHOST_ONLY mode is not on, allow returning empty
    if [[ "${GHOST_ONLY:-false}" != "true" ]]; then
        return 0
    fi
    while true; do
        # Bootstrap: if active pool missing but master exists, seed active pool with first 10
        if [[ ! -f "$active_file" || ! -s "$active_file" ]]; then
            if [[ -f "${BASE_DIR}/proxies.txt" && -s "${BASE_DIR}/proxies.txt" ]]; then
                mkdir -p "$(dirname "$active_file")" 2>/dev/null || true
                head -n 10 "${BASE_DIR}/proxies.txt" > "$active_file" 2>/dev/null || cp -f "${BASE_DIR}/proxies.txt" "$active_file" 2>/dev/null || true
            fi
        fi

        if [[ -f "$active_file" && -s "$active_file" ]]; then
            CURRENT_PROXY=$(shuf -n1 "$active_file" 2>/dev/null || head -n1 "$active_file" 2>/dev/null || echo "")
            [[ -n "$CURRENT_PROXY" ]] && return 0
        fi
        # Check refueler status and wait for it to repopulate
        if [[ -f "${BASE_DIR}/lib/proxy_engine/status.json" ]]; then
            sleep 5
        else
            sleep 5
        fi
    done
}

restart_current_phase() {
    local phase="${CURRENT_PHASE:-}"
    case "$phase" in
        RECON) phase_recon ;; 
        SURFACE) phase_surface ;; 
        CRAWL) phase_crawl ;; 
        ANALYZE) phase_analyze ;; 
        VULN) phase_vuln ;; 
        *) return 1 ;;
    esac
}

# Wrapper for curl that enforces proxy usage when GHOST_ONLY is true
curl() {
    local _bin; _bin=$(command -v curl 2>/dev/null || true)
    if [[ -z "$_bin" ]]; then
        command curl "$@"
        return $?
    fi
    if [[ "${GHOST_ONLY:-false}" == "true" ]]; then
        ensure_current_proxy
        if [[ -n "$CURRENT_PROXY" && "$*" != *"-x "* && "$*" != *"--proxy"* ]]; then
            # Capture output to detect HTML blocks
            local out; out=$(mktemp)
            command curl -s -4 -x "$CURRENT_PROXY" ${CURL_OPTS[@]} "$@" >"$out" 2>&1 || true
            if grep -qiE '<!DOCTYPE|<html' "$out"; then
                # Asynchronous purge: add to blacklist and continue with next proxy
                rotate_and_purge "$CURRENT_PROXY"
                echo "[🛰] GHOST EXIT: Switching..."
                # retry once with new proxy
                ensure_current_proxy
                if [[ -n "$CURRENT_PROXY" ]]; then
                    command curl -s -4 -x "$CURRENT_PROXY" ${CURL_OPTS[@]} "$@"
                    rm -f "$out" 2>/dev/null || true
                    return $?
                fi
            fi
            # return captured output
            cat "$out"
            rm -f "$out" 2>/dev/null || true
            return 0
        fi
    fi
    command curl "$@"
}

# Wrapper for httpx (ProjectDiscovery)
httpx() {
    local _bin; _bin=$(command -v httpx 2>/dev/null || true)
    if [[ -z "$_bin" ]]; then
        command httpx "$@"
        return $?
    fi
    if [[ "${GHOST_ONLY:-false}" == "true" ]]; then
        ensure_current_proxy
        if [[ -n "$CURRENT_PROXY" && "$*" != *"-proxy "* && "$*" != *"--proxy"* ]]; then
            # Run httpx capturing output to detect HTML blocks
            local out; out=$(mktemp)
            command httpx -proxy "$CURRENT_PROXY" "$@" >"$out" 2>&1 || true
            if grep -qiE '<!DOCTYPE|<html' "$out"; then
                rotate_and_purge "$CURRENT_PROXY"
                echo "[🛰] GHOST EXIT: Switching..."
                ensure_current_proxy
                if [[ -n "$CURRENT_PROXY" ]]; then
                    command httpx -proxy "$CURRENT_PROXY" "$@"
                    rm -f "$out" 2>/dev/null || true
                    return $?
                fi
            fi
            cat "$out"
            rm -f "$out" 2>/dev/null || true
            return 0
        fi
    fi
    command httpx "$@"
}

# Wrapper for naabu
naabu() {
    local _bin; _bin=$(command -v naabu 2>/dev/null || true)
    if [[ -z "$_bin" ]]; then
        command naabu "$@"
        return $?
    fi
    if [[ "${GHOST_ONLY:-false}" == "true" ]]; then
        ensure_current_proxy
        if [[ -n "$CURRENT_PROXY" && "$*" != *"-proxy "* && "$*" != *"--proxy"* ]]; then
            local out; out=$(mktemp)
            command naabu --proxy "$CURRENT_PROXY" "$@" >"$out" 2>&1 || true
            if grep -qiE '<!DOCTYPE|<html' "$out"; then
                rotate_and_purge "$CURRENT_PROXY"
                echo "[🛰] GHOST EXIT: Switching..."
                ensure_current_proxy
                if [[ -n "$CURRENT_PROXY" ]]; then
                    command naabu --proxy "$CURRENT_PROXY" "$@"
                    rm -f "$out" 2>/dev/null || true
                    return $?
                fi
            fi
            cat "$out"
            rm -f "$out" 2>/dev/null || true
            return 0
        fi
    fi
    command naabu "$@"
}


# Duplicate show_identity removed; use the primary show_identity() defined earlier.
