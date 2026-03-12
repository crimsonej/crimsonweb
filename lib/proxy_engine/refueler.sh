#!/usr/bin/env bash
# Run in soft-fail mode to avoid killing the parent process on transient failures
set +e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_DIR="${BASE_DIR}/lib/proxy_engine"
mkdir -p "${ENGINE_DIR}" 2>/dev/null || true

WORKING_POOL="${ENGINE_DIR}/working_pool.txt"
WORKING_TMP="${ENGINE_DIR}/working_pool.tmp"
ACTIVE_TMP="${ENGINE_DIR}/active.tmp"
ACTIVE_OUT="${ENGINE_DIR}/active_proxies.txt"
STATUS_JSON="${ENGINE_DIR}/status.json"

sources=(
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt"
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt"
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"
)

ghost_refueler() {
    while true; do
        start_ts=$(date +%s)
        raw_tmp=$(mktemp)
        tested=0
        passed=0

        # Build working pool: prefer using the project's master proxies.txt if present
        if [[ -f "${BASE_DIR}/proxies.txt" ]]; then
            # Normalize and dedupe master list
            awk 'NF' "${BASE_DIR}/proxies.txt" | sed 's/\r//g' | sed '/^#/d' | sed '/^$/d' | sort -u > "$WORKING_TMP" || true
            mv -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || cp -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || true
        else
            # Scrape upstream sources and dedupe
            for src in "${sources[@]}"; do
                curl -s -4 --noproxy "*" --connect-timeout 8 --max-time 15 "$src" >> "$raw_tmp" 2>/dev/null || true
            done
            awk 'NF' "$raw_tmp" | sed 's/\r//g' | sed '/^#/d' | sed '/^$/d' | sort -u > "$WORKING_TMP" || true
            mv -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || cp -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || true
        fi

        # Test top 200 proxies in parallel and collect good ones
        good_tmp=$(mktemp)
        head -n 200 "$WORKING_POOL" | xargs -P 20 -I {} bash -c '
            px="{}"
            # try socks5-hostname first, then http-x
            resp=$(curl -s -4 --noproxy "*" --socks5-hostname "$px" --connect-timeout 4 --max-time 6 https://ipconfig.io/json 2>/dev/null || curl -s -4 --noproxy "*" -x "$px" --connect-timeout 4 --max-time 6 https://ipconfig.io/json 2>/dev/null || true)
            if [[ -n "$resp" && "$resp" != *"<html"* && "$resp" != *"<!DOCTYPE"* ]]; then
                printf "%s\n" "$px"
            fi
        ' >> "$good_tmp" 2>/dev/null || true

        # Deduplicate results
        if [[ -s "$good_tmp" ]]; then
            sort -u "$good_tmp" > "${good_tmp}.uniq" || true
            # If an active out exists, merge and dedupe; else atomically write uniq
            if [[ -f "$ACTIVE_OUT" ]]; then
                cat "${good_tmp}.uniq" "$ACTIVE_OUT" | sort -u > "${ACTIVE_OUT}.tmp" || true
                mv -f "${ACTIVE_OUT}.tmp" "$ACTIVE_OUT" 2>/dev/null || cp -f "${ACTIVE_OUT}.tmp" "$ACTIVE_OUT" 2>/dev/null || true
            else
                mv -f "${good_tmp}.uniq" "$ACTIVE_OUT" 2>/dev/null || cp -f "${good_tmp}.uniq" "$ACTIVE_OUT" 2>/dev/null || true
            fi
            passed=$(wc -l < "$ACTIVE_OUT" 2>/dev/null || echo 0)
        else
            rm -f "$good_tmp" 2>/dev/null || true
            passed=0
        fi

        # Process blacklist (asynchronous purging requested by main process)
        if [[ -f "${ENGINE_DIR}/blacklist.txt" ]]; then
            if [[ -f "$ACTIVE_OUT" ]]; then
                grep -F -x -v -f "${ENGINE_DIR}/blacklist.txt" "$ACTIVE_OUT" > "${ACTIVE_OUT}.tmp.filtered" 2>/dev/null || true
                mv -f "${ACTIVE_OUT}.tmp.filtered" "$ACTIVE_OUT" 2>/dev/null || true
            fi
            # Also remove from master proxies file to avoid re-adding bad proxies
            if [[ -f "${BASE_DIR}/proxies.txt" ]]; then
                grep -F -x -v -f "${ENGINE_DIR}/blacklist.txt" "${BASE_DIR}/proxies.txt" > "${BASE_DIR}/proxies.txt.tmp" 2>/dev/null || true
                mv -f "${BASE_DIR}/proxies.txt.tmp" "${BASE_DIR}/proxies.txt" 2>/dev/null || true
            fi
            # Clear blacklist after processing
            rm -f "${ENGINE_DIR}/blacklist.txt" 2>/dev/null || true
        fi

        tested=$(wc -l < "$WORKING_POOL" 2>/dev/null || echo 0)
        elapsed=$(( $(date +%s) - start_ts ))
        speed=0
        if [[ $elapsed -gt 0 ]]; then
            speed=$(( tested / elapsed ))
        fi

        # Write status JSON for dashboard consumption
        next_run=$(( $(date +%s) + 300 ))
        cat > "$STATUS_JSON" <<EOF
{"last_run": $(date +%s), "tested": ${tested}, "passed": ${passed}, "speed_per_s": ${speed}, "next_run": ${next_run}}
EOF

        rm -f "$raw_tmp" "$good_tmp" 2>/dev/null || true
        sleep 300
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ghost_refueler
fi
