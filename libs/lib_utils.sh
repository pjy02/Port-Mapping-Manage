#!/bin/bash

# libs/lib_utils.sh
#
# Utility functions for Port Mapping Manager

# --- Color Definitions ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'

# --- Global Variables ---
LOG_DIR="/var/log/port_mapping_manager"
LOG_FILE="$LOG_DIR/port_mapping_manager.log"
CONFIG_DIR="/etc/port_mapping_manager"
CONFIG_FILE="$CONFIG_DIR/port_mapping_manager.conf"
BACKUP_DIR="$CONFIG_DIR/backups"

# --- Logging ---
log_message() {
    local type=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp [$type] - $message"
    echo -e "$log_entry" >> "$LOG_FILE"
}

# --- Input Sanitization ---
sanitize_input() {
    local input=$1
    # Strict sanitization: Allow only alphanumeric, underscore, hyphen, dot.
    # Disallow path characters like '/' to prevent path traversal unless specifically handled.
    echo "$input" | sed 's/[^a-zA-Z0-9_.-]//g'
}

validate_ip_address() {
    local ip=$1
    local ip_type=$2 # "4" or "6"

    if [[ "$ip_type" == "4" ]]; then
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            IFS='.' read -r -a octets <<< "$ip"
            for octet in "${octets[@]}"; do
                if (( octet > 255 )); then
                    echo "invalid"
                    return
                fi
            done
            echo "valid"
        else
            echo "invalid"
        fi
    elif [[ "$ip_type" == "6" ]]; then
        # A simple regex for IPv6, not exhaustive but good enough for many cases.
        # For a truly robust validation, a more complex function or external tool is needed.
        if [[ $ip =~ ^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}$ || # 1:2:3:4:5:6:7:8
              $ip =~ ^([0-9a-fA-F]{1,4}:){1,7}:$ ||                  # 1::
              $ip =~ ^:(:[0-9a-fA-F]{1,4}){1,7}$ ||                 # ::2
              $ip =~ ^([0-9a-fA-F]{1,4}:){1,}(:[0-9a-fA-F]{1,4}){1,}$ ]]; then # 1::8 or 1:2::8 etc.
            echo "valid"
        else
            echo "invalid"
        fi
    else
        echo "invalid_type"
    fi
}

# --- System Detection ---
detect_package_manager() {
    if command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

detect_persistence_method() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        echo "netfilter-persistent"
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q iptables-persistent; then
        echo "systemd_iptables_persistent"
    elif command -v service >/dev/null 2>&1; then
        echo "service"
    elif command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
    else
        echo "manual"
    fi
}

# --- Prerequisite Checks ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}Error: This script must be run as root. Please use sudo.${C_RESET}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for dep in iptables grep awk sed; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${C_RED}Error: Missing critical dependencies: ${missing_deps[*]}.${C_RESET}"
        # Attempt to install
        local pm
        pm=$(detect_package_manager)
        if [ "$pm" != "unknown" ]; then
            echo -e "${C_YELLOW}Attempting to install missing packages using $pm...${C_RESET}"
            case $pm in
                apt) sudo apt-get update && sudo apt-get install -y iptables coreutils;;
                dnf) sudo dnf install -y iptables-services coreutils;;
                yum) sudo yum install -y iptables-services coreutils;;
                pacman) sudo pacman -Syu --noconfirm iptables coreutils;;
            esac
            # Re-check after install attempt
            for dep in "${missing_deps[@]}"; do
                if ! command -v "$dep" >/dev/null 2>&1; then
                     echo -e "${C_RED}Failed to install '$dep'. Please install it manually and rerun the script.${C_RESET}"
                     exit 1
                fi
            done
        else
            echo -e "${C_RED}Could not determine package manager. Please install the missing dependencies manually.${C_RESET}"
            exit 1
        fi
    fi
}

# --- Port Validation ---
validate_port() {
    local port=$1
    local protocol=$2 # Optional: tcp or udp

    if ! [[ $port =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "invalid"
        return
    fi

    # Check for system reserved ports, but allow user to proceed with caution.
    if [ "$port" -lt 1024 ]; then
        echo "reserved"
        # We return 'reserved' but don't exit, the calling function should handle this.
    fi

    # A more reliable check for listening ports using ss.
    # The regex `\s:$port(\s|$)` ensures we match the exact port number.
    local listen_check_cmd="ss -tln"
    if [[ "$protocol" == "udp" ]]; then
        listen_check_cmd="ss -uln"
    fi

    if $listen_check_cmd | awk '{print $5}' | grep -q -w ":$port"; then
        echo "listening"
        return
    fi

    echo "valid"
}

# --- Byte Formatter ---
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fK", b/1024}')"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fM", b/1048576}')"
    else
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fG", b/1073741824}')"
    fi
}