#!/bin/bash

#
# Description: Functions for rule editing, restoration, and uninstallation.
#

# Interactive rule editing menu
edit_rules() {
    while true; do
        show_current_rules
        echo -e "\n${BLUE}规则编辑选项:${NC}"
        echo "1. 删除指定规则"
        echo "2. 修改规则端口"
        echo "3. 切换规则状态 (暂未实现)" 
        echo "4. 返回主菜单"
        read -p "请选择操作 [1-4]: " choice

        case "$choice" in
            1) delete_specific_rule ;;
            2) modify_rule_ports ;;
            3) toggle_rule_status ;;
            4) break ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

# Delete a specific rule by its line number
delete_specific_rule() {
    read -p "请输入要删除的规则编号: " line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的编号${NC}"
        return
    fi

    if iptables -t nat -D PREROUTING "$line_num"; then
        echo -e "${GREEN}✓ 规则 $line_num 已删除${NC}"
        log_message "INFO" "删除规则 #${line_num}"
        save_rules
    else
        echo -e "${RED}✗ 删除规则 $line_num 失败${NC}"
    fi
}

# Modify ports for an existing rule
modify_rule_ports() {
    read -p "请输入要修改的规则编号: " line_num
    # ... (Implementation requires careful parsing of the rule) ...
    echo -e "${YELLOW}此功能正在开发中...${NC}"
}

# Toggle the status of a rule (enable/disable)
toggle_rule_status() {
    # ... (Implementation would involve replacing the rule with a DROP target or similar) ...
    echo -e "${YELLOW}此功能正在开发中...${NC}"
}

# Enhanced recovery options
restore_defaults() {
    echo -e "${YELLOW}警告：此操作将修改或删除iptables规则。${NC}"
    echo -e "${BLUE}恢复与重置选项：${NC}"
    echo "1. 仅删除本脚本创建的端口映射规则"
    echo "2. 删除规则并从最新备份恢复"
    echo "3. 完全重置iptables (清空所有规则)"
    echo "4. 返回"
    read -p "请选择操作 [1-4]: " choice

    case "$choice" in
        1) remove_mapping_rules ;;
        2) remove_and_restore ;;
        3) full_reset_iptables ;;
        4) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# Remove only the mapping rules created by this script
remove_mapping_rules() {
    read -p "确认要删除所有由本脚本创建的规则吗? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "正在删除规则..."
        iptables-save | grep -v "$RULE_COMMENT" | iptables-restore
        echo -e "${GREEN}✓ 脚本创建的规则已全部删除${NC}"
        log_message "INFO" "删除了所有脚本创建的规则"
        save_rules
    fi
}

# Remove rules and restore from the latest backup
remove_and_restore() {
    read -p "确认要删除现有规则并从最新备份恢复吗? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        remove_mapping_rules
        restore_from_backup
    fi
}

# Full reset of iptables (clears all rules)
full_reset_iptables() {
    read -p "${RED}警告：这将清空所有iptables规则，可能导致网络中断！确定吗? (y/n): ${NC}" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "正在重置iptables..."
        iptables -F
        iptables -X
        iptables -t nat -F
        iptables -t nat -X
        iptables -t mangle -F
        iptables -t mangle -X
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        echo -e "${GREEN}✓ iptables已完全重置${NC}"
        log_message "WARN" "执行了iptables完全重置"
        save_rules
    fi
}

# One-click uninstall function
uninstall_script() {
    echo -e "${RED}警告：这将从系统中卸载端口映射管理器。${NC}"
    read -p "是否同时删除所有由本脚本创建的iptables规则? (y/n): " delete_rules
    read -p "是否删除所有配置文件、日志和备份? (y/n): " delete_data
    read -p "${YELLOW}请再次确认要卸载吗? (y/n): ${NC}" final_confirm
    
    if [[ "$final_confirm" != "y" && "$final_confirm" != "Y" ]]; then
        echo "卸载已取消。"
        return
    fi

    echo "正在开始卸载..."
    
    # 1. Stop systemd service if it exists
    if systemctl is-active --quiet udp-port-mapping.service; then
        systemctl stop udp-port-mapping.service
        systemctl disable udp-port-mapping.service
        rm -f /etc/systemd/system/udp-port-mapping.service
        systemctl daemon-reload
        echo "Systemd服务已停止并移除。"
    fi

    # 2. Delete rules if requested
    if [[ "$delete_rules" == "y" || "$delete_rules" == "Y" ]]; then
        remove_mapping_rules
    fi

    # 3. Delete script files
    rm -f "/usr/local/bin/pmm"
    rm -rf "$SCRIPT_DIR"
    echo "脚本文件已删除。"

    # 4. Delete data files if requested
    if [[ "$delete_data" == "y" || "$delete_data" == "Y" ]]; then
        rm -rf "$CONFIG_DIR" "$BACKUP_DIR" "$LOG_DIR"
        echo "配置文件、日志和备份已删除。"
    fi

    echo -e "${GREEN}✓ 卸载完成。感谢使用！${NC}"
    log_message "INFO" "脚本已卸载"
    exit 0
}