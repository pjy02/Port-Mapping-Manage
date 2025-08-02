#!/bin/bash

# libs/lib_core.sh
#
# Core logic for Port Mapping Manager

source "$(dirname "$0")/lib_utils.sh"
source "$(dirname "$0")/lib_iptables.sh"

# --- Configuration Management ---
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        log_message "INFO" "Configuration loaded from $CONFIG_FILE"
    else
        echo -e "${C_YELLOW}Configuration file not found. A new one will be created with default values.${C_RESET}"
        # Set default values
        MAPPINGS=()
        log_message "INFO" "No config file found, using default empty configuration."
    fi
}

save_config() {
    # This function needs to be carefully implemented to save the MAPPINGS array correctly
    # to the config file.
    echo "# Port Mapping Manager Configuration" > "$CONFIG_FILE"
    echo "# Auto-generated on $(date)" >> "$CONFIG_FILE"
    for mapping in "${MAPPINGS[@]}"; do
        echo "MAPPINGS+=('$mapping')" >> "$CONFIG_FILE"
    done
    log_message "INFO" "Configuration saved to $CONFIG_FILE"
}

# --- Rule Management Logic ---
setup_mapping() {
    local ip_version proto from_port to_port validation_status

    read -p "Enter IP version (4 for IPv4, 6 for IPv6): " ip_version
    if [[ "$ip_version" != "4" && "$ip_version" != "6" ]]; then
        echo -e "${C_RED}Invalid IP version. Please enter '4' or '6'.${C_RESET}"
        return
    fi
    if [[ "$ip_version" == "6" ]] && ! command -v ip6tables &>/dev/null; then
        echo -e "${C_RED}ip6tables command not found. Cannot manage IPv6 rules.${C_RESET}"
        return
    fi
    IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")

    read -p "Enter protocol (udp/tcp): " proto
    proto=$(echo "$proto" | tr '[:upper:]' '[:lower:]')
    if [[ "$proto" != "udp" && "$proto" != "tcp" ]]; then
        echo -e "${C_RED}Invalid protocol. Please enter 'udp' or 'tcp'.${C_RESET}"
        return
    fi

    read -p "Enter source port to map from (1-65535): " from_port
    validation_status=$(validate_port "$from_port" "$proto")
    if [[ "$validation_status" == "invalid" ]]; then
        echo -e "${C_RED}Invalid source port number.${C_RESET}"
        return
    elif [[ "$validation_status" == "listening" ]]; then
        echo -e "${C_RED}Error: Source port $from_port is already in use.${C_RESET}"
        return
    elif [[ "$validation_status" == "reserved" ]]; then
        echo -e "${C_YELLOW}Warning: Source port $from_port is in the system-reserved range (< 1024).${C_RESET}"
    fi

    read -p "Enter destination port to map to (1-65535): " to_port
    validation_status=$(validate_port "$to_port")
    if [[ "$validation_status" == "invalid" ]]; then
        echo -e "${C_RED}Invalid destination port number.${C_RESET}"
        return
    fi

    if [[ "$from_port" == "$to_port" ]]; then
        echo -e "${C_RED}Source and destination ports cannot be the same.${C_RESET}"
        return
    fi

    echo -e "${C_YELLOW}You are about to add the following mapping:${C_RESET}"
    echo -e "  Version:   ${C_CYAN}IPv$ip_version${C_RESET}"
    echo -e "  Protocol:  ${C_CYAN}$proto${C_RESET}"
    echo -e "  From Port: ${C_CYAN}$from_port${C_RESET}"
    echo -e "  To Port:   ${C_CYAN}$to_port${C_RESET}"
    read -p "Confirm? (y/n): " confirm

    if [[ "$confirm" == "y" ]]; then
        backup_rules # Auto-backup before making changes
        if add_iptables_rule "$proto" "$from_port" "$to_port"; then
            MAPPINGS+=("$ip_version:$proto:$from_port:$to_port:enabled") # Add status
            save_config
            read -p "Do you want to make this rule persistent across reboots? (y/n): " persist
            if [[ "$persist" == "y" ]]; then
                save_rules_persistent "adding new rule"
            fi
        fi
    else
        echo "Operation cancelled."
    fi
}

delete_specific_rule() {
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}No managed mapping rules to delete.${C_RESET}"
        return
    fi

    echo -e "${C_PURPLE}Select a rule to PERMANENTLY delete:${C_RESET}"
    select mapping_choice in "${MAPPINGS[@]}" "Cancel"; do
        if [[ "$mapping_choice" == "Cancel" ]]; then
            echo "Cancelled."
            break
        fi
        if [ -n "$mapping_choice" ]; then
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping_choice"
            
            IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")

            # Even if the rule is 'disabled', we must ensure it's removed from iptables
            # because a disabled rule might not be in iptables, and that's okay.
            disable_iptables_rule "$proto" "$from_port" "$to_port" # Ensure it's not active
            
            # Remove from array
            local new_mappings=()
            for item in "${MAPPINGS[@]}"; do
                [[ "$item" != "$mapping_choice" ]] && new_mappings+=("$item")
            done
            MAPPINGS=("${new_mappings[@]}")
            save_config
            echo -e "${C_GREEN}Rule '$mapping_choice' permanently removed from configuration.${C_RESET}"
            
            read -p "Do you want to save the rule deletion permanently (update persistent rules)? (y/n): " persist
            if [[ "$persist" == "y" ]]; then
                save_rules_persistent "deleting rule"
            fi
            break
        else
            echo -e "${C_RED}Invalid selection.${C_RESET}"
        fi
    done
}

toggle_rule_menu() {
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}No managed mapping rules to toggle.${C_RESET}"
        return
    fi

    echo -e "${C_PURPLE}Select a rule to enable/disable:${C_RESET}"
    # Adding an index to the select prompt for clarity
    local options=()
    for i in "${!MAPPINGS[@]}"; do
        options+=("$((i+1))) ${MAPPINGS[$i]}")
    done
    options+=("Cancel")

    select choice in "${options[@]}"; do
        if [[ "$choice" == "Cancel" ]]; then
            echo "Cancelled."
            break
        fi
        
        # Extract the index from the choice string
        local index=$(echo "$choice" | awk '{print $1}' | sed 's/)//')
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#MAPPINGS[@]} ]; then
            local selected_mapping_index=$((index - 1))
            local mapping=${MAPPINGS[$selected_mapping_index]}
            
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping"
            IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")
            
            if toggle_rule_status "$proto" "$from_port" "$to_port" "$status"; then
                # Update status in the array
                local new_status=$([[ "$status" == "enabled" ]] && echo "disabled" || echo "enabled")
                MAPPINGS[$selected_mapping_index]="$ip_version:$proto:$from_port:$to_port:$new_status"
                save_config
                echo -e "${C_GREEN}Rule status updated in configuration.${C_RESET}"
            else
                echo -e "${C_RED}Failed to toggle rule status. Configuration not changed.${C_RESET}"
            fi
            break
        else
            echo -e "${C_RED}Invalid selection.${C_RESET}"
        fi
    done
}

# --- Bulk Operations ---
bulk_import_from_file() {
    read -e -p "Enter the full path to the import file: " import_file
    import_file=$(sanitize_input "$import_file")

    if [ ! -f "$import_file" ]; then
        echo -e "${C_RED}Error: File not found: '$import_file'${C_RESET}"
        return
    fi

    backup_rules # Backup before large change
    local success_count=0
    local fail_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Expected format: ip_version,protocol,from_port,to_port,status (e.g., 4,udp,8080,8081,enabled)
        line=$(echo "$line" | tr -d '[:space:]') # remove whitespace
        if [[ -z "$line" || "$line" == \#* ]]; then continue; fi # Skip empty/commented lines

        IFS=',' read -r ip_version proto from_port to_port status <<<"$line"
        status=${status:-enabled} # Default to enabled if status is missing
        if [[ -z "$ip_version" || -z "$proto" || -z "$from_port" || -z "$to_port" ]]; then
            log_message "ERROR" "Bulk import skipping invalid line: $line"
            ((fail_count++))
            continue
        fi

        local port_valid
        port_valid=$(validate_port "$from_port" "$proto")
        if [[ "$port_valid" == "invalid" || "$port_valid" == "listening" ]]; then
            log_message "ERROR" "Bulk import skipping rule for invalid/used source port: $from_port ($proto)"
            ((fail_count++))
            continue
        fi

        port_valid=$(validate_port "$to_port")
        if [[ "$port_valid" == "invalid" ]]; then
            log_message "ERROR" "Bulk import skipping rule for invalid destination port: $to_port"
            ((fail_count++))
            continue
        fi

        IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")
        # Only try to add the rule to iptables if it's marked as enabled
        local rule_added=true
        if [[ "$status" == "enabled" ]]; then
            if ! add_iptables_rule "$proto" "$from_port" "$to_port"; then
                rule_added=false
            fi
        fi

        if [ "$rule_added" = true ]; then
            MAPPINGS+=("$ip_version:$proto:$from_port:$to_port:$status")
            ((success_count++))
        else
            ((fail_count++))
        fi
        else
             echo -e "${C_RED}Skipping invalid line: $line${C_RESET}"
            ((fail_count++))
        fi
    done < "$import_file"

    save_config
    echo -e "${C_GREEN}Bulk import completed. Successfully added: $success_count. Failed: $fail_count.${C_RESET}"
    if [ $success_count -gt 0 ]; then
        read -p "Do you want to save these new rules permanently? (y/n): " persist
        if [[ "$persist" == "y" ]]; then
            save_rules_persistent "bulk import"
        fi
    fi
}

# --- Diagnostics ---
diagnose_system() {
    echo -e "${C_BLUE}--- System Diagnostics ---${C_RESET}"
    echo "- Kernel: $(uname -r)"
    echo "- iptables version: $(iptables --version)"
    if command -v ip6tables &>/dev/null; then
        echo "- ip6tables version: $(ip6tables --version)"
    fi
    echo "- Detected Package Manager: $(detect_package_manager)"
    echo "- Detected Persistence: $(detect_persistence_method)"

    echo -e "\n${C_BLUE}--- Listening Ports (TCP/UDP) ---${C_RESET}"
    ss -tuln

    echo -e "\n${C_BLUE}--- Current IPv4 NAT Rules ---${C_RESET}"
    iptables -t nat -L -n -v

    if command -v ip6tables &>/dev/null; then
        echo -e "\n${C_BLUE}--- Current IPv6 NAT Rules ---${C_RESET}"
        ip6tables -t nat -L -n -v
    fi

    echo -e "${C_BLUE}--- Diagnostics Complete ---${C_RESET}"
}

# --- Cleanup ---
uninstall_script() {
    echo -e "${C_RED}This will remove all managed rules, config files, and the script itself.${C_RESET}"
    read -p "Are you sure you want to uninstall? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then echo "Uninstall cancelled."; return; fi

    # Remove rules
    for mapping in "${MAPPINGS[@]}"; do
        IFS=':' read -r ip_version proto from_port to_port <<< "$mapping"
        if [[ "$ip_version" == "6" ]]; then
            IPTABLES_COMMAND="ip6tables"
        else
            IPTABLES_COMMAND="iptables"
        fi
        delete_iptables_rule "$proto" "$from_port" "$to_port"
    done

    read -p "Save rule deletions permanently? (y/n): " save_confirm
    if [[ "$save_confirm" == "y" ]]; then save_rules_persistent "uninstalling"; fi

    # Remove files
    rm -rf "$CONFIG_DIR"
    rm -f "$LOG_FILE"
    rm -f /usr/local/bin/pmm
    rm -f /usr/local/bin/port_mapping_manager.sh

    echo -e "${C_GREEN}Port Mapping Manager has been uninstalled.${C_RESET}"
}