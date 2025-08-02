#!/bin/bash

# Source necessary modules
# source "./config.sh"
# source "./utils.sh"

# Enhanced Help Information
show_enhanced_help() {
    echo -e "${BLUE}Port-Mapping-Manager v${SCRIPT_VERSION} - Help Center${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo -e "${YELLOW}Usage:${NC} pmm.sh [command] [options]"
    echo
    echo -e "${GREEN}Available Commands:${NC}"
    echo -e "  ${PURPLE}menu${NC}             - Show the interactive main menu (default)"
    echo -e "  ${PURPLE}add${NC}              - Add a new port mapping rule"
    echo -e "  ${PURPLE}delete${NC}           - Delete an existing port mapping rule"
    echo -e "  ${PURPLE}list${NC}             - List all active port mapping rules"
    echo -e "  ${PURPLE}monitor${NC}          - Monitor traffic for a specific rule"
    echo -e "  ${PURPLE}backup${NC}           - Create a backup of the current iptables rules"
    echo -e "  ${PURPLE}restore${NC}          - Restore iptables rules from a backup"
    echo -e "  ${PURPLE}diagnose${NC}         - Run a system and configuration diagnostic check"
    echo -e "  ${PURPLE}help${NC}             - Display this help message"
    echo -e "  ${PURPLE}version${NC}          - Show script version"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${PURPLE}-v, --verbose${NC}    - Enable verbose logging for the current session"
    echo
    echo -e "${CYAN}For more detailed information, please visit our documentation or run the interactive menu.${NC}"
}

# Show script version
show_version() {
    echo -e "${BLUE}Port-Mapping-Manager version ${SCRIPT_VERSION}${NC}"
}

# Main Menu
show_main_menu() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${CYAN}    Port-Mapping-Manager v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e " ${YELLOW}1) Show Current Rules & Traffic${NC}"
    echo -e " ${YELLOW}2) Add New Port Mapping${NC}"
    echo -e " ${YELLOW}3) Delete a Specific Rule${NC}"
    echo -e " ${YELLOW}4) Batch Operations Menu${NC}"
    echo -e " ${YELLOW}5) Backup & Restore Menu${NC}"
    echo -e " ${YELLOW}6) System Diagnostics & Monitoring${NC}"
    echo -e " ${YELLOW}7) Restore Default iptables (Clean Slate)${NC}"
    echo -e " ${YELLOW}8) Uninstall Script${NC}"
    echo -e " ${RED}9) Exit${NC}"
    echo -e "${BLUE}------------------------------------${NC}"
    echo -en "${GREEN}Please select an option [1-9]: ${NC}"
}

# Batch Operations Menu
show_batch_menu() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${CYAN}        Batch Operations Menu${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e " ${YELLOW}1) Import Rules from File${NC}"
    echo -e " ${YELLOW}2) Export Current Rules to File${NC}"
    echo -e " ${YELLOW}3) Create Sample Config File${NC}"
    echo -e " ${RED}4) Back to Main Menu${NC}"
    echo -e "${BLUE}------------------------------------${NC}"
    echo -en "${GREEN}Please select an option [1-4]: ${NC}"
}

# Backup Management Menu
show_backup_menu() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${CYAN}      Backup & Restore Menu${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e " ${YELLOW}1) Create a New Backup${NC}"
    echo -e " ${YELLOW}2) List Available Backups${NC}"
    echo -e " ${YELLOW}3) Restore from a Backup${NC}"
    echo -e " ${YELLOW}4) Clean Up Old Backups${NC}"
    echo -e " ${RED}5) Back to Main Menu${NC}"
    echo -e "${BLUE}------------------------------------${NC}"
    echo -en "${GREEN}Please select an option [1-5]: ${NC}"
}

# Port Presets Menu
show_port_presets() {
    echo -e "${CYAN}Available Port Presets:${NC}"
    for i in "${!PRESET_RANGES[@]}"; do
        echo -e "  ${PURPLE}${i}) ${PRESET_RANGES[$i]}${NC}"
    done
    echo -en "${GREEN}Choose a preset or press Enter to skip: ${NC}"
}