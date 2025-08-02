#!/bin/bash

# libs/lib_iptables.sh
#
# Functions for interacting with iptables

# Source utility functions
source "$(dirname "$0")/lib_utils.sh"

# Global variable to hold the correct iptables command
IPTABLES_COMMAND="iptables"

# --- Error Handling for iptables ---
handle_iptables_error() {
    local exit_code=$1
    local command_output=$2
    local action=$3

    log_message "ERROR" "iptables command failed with exit code $exit_code while $action."
    log_message "ERROR" "Output: $command_output"

    echo -e "${C_RED}Error: Failed to $action. (Exit code: $exit_code)${C_RESET}"
    echo -e "${C_YELLOW}Details: $command_output${C_RESET}"

    if [[ "$command_output" == *"No chain/target/match by that name"* ]]; then
        echo -e "${C_CYAN}Suggestion: This may be caused by a missing kernel module. Try running 'modprobe xt_REDIRECT'.${C_RESET}"
    elif [[ "$command_output" == *"rule in chain PREROUTING already exists"* ]]; then
        echo -e "${C_CYAN}Suggestion: The exact same rule already exists. No action needed.${C_RESET}"
    else
        echo -e "${C_CYAN}Suggestion: Check your system's iptables setup and kernel logs ('dmesg') for more information.${C_RESET}"
    fi
}

# --- Rule and Traffic Management ---
check_rule_active() {
    local proto=$1
    local from_port=$2
    local to_port=$3
    # A simplified check looking for the core components of the rule
    $IPTABLES_COMMAND -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null | grep -q "REDIRECT.*$proto.*dpt:$from_port.*redir ports $to_port"
}

enable_iptables_rule() {
    local proto=$1
    local from_port=$2
    local to_port=$3

    local command_output
    command_output=$($IPTABLES_COMMAND -t nat -A PREROUTING -p "$proto" --dport "$from_port" -j REDIRECT --to-port "$to_port" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        handle_iptables_error "$exit_code" "$command_output" "enabling rule for $proto $from_port -> $to_port"
        return 1
    fi
    return 0
}

disable_iptables_rule() {
    local proto=$1
    local from_port=$2
    local to_port=$3

    local command_output
    command_output=$($IPTABLES_COMMAND -t nat -D PREROUTING -p "$proto" --dport "$from_port" -j REDIRECT --to-port "$to_port" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        handle_iptables_error "$exit_code" "$command_output" "disabling rule for $proto $from_port -> $to_port"
        return 1
    fi
    return 0
}

add_iptables_rule() {
    if enable_iptables_rule "$1" "$2" "$3"; then
        log_message "SUCCESS" "Added mapping: $1 from $2 to $3."
        echo -e "${C_GREEN}Successfully added mapping rule.${C_RESET}"
        return 0
    else
        return 1
    fi
}

delete_iptables_rule() {
    if disable_iptables_rule "$1" "$2" "$3"; then
        log_message "SUCCESS" "Deleted mapping: $1 from $2 to $3."
        echo -e "${C_GREEN}Successfully deleted mapping rule.${C_RESET}"
        return 0
    else
        return 1
    fi
}

toggle_rule_status() {
    local proto=$1
    local from_port=$2
    local to_port=$3
    local current_status=$4 # 'enabled' or 'disabled'

    if [[ "$current_status" == "enabled" ]]; then
        if disable_iptables_rule "$proto" "$from_port" "$to_port"; then
            log_message "SUCCESS" "Disabled rule: $proto $from_port -> $to_port"
            echo -e "${C_GREEN}Rule disabled.${C_RESET}"
            return 0
        else
            log_message "ERROR" "Failed to disable rule: $proto $from_port -> $to_port"
            echo -e "${C_RED}Failed to disable rule.${C_RESET}"
            return 1
        fi
    else # It's disabled, so enable it
        if enable_iptables_rule "$proto" "$from_port" "$to_port"; then
            log_message "SUCCESS" "Enabled rule: $proto $from_port -> $to_port"
            echo -e "${C_GREEN}Rule enabled.${C_RESET}"
            return 0
        else
            log_message "ERROR" "Failed to enable rule: $proto $from_port -> $to_port"
            echo -e "${C_RED}Failed to enable rule.${C_RESET}"
            return 1
        fi
    fi
}

# --- Backup and Restore ---
backup_rules() {
    local backup_file_v4="$BACKUP_DIR/iptables-backup-$(date +%Y%m%d_%H%M%S).v4.rules"
    local backup_file_v6="$BACKUP_DIR/iptables-backup-$(date +%Y%m%d_%H%M%S).v6.rules"
    mkdir -p "$BACKUP_DIR"
    
    local success=true
    if iptables-save > "$backup_file_v4"; then
        echo -e "${C_GREEN}IPv4 rules backed up to $backup_file_v4${C_RESET}"
        log_message "INFO" "Created IPv4 backup at $backup_file_v4"
    else
        echo -e "${C_RED}Error: Failed to backup IPv4 rules.${C_RESET}"
        log_message "ERROR" "Failed to create IPv4 backup."
        success=false
    fi

    if command -v ip6tables-save &>/dev/null; then
        if ip6tables-save > "$backup_file_v6"; then
            echo -e "${C_GREEN}IPv6 rules backed up to $backup_file_v6${C_RESET}"
            log_message "INFO" "Created IPv6 backup at $backup_file_v6"
        else
            echo -e "${C_RED}Error: Failed to backup IPv6 rules.${C_RESET}"
            log_message "ERROR" "Failed to create IPv6 backup."
            success=false
        fi
    fi
    
    if [ "$success" = true ]; then
        echo -e "${C_GREEN}Backup process completed.${C_RESET}"
    else
        echo -e "${C_RED}Backup process completed with errors.${C_RESET}"
    fi
}

restore_rules_from_backup() {
    local backup_file=$1
    if [ ! -f "$backup_file" ]; then
        echo -e "${C_RED}Error: Backup file not found: $backup_file${C_RESET}"
        return
    fi

    if iptables-restore < "$backup_file"; then
        echo -e "${C_GREEN}iptables rules restored successfully from $backup_file${C_RESET}"
        log_message "INFO" "Restored rules from $backup_file"
        save_rules_persistent "restoring backup"
    else
        echo -e "${C_RED}Error: Failed to restore iptables rules.${C_RESET}"
        log_message "ERROR" "Failed to restore from $backup_file"
    fi
}

# --- Persistence ---
save_rules_persistent_v4() {
    PERSISTENCE_METHOD=$(detect_persistence_method)
    echo -e "${C_YELLOW}Attempting to save IPv4 rules permanently using '$PERSISTENCE_METHOD'...${C_RESET}"

    case $PERSISTENCE_METHOD in
        netfilter-persistent)
            if sudo netfilter-persistent save; then
                 echo -e "${C_GREEN}IPv4 rules saved successfully with netfilter-persistent.${C_RESET}"
            else
                 echo -e "${C_RED}Failed to save IPv4 rules with netfilter-persistent.${C_RESET}"
            fi
            ;;
        service)
            if sudo service iptables save; then
                 echo -e "${C_GREEN}IPv4 rules saved successfully with service iptables save.${C_RESET}"
            else
                 echo -e "${C_RED}Failed to save IPv4 rules with service iptables save.${C_RESET}"
            fi
            ;;
        systemd)
            # Provide instructions for systemd, as direct save isn't standard
            echo -e "${C_CYAN}To make IPv4 rules persistent on this systemd system, you might need to:${C_RESET}"
            echo -e "  1. Install 'iptables-persistent' (Debian/Ubuntu) or 'iptables-services' (CentOS/RHEL)."
            echo -e "  2. Then run 'sudo netfilter-persistent save' or 'sudo service iptables save'."
            echo -e "  Alternatively, you can manually save with: ${C_YELLOW}sudo iptables-save > /etc/iptables/rules.v4${C_RESET}"
            ;;
        *)
            echo -e "${C_RED}Unsupported persistence method for IPv4: $PERSISTENCE_METHOD.${C_RESET}"
            echo -e "${C_CYAN}Please save your IPv4 rules manually: sudo iptables-save > /etc/iptables/rules.v4${C_RESET}"
            ;;
    esac
}

save_rules_persistent_v6() {
    if ! command -v ip6tables-save &>/dev/null; then
        log_message "INFO" "ip6tables not found, skipping IPv6 rule saving."
        return
    fi

    PERSISTENCE_METHOD=$(detect_persistence_method)
    echo -e "${C_YELLOW}Attempting to save IPv6 rules permanently using '$PERSISTENCE_METHOD'...${C_RESET}"

    case $PERSISTENCE_METHOD in
        netfilter-persistent)
            # netfilter-persistent saves both v4 and v6, so this might be redundant but safe
            if sudo netfilter-persistent save; then
                 echo -e "${C_GREEN}IPv6 rules saved successfully with netfilter-persistent.${C_RESET}"
            else
                 echo -e "${C_RED}Failed to save IPv6 rules with netfilter-persistent.${C_RESET}"
            fi
            ;;
        service)
            if sudo service ip6tables save; then
                 echo -e "${C_GREEN}IPv6 rules saved successfully with service ip6tables save.${C_RESET}"
            else
                 echo -e "${C_RED}Failed to save IPv6 rules with service ip6tables save. Is 'ip6tables-services' installed?${C_RESET}"
            fi
            ;;
        systemd)
            echo -e "${C_CYAN}To make IPv6 rules persistent, you can manually save with: ${C_YELLOW}sudo ip6tables-save > /etc/iptables/rules.v6${C_RESET}"
            ;;
        *)
            echo -e "${C_RED}Unsupported persistence method for IPv6: $PERSISTENCE_METHOD.${C_RESET}"
            echo -e "${C_CYAN}Please save your IPv6 rules manually: sudo ip6tables-save > /etc/iptables/rules.v6${C_RESET}"
            ;;
    esac
}

save_rules_persistent() {
    local action_context=$1
    save_rules_persistent_v4 "$action_context"
    save_rules_persistent_v6 "$action_context"
}

# --- Full Reset ---
full_reset_iptables() {
    echo -e "${C_RED}WARNING: This will flush ALL IPv4 and IPv6 iptables rules, delete all custom chains, and set default policies to ACCEPT. This may expose your server.${C_RESET}"
    read -p "Are you absolutely sure you want to proceed? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return
    fi

    echo "Flushing all IPv4 rules..."
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    echo "Deleting all non-default IPv4 chains..."
    iptables -X
    iptables -t nat -X
    iptables -t mangle -X
    echo "Setting default IPv4 policies to ACCEPT..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    if command -v ip6tables &> /dev/null; then
        echo "Flushing all IPv6 rules..."
        ip6tables -F
        ip6tables -t nat -F
        ip6tables -t mangle -F
        echo "Deleting all non-default IPv6 chains..."
        ip6tables -X
        ip6tables -t nat -X
        ip6tables -t mangle -X
        echo "Setting default IPv6 policies to ACCEPT..."
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
    fi

    log_message "WARNING" "Performed a full reset of all iptables rules (IPv4 and IPv6)."
    echo -e "${C_GREEN}All iptables rules (IPv4 and IPv6) have been completely reset.${C_RESET}"

    read -p "Do you want to save this reset state permanently? (yes/no): " save_confirm
    if [[ "$save_confirm" == "yes" ]]; then
        save_rules_persistent "saving full reset"
    fi
}