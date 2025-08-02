#!/bin/bash

#
# Description: Utility functions for logging, validation, and system checks.

# Log a message with a given log level, with log rotation
log_message() {
    local level=$1
    local message=$2

    # Log rotation check
    if [ -f "$LOG_FILE" ] && [ $(du -k "$LOG_FILE" | cut -f1) -ge "$LOG_MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi

    # Respect log level
    case "$LOG_LEVEL" in
        ERROR) [[ "$level" != "ERROR" ]] && return ;;
        WARNING) [[ "$level" != "ERROR" && "$level" != "WARNING" ]] && return ;;
        INFO) [[ "$level" == "DEBUG" ]] && return ;;
        DEBUG) ;;
        *) ;;
    esac

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "${LOG_FILE}"
}

# Sanitize user input to prevent command injection
santize_input() {
    local input="$1"
    # Allow numbers, letters, hyphens, and underscores
    echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
}

# Create necessary directories for the script
setup_directories() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
}

# Detect the operating system and package manager
detect_system() {
    if command -v apt-get &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="unknown"
    fi
    
    # Detect the persistence method
    if command -v netfilter-persistent &> /dev/null; then
        PERSISTENT_METHOD="netfilter-persistent"
    elif command -v service &> /dev/null && [ -f "/etc/init.d/iptables" ]; then
        PERSISTENT_METHOD="service"
    elif command -v systemctl &> /dev/null; then
        PERSISTENT_METHOD="systemd"
    else
        PERSISTENT_METHOD="manual"
    fi
    
    log_message "INFO" "System detected: PM=$PACKAGE_MANAGER, Persistence=$PERSISTENT_METHOD"
}

# Check if the script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}"
        echo -e "Try with: ${YELLOW}sudo $0${NC}"
        exit 1
    fi
}

# Check for required dependencies
check_dependencies() {
    local missing_deps=()
    local required_commands=("iptables" "iptables-save" "ss" "grep" "awk" "sed")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing dependencies: ${missing_deps[*]}${NC}"
        echo -e "Attempting to install automatically..."
        install_dependencies "${missing_deps[@]}"
    fi
    
    if ! iptables -t nat -L >/dev/null 2>&1; then
        echo -e "${RED}Error: iptables NAT table is not available. Try loading the module: ${YELLOW}modprobe iptable_nat${NC}"
        exit 1
    fi
}

# Install dependencies automatically
install_dependencies() {
    local deps=S("$@")
    case $PACKAGE_MANAGER in
        "apt")
            apt-get update && apt-get install -y "${deps[@]}"
            ;;
        "yum"|"dnf")
            $PACKAGE_MANAGER install -y "${deps[@]}"
            ;;
        "pacman")
            pacman -S --noconfirm "${deps[@]}"
            ;;
        *)
            echo -e "${RED}Cannot install dependencies automatically. Please install them manually: ${deps[*]}${NC}"
            exit 1
            ;;
    esac
}

# Validate a port number
validate_port() {
    local port=$1
    local port_name=$2
    
    port=$(sanitize_input "$port")
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: $port_name must be a number.${NC}"
        return 1
    fi
    
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Error: $port_name must be between 1-65535.${NC}"
        return 1
    fi
    
    if [ "$port" -lt 1024 ]; then
        echo -e "${YELLOW}Warning: Port $port is a system reserved port.${NC}"
    fi
    
    return 0
}

# Check if a port is in use
check_port_in_use() {
    local port=$1
    local detailed=${2:-false}
    
    if ss -ulnp | grep -q ":$port "; then
        if [ "$detailed" = true ]; then
            local process_info=$(ss -ulnp | grep ":$port " | awk '{print $6}')
            echo -e "${YELLOW}Warning: Port $port is already in use by $process_info${NC}"
        else
            echo -e "${YELLOW}Warning: Port $port may be in use.${NC}"
        fi
        return 0
    fi
    return 1
}

# Check for port conflicts in existing iptables rules
check_port_conflicts() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    
    local conflicts=$(iptables -t nat -L PREROUTING -n | grep -E "dpt:($start_port|$end_port|$service_port)([^0-9]|$)")
    
    if [ -n "$conflicts" ]; then
        echo -e "${YELLOW}Potential port conflicts found:${NC}"
        echo "$conflicts"
        return 1
    fi
    
    return 0
}

# Handle iptables errors with detailed feedback
handle_iptables_error() {
    local exit_code=$1
    local operation=$2
    
    case $exit_code in
        0) return 0 ;;
        1) echo -e "${RED}iptables Error: General error or permission issue.${NC}" ;;
        2) echo -e "${RED}iptables Error: Protocol does not exist or is not supported.${NC}" ;;
        3) echo -e "${RED}iptables Error: Invalid parameter or option.${NC}" ;;
        4) echo -e "${RED}iptables Error: Resource problem.${NC}" ;;
        *) echo -e "${RED}iptables Error: Unknown error (Code: $exit_code)${NC}" ;;
    esac
    
    log_message "ERROR" "iptables $operation failed with exit code $exit_code"
    
    echo -e "${YELLOW}Suggestions:${NC}"
    echo "1. Verify root privileges."
    echo "2. Check if the iptables service is running."
    echo "3. Ensure kernel modules (e.g., iptable_nat) are loaded."
    echo "4. For more details, run: dmesg | tail"
    
    return $exit_code
}