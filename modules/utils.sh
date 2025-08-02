#!/bin/bash

# Source necessary modules
source "c:\program user\trae\Port-Mapping-Manage\modules\config.sh"

# Log messages
log_message() {
    local type=$1
    local message=$2
    local log_line="$(date '+%Y-%m-%d %H:%M:%S') - [$type] - $message"
    echo -e "$log_line" >> "$LOG_FILE"
    if [ "$type" == "ERROR" ]; then
        echo -e "${RED}[$type] $message${NC}" >&2
    elif [ "$VERBOSE_MODE" == true ]; then
        echo -e "${GREEN}[$type] $message${NC}"
    fi
}

# Sanitize input
sanatize_input() {
    echo "$1" | sed 's/[^a-zA-Z0-9_.-]//g'
}

# Setup directories
setup_directories() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"
}

# Detect system and package manager
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ $ID == "ubuntu" || $ID == "debian" ]]; then
            PACKAGE_MANAGER="apt-get"
        elif [[ $ID == "centos" || $ID == "rhel" || $ID == "fedora" ]]; then
            PACKAGE_MANAGER="yum"
        fi
    fi
    if [ -z "$PACKAGE_MANAGER" ]; then
        log_message "ERROR" "Unsupported Linux distribution."
        exit 1
    fi
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_message "ERROR" "This script must be run as root."
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local dependencies=("iptables" "curl")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_message "WARNING" "Dependency '$dep' not found. Attempting to install."
            install_dependencies "$dep"
        fi
    done
}

# Install dependencies
install_dependencies() {
    log_message "INFO" "Using $PACKAGE_MANAGER to install $@"
    if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
        sudo apt-get update && sudo apt-get install -y "$@"
    elif [ "$PACKAGE_MANAGER" == "yum" ]; then
        sudo yum install -y "$@"
    fi
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to install dependencies: $@"
        exit 1
    fi
}

# Validate port number
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_message "ERROR" "Invalid port number: $port. Must be between 1 and 65535."
        return 1
    fi
    return 0
}

# Check if a port is in use
check_port_in_use() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        log_message "WARNING" "Port $port is currently in use by another service."
        return 0
    fi
    return 1
}

# Check for port conflicts in iptables rules
check_port_conflicts() {
    local port=$1
    if iptables -t nat -L PREROUTING -n | grep -q -- "--dports $port"; then
        log_message "ERROR" "Port $port is already used in another mapping rule."
        return 1
    fi
    return 0
}

# Format bytes to human-readable format
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(($bytes/1024))KB"
    else
        echo "$(($bytes/1048576))MB"
    fi
}