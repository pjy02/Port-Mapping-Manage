#!/bin/bash

#
# Description: Handles loading configuration files.

# Load configuration from the default path
load_config() {
    local config_file="${CONFIG_DIR}/pmm.conf"

    if [[ ! -f "$config_file" ]]; then
        create_default_config
    fi
    
    # Source the main config file to get all variables
    source "$config_file"
}

# Save mapping configurations
save_mapping_config() {
    echo "#!/bin/bash" > "$MAPPING_CONFIG_FILE"
    echo "# Auto-generated mapping configuration. Do not edit manually." >> "$MAPPING_CONFIG_FILE"
    iptables-save | grep -- "-m comment --comment \"$RULE_COMMENT\"" | sed -e 's/^-A/iptables -t nat -A/' >> "$MAPPING_CONFIG_FILE"
    chmod +x "$MAPPING_CONFIG_FILE"
    log_message "INFO" "Mapping configuration saved to $MAPPING_CONFIG_FILE"
}

# Create a default configuration file if one doesn't exist
create_default_config() {
    local config_file="${CONFIG_DIR}/pmm.conf"

    # Ensure the config directory exists
    mkdir -p "$(dirname "$config_file")"

    # Create the default config file
    cat > "$config_file" <<EOL
# Default configuration for Port-Mapping-Manage

# Directories
BACKUP_DIR=\"${CONFIG_DIR}/backups\"
LOG_DIR=\"/var/log\"

# Log file
LOG_FILE=\"${LOG_DIR}/port_mapping_manager.log\"

# Color codes
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[0;33m'
BLUE='\\033[0;34m'
NC='\\033[0m' # No Color
EOL

    # Load the newly created config
    source "$config_file"
}