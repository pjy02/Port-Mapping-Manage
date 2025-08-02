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

# --- 规则管理逻辑 ---
setup_mapping() {
    local ip_version proto from_port to_port validation_status

    read -p "输入IP版本 (4 代表 IPv4, 6 代表 IPv6): " ip_version
    if [[ "$ip_version" != "4" && "$ip_version" != "6" ]]; then
        echo -e "${C_RED}无效的IP版本。请输入 '4' 或 '6'。${C_RESET}"
        return
    fi
    if [[ "$ip_version" == "6" ]] && ! command -v ip6tables &>/dev/null; then
        echo -e "${C_RED}未找到ip6tables命令。无法管理IPv6规则。${C_RESET}"
        return
    fi
    IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")

    read -p "输入协议 (udp/tcp): " proto
    proto=$(echo "$proto" | tr '[:upper:]' '[:lower:]')
    if [[ "$proto" != "udp" && "$proto" != "tcp" ]]; then
        echo -e "${C_RED}无效的协议。请输入 'udp' 或 'tcp'。${C_RESET}"
        return
    fi

    read -p "输入要映射的源端口 (1-65535): " from_port
    validation_status=$(validate_port "$from_port" "$proto")
    if [[ "$validation_status" == "invalid" ]]; then
        echo -e "${C_RED}无效的源端口号。${C_RESET}"
        return
    elif [[ "$validation_status" == "listening" ]]; then
        echo -e "${C_RED}错误: 源端口 $from_port 已被占用。${C_RESET}"
        return
    elif [[ "$validation_status" == "reserved" ]]; then
        echo -e "${C_YELLOW}警告: 源端口 $from_port 位于系统保留范围 (< 1024)。${C_RESET}"
    fi

    read -p "输入要映射到的目标端口 (1-65535): " to_port
    validation_status=$(validate_port "$to_port")
    if [[ "$validation_status" == "invalid" ]]; then
        echo -e "${C_RED}无效的目标端口号。${C_RESET}"
        return
    fi

    if [[ "$from_port" == "$to_port" ]]; then
        echo -e "${C_RED}源端口和目标端口不能相同。${C_RESET}"
        return
    fi

    echo -e "${C_YELLOW}您将要添加以下映射:${C_RESET}"
    echo -e "  版本:   ${C_CYAN}IPv$ip_version${C_RESET}"
    echo -e "  协议:  ${C_CYAN}$proto${C_RESET}"
    echo -e "  源端口: ${C_CYAN}$from_port${C_RESET}"
    echo -e "  目标端口:   ${C_CYAN}$to_port${C_RESET}"
    read -p "确认? (y/n): " confirm

    if [[ "$confirm" == "y" ]]; then
        backup_rules # 在做更改前自动备份
        if add_iptables_rule "$proto" "$from_port" "$to_port"; then
            MAPPINGS+=("$ip_version:$proto:$from_port:$to_port:enabled") # 添加状态
            save_config
            read -p "您想让此规则在重启后也保持生效吗? (y/n): " persist
            if [[ "$persist" == "y" ]]; then
                save_rules_persistent "adding new rule"
            fi
        fi
    else
        echo "操作已取消。"
    fi
}

delete_specific_rule() {
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}没有可删除的托管映射规则。${C_RESET}"
        return
    fi

    echo -e "${C_PURPLE}选择要永久删除的规则:${C_RESET}"
    select mapping_choice in "${MAPPINGS[@]}" "取消"; do
        if [[ "$mapping_choice" == "取消" ]]; then
            echo "已取消。"
            break
        fi
        if [ -n "$mapping_choice" ]; then
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping_choice"
            
            IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")

            # 即使规则是 'disabled'，我们也必须确保它从iptables中移除
            # 因为一个禁用的规则可能不在iptables中，这没关系。
            disable_iptables_rule "$proto" "$from_port" "$to_port" # 确保它不活跃
            
            # 从数组中移除
            local new_mappings=()
            for item in "${MAPPINGS[@]}"; do
                [[ "$item" != "$mapping_choice" ]] && new_mappings+=("$item")
            done
            MAPPINGS=("${new_mappings[@]}")
            save_config
            echo -e "${C_GREEN}规则 '$mapping_choice' 已从配置中永久移除。${C_RESET}"
            
            read -p "您想永久保存规则删除吗 (更新持久化规则)？ (y/n): " persist
            if [[ "$persist" == "y" ]]; then
                save_rules_persistent "deleting rule"
            fi
            break
        else
            echo -e "${C_RED}无效的选择。${C_RESET}"
        fi
    done
}

toggle_rule_menu() {
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}没有可切换状态的托管映射规则。${C_RESET}"
        return
    fi

    echo -e "${C_PURPLE}选择一个规则以启用/禁用:${C_RESET}"
    # 为了清晰，在选择提示中添加一个索引
    local options=()
    for i in "${!MAPPINGS[@]}"; do
        options+=("$((i+1))) ${MAPPINGS[$i]}")
    done
    options+=("取消")

    select choice in "${options[@]}"; do
        if [[ "$choice" == "取消" ]]; then
            echo "已取消。"
            break
        fi
        
        # 从选择的字符串中提取索引
        local index=$(echo "$choice" | awk '{print $1}' | sed 's/)//')
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#MAPPINGS[@]} ]; then
            local selected_mapping_index=$((index - 1))
            local mapping=${MAPPINGS[$selected_mapping_index]}
            
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping"
            IPTABLES_COMMAND=$([[ "$ip_version" == "6" ]] && echo "ip6tables" || echo "iptables")
            
            if toggle_rule_status "$proto" "$from_port" "$to_port" "$status"; then
                # 更新数组中的状态
                local new_status=$([[ "$status"

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

# --- 清理 ---
uninstall_script() {
    echo -e "${C_RED}这将删除所有托管的规则、配置文件和脚本本身。${C_RESET}"
    read -p "您确定要卸载吗? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then echo "卸载已取消。"; return; fi

    # 删除规则
    for mapping in "${MAPPINGS[@]}"; do
        IFS=':' read -r ip_version proto from_port to_port <<< "$mapping"
        if [[ "$ip_version" == "6" ]]; then
            IPTABLES_COMMAND="ip6tables"
        else
            IPTABLES_COMMAND="iptables"
        fi
        delete_iptables_rule "$proto" "$from_port" "$to_port"
    done

    read -p "是否永久保存规则删除? (y/n): " save_confirm
    if [[ "$save_confirm" == "y" ]]; then save_rules_persistent "uninstalling"; fi

    # 删除文件
    rm -rf "$CONFIG_DIR"
    rm -f "$LOG_FILE"
    rm -f /usr/local/bin/pmm
    rm -f /usr/local/bin/port_mapping_manager.sh

    echo -e "${C_GREEN}端口映射管理器已卸载。${C_RESET}"
}