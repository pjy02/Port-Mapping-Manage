#!/bin/bash

# Source necessary modules
source "c:\program user\trae\Port-Mapping-Manage\modules\config.sh"
source "c:\program user\trae\Port-Mapping-Manage\modules\utils.sh"

# Show current iptables rules for UDP mapping
show_current_rules() {
    echo -e "${BLUE}Current UDP Port Mapping Rules:${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers | grep "$RULE_COMMENT"
    echo -e "${BLUE}Current Traffic Statistics:${NC}"
    iptables -t nat -L PREROUTING -nvx | grep "$RULE_COMMENT"
}

# Check if a rule is active
check_rule_active() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    iptables -t nat -C PREROUTING -p udp --dport "$start_port:$end_port" -j DNAT --to-destination ":$service_port" -m comment --comment "$RULE_COMMENT" &>/dev/null
}

# Show traffic statistics for a rule
show_traffic_stats() {
    local start_port=$1
    local end_port=$2

    echo -e "${BLUE}Traffic Statistics for ${start_port}-${end_port}:${NC}"
    local stats=$(iptables -t nat -L PREROUTING -nvx | grep "dports ${start_port}:${end_port}")
    if [ -n "$stats" ]; then
        local packets=$(echo "$stats" | awk '{print $1}')
        local bytes=$(echo "$stats" | awk '{print $2}')
        echo -e "  ${GREEN}Packets: ${packets}${NC}"
        echo -e "  ${GREEN}Bytes: $(format_bytes "$bytes")${NC}"
    else
        echo -e "${YELLOW}No active rule found for this port range.${NC}"
    fi
}

# Setup a new port mapping
setup_mapping() {
    read -p "Enter the starting port of the connection range: " start_port
    read -p "Enter the ending port of the connection range: " end_port
    read -p "Enter the service port: " service_port
    add_mapping_rule "$start_port" "$end_port" "$service_port"
}

# Add a port mapping rule
add_mapping_rule() {
    local start_port=$1
    local end_port=$2
    local service_port=$3

    if ! validate_port "$start_port" || ! validate_port "$end_port" || ! validate_port "$service_port"; then return 1; fi
    if check_port_conflicts "$start_port:$end_port"; then return 1; fi

    log_message "INFO" "Adding rule: map $start_port-$end_port to $service_port"
    iptables -t nat -A PREROUTING -p udp --dport "$start_port:$end_port" -j DNAT --to-destination ":$service_port" -m comment --comment "$RULE_COMMENT"
    handle_iptables_error "Failed to add rule for $start_port-$end_port"
    save_mapping_config "$start_port" "$end_port" "$service_port"
    save_rules
}

# Batch import rules from a file
batch_import_rules() {
    read -p "Enter the full path to the import file: " import_file
    if [ ! -f "$import_file" ]; then
        log_message "ERROR" "Import file not found: $import_file"
        return
    fi
    while IFS=, read -r start_port end_port service_port; do
        add_mapping_rule "$start_port" "$end_port" "$service_port"
    done < "$import_file"
    log_message "INFO" "Batch import completed."
}

# Batch export rules to a file
batch_export_rules() {
    local export_file="$CONFIG_DIR/exported_rules_$(date +%F).csv"
    iptables -t nat -L PREROUTING -n | grep "$RULE_COMMENT" | awk -F 'dports | to::' '{print $2 "," $3}' | sed 's/:/ /' > "$export_file"
    log_message "INFO" "Rules exported to $export_file"
}

# Backup current iptables rules
backup_rules() {
    local backup_file="$BACKUP_DIR/iptables-backup-$(date +%F_%T).rules"
    iptables-save > "$backup_file"
    log_message "INFO" "iptables rules backed up to $backup_file"
    cleanup_old_backups
}

# Clean up old backups
cleanup_old_backups() {
    local file_count=$(ls -1 "$BACKUP_DIR" | wc -l)
    if [ "$file_count" -gt "$MAX_BACKUPS" ]; then
        local to_delete=$((file_count - MAX_BACKUPS))
        ls -t "$BACKUP_DIR" | tail -n "$to_delete" | xargs -I {} rm -- "$BACKUP_DIR/{}"
        log_message "INFO" "Cleaned up $to_delete old backups."
    fi
}

# Restore iptables rules from a backup
restore_from_backup() {
    list_backups
    read -p "Enter the full path of the backup file to restore: " backup_file
    if [ -f "$backup_file" ]; then
        iptables-restore < "$backup_file"
        log_message "INFO" "iptables rules restored from $backup_file"
    else
        log_message "ERROR" "Backup file not found."
    fi
}

# Check for persistent package
check_persistent_package() {
    if command -v iptables-persistent &> /dev/null; then
        PERSISTENT_METHOD="iptables-persistent"
    elif command -v netfilter-persistent &> /dev/null; then
        PERSISTENT_METHOD="netfilter-persistent"
    fi
}

# Create a systemd service for persistence
create_systemd_service() {
    cat > /etc/systemd/system/pmm-rules.service << EOF
[Unit]
Description=Port Mapping Manager Iptables Rules
Before=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pmm-rules.service
}

# Save rules persistently
save_rules() {
    if [ "$PERSISTENT_METHOD" == "iptables-persistent" ] || [ "$PERSISTENT_METHOD" == "netfilter-persistent" ]; then
        sudo netfilter-persistent save
        log_message "INFO" "Rules saved using netfilter-persistent."
    else
        iptables-save > /etc/iptables/rules.v4
        log_message "INFO" "Rules saved to /etc/iptables/rules.v4. Ensure you have a mechanism to load them on boot."
    fi
}


# Delete a specific rule by line number
delete_specific_rule() {
    show_current_rules
    read -p "Enter the line number of the rule to delete: " line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "Invalid line number."
        return
    fi
    iptables -t nat -D PREROUTING "$line_num"
    handle_iptables_error "Failed to delete rule at line $line_num"
    save_rules
}

# Handle iptables errors
handle_iptables_error() {
    if [ $? -ne 0 ]; then
        log_message "ERROR" "$1"
        return 1
    fi
    log_message "INFO" "Operation successful."
    return 0
}

# Uninstall the script and its configurations
uninstall_script() {
    read -p "Are you sure you want to uninstall the script and remove all configurations? [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY](es)?$ ]]; then
        remove_mapping_rules
        rm -rf "$CONFIG_DIR"
        rm -f "$LOG_FILE"
        rm -f "/usr/local/bin/pmm.sh"
        log_message "INFO" "Script uninstalled successfully."
        echo -e "${GREEN}Uninstallation complete.${NC}"
        exit 0
    fi
}

# Remove all mapping rules added by this script
remove_mapping_rules() {
    local line_numbers
    line_numbers=$(iptables -t nat -L PREROUTING --line-numbers | grep "$RULE_COMMENT" | awk '{print $1}' | sort -r)
    for num in $line_numbers; do
        iptables -t nat -D PREROUTING "$num"
    done
    log_message "INFO" "All mapping rules have been removed."
    save_rules
}