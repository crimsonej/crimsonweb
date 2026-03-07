#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  §INTELLIGENCE  Initialization & Configuration
# ═══════════════════════════════════════════════════════════════════════════════

# Argument Parser
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) TARGET="$2"; shift 2 ;;
            -t|--threads) THREADS="$2"; shift 2 ;;
            --proxy) USE_PROXY=true; shift ;;
            --help) print_help; exit 0 ;;
            *) shift ;;
        esac
    done
}

# Initialize Settings
init_settings() {
    local config_dir="${HOME}/.crimson_vault"
    local config="${config_dir}/config"
    mkdir -p "$config_dir"
    
    if [[ -f "$config" ]]; then
        source "$config"
        log OK "Intelligence Loaded from ${WH}${config}${RST}"
    fi
}

# Vault Setup
init_vault() {
    TARGET_SAFE="${TARGET//[^a-zA-Z0-9._-]/_}"
    TARGET_DIR="${VAULT_ROOT}/${TARGET_SAFE}"
    mkdir -p "${TARGET_DIR}/logs" "${TARGET_DIR}/websites" "${TARGET_DIR}/tools_used"
    log OK "Vault Initialized: ${WH}${TARGET_DIR}${RST}"
}

# Detection logic
detect_system() {
    log INFO "Environment Audit: $(uname -a | cut -d' ' -f1-3)"
}

# Session Management
session_init() {
    log INFO "Session Epoch: ${START_EPOCH}"
}

# Post-flight setup
cmd_setup() {
    log INFO "Verifying binary arsenal..."
    local tools=(bc stdbuf pkill pgrep curl jq)
    for t in "${tools[@]}"; do
        if ! tool_exists "$t"; then
            log ERROR "Missing system dependency: ${WH}${t}${RST}"
        fi
    done
}

# Interactive Target Prompt
prompt_target() {
    printf "  ${BCR}●${RST} ${BWHT}TARGET DOMAIN${RST} (e.g. example.com): "
    read -r TARGET
    if [[ -z "$TARGET" ]]; then
        log FATAL "Target domain cannot be empty."
    fi
}

# High Alert Keywords
init_high_alert_keywords() {
    HIGH_INTEREST_KEYWORDS="api|key|credential|secret|backup|config|bugbounty|private|db|database|money|leak|card|credit|account|invoice|pdf|docx|xlsx|.env|sql|dump"
    local kw_file="${HOME}/.crimson_vault/keywords.txt"
    if [[ -f "$kw_file" ]]; then
        local user_kw; user_kw=$(grep -v '^#' "$kw_file" | tr '\n' '|' | sed 's/|$//')
        if [[ -n "$user_kw" ]]; then
            HIGH_INTEREST_KEYWORDS="${HIGH_INTEREST_KEYWORDS}|${user_kw}"
        fi
    fi
    export HIGH_INTEREST_KEYWORDS
}

phase_should_run() { true; } 
phase_complete() {
    log OK "Phase $1 Complete."
}
