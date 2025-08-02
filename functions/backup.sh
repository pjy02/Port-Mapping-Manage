#!/bin/bash

#
# Description: Functions for backing up and restoring iptables rules.

# Backup current iptables rules
backup_rules() {
    local backup_file="$BACKUP_DIR/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
    
    if iptables-save > "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}✓ iptables rules backed up to: $backup_file${NC}"
        log_message "INFO" "Rules backup successful: $backup_file"
        
        # Clean up old backups
        cleanup_old_backups
        return 0
    else
        echo -e "${RED}✗ Backup failed${NC}"
        log_message "ERROR" "Rules backup failed"
        return 1
    fi
}

# Clean up old backups, keeping the most recent ones
cleanup_old_backups() {
    local max_backups=${MAX_BACKUPS:-10}
    local backup_count=$(ls -1 "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null | wc -l)
    
    if [ "$backup_count" -gt "$max_backups" ]; then
        local excess=$((backup_count - max_backups))
        ls -1t "$BACKUP_DIR"/iptables_backup_*.rules | tail -n "$excess" | xargs rm -f
        log_message "INFO" "Cleaned up $excess old backup files"
    fi
}

# Restore iptables rules from a backup file
restore_from_backup() {
    echo -e "${BLUE}Available backups:${NC}"
    local backups=($(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backup files found.${NC}"
        return 1
    fi
    
    for i in "${!backups[@]}"; do
        local file_date=$(basename "${backups[$i]}" | sed 's/iptables_backup_\(.*\)\.rules/\1/')
        echo "$((i+1)). $file_date"
    done
    
    read -p "Select a backup to restore (enter number): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
        local selected_backup="${backups[$((choice-1))]}"
        echo -e "${YELLOW}Warning: This will overwrite all current iptables rules!${NC}"
        read -p "Are you sure you want to restore this backup? (y/n): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if iptables-restore < "$selected_backup"; then
                echo -e "${GREEN}✓ Backup restored successfully${NC}"
                log_message "INFO" "Restored from backup: $selected_backup"
            else
                echo -e "${RED}✗ Restore failed${NC}"
                log_message "ERROR" "Failed to restore from backup: $selected_backup"
            fi
        fi
    else
        echo -e "${RED}Invalid selection${NC}"
    fi
}

# Interactively clean up backup files
interactive_cleanup_backups() {
    local backups=( $(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null) )
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backup files found${NC}"
        return
    fi

    echo -e "${BLUE}Backup List:${NC}"
    for i in "${!backups[@]}"; do
        local file=$(basename "${backups[$i]}")
        local size=$(du -h "${backups[$i]}" | cut -f1)
        local date=$(echo "$file" | sed 's/iptables_backup_\(.*\)\.rules/\1/' | sed 's/_/ /g')
        echo "$((i+1)). $date ($size)"
    done
    echo
    read -p "Enter backup numbers to delete (space-separated, or 'all' for all): " choices
    if [ "$choices" = "all" ]; then
        rm -f "${backups[@]}"
        echo -e "${GREEN}✓ All backups have been deleted${NC}"
        log_message "INFO" "Deleted all backup files"
        return
    fi

    choices=$(echo "$choices" | tr -cs '0-9' ' ')
    read -ra selected <<< "$choices"
    local deleted=0
    for sel in "${selected[@]}"; do
        sel=$(echo "$sel" | xargs)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#backups[@]} ]; then
            local target="${backups[$((sel-1))]}"
            if rm -f "$target"; then
                echo -e "${GREEN}✓ Deleted backup: $(basename "$target")${NC}"
                ((deleted++))
            else
                echo -e "${RED}✗ Failed to delete: $(basename "$target")${NC}"
            fi
        else
            echo -e "${YELLOW}Ignoring invalid number: $sel${NC}"
        fi
    done
    log_message "INFO" "Deleted $deleted backup files"
}