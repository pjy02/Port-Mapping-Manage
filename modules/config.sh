#!/bin/bash

# Script configuration
SCRIPT_VERSION="3.0"
RULE_COMMENT="udp-port-mapping-script-v3"
CONFIG_DIR="/etc/port_mapping_manager"
LOG_FILE="/var/log/udp-port-mapping.log"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# Color definitions
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Global variables
PACKAGE_MANAGER=""
PERSISTENT_METHOD=""
VERBOSE_MODE=false
AUTO_BACKUP=true

# Load configuration file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_message "INFO" "Configuration file loaded."
    else
        create_default_config
    fi
}

# Create a default configuration file
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# UDP Port Mapping Script Configuration
# Auto-backup settings
AUTO_BACKUP=true
# Maximum number of backup files
MAX_BACKUPS=10
# Verbose logging mode
VERBOSE_MODE=false
# Common port presets
PRESET_RANGES=("6000-7000:3000" "8000-9000:4000" "10000-11000:5000")
EOF
    log_message "INFO" "Created default configuration file."
}

# Save mapping configuration to a file
save_mapping_config() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    # Ensure the mappings file exists
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_DIR/mappings.conf"

    cat >> "$CONFIG_DIR/mappings.conf" << EOF
# Added on: $(date)
MAPPING_${timestamp}_START=$start_port
MAPPING_${timestamp}_END=$end_port
MAPPING_${timestamp}_SERVICE=$service_port
EOF
}