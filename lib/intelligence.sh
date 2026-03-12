[[ -n "${INTELLIGENCE_SOURCED:-}" ]] && return
export INTELLIGENCE_SOURCED=true
# ═══════════════════════════════════════════════════════════════════════════════
#  §INTELLIGENCE  Initialization & Configuration
# ═══════════════════════════════════════════════════════════════════════════════

# Argument Parser
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) TARGET="$2"; shift 2 ;;
            -t|--threads) THREADS="$2"; shift 2 ;;
            --force) FORCE_ALL=true; export FORCE_ALL=true; SKIP_PROMPTS=true; export SKIP_PROMPTS=true; shift ;;
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
    # Use absolute VAULT_PATH if provided, otherwise fall back to VAULT_ROOT under BASE_DIR
    if [[ -n "${VAULT_PATH:-}" ]]; then
        if [[ "${VAULT_PATH}" == /* ]]; then
            TARGET_DIR="${VAULT_PATH}/${TARGET_SAFE}"
        else
            TARGET_DIR="${BASE_DIR}/${VAULT_PATH}/${TARGET_SAFE}"
        fi
    else
        TARGET_DIR="${BASE_DIR}/${VAULT_ROOT}/${TARGET_SAFE}"
    fi
    
    # §FIX: Centralized Mandatory Directory Initialization
    echo -e "[*] Preparing target vault: ${BWHT}${TARGET_DIR}${RST}"
    mkdir -p "${TARGET_DIR}/logs" 
    mkdir -p "${TARGET_DIR}/websites" 
    mkdir -p "${TARGET_DIR}/tools_used"
    mkdir -p "${TARGET_DIR}/raw"
    mkdir -p "${TARGET_DIR}/vulnerabilities"
    mkdir -p "${TARGET_DIR}/vulns"
    mkdir -p "${TARGET_DIR}/screenshots"
    mkdir -p "${TARGET_DIR}/HIGH_ALERTS"
    mkdir -p "${TARGET_DIR}/filtered"
    touch "${TARGET_DIR}/RECON_results.txt"
    touch "${TARGET_DIR}/logs/session.log"

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
    local tools=(bc stdbuf pkill pgrep curl jq anew)
    for t in "${tools[@]}"; do
        if ! tool_exists "$t"; then
            log ERROR "Missing system dependency: ${WH}${t}${RST}"
        fi
    done
}

# Interactive Target Prompt
prompt_target() {
    # CRITICAL: Operator has total control over target input - no timeouts
    # Domain validation regex: accepts domains AND IPs
    local DOMAIN_REGEX='^([a-zA-Z0-9]{1,63}\.)+[a-zA-Z]{2,63}$|^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    # Loop until a valid TARGET is set (either local or via C2)
    while [[ -z "$TARGET" ]]; do
        # Check if remote target was set via Telegram /target command
        if [[ -f /tmp/crimson_answer ]]; then
            TARGET=$(cat /tmp/crimson_answer)
            rm -f /tmp/crimson_answer
            TARGET=$(echo "$TARGET" | sed -e 's|^[^/]*://||' -e 's|/.*$||')
            if [[ "$TARGET" =~ $DOMAIN_REGEX ]]; then
                printf "  🕷️  ENTER TARGET DOMAIN (e.g., example.com) > %s (remote)\n" "$TARGET"
                log OK "Target accepted from remote: ${WH}${TARGET}${RST}"
                break
            else
                log WARN "Remote target had invalid format: ${TARGET}. Ignoring."
                TARGET=""
                continue
            fi
        fi

        # Prompt local operator (blocking, no timers)
        read -r -p "  ● TARGET DOMAIN: " TARGET
        TARGET=$(echo "$TARGET" | sed -e 's|^[^/]*://||' -e 's|/.*$||')

        if [[ -z "$TARGET" ]]; then
            printf "  ${BCR}[ERROR]${RST} Input cannot be empty. Try again.\n"
            TARGET=""
            continue
        fi

        if [[ "$TARGET" =~ $DOMAIN_REGEX ]]; then
            log OK "Target accepted: ${WH}${TARGET}${RST}"
            break
        else
            printf "  ${BCR}[ERROR]${RST} Invalid format. Enter domain (example.com), subdomain (api.example.com), or IP (1.2.3.4)\n"
            TARGET=""
        fi
    done
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

phase_should_run() {
    local phase="$1"
    # If TARGET_DIR not set, default to running the phase
    [[ -z "${TARGET_DIR:-}" ]] && return 0
    local marker_file="${TARGET_DIR}/.phase_${phase}.done"
    if [[ -f "$marker_file" ]]; then
        # Phase already completed — ask operator whether to rerun (non-blocking)
        # If FORCE_ALL is set, always re-run without prompting
        if [[ "${FORCE_ALL:-false}" == "true" ]]; then
            return 0
        fi

        # Pause global keyboard skip listener so it doesn't steal input
        stop_control_listener 2>/dev/null || true
        # Reset terminal state to grab keyboard focus cleanly
        stty echo lnext ^V 2>/dev/null || true
        # Add a visual hint to the HUD so the user knows to look at the prompt
        hud_event "*" "Waiting for $phase decision (terminal or Telegram)..."
        printf "[?] %s already completed. Re-run? (y/N) — default Re-run in 20s: " "$phase"
        local decision=""
        local timeout_secs=20
        local elapsed=0
        local fifo="${INPUT_FIFO:-/tmp/crimson_c2}"

        # Loop listening to both Telegram FIFO and local terminal input
        while (( elapsed < timeout_secs )); do
            # Check FIFO (Telegram) for actionable commands
            if [[ -p "$fifo" ]]; then
                if timeout 0.5 cat "$fifo" 2>/dev/null | head -1 | grep -q .; then
                    local tf; tf=$(timeout 0.5 cat "$fifo" 2>/dev/null | head -1 2>/dev/null || true)
                    tf=$(echo "$tf" | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true)
                    if [[ "$tf" =~ ^(re_run|rerun|retry|y|yes)$ ]]; then
                        decision="y"; break
                    elif [[ "$tf" =~ ^(skip|s|n|no)$ ]]; then
                        decision="n"; break
                    elif [[ "$tf" =~ ^(abort|a)$ ]]; then
                        decision="a"; break
                    fi
                fi
            fi

            # Check local terminal input (non-blocking)
            if [[ -t 0 ]]; then
                # Read directly from terminal device to bypass any pipe issues
                if read -r -t 1 local_ans < /dev/tty 2>/dev/null; then
                    local_ans=$(echo "$local_ans" | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true)
                    if [[ "$local_ans" =~ ^(y|yes|rerun|retry)$ ]]; then
                        decision="y"; break
                    elif [[ "$local_ans" =~ ^(n|no|skip)$ ]]; then
                        decision="n"; break
                    elif [[ "$local_ans" =~ ^(a|abort)$ ]]; then
                        decision="a"; break
                    fi
                fi
            fi

            sleep 1
            elapsed=$((elapsed + 1))
        done

        # Default behavior if no decision received: default to Re-run (per strict repair)
        if [[ -z "$decision" ]]; then
            decision="y"
        fi

        case "$decision" in
            y)
                printf "\n[+] Operator selected: Fresh scan for %s. Purging old data...\n" "$phase"
                # Targeted Purge: Only wipe the specific folders for this phase
                case "$phase" in
                    RECON)   rm -rf "${TARGET_DIR}/raw" "${TARGET_DIR}/loot" 2>/dev/null ;;
                    SURFACE) rm -rf "${TARGET_DIR}/websites" 2>/dev/null ;;
                    CRAWL)   rm -f "${TARGET_DIR}/websites/master_urls.txt" "${TARGET_DIR}/websites/js_urls.txt" 2>/dev/null ;;
                    ANALYZE) rm -rf "${TARGET_DIR}/analysis" 2>/dev/null ;;
                esac
                
                # Remove the phase marker
                if [[ -f "$marker_file" ]]; then
                    rm -f "$marker_file" 2>/dev/null || true
                fi
                # Resume keyboard listener
                start_control_listener 2>/dev/null || true
                # Ensure subsequent phases run automatically without prompting
                export FORCE_ALL=true
                return 0
                ;;
            a)
                printf "\n[!] Operator selected: Abort\n"
                start_control_listener 2>/dev/null || true
                return 1
                ;;
            n)
                printf "\n[-] Skipping %s (operator selected)\n" "$phase"
                start_control_listener 2>/dev/null || true
                return 1
                ;;
            *)
                printf "\n[-] Skipping %s (default action)\n" "$phase"
                start_control_listener 2>/dev/null || true
                return 1
                ;;
        esac
    fi
    return 0
}

phase_complete() {
    local phase="$1"
    log OK "Phase $phase Complete."
    if [[ -n "${TARGET_DIR:-}" ]]; then
        touch "${TARGET_DIR}/.phase_${phase}.done"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §BOOTSTRAP  Universal Linux Environment Detection & Tool Sync
# ═══════════════════════════════════════════════════════════════════════════════

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        local name; name=$(grep ^NAME= /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        echo "${name,,}"
    else
        echo "unknown"
    fi
}

# Map distro to package manager
get_package_manager() {
    local distro="$1"
    case "$distro" in
        ubuntu|debian|parrot|kali|mint|raspbian) echo "apt" ;;
        arch|manjaro) echo "pacman" ;;
        fedora|rhel|centos|rocky|almalinux) echo "dnf" ;;
        opensuse|opensuse-leap|opensuse-tumbleweed) echo "zypper" ;;
        alpine) echo "apk" ;;
        *) echo "apt" ;; # Default fallback
    esac
}

# Detect OS version info
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        local pretty; pretty=$(grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [[ -n "$pretty" ]]; then
            echo "$pretty"
        else
            uname -s -r
        fi
    else
        uname -s -r
    fi
}

# Get system hardware specs
get_hardware_specs() {
    local cpu_cores; cpu_cores=$(nproc 2>/dev/null || echo "1")
    local total_ram; total_ram=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "Unknown")
    local distro; distro=$(detect_distro)
    local os_info; os_info=$(get_os_info)
    
    echo "CPU_CORES=$cpu_cores"
    echo "TOTAL_RAM=$total_ram"
    echo "DISTRO=$distro"
    echo "OS_INFO=$os_info"
}

# Install core system dependencies
install_core_tools() {
    local distro="$1"
    local pm; pm=$(get_package_manager "$distro")
    local tools=("jq" "curl" "git" "bc")
    
    log INFO "Installing system dependencies via ${WH}${pm}${RST}..."
    
    case "$pm" in
        apt)
            sudo apt-get update -qq >/dev/null 2>&1
            for tool in "${tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    log INFO "Installing ${WH}${tool}${RST}..."
                    sudo apt-get install -y "$tool" >/dev/null 2>&1 && log OK "${tool}" || log WARN "Failed to install ${tool}"
                fi
            done
            ;;
        pacman)
            for tool in "${tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    log INFO "Installing ${WH}${tool}${RST}..."
                    sudo pacman -Sy --noconfirm "$tool" >/dev/null 2>&1 && log OK "${tool}" || log WARN "Failed to install ${tool}"
                fi
            done
            ;;
        dnf)
            for tool in "${tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    log INFO "Installing ${WH}${tool}${RST}..."
                    sudo dnf install -y "$tool" >/dev/null 2>&1 && log OK "${tool}" || log WARN "Failed to install ${tool}"
                fi
            done
            ;;
        zypper)
            sudo zypper refresh >/dev/null 2>&1
            for tool in "${tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    log INFO "Installing ${WH}${tool}${RST}..."
                    sudo zypper install -y "$tool" >/dev/null 2>&1 && log OK "${tool}" || log WARN "Failed to install ${tool}"
                fi
            done
            ;;
        apk)
            for tool in "${tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    log INFO "Installing ${WH}${tool}${RST}..."
                    sudo apk add "$tool" >/dev/null 2>&1 && log OK "${tool}" || log WARN "Failed to install ${tool}"
                fi
            done
            ;;
    esac
}

# Install Go (if missing)
install_golang() {
    if command -v go &>/dev/null; then
        log OK "Go is already installed"
        return 0
    fi
    
    log INFO "Go not found. Attempting installation..."
    
    local os_type; os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch; arch=$(uname -m)
    local go_ver="1.22.0"
    
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    
    local go_url="https://go.dev/dl/go${go_ver}.${os_type}-${arch}.tar.gz"
    
    log INFO "Downloading Go from ${WH}${go_url}${RST}..."
    if curl -fsSL "$go_url" -o /tmp/go.tar.gz 2>/dev/null; then
        sudo rm -rf /usr/local/go 2>/dev/null || true
        sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        
        # Update PATH for current session
        export PATH="/usr/local/go/bin:$PATH"
        mkdir -p "${HOME}/go/bin"
        export PATH="${HOME}/go/bin:$PATH"
        
        log OK "Go installed successfully"
        return 0
    else
        log WARN "Failed to download Go"
        return 1
    fi
}

# Sync Go-based security tools
sync_security_tools() {
    local force_bg="${1:-false}"
    
    log INFO "Synchronizing Go-based security tools..."
    
    # Ensure Go PATH is set
    export GOPATH="${HOME}/go"
    export PATH="${GOPATH}/bin:/usr/local/go/bin:$PATH"
    
    # Map of tool → go install package
    declare -A GO_TOOLS=(
        ["nuclei"]="github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
        ["subfinder"]="github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
        ["anew"]="github.com/tomnomnom/anew@latest"
        ["ghauri"]="github.com/r0oth3x0r/ghauri@latest"
        ["arjun"]="github.com/s0md3v/arjun@latest"
        ["cloudkiller"]="github.com/hakluke/cloudkiller@latest"
    )
    
    # Helper function for synchronizing tools
    _sync_tools_impl() {
        for tool in "${!GO_TOOLS[@]}"; do
            if ! command -v "$tool" &>/dev/null; then
                log INFO "Installing ${WH}${tool}${RST} via go install..."
                if go install "${GO_TOOLS[$tool]}" 2>/dev/null; then
                    log OK "${tool} installed"
                    # Ensure tool is in local bin
                    if [[ -f "${GOPATH}/bin/${tool}" ]]; then
                        chmod +x "${GOPATH}/bin/${tool}"
                    fi
                else
                    log WARN "Failed to install ${tool}"
                fi
            fi
        done
    }
    
    if [[ "$force_bg" == "true" ]]; then
        # Run in background with nohup; redirect output to sync log to keep terminal clean
        local sync_log="/tmp/crimson_sync.log"
        nohup bash -c "
            export GOPATH='${GOPATH}'; export PATH='${PATH}'; \
            declare -A GO_TOOLS=( \
                ['nuclei']='github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest' \
                ['subfinder']='github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest' \
                ['anew']='github.com/tomnomnom/anew@latest' \
                ['ghauri']='github.com/r0oth3x0r/ghauri@latest' \
                ['arjun']='github.com/s0md3v/arjun@latest' \
                ['cloudkiller']='github.com/hakluke/cloudkiller@latest' \
            ); \
            for tool in "\${!GO_TOOLS[@]}"; do \
                [[ ! \$(command -v \$tool 2>/dev/null) ]] && go install "\${GO_TOOLS[\$tool]}" 2>>"${sync_log}" && chmod +x \${GOPATH}/bin/\$tool 2>>"${sync_log}" || true; \
            done
        " >"${sync_log}" 2>&1 &
        local sync_pid=$!
        register_pid $! 2>/dev/null || true
        log OK "Tool sync started in background (PID: ${WH}${sync_pid}${RST}); logs: ${WH}${sync_log}${RST}"
    else
        _sync_tools_impl
    fi
}

# Lazy-load tool before phase execution
lazy_install_tool() {
    local tool="$1"
    
    if command -v "$tool" &>/dev/null; then
        return 0
    fi
    
    log WARN "${WH}${tool}${RST} not found. Attempting just-in-time installation..."
    
    export GOPATH="${HOME}/go"
    export PATH="${GOPATH}/bin:/usr/local/go/bin:$PATH"
    
    declare -A TOOL_PACKAGES=(
        ["nuclei"]="github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
        ["subfinder"]="github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
        ["anew"]="github.com/tomnomnom/anew@latest"
        ["ghauri"]="github.com/r0oth3x0r/ghauri@latest"
        ["arjun"]="github.com/s0md3v/arjun@latest"
        ["cloudkiller"]="github.com/hakluke/cloudkiller@latest"
    )
    
    if [[ -n "${TOOL_PACKAGES[$tool]:-}" ]]; then
        if go install "${TOOL_PACKAGES[$tool]}" 2>/dev/null; then
            log OK "${tool} installed just-in-time"
            export PATH="${GOPATH}/bin:$PATH"
            return 0
        fi
    fi
    
    log ERROR "Could not install ${tool}. Phase may fail."
    return 1
}

# Arjun Deep JIT Recovery Installer (pipx method for Parrot/Debian)
install_arjun_jit() {
    log WARN "Arjun missing. Installing via pipx..."

    # 1. Ensure pipx is available (apt update first, exactly like manual install)
    if ! command -v pipx &>/dev/null; then
        sudo apt update -qq 2>/dev/null || true
        sudo apt install -y pipx 2>/dev/null || true
        pipx ensurepath 2>/dev/null || true
        export PATH="$PATH:$HOME/.local/bin"
    fi

    # 2. Install arjun via pipx (creates its own venv + puts binary in ~/.local/bin)
    pipx install arjun 2>/dev/null || true
    export PATH="$PATH:$HOME/.local/bin"

    # 3. Verify
    if command -v arjun &>/dev/null; then
        log OK "Arjun successfully installed via pipx."
        return 0
    else
        log ERR "Arjun installation failed. Manual: sudo apt install -y pipx && pipx install arjun"
        return 1
    fi
}

# Universal environment bootstrap
bootstrap_env() {
    local distro; distro=$(detect_distro)
    
    log PHASE "🔧 Universal Bootstrap: Initializing ${WH}${distro}${RST} environment..."
    
    # Check if sudo is available and necessary
    local needs_sudo=false
    if [[ "$(whoami)" != "root" ]] && ! sudo -n true 2>/dev/null; then
        log WARN "This system may require ${WH}sudo${RST} for package installation"
        log WARN "Run with ${WH}sudo${RST} or configure passwordless sudo for better experience"
        needs_sudo=true
    fi
    
    # Install core dependencies
    install_core_tools "$distro"
    
    # Install or verify Go
    if ! command -v go &>/dev/null; then
        if [[ "$needs_sudo" == "true" ]]; then
            log WARN "Go not installed and sudo required. Skipping Go installation."
            log INFO "Install manually: ${WH}sudo apt-get install golang-go${RST} (or equivalent)"
        else
            install_golang
        fi
    else
        log OK "Go environment ready"
    fi
    
    # Sync Go tools (background mode for non-blocking startup)
    sync_security_tools "true"
    
    log OK "Bootstrap complete. Tools syncing in background..."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  §SYSTEM AUDIT: Enhanced startup verification and auto-provisioning
# ═══════════════════════════════════════════════════════════════════════════════

bootstrap_system() {
    local distro; distro=$(detect_distro)
    local pm; pm=$(get_package_manager "$distro")
    
    log PHASE "🔧 OS-AWARE BOOTSTRAP: Detecting environment and provisioning tools..."
    log PHASE "Detected: ${WH}${distro}${RST} | Package Manager: ${WH}${pm}${RST}"
    
    # Start environment bootstrap in background (tool sync will log to /tmp/crimson_sync.log)
    bootstrap_env > /tmp/crimson_sync.log 2>&1 &
    local bootstrap_pid=$!
    # Register background PID for cleanup tracking
    [[ -n "${bootstrap_pid}" ]] && register_pid "${bootstrap_pid}" 2>/dev/null || true
    
    # Important: Do NOT wait for bootstrap - framework proceeds immediately
    # Bootstrap and tool installation continue silently in the background
    # This enables operator to start targeting while tools still install
    log OK "System provisioning running in background (PID: ${WH}${bootstrap_pid}${RST}); sync log: /tmp/crimson_sync.log"
    log OK "Framework ready for targeting while tools sync..."
    return 0
}
