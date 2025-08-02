#!/bin/bash

# libs/lib_ui.sh
#
# 端口映射管理器的用户界面函数

source "$(dirname "$0")/lib_utils.sh"

# --- 规则显示 ---
show_current_rules() {
    echo -e "${C_BLUE}--- 当前端口映射 ---${C_RESET}"

    local rules_output_v4
    rules_output_v4=$(iptables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null)
    local rules_output_v6
    if command -v ip6tables &>/dev/null; then
        rules_output_v6=$(ip6tables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null)
    fi

    echo -e "${C_CYAN}由此脚本管理 (来自配置):${C_RESET}"
    if [ ${#MAPPINGS[@]} -eq 0 ]; then
        echo "  (没有配置的规则)"
    else
        printf "%-5s %-10s %-15s %-15s %-12s\n" "版本" "协议" "源端口" "目标端口" "状态"
        for mapping in "${MAPPINGS[@]}"; do
            IFS=':' read -r ip_version proto from_port to_port status <<< "$mapping"
            local display_status
            if [[ "$status" == "enabled" ]]; then
                display_status="${C_GREEN}已启用${C_RESET}"
            else
                display_status="${C_RED}已禁用${C_RESET}"
            fi
            printf "%-5s %-10s %-15s %-15s %-12s\n" "IPv$ip_version" "$proto" "$from_port" "$to_port" "$display_status"
        done
    fi

    echo -e "\n${C_CYAN}系统上找到的所有IPv4 PREROUTING规则:${C_RESET}"
    if [ -z "$rules_output_v4" ]; then
        echo "  (未找到IPv4 NAT规则)"
    else
        echo "$rules_output_v4"
    fi

    if command -v ip6tables &>/dev/null; then
        echo -e "\n${C_CYAN}系统上找到的所有IPv6 PREROUTING规则:${C_RESET}"
        if [ -z "$rules_output_v6" ]; then
            echo "  (未找到IPv6 NAT规则)"
        else
            echo "$rules_output_v6"
        fi
    fi

    echo -e "${C_BLUE}--- 列表结束 ---${C_RESET}"
}

# --- 菜单 ---
show_main_menu() {
    echo -e "\n${C_PURPLE}--- 端口映射管理器 ---${C_RESET}"
    echo "1. 显示当前规则"
    echo "2. 添加新映射"
    echo "3. 启用/禁用映射"
    echo "4. 删除映射"
    echo "5. 备份和恢复"
    echo "6. 批量操作"
    echo "7. 系统诊断"
    echo "8. 卸载脚本"
    echo "h. 帮助"
    echo "q. 退出"
    read -p "请输入您的选择: " choice
    echo
}

show_backup_menu() {
    echo -e "\n${C_PURPLE}--- 备份和恢复菜单 ---${C_RESET}"
    echo "1. 创建新备份"
    echo "2. 列出所有备份"
    echo "3. 从备份中恢复"
    echo "4. 清理旧备份"
    echo "5. 重置所有iptables规则"
    echo "b. 返回主菜单"
    read -p "请输入您的选择: " backup_choice
    echo
}

show_batch_menu() {
    echo -e "\n${C_PURPLE}--- 批量操作菜单 ---${C_RESET}"
    echo "1. 从文件导入规则"
    echo "2. 将托管规则导出到文件"
    echo "b. 返回主菜单"
    read -p "请输入您的选择: " batch_choice
    echo
}

# --- 帮助和信息 ---
show_enhanced_help() {
    echo -e "${C_BLUE}端口映射管理器 - 帮助${C_RESET}"
    echo "此脚本可帮助您管理用于端口转发的iptables REDIRECT规则。"
    echo
    echo -e "${C_YELLOW}功能:${C_RESET}"
    echo "- ${C_GREEN}显示规则:${C_RESET} 显示此脚本配置中的规则和所有系统NAT规则。"
    echo "- ${C_GREEN}添加/删除:${C_RESET} 指导您添加或删除特定的映射规则。"
    echo "- ${C_GREEN}启用/禁用:${C_RESET} 动态激活或停用规则，而无需删除它们。"
    echo "- ${C_GREEN}备份/恢复:${C_RESET} 保存您整个iptables状态并在以后恢复。"
    echo "- ${C_GREEN}批量导入:${C_RESET} 从一个简单的文本文件添加多个规则。"
    echo "- ${C_GREEN}诊断:${C_RESET} 提供您系统网络状态的快速概览。"
    echo
    echo -e "${C_YELLOW}批量导入文件格式:${C_RESET}"
    echo "创建一个文本文件，每行格式如下: ${C_CYAN}ip_version,protocol,from_port,to_port,status${C_RESET}"
    echo "'status'字段是可选的，可以是'enabled'或'disabled'。默认为'enabled'。"
    echo "示例:"
    echo "4,udp,8001,9001,enabled"
    echo "6,tcp,8002,9002,disabled"
    echo "4,tcp,8080,80"
}

show_version() {
    echo "端口映射管理器 (PMM) - 版本 4.0 (模块化)"
}