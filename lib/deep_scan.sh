#!/usr/bin/env bash
# CRIMSON DEEP SCAN — Full range port scanner (additive, standalone)
# Usage: deep_scan.sh [TARGET] [OUTPUT_DIR]

TARGET="$1"
OUTPUT_DIR="$2"

if [[ -z "$TARGET" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 TARGET OUTPUT_DIR" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
echo "[*] Starting Deep Full-Range Scan on $TARGET..."

OPEN_FILE="$OUTPUT_DIR/open_ports.txt"
> "$OPEN_FILE"

# Prefer masscan for speed if available
if command -v masscan >/dev/null 2>&1; then
    echo "[*] Using masscan for fast full-range scan"
    # masscan requires root on many systems; best-effort invocation
    masscan -p1-65535 "$TARGET" --rate 2000 -oL "$OUTPUT_DIR/masscan.out" 2>/dev/null || true
    # Parse masscan output for ports: lines like "open tcp 80 1.2.3.4"
    if [[ -f "$OUTPUT_DIR/masscan.out" ]]; then
        grep -Ei "open" "$OUTPUT_DIR/masscan.out" | awk '{print $3}' | sed 's|/tcp||; s|/udp||' | sort -n -u > "$OPEN_FILE" || true
    fi
fi

# Fallback to naabu if masscan not available or produced no output
if [[ ! -s "$OPEN_FILE" ]] && command -v naabu >/dev/null 2>&1; then
    echo "[*] Using naabu fallback for full-range scan"
    # Use port range to cover all ports
    naabu -host "$TARGET" -p 1-65535 -rate 2000 -o "$OUTPUT_DIR/naabu.out" 2>/dev/null || true
    if [[ -f "$OUTPUT_DIR/naabu.out" ]]; then
        # naabu outputs host:port lines; extract port
        awk -F: '{print $2}' "$OUTPUT_DIR/naabu.out" | sort -n -u > "$OPEN_FILE" || true
    fi
fi

# As a last resort, attempt nmap fast scan for common ports if nothing found
if [[ ! -s "$OPEN_FILE" ]] && command -v nmap >/dev/null 2>&1; then
    echo "[*] No open ports discovered by fast scanners; running nmap SYN scan for common ports (may be slow)"
    nmap -p- --min-rate 1000 -T4 -oG "$OUTPUT_DIR/nmap_greppable.out" "$TARGET" 2>/dev/null || true
    if [[ -f "$OUTPUT_DIR/nmap_greppable.out" ]]; then
        grep -Ei "Ports:" "$OUTPUT_DIR/nmap_greppable.out" | sed -n 's/.*Ports: //p' | tr ',' '\n' | awk -F/ '{print $1}' | sort -n -u > "$OPEN_FILE" || true
    fi
fi

if [[ -s "$OPEN_FILE" ]]; then
    echo "[+] Open ports found. Fingerprinting services (batched)..."

    # §PERF: Build comma-separated port list and run ONE nmap call instead of one per port
    local port_list
    port_list=$(paste -sd "," "$OPEN_FILE")

    nmap -sV -sC -p "$port_list" "$TARGET" \
        -oN "$OUTPUT_DIR/service_info.txt" \
        --open --min-rate 1000 >/dev/null 2>&1 || true

    echo "[!] Deep scan complete. Results in $OUTPUT_DIR/service_info.txt"
else
    echo "[!] No open ports detected by deep scan." >&2
fi

exit 0
