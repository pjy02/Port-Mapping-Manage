#!/bin/bash

# libs/lib_iptables.sh
#
# 与 iptables 交互的函数

# Source utility functions
source "$(dirname "$0")/lib_utils.sh"

# 用于保存正确iptables命令的全局变量
IPTABLES_COMMAND="iptables"

# --- Error Handling for iptables ---
handle_iptables_error() {
    local exit_code=$1
    local command_output=$2
    local action=$3

    log_message "错误" "iptables 命令执行失败，退出代码 $exit_code，操作：$action。"
    log_message "错误" "输出: $command_output"

    echo -e "${C_RED}错误: 操作失败: $action。(退出代码: $exit_code)${C_RESET}"
    echo -e "${C_YELLOW}详情: $command_output${C_RESET}"

    if [[ "$command_output" == *"No chain/target/match by that name"* ]]; then
        echo -e "${C_CYAN}建议: 这可能是由于缺少内核模块引起的。请尝试运行 'modprobe xt_REDIRECT'。${C_RESET}"
    elif [[ "$command_output" == *"rule in chain PREROUTING already exists"* ]]; then
        echo -e "${C_CYAN}建议: 完全相同的规则已经存在。无需操作。${C_RESET}"
    else
        echo -e "${C_CYAN}建议: 请检查您系统的 iptables 设置和内核日志 ('dmesg') 以获取更多信息。${C_RESET}"
    fi
}

# --- Rule and Traffic Management ---
check_rule_active() {
    local proto=$1
    local from_port=$2
    local to_port=$3
    # 一个简化的检查，查找规则的核心组件
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
        handle_iptables_error "$exit_code" "$command_output" "启用规则 $proto $from_port -> $to_port"
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
        handle_iptables_error "$exit_code" "$command_output" "禁用规则 $proto $from_port -> $to_port"
        return 1
    fi
    return 0
}

add_iptables_rule() {
    if enable_iptables_rule "$1" "$2" "$3"; then
        log_message "成功" "已添加映射: $1 从 $2 到 $3。"
        echo -e "${C_GREEN}成功添加映射规则。${C_RESET}"
        return 0
    else
        return 1
    fi
}

delete_iptables_rule() {
    if disable_iptables_rule "$1" "$2" "$3"; then
        log_message "成功" "已删除映射: $1 从 $2 到 $3。"
        echo -e "${C_GREEN}成功删除映射规则。${C_RESET}"
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
            log_message "成功" "已禁用规则: $proto $from_port -> $to_port"
            echo -e "${C_GREEN}规则已禁用。${C_RESET}"
            return 0
        else
            log_message "错误" "禁用规则失败: $proto $from_port -> $to_port"
            echo -e "${C_RED}禁用规则失败。${C_RESET}"
            return 1
        fi
    else # 禁用状态，所以启用它
        if enable_iptables_rule "$proto" "$from_port" "$to_port"; then
            log_message "成功" "已启用规则: $proto $from_port -> $to_port"
            echo -e "${C_GREEN}规则已启用。${C_RESET}"
            return 0
        else
            log_message "错误" "启用规则失败: $proto $from_port -> $to_port"
            echo -e "${C_RED}启用规则失败。${C_RESET}"
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
        echo -e "${C_GREEN}IPv4 规则已备份到 $backup_file_v4${C_RESET}"
        log_message "信息" "已在 $backup_file_v4 创建 IPv4 备份"
    else
        echo -e "${C_RED}错误：备份 IPv4 规则失败。${C_RESET}"
        log_message "错误" "创建 IPv4 备份失败。"
        success=false
    fi

    if command -v ip6tables-save &>/dev/null; then
        if ip6tables-save > "$backup_file_v6"; then
            echo -e "${C_GREEN}IPv6 规则已备份到 $backup_file_v6${C_RESET}"
            log_message "信息" "已在 $backup_file_v6 创建 IPv6 备份"
        else
            echo -e "${C_RED}错误：备份 IPv6 规则失败。${C_RESET}"
            log_message "错误" "创建 IPv6 备份失败。"
            success=false
        fi
    fi
    
    if [ "$success" = true ]; then
        echo -e "${C_GREEN}备份过程已完成。${C_RESET}"
    else
        echo -e "${C_RED}备份过程完成但出现错误。${C_RESET}"
    fi
}

restore_rules_from_backup() {
    local backup_file=$1
    if [ ! -f "$backup_file" ]; then
        echo -e "${C_RED}错误：未找到备份文件: $backup_file${C_RESET}"
        return
    fi

    if iptables-restore < "$backup_file"; then
        echo -e "${C_GREEN}iptables 规则已成功从 $backup_file 恢复${C_RESET}"
        log_message "信息" "已从 $backup_file 恢复规则"
        save_rules_persistent "恢复备份"
    else
        echo -e "${C_RED}错误：恢复 iptables 规则失败。${C_RESET}"
        log_message "错误" "从 $backup_file 恢复失败"
    fi
}

# --- Persistence ---
save_rules_persistent_v4() {
    PERSISTENCE_METHOD=$(detect_persistence_method)
    echo -e "${C_YELLOW}正在尝试使用 '$PERSISTENCE_METHOD' 永久保存 IPv4 规则...${C_RESET}"

    case $PERSISTENCE_METHOD in
        netfilter-persistent)
            if sudo netfilter-persistent save; then
                 echo -e "${C_GREEN}IPv4 规则已通过 netfilter-persistent 成功保存。${C_RESET}"
            else
                 echo -e "${C_RED}使用 netfilter-persistent 保存 IPv4 规则失败。${C_RESET}"
            fi
            ;;
        service)
            if sudo service iptables save; then
                 echo -e "${C_GREEN}IPv4 规则已通过 service iptables save 成功保存。${C_RESET}"
            else
                 echo -e "${C_RED}使用 service iptables save 保存 IPv4 规则失败。${C_RESET}"
            fi
            ;;
        systemd)
            # 为 systemd 提供说明，因为直接保存不是标准方法
            echo -e "${C_CYAN}要在此 systemd 系统上使 IPv4 规则持久化，您可能需要：${C_RESET}"
            echo -e "  1. 安装 'iptables-persistent' (Debian/Ubuntu) 或 'iptables-services' (CentOS/RHEL)。"
            echo -e "  2. 然后运行 'sudo netfilter-persistent save' 或 'sudo service iptables save'。"
            echo -e "  或者，您可以手动保存：${C_YELLOW}sudo iptables-save > /etc/iptables/rules.v4${C_RESET}"
            ;;
        *)
            echo -e "${C_RED}不支持的 IPv4 持久化方法: $PERSISTENCE_METHOD。${C_RESET}"
            echo -e "${C_CYAN}请手动保存您的 IPv4 规则: sudo iptables-save > /etc/iptables/rules.v4${C_RESET}"
            ;;
    esac
}

save_rules_persistent_v6() {
    if ! command -v ip6tables-save &>/dev/null; then
        log_message "信息" "未找到 ip6tables，跳过 IPv6 规则保存。"
        return
    fi

    PERSISTENCE_METHOD=$(detect_persistence_method)
    echo -e "${C_YELLOW}正在尝试使用 '$PERSISTENCE_METHOD' 永久保存 IPv6 规则...${C_RESET}"

    case $PERSISTENCE_METHOD in
        netfilter-persistent)
            # netfilter-persistent 保存 v4 和 v6，所以这可能是多余但安全的
            if sudo netfilter-persistent save; then
                 echo -e "${C_GREEN}已使用 netfilter-persistent 成功保存 IPv6 规则。${C_RESET}"
            else
                 echo -e "${C_RED}使用 netfilter-persistent 保存 IPv6 规则失败。${C_RESET}"
            fi
            ;;
        service)
            if sudo service ip6tables save; then
                 echo -e "${C_GREEN}已使用 service ip6tables save 成功保存 IPv6 规则。${C_RESET}"
            else
                 echo -e "${C_RED}使用 service ip6tables save 保存 IPv6 规则失败。是否已安装 'ip6tables-services'？${C_RESET}"
            fi
            ;;
        systemd)
            echo -e "${C_CYAN}要使 IPv6 规则持久化，您可以手动保存：${C_YELLOW}sudo ip6tables-save > /etc/iptables/rules.v6${C_RESET}"
            ;;
        *)
            echo -e "${C_RED}不支持的 IPv6 持久化方法: $PERSISTENCE_METHOD。${C_RESET}"
            echo -e "${C_CYAN}请手动保存您的 IPv6 规则: sudo ip6tables-save > /etc/iptables/rules.v6${C_RESET}"
            ;;
    esac
}

save_rules_persistent() {
    local action_context=$1
    save_rules_persistent_v4 "$action_context"
    save_rules_persistent_v6 "$action_context"
}

# --- 完全重置 ---
full_reset_iptables() {
    echo -e "${C_RED}警告：这将清空所有 IPv4 和 IPv6 iptables 规则，删除所有自定义链，并将默认策略设置为 ACCEPT。这可能会暴露您的服务器。${C_RESET}"
    read -p "您确定要继续吗？ (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "已中止。"
        return
    fi

    echo "正在清空所有 IPv4 规则..."
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    echo "正在删除所有非默认 IPv4 链..."
    iptables -X
    iptables -t nat -X
    iptables -t mangle -X
    echo "正在将默认 IPv4 策略设置为 ACCEPT..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    if command -v ip6tables &> /dev/null; then
        echo "正在清空所有 IPv6 规则..."
        ip6tables -F
        ip6tables -t nat -F
        ip6tables -t mangle -F
        echo "正在删除所有非默认 IPv6 链..."
        ip6tables -X
        ip6tables -t nat -X
        ip6tables -t mangle -X
        echo "正在将默认 IPv6 策略设置为 ACCEPT..."
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
    fi

    log_message "警告" "对所有 iptables 规则（IPv4 和 IPv6）执行了完全重置。"
    echo -e "${C_GREEN}所有 iptables 规则（IPv4 和 IPv6）已被完全重置。${C_RESET}"

    read -p "您想永久保存此重置状态吗？ (yes/no): " save_confirm
    if [[ "$save_confirm" == "yes" ]]; then
        save_rules_persistent "保存完全重置"
    fi
}