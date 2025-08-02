#!/bin/bash

# libs/lib_ui.sh
#
# User interface functions for Port Mapping Manager

source "$(dirname "$0")/lib_utils.sh"

# --- Rule Display ---
show_current_rules() {
    echo -e "${C_BLUE}--- Current Port Mappings ---${C_RESET}"

    local rules_output_v4
    rules_output_v4=$(iptables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null)
    local rules_output_v6
    if command -v ip6tables &>/dev/null; then
        rules_output_v6=$(ip6tables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null)
    fi

    echo -e "${C_CYAN}Managed by this script (from config):${C_RESET}"
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo "  (No configured rules)"
    else
        printf "%-5s %-10s %-15s %-15s %-12s\n" "Ver" "Protocol" "From Port" "To Port" "Status"
        for mapping in "${MAPPINGS[@]}"; do
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping"
            local display_status
            if [[ "$status" == "enabled" ]]; then
                display_status="${C_GREEN}Enabled${C_RESET}"
            else
                display_status="${C_RED}Disabled${C_RESET}"
            fi
            printf "%-5s %-10s %-15s %-15s %-12s\n" "IPv$ip_version" "$proto" "$from_port" "$to_port" "$display_status"
        done
    fi

    echo -e "\n${C_CYAN}All IPv4 PREROUTING rules found on system:${C_RESET}"
    if [ -z "$rules_output_v4" ]; then
        echo "  (No IPv4 NAT rules found)"
    else
        echo "$rules_output_v4"
    fi

    if command -v ip6tables &>/dev/null; then
        echo -e "\n${C_CYAN}All IPv6 PREROUTING rules found on system:${C_RESET}"
        if [ -z "$rules_output_v6" ]; then
            echo "  (No IPv6 NAT rules found)"
        else
            echo "$rules_output_v6"
        fi
    fi

    echo -e "${C_BLUE}--- End of List ---${C_RESET}"
}

# --- Menus ---
show_main_menu() {
    echo -e "\n${C_PURPLE}--- Port Mapping Manager ---${C_RESET}"
    echo "1. Show Current Rules" 
    echo "2. Add New Mapping"
    echo "3. Enable/Disable a Mapping"
    echo "4. Delete a Mapping"
    echo "5. Backup & Restore"
    echo "6. Bulk Operations"
    echo "7. System Diagnostics"
    echo "8. Uninstall Script"
    echo "h. Help"
    echo "q. Quit"
    read -p "Enter your choice: " choice
    echo
}

show_backup_menu() {
    echo -e "\n${C_PURPLE}--- Backup & Restore Menu ---${C_RESET}"
    echo "1. Create a New Backup"
    echo "2. List All Backups"
    echo "3. Restore from a Backup"
    echo "4. Clean Old Backups"
    echo "5. Reset All iptables Rules"
    echo "b. Back to Main Menu"
    read -p "Enter your choice: " backup_choice
    echo
}

show_batch_menu() {
    echo -e "\n${C_PURPLE}--- Bulk Operations Menu ---${C_RESET}"
    echo "1. Import Rules from File"
    echo "2. Export Managed Rules to File"
    echo "b. Back to Main Menu"
    read -p "Enter your choice: " batch_choice
    echo
}

# --- Help and Info ---
show_enhanced_help() {
    echo -e "${C_BLUE}Port Mapping Manager - Help${C_RESET}"
    echo "This script helps you manage iptables REDIRECT rules for port forwarding."
    echo
    echo -e "${C_YELLOW}Features:${C_RESET}"
    echo "- ${C_GREEN}Show Rules:${C_RESET} Displays rules from this script's config and all system NAT rules."
    echo "- ${C_GREEN}Add/Delete:${C_RESET} Guides you to add or remove specific mapping rules."
    echo "- ${C_GREEN}Enable/Disable:${C_RESET} Dynamically activate or deactivate rules without deleting them."
    echo "- ${C_GREEN}Backup/Restore:${C_RESET} Save your entire iptables state and restore it later."
    echo "- ${C_GREEN}Bulk Import:${C_RESET} Add multiple rules from a simple text file."
    echo "- ${C_GREEN}Diagnostics:${C_RESET} Provides a quick overview of your system's network state."
    echo
    echo -e "${C_YELLOW}Bulk Import File Format:${C_RESET}"
    echo "Create a text file with each line in the format: ${C_CYAN}ip_version,protocol,from_port,to_port,status${C_RESET}"
    echo "The 'status' field is optional and can be 'enabled' or 'disabled'. Defaults to 'enabled'."
    echo "Example:"
    echo "4,udp,8001,9001,enabled"
    echo "6,tcp,8002,9002,disabled"
    echo "4,tcp,8080,80"
}

show_version() {
    echo "Port Mapping Manager (PMM) - Version 4.0 (Modular)"
}