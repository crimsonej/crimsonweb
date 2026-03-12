#!/usr/bin/env bash
# Proxy Engine Room: isolated refueler worker
# Soft-fail mode: disable immediate exit on command failure but keep unset-var checks
set +e

# Compute project BASE_DIR (three levels up from this script: lib/proxy_engine -> lib -> project)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_DIR="${BASE_DIR}/lib/proxy_engine"
mkdir -p "${ENGINE_DIR}" 2>/dev/null || true

WORKING_POOL="${ENGINE_DIR}/working_pool.txt"
WORKING_TMP="${ENGINE_DIR}/working_pool.tmp"
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

        # Scrape and dedupe
        for src in "${sources[@]}"; do
            curl -s -4 --noproxy "*" --connect-timeout 8 --max-time 15 "$src" >> "$raw_tmp" 2>/dev/null || true
        done
        awk 'NF' "$raw_tmp" | sed 's/\r//g' | sed '/^#/d' | sed '/^$/d' | sort -u > "$WORKING_TMP" || true
        mv -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || cp -f "$WORKING_TMP" "$WORKING_POOL" 2>/dev/null || true

        # Test top 100 proxies in parallel and collect good ones
        good_tmp=$(mktemp)
        head -n 100 "$WORKING_POOL" | xargs -P 20 -I {} bash -c '
            px="{}"
            # quick probe against ipinfo (JSON) which is slightly friendlier
            resp=$(curl -s -4 --noproxy "*" -x "$px" --connect-timeout 3 --max-time 6 https://ipinfo.io/json 2>/dev/null || true)
            if [[ -n "$resp" && "$resp" != *"<html"* && "$resp" != *"<!DOCTYPE"* ]]; then
                printf "%s\n" "$px"
            fi
        ' >> "$good_tmp" 2>/dev/null || true

        # Deduplicate and write final active list atomically
        if [[ -s "$good_tmp" ]]; then
            sort -u "$good_tmp" > "${good_tmp}.uniq" || true
            mv -f "${good_tmp}.uniq" "$ACTIVE_OUT" 2>/dev/null || cp -f "${good_tmp}.uniq" "$ACTIVE_OUT" 2>/dev/null || true
            passed=$(wc -l < "$ACTIVE_OUT" 2>/dev/null || echo 0)
        else
            rm -f "$good_tmp" 2>/dev/null || true
            passed=0
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
