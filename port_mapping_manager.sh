#!/bin/bash

# TCP/UDP端口映射管理脚本 Enhanced v3.3
# 适用于 Hysteria2 机场端口跳跃配置
# 增强版本包含：安全性改进、错误处理、批量操作、监控诊断等功能

# 脚本配置
SCRIPT_VERSION="3.7"
RULE_COMMENT="udp-port-mapping-script-v3"
CONFIG_DIR="/etc/port_mapping_manager"
LOG_FILE="/var/log/udp-port-mapping.log"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# 颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# 全局变量
PACKAGE_MANAGER=""
PERSISTENT_METHOD=""
VERBOSE_MODE=false
AUTO_BACKUP=true
IP_VERSION="4" # 默认使用IPv4

# --- 日志和安全函数 ---

# 日志记录函数
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" >/dev/null 2>&1
}

# 输入安全验证
sanitize_input() {
    local input="$1"
    # 只允许数字、字母、短横线、下划线
    echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
}

# 创建必要的目录
setup_directories() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
}

# --- 系统检测和兼容性函数 ---

# 检测系统类型和包管理器
detect_system() {
    if command -v apt-get &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="unknown"
    fi
    
    # 检测持久化方法
    if command -v netfilter-persistent &> /dev/null; then
        PERSISTENT_METHOD="netfilter-persistent"
    elif command -v service &> /dev/null && [ -f "/etc/init.d/iptables" ]; then
        PERSISTENT_METHOD="service"
    elif command -v systemctl &> /dev/null; then
        PERSISTENT_METHOD="systemd"
    else
        PERSISTENT_METHOD="manual"
    fi
    
    # 检测ip6tables持久化方法
    if command -v netfilter-persistent &> /dev/null; then
        PERSISTENT_METHOD_V6="netfilter-persistent"
    elif command -v service &> /dev/null && [ -f "/etc/init.d/ip6tables" ]; then
        PERSISTENT_METHOD_V6="service"
    elif command -v systemctl &> /dev/null; then
        PERSISTENT_METHOD_V6="systemd"
    else
        PERSISTENT_METHOD_V6="manual"
    fi
    
    log_message "INFO" "IPv6 持久化方法: $PERSISTENT_METHOD_V6"
    
    log_message "INFO" "系统检测: 包管理器=$PACKAGE_MANAGER, 持久化方法=$PERSISTENT_METHOD"
}

# 根据IP版本获取正确的iptables命令
get_iptables_cmd() {
    if [ "$IP_VERSION" = "6" ]; then
        echo "ip6tables"
    else
        echo "iptables"
    fi
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要以 root 权限运行。${NC}"
        echo -e "请尝试使用: ${YELLOW}sudo $0${NC}"
        exit 1
    fi
}

# 交互式清理备份文件
interactive_cleanup_backups() {
    local backups=( $(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null) )
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到备份文件${NC}"
        return
    fi

    echo -e "${BLUE}备份列表:${NC}"
    for i in "${!backups[@]}"; do
        local file=$(basename "${backups[$i]}")
        local size=$(du -h "${backups[$i]}" | cut -f1)
        local date=$(echo "$file" | sed 's/iptables_backup_\(.*\)\.rules/\1/' | sed 's/_/ /g')
        echo "$((i+1)). $date ($size)"
    done
    echo
    read -p "请输入要删除的备份序号(可输入多个，用空格、逗号等分隔，输入 all 删除全部): " choices
    if [ "$choices" = "all" ]; then
        rm -f "${backups[@]}"
        echo -e "${GREEN}✓ 已删除全部备份${NC}"
        log_message "INFO" "删除全部备份文件"
        return
    fi

    # 将所有非数字字符转换为空格作为分隔符
    choices=$(echo "$choices" | tr -cs '0-9' ' ')
    read -ra selected <<< "$choices"
    local deleted=0
    for sel in "${selected[@]}"; do
        sel=$(echo "$sel" | xargs)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#backups[@]} ]; then
            local target="${backups[$((sel-1))]}"
            if rm -f "$target"; then
                echo -e "${GREEN}✓ 删除备份: $(basename "$target")${NC}"
                ((deleted++))
            else
                echo -e "${RED}✗ 无法删除: $(basename "$target")${NC}"
            fi
        else
            echo -e "${YELLOW}忽略无效序号: $sel${NC}"
        fi
    done
    log_message "INFO" "删除备份文件数量: $deleted"
}
# 增强的依赖检查
check_dependencies() {
    local missing_deps=()
    local required_commands=("iptables" "ip6tables" "iptables-save" "ip6tables-save" "ss" "grep" "awk" "sed")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}错误：缺少必要的依赖：${missing_deps[*]}${NC}"
        echo -e "正在尝试自动安装..."
        install_dependencies "${missing_deps[@]}"
    fi
    
    # 检查iptables功能
        local ipt_cmd=$(get_iptables_cmd)
    if ! $ipt_cmd -t nat -L >/dev/null 2>&1; then
        echo -e "${RED}错误：iptables NAT 功能不可用，可能需要加载内核模块。${NC}"
        echo -e "尝试执行: ${YELLOW}modprobe iptable_nat${NC}"
        exit 1
    fi
}

# 自动安装依赖
install_dependencies() {
    local deps=("$@")
    case $PACKAGE_MANAGER in
        "apt")
            apt-get update && apt-get install -y "${deps[@]}"
            ;;
        "yum"|"dnf")
            $PACKAGE_MANAGER install -y "${deps[@]}"
            ;;
        "pacman")
            pacman -S --noconfirm "${deps[@]}"
            ;;
        *)
            echo -e "${RED}无法自动安装依赖，请手动安装：${deps[*]}${NC}"
            exit 1
            ;;
    esac
}

# --- 增强的验证函数 ---

# 端口验证函数
validate_port() {
    local port=$1
    local port_name=$2
    
    # 输入清理
    port=$(sanitize_input "$port")
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：${port_name} 必须是纯数字。${NC}"
        return 1
    fi
    
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}错误：${port_name} 必须在 1-65535 范围内。${NC}"
        return 1
    fi
    
    # 检查是否为系统保留端口
    if [ "$port" -lt 1024 ]; then
        echo -e "${YELLOW}警告：端口 $port 是系统保留端口，可能需要特殊权限。${NC}"
    fi
    
    return 0
}

# 增强的端口占用检查
check_port_in_use() {
    local port=$1
    local detailed=${2:-false}
    
    if ss -ulnp | grep -q ":$port "; then
        if [ "$detailed" = true ]; then
            local process_info=$(ss -ulnp | grep ":$port " | awk '{print $6}')
            echo -e "${YELLOW}警告：端口 $port 已被占用 - $process_info${NC}"
        else
            echo -e "${YELLOW}警告：端口 $port 可能已被占用。${NC}"
        fi
        return 0
    fi
    return 1
}

# 检查端口范围冲突
check_port_conflicts() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    
    # 检查现有iptables规则冲突
    local conflicts=$(iptables -t nat -L PREROUTING -n | grep -E "dpt:($start_port|$end_port|$service_port)([^0-9]|$)")
    
    if [ -n "$conflicts" ]; then
        echo -e "${YELLOW}发现可能的端口冲突：${NC}"
        echo "$conflicts"
        return 1
    fi
    
    return 0
}

# --- 配置管理函数 ---

# 加载配置文件
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_message "INFO" "配置文件已加载"
    else
        create_default_config
    fi
}

# 创建默认配置
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# UDP端口映射脚本配置文件
# 自动备份设置
AUTO_BACKUP=true
# 最大备份文件数量
MAX_BACKUPS=10
# 详细日志模式
VERBOSE_MODE=false
# 常用端口预设
PRESET_RANGES=("6000-7000:3000" "8000-9000:4000" "10000-11000:5000")
EOF
    log_message "INFO" "创建默认配置文件"
}

# 保存配置到文件
save_mapping_config() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    cat >> "$CONFIG_DIR/mappings.conf" << EOF
# 添加时间: $(date)
MAPPING_${timestamp}_START=$start_port
MAPPING_${timestamp}_END=$end_port
MAPPING_${timestamp}_SERVICE=$service_port
EOF
}

# --- 备份和恢复函数 ---

# 备份当前iptables规则
backup_rules() {
    local backup_file="$BACKUP_DIR/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
    
    if iptables-save > "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}✓ iptables规则已备份到: $backup_file${NC}"
        log_message "INFO" "规则备份成功: $backup_file"
        
        # 清理旧备份（保留最新的10个）
        cleanup_old_backups
        return 0
    else
        echo -e "${RED}✗ 备份失败${NC}"
        log_message "ERROR" "规则备份失败"
        return 1
    fi
}

# 清理旧备份
cleanup_old_backups() {
    local max_backups=${MAX_BACKUPS:-10}
    local backup_count=$(ls -1 "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null | wc -l)
    
    if [ "$backup_count" -gt "$max_backups" ]; then
        local excess=$((backup_count - max_backups))
        ls -1t "$BACKUP_DIR"/iptables_backup_*.rules | tail -n "$excess" | xargs rm -f
        log_message "INFO" "清理了 $excess 个旧备份文件"
    fi
}

# 恢复规则
restore_from_backup() {
    echo -e "${BLUE}可用的备份文件：${NC}"
    local backups=($(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到备份文件。${NC}"
        return 1
    fi
    
    for i in "${!backups[@]}"; do
        local file_date=$(basename "${backups[$i]}" | sed 's/iptables_backup_\(.*\)\.rules/\1/')
        echo "$((i+1)). $file_date"
    done
    
    read -p "请选择要恢复的备份 (输入序号): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
        local selected_backup="${backups[$((choice-1))]}"
        echo -e "${YELLOW}警告：这将替换当前所有iptables规则！${NC}"
        read -p "确认恢复备份吗? (y/n): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if iptables-restore < "$selected_backup"; then
                echo -e "${GREEN}✓ 备份恢复成功${NC}"
                log_message "INFO" "从备份恢复: $selected_backup"
            else
                echo -e "${RED}✗ 恢复失败${NC}"
                log_message "ERROR" "备份恢复失败: $selected_backup"
            fi
        fi
    else
        echo -e "${RED}无效的选择${NC}"
    fi
}

# --- 增强的错误处理 ---

# 详细的iptables错误处理
handle_iptables_error() {
    local exit_code=$1
    local operation=$2
    
    case $exit_code in
        0) return 0 ;;
        1) 
            echo -e "${RED}iptables错误：一般错误或权限不足${NC}"
            log_message "ERROR" "iptables $operation: 一般错误 (代码: 1)"
            ;;
        2) 
            echo -e "${RED}iptables错误：协议不存在或不支持${NC}"
            log_message "ERROR" "iptables $operation: 协议错误 (代码: 2)"
            ;;
        3) 
            echo -e "${RED}iptables错误：无效的参数或选项${NC}"
            log_message "ERROR" "iptables $operation: 参数错误 (代码: 3)"
            ;;
        4) 
            echo -e "${RED}iptables错误：资源不足${NC}"
            log_message "ERROR" "iptables $operation: 资源不足 (代码: 4)"
            ;;
        *)
            echo -e "${RED}iptables错误：未知错误 (代码: $exit_code)${NC}"
            log_message "ERROR" "iptables $operation: 未知错误 (代码: $exit_code)"
            ;;
    esac
    
    # 提供解决建议
    echo -e "${YELLOW}建议解决方案：${NC}"
    echo "1. 检查是否有足够的系统权限"
    echo "2. 确认iptables服务正在运行"
    echo "3. 检查内核模块是否已加载 (iptable_nat)"
    echo "4. 查看详细错误: dmesg | tail"
    
    return $exit_code
}

# --- 核心功能增强 ---

# 增强的规则显示
show_rules_for_version() {
    local ip_version=$1
    local total_rules=0
    local iptables_cmd

    if [ "$ip_version" = "6" ]; then
        iptables_cmd="ip6tables"
    else
        iptables_cmd="iptables"
    fi

    echo -e "\n${YELLOW}--- IPv${ip_version} 规则 ---${NC}"

    local rules=$($iptables_cmd -t nat -L PREROUTING -n --line-numbers 2>/dev/null)

    if [ -z "$rules" ] || [[ $(echo "$rules" | wc -l) -le 2 ]]; then
        echo -e "${YELLOW}未找到 IPv${ip_version} 映射规则。${NC}"
        return 0
    fi

    printf "%-4s %-18s %-8s %-15s %-15s %-20s %-10s %-6s\n" \
        "No." "Type" "Prot" "Source" "Destination" "PortRange" "DstPort" "From"
    echo "---------------------------------------------------------------------------------"

    local rule_count=0
    while IFS= read -r rule; do
        if [[ "$rule" =~ ^Chain[[:space:]] ]] || [[ "$rule" =~ ^num[[:space:]] ]]; then
            continue
        fi
        
        local line_num=$(echo "$rule" | awk '{print $1}')
        local target=$(echo "$rule" | awk '{print $2}')
        local protocol=$(echo "$rule" | awk '{print $3}')
        local source=$(echo "$rule" | awk '{print $4}')
        local destination=$(echo "$rule" | awk '{print $5}')
        local origin="外部"
        if echo "$rule" | grep -q "$RULE_COMMENT"; then
            origin="脚本"
        fi

        local port_range=""
        if echo "$rule" | grep -q "dpts:"; then
            port_range=$(echo "$rule" | sed -n 's/.*dpts:\([0-9]*:[0-9]*\).*/\1/p')
        elif echo "$rule" | grep -q "dpt:"; then
            port_range=$(echo "$rule" | sed -n 's/.*dpt:\([0-9]*\).*/\1/p')
        fi

        local redirect_port=""
        if echo "$rule" | grep -q "redir ports"; then
            redirect_port=$(echo "$rule" | sed -n 's/.*redir ports \([0-9]*\).*/\1/p')
        fi

        local status="🔴"
        if check_rule_active "$port_range" "$redirect_port"; then
            status="🟢"
        fi

        printf "%-4s %-18s %-8s %-15s %-15s %-20s %-10s %-6s %s\n" \
            "$line_num" "$target" "$protocol" "$source" "$destination" \
            "$port_range" "$redirect_port" "$origin" "$status"

        ((rule_count++))
    done <<< "$rules"

    echo "---------------------------------------------------------------------------------"
    echo -e "${GREEN}共 $rule_count 条 IPv${ip_version} 规则 | 🟢=活跃 🔴=非活跃${NC}"
    
    return $rule_count
}

show_current_rules() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}      当前映射规则 (Enhanced View)${NC}"
    echo -e "${BLUE}=========================================${NC}"

    local total_rules_v4=0
    local total_rules_v6=0

    show_rules_for_version "4"
    total_rules_v4=$?

    show_rules_for_version "6"
    total_rules_v6=$?

    if [ $((total_rules_v4 + total_rules_v6)) -eq 0 ]; then
        echo -e "${YELLOW}未找到任何由本脚本创建的映射规则。${NC}"
    fi

    # 显示流量统计
    show_traffic_stats
}

# 检查规则是否活跃
check_rule_active() {
    local port_range=$1
    local service_port=$2
    
    # 检查服务端口是否在监听
    if ss -ulnp | grep -q ":$service_port "; then
        return 0
    fi
    return 1
}

# 流量统计显示
show_traffic_stats() {
    echo -e "\n${CYAN}流量统计概览：${NC}"

    local iptables_cmd=$(get_iptables_cmd $IP_VERSION)
    if [ -z "$iptables_cmd" ]; then
        return
    fi

        local total_packets=0
        local total_bytes=0

        # 获取NAT表统计信息
        while read -r line; do
            if echo "$line" | grep -q "$RULE_COMMENT"; then
                local packets=$(echo "$line" | awk '{print $1}' | tr -d '[]')
                local bytes=$(echo "$line" | awk '{print $2}' | tr -d '[]')
                if [[ "$packets" =~ ^[0-9]+$ ]] && [[ "$bytes" =~ ^[0-9]+$ ]]; then
                    total_packets=$((total_packets + packets))
                    total_bytes=$((total_bytes + bytes))
                fi
            fi
        done < <($iptables_cmd -t nat -L PREROUTING -v -n 2>/dev/null)

    if [ "$total_packets" -gt 0 ] || [ "$total_bytes" -gt 0 ]; then
        echo -e "${YELLOW}--- IPv${IP_VERSION} 流量 ---${NC}"
        echo "总数据包: $total_packets"
        echo "总字节数: $(format_bytes $total_bytes)"
    fi
}

# 格式化字节显示
format_bytes() {
    local bytes=$1
    if [ "$bytes" -gt 1073741824 ]; then
        echo "$((bytes / 1073741824))GB"
    elif [ "$bytes" -gt 1048576 ]; then
        echo "$((bytes / 1048576))MB"
    elif [ "$bytes" -gt 1024 ]; then
        echo "$((bytes / 1024))KB"
    else
        echo "${bytes}B"
    fi
}

# 端口预设功能
show_port_presets() {
    echo -e "${BLUE}常用端口范围预设：${NC}"
    echo "1. Hysteria2 标准 (6000-7000 -> 3000)"
    echo "2. Hysteria2 扩展 (8000-9000 -> 4000)" 
    echo "3. 大范围映射 (10000-12000 -> 5000)"
    echo "4. 自定义配置"
    echo "5. 返回主菜单"
    
    read -p "请选择预设 [1-5]: " preset_choice
    
    case $preset_choice in
        1) setup_mapping_with_preset 6000 7000 3000 ;;
        2) setup_mapping_with_preset 8000 9000 4000 ;;
        3) setup_mapping_with_preset 10000 12000 5000 ;;
        4) setup_mapping ;;
        5) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 使用预设配置的映射设置
setup_mapping_with_preset() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local protocol
    
    echo -e "${BLUE}预设配置：${NC}"
    echo "连接端口范围: $start_port-$end_port"
    echo "服务端口: $service_port"
    read -p "协议 (1=TCP, 2=UDP): " protocol
    case "$protocol" in
        1|tcp|TCP) protocol="tcp" ;;
        2|udp|UDP) protocol="udp" ;;
        *) echo -e "${RED}错误：请输入 1(=TCP) 或 2(=UDP)${NC}"; return ;;
    esac
    echo "协议: $protocol"
    
    read -p "确认使用此预设配置吗? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        add_mapping_rule "$start_port" "$end_port" "$service_port" "$protocol"
    fi
}

# 增强的映射设置
setup_mapping() {
    local start_port end_port service_port protocol

    while true; do
        echo -e "${BLUE}请输入端口映射配置：${NC}"
        read -p "连接端口（起始）: " start_port
        read -p "连接端口（终止）: " end_port
        read -p "服务端口: " service_port
        # 选择协议
        read -p "协议 (1=TCP, 2=UDP): " protocol
        case "$protocol" in
            1|tcp|TCP) protocol="tcp" ;;
            2|udp|UDP) protocol="udp" ;;
            *) echo -e "${RED}错误：请输入 1(=TCP) 或 2(=UDP)${NC}"; continue ;;
        esac

        # 验证输入
        if ! validate_port "$start_port" "起始端口" || \
           ! validate_port "$end_port" "终止端口" || \
           ! validate_port "$service_port" "服务端口"; then
            continue
        fi

        # 验证端口范围逻辑
        if [ "$start_port" -gt "$end_port" ]; then
            echo -e "${RED}错误：起始端口不能大于终止端口。${NC}"
            continue
        fi

        # 验证服务端口不在连接端口范围内
        if [ "$service_port" -ge "$start_port" ] && [ "$service_port" -le "$end_port" ]; then
            echo -e "${RED}错误：服务端口不能在连接端口范围内！${NC}"
            continue
        fi

        # 高级检查
        check_port_in_use "$service_port" true
        
        if ! check_port_conflicts "$start_port" "$end_port" "$service_port"; then
            read -p "发现端口冲突，是否继续? (y/n): " continue_choice
            if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
                continue
            fi
        fi

        # 确认配置
        echo -e "\n${BLUE}配置确认：${NC}"
        echo "连接端口范围: $start_port-$end_port"
        echo "服务端口: $service_port"
        echo "映射类型: ${protocol^^}"
        echo "预计端口数量: $((end_port - start_port + 1))"
        
        read -p "确认添加此映射规则吗? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            add_mapping_rule "$start_port" "$end_port" "$service_port" "$protocol"
            break
        else
            echo "已取消。"
            return
        fi
    done
}

# 添加映射规则的核心函数
add_mapping_rule() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local protocol=${4:-udp}
    
    # 自动备份
    if [ "$AUTO_BACKUP" = true ]; then
        echo "正在备份当前规则..."
        backup_rules
    fi

    echo "正在添加端口映射规则..."
    
    # 根据IP_VERSION获取对应的iptables命令
    local iptables_cmd=$(get_iptables_cmd)

    echo "正在添加端口映射规则..."

    # 添加规则
    if $iptables_cmd -t nat -A PREROUTING -p $protocol --dport "$start_port:$end_port" \
       -m comment --comment "$RULE_COMMENT" \
       -j REDIRECT --to-port "$service_port" 2>/dev/null; then
        
        echo -e "${GREEN}✓ 映射规则添加成功: ${protocol^^} ${start_port}-${end_port} -> ${service_port}${NC}"
        log_message "INFO" "添加规则: ${protocol^^} ${start_port}-${end_port} -> ${service_port}"
        
        # 保存配置
        save_mapping_config "$start_port" "$end_port" "$service_port"
        
        # 显示规则状态
        show_current_rules
        
        # 询问是否永久保存
        read -p "是否将规则永久保存? (y/n): " save_choice
        if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
            save_rules
        else
            echo -e "${YELLOW}注意：规则仅为临时规则，重启后将失效。${NC}"
        fi
        
    else
        local exit_code=$?
        echo -e "${RED}✗ 添加规则失败${NC}"
        handle_iptables_error $exit_code "添加规则"
        return $exit_code
    fi
}

# 增强的持久化检查和保存
check_persistent_package() {
    case $PERSISTENT_METHOD in
        "netfilter-persistent")
            return 0
            ;;
        "service")
            echo -e "${YELLOW}使用传统的service方法保存规则${NC}"
            return 0
            ;;
        "systemd")
            echo -e "${YELLOW}检测到systemd环境，尝试创建自定义服务${NC}"
            create_systemd_service
            return $?
            ;;
        "manual")
            echo -e "${YELLOW}未检测到自动持久化方法，需要手动配置${NC}"
            show_manual_save_instructions
            return 1
            ;;
        *)
            echo -e "${RED}无法确定持久化方法${NC}"
            return 1
            ;;
    esac
}

# 创建systemd服务用于规则持久化
create_systemd_service() {
    local service_file="/etc/systemd/system/udp-port-mapping.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=UDP Port Mapping Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $CONFIG_DIR/current.rules.v4
ExecStart=/sbin/ip6tables-restore $CONFIG_DIR/current.rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable udp-port-mapping.service
    systemctl start udp-port-mapping.service
    echo -e "${GREEN}已创建systemd服务用于规则持久化并启动${NC}"
    log_message "INFO" "create_systemd_service: 服务已创建并启动"
}

# 显示手动保存说明
show_manual_save_instructions() {
    echo -e "${BLUE}手动持久化规则说明：${NC}"
    echo "1. 将当前规则保存到文件:"
    echo "   iptables-save > /etc/iptables/rules.v4"
    echo "2. 添加到系统启动脚本:"
    echo "   echo 'iptables-restore < /etc/iptables/rules.v4' >> /etc/rc.local"
    echo "3. 或使用crontab在重启时恢复:"
    echo "   echo '@reboot iptables-restore < /etc/iptables/rules.v4' | crontab -"
}

# 增强的规则保存
save_rules() {
    local iptables_save_cmd
    local rules_file
    local effective_persistent_method

    if [ "$IP_VERSION" = "6" ]; then
        iptables_save_cmd="ip6tables-save"
        rules_file="$CONFIG_DIR/current.rules.v6"
        effective_persistent_method=$PERSISTENT_METHOD_V6
    else
        iptables_save_cmd="iptables-save"
        rules_file="$CONFIG_DIR/current.rules.v4"
        effective_persistent_method=$PERSISTENT_METHOD
    fi

    echo "正在保存iptables规则 (IP v${IP_VERSION})..."
    
    case $effective_persistent_method in
        "netfilter-persistent")
            if $iptables_save_cmd > /dev/null; then # just to check if command works
                 netfilter-persistent save
                 echo -e "${GREEN}✓ 规则已通过netfilter-persistent永久保存${NC}"
                 log_message "INFO" "规则永久保存成功 (v${IP_VERSION})"
                 return 0
            fi
            ;;
        "service")
            if service $iptables_save_cmd save 2>/dev/null; then
                echo -e "${GREEN}✓ 规则已通过service命令永久保存${NC}"
                log_message "INFO" "规则永久保存成功 (v${IP_VERSION})"
                return 0
            fi
            ;;
        "systemd")
            # 保存当前IP版本的规则
            if $iptables_save_cmd > "$rules_file"; then
                echo -e "${GREEN}✓ 规则已保存到 $rules_file${NC}"
                log_message "INFO" "规则保存到文件: $rules_file"
                
                # 同时保存另一个IP版本的规则（如果存在）
                local other_ip_version other_iptables_cmd other_rules_file
                if [ "$IP_VERSION" = "6" ]; then
                    other_ip_version="4"
                    other_iptables_cmd="iptables-save"
                    other_rules_file="$CONFIG_DIR/current.rules.v4"
                else
                    other_ip_version="6"
                    other_iptables_cmd="ip6tables-save"
                    other_rules_file="$CONFIG_DIR/current.rules.v6"
                fi
                
                # 检查另一个IP版本是否有规则，如果有则保存
                if [ "$other_ip_version" = "4" ] && iptables -t nat -L PREROUTING -n | grep -q "$RULE_COMMENT"; then
                    if $other_iptables_cmd > "$other_rules_file" 2>/dev/null; then
                        echo -e "${GREEN}✓ IPv${other_ip_version}规则已同步保存到 $other_rules_file${NC}"
                        log_message "INFO" "IPv${other_ip_version}规则同步保存到文件: $other_rules_file"
                    fi
                elif [ "$other_ip_version" = "6" ] && ip6tables -t nat -L PREROUTING -n | grep -q "$RULE_COMMENT"; then
                    if $other_iptables_cmd > "$other_rules_file" 2>/dev/null; then
                        echo -e "${GREEN}✓ IPv${other_ip_version}规则已同步保存到 $other_rules_file${NC}"
                        log_message "INFO" "IPv${other_ip_version}规则同步保存到文件: $other_rules_file"
                    fi
                fi
                
                setup_systemd_service
                return 0
            fi
            ;;
    esac
    
    echo -e "${RED}✗ 规则保存失败${NC}"
    log_message "ERROR" "规则保存失败 (v${IP_VERSION})"
    show_manual_save_instructions
    return 1
}

# 配置 systemd 服务以实现持久化
setup_systemd_service() {
    local service_file="/etc/systemd/system/iptables-restore.service"
    if [ ! -f "$service_file" ]; then
        echo "正在创建 systemd 服务..."
        cat > "$service_file" <<EOF
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $CONFIG_DIR/current.rules.v4
ExecStart=/sbin/ip6tables-restore $CONFIG_DIR/current.rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable iptables-restore.service
        systemctl start iptables-restore.service
        echo -e "${GREEN}✓ systemd 服务已创建、启用并启动${NC}"
        log_message "INFO" "systemd 服务已创建、启用并启动"
    else
        echo -e "${YELLOW}systemd 服务已存在，正在重新加载和启动...${NC}"
        systemctl daemon-reload
        systemctl start iptables-restore.service
        echo -e "${GREEN}✓ systemd 服务已重新加载并启动${NC}"
        log_message "INFO" "systemd 服务已重新加载并启动"
    fi
}

# --- 新增功能：批量操作 ---

# 批量导入规则
batch_import_rules() {
    echo -e "${BLUE}批量导入规则${NC}"
    echo "请输入配置文件路径 (格式: start_port:end_port:service_port 每行一个):"
    read -p "文件路径: " config_file
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}文件不存在: $config_file${NC}"
        return 1
    fi
    
    local line_num=0
    local success_count=0
    local error_count=0
    
    while IFS=':' read -r start_port end_port service_port; do
        ((line_num++))
        
        # 跳过空行和注释
        [[ -z "$start_port" ]] || [[ "$start_port" =~ ^#.*$ ]] && continue
        
        echo "处理第 $line_num 行: $start_port:$end_port:$service_port"
        
        if validate_port "$start_port" "起始端口" && \
           validate_port "$end_port" "终止端口" && \
           validate_port "$service_port" "服务端口"; then
            
            if add_mapping_rule "$start_port" "$end_port" "$service_port"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        else
            echo -e "${RED}第 $line_num 行格式错误，跳过${NC}"
            ((error_count++))
        fi
    done < "$config_file"
    
    echo -e "${GREEN}批量导入完成: 成功 $success_count 条, 失败 $error_count 条${NC}"
    log_message "INFO" "批量导入: 成功=$success_count, 失败=$error_count"
}

# 批量导出规则
batch_export_rules() {
    local export_file="${1:-$CONFIG_DIR/exported_rules_$(date +%Y%m%d_%H%M%S).conf}"
    
    echo "正在导出规则到: $export_file"
    
    # 写入文件头
    cat > "$export_file" << EOF
# UDP端口映射规则导出文件
# 生成时间: $(date)
# 格式: start_port:end_port:service_port
# 
EOF
    
    # 提取并写入规则
    local exported_count=0
    while IFS= read -r rule; do
        if echo "$rule" | grep -q "$RULE_COMMENT"; then
            local port_range=""
            local service_port=""
            
            if echo "$rule" | grep -q "dpts:"; then
                port_range=$(echo "$rule" | sed -n 's/.*dpts:\([0-9]*:[0-9]*\).*/\1/p')
            fi
            
            if echo "$rule" | grep -q "redir ports"; then
                service_port=$(echo "$rule" | sed -n 's/.*redir ports \([0-9]*\).*/\1/p')
            fi
            
            if [ -n "$port_range" ] && [ -n "$service_port" ]; then
                echo "${port_range}:${service_port}" | tr ':' ':' >> "$export_file"
                ((exported_count++))
            fi
        fi
    done < <(iptables -t nat -L PREROUTING -n)
    
    echo -e "${GREEN}✓ 已导出 $exported_count 条规则到 $export_file${NC}"
    log_message "INFO" "导出规则: $exported_count 条到 $export_file"
}

# --- 新增功能：诊断和监控 ---

# 综合诊断功能
diagnose_system() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}        系统诊断报告${NC}"
    echo -e "${BLUE}=========================================${NC}"
    
    # 1. 系统信息
    echo -e "\n${CYAN}1. 系统信息:${NC}"
    echo "操作系统: $(uname -o)"
    echo "内核版本: $(uname -r)"
    echo "包管理器: $PACKAGE_MANAGER"
    echo "持久化方法: $PERSISTENT_METHOD"
    
    # 2. 依赖检查
    echo -e "\n${CYAN}2. 依赖检查:${NC}"
    local deps=("iptables" "iptables-save" "ss" "netfilter-persistent")
    for dep in "${deps[@]}"; do
        if command -v "$dep" &> /dev/null; then
            echo "✓ $dep: 已安装"
        else
            echo "✗ $dep: 未安装"
        fi
    done
    
    # 3. 内核模块检查
    echo -e "\n${CYAN}3. 内核模块检查:${NC}"
    local modules=("iptable_nat" "nf_nat" "nf_conntrack")
    for module in "${modules[@]}"; do
        if lsmod | grep -q "^$module"; then
            echo "✓ $module: 已加载"
        else
            echo "✗ $module: 未加载"
        fi
    done
    
    # 4. 端口监听状态
    echo -e "\n${CYAN}4. 服务端口监听状态:${NC}"
    local service_ports=($(iptables -t nat -L PREROUTING -n | grep "$RULE_COMMENT" | sed -n 's/.*redir ports \([0-9]*\).*/\1/p' | sort -u))
    
    for port in "${service_ports[@]}"; do
        if ss -ulnp | grep -q ":$port "; then
            local process=$(ss -ulnp | grep ":$port " | awk '{print $6}' | head -1)
            echo "✓ 端口 $port: 正在监听 - $process"
        else
            echo "✗ 端口 $port: 未监听"
        fi
    done
    
    # 5. 防火墙状态
    echo -e "\n${CYAN}5. 防火墙状态:${NC}"
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo "⚠ UFW防火墙已启用，可能影响端口访问"
        echo "建议检查UFW规则: ufw status verbose"
    elif command -v firewalld &> /dev/null && firewall-cmd --state &> /dev/null; then
        echo "⚠ firewalld防火墙已启用，可能影响端口访问"
        echo "建议检查firewalld规则: firewall-cmd --list-all"
    else
        echo "✓ 未检测到活跃的防火墙服务"
    fi
    
    # 6. 规则统计
    echo -e "\n${CYAN}6. 映射规则统计:${NC}"
    local rule_count=$(iptables -t nat -L PREROUTING -n | grep -c "$RULE_COMMENT")
    echo "活跃映射规则: $rule_count 条"
    
    if [ "$rule_count" -gt 0 ]; then
        echo "规则详情:"
        show_current_rules
    fi
    
    # 7. 性能建议
    echo -e "\n${CYAN}7. 性能建议:${NC}"
    if [ "$rule_count" -gt 50 ]; then
        echo "⚠ 映射规则较多($rule_count条)，可能影响网络性能"
        echo "建议: 定期清理不用的规则，或考虑使用负载均衡"
    else
        echo "✓ 规则数量合理"
    fi
    
    echo -e "\n${BLUE}=========================================${NC}"
    echo -e "${BLUE}        诊断完成${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

# 实时监控功能
monitor_traffic() {
    echo -e "${BLUE}开始实时监控 (按Ctrl+C退出)${NC}"
    echo -e "${CYAN}时间\t\t数据包\t字节数\t速率${NC}"
    
    local prev_packets=0
    local prev_bytes=0
    
    while true; do
        local current_packets=0
        local current_bytes=0
        
        # 统计当前流量
        while read -r line; do
            if echo "$line" | grep -q "$RULE_COMMENT"; then
                local packets=$(echo "$line" | awk '{print $1}' | tr -d '[]')
                local bytes=$(echo "$line" | awk '{print $2}' | tr -d '[]')
                if [[ "$packets" =~ ^[0-9]+$ ]] && [[ "$bytes" =~ ^[0-9]+$ ]]; then
                    current_packets=$((current_packets + packets))
                    current_bytes=$((current_bytes + bytes))
                fi
            fi
        done < <(iptables -t nat -L PREROUTING -v -n)
        
        # 计算速率
        local packet_rate=$((current_packets - prev_packets))
        local byte_rate=$((current_bytes - prev_bytes))
        
        printf "%s\t%d\t%s\t%s/s\n" \
            "$(date '+%H:%M:%S')" \
            "$current_packets" \
            "$(format_bytes $current_bytes)" \
            "$(format_bytes $byte_rate)"
        
        prev_packets=$current_packets
        prev_bytes=$current_bytes
        
        sleep 1
    done
}

# --- 新增功能：规则管理 ---

# 交互式规则编辑
edit_rules() {
    show_current_rules
    echo -e "\n${BLUE}规则编辑选项:${NC}"
    echo "1. 删除指定规则"
    echo "2. 修改规则端口"
    echo "3. 启用/禁用规则"
    echo "4. 返回主菜单"
    
    read -p "请选择操作 [1-4]: " edit_choice
    
    case $edit_choice in
        1) delete_specific_rule ;;
        2) modify_rule_ports ;;
        3) toggle_rule_status ;;
        4) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 删除指定规则
delete_specific_rule() {
    local iptables_cmd=$(get_iptables_cmd)
    # 收集所有 UDP REDIRECT 规则（包含脚本与外部）
    local rules=()
    local origins=()
    while read -r line; do
        local num=$(echo "$line" | awk '{print $1}')
        # 过滤非数字行
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            continue
        fi
        rules+=("$num")
        if echo "$line" | grep -q "$RULE_COMMENT"; then
            origins+=("脚本")
        else
            origins+=("外部")
        fi
    done < <($iptables_cmd -t nat -L PREROUTING --line-numbers | grep "REDIRECT")

    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的规则${NC}"
        return
    fi

    echo -e "${BLUE}请选择要删除的规则:${NC}"
    for i in "${!rules[@]}"; do
        local rule_info=$($iptables_cmd -t nat -L PREROUTING --line-numbers | grep "^${rules[$i]} ")
        echo "$((i+1)). [${origins[$i]}] $rule_info"
    done

    read -p "请输入规则序号(可输入多个，用空格、逗号等分隔): " choices
    if [ -z "$choices" ]; then
        echo -e "${RED}未输入序号${NC}"
        return
    fi

    # 将所有非数字字符转换为空格作为分隔符
    choices=$(echo "$choices" | tr -cs '0-9' ' ')
    read -ra choice_arr <<< "$choices"
    local valid_choices=()
    for sel in "${choice_arr[@]}"; do
        sel=$(echo "$sel" | xargs)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#rules[@]} ]; then
            valid_choices+=("$sel")
        else
            echo -e "${YELLOW}忽略无效序号: $sel${NC}"
        fi
    done

    if [ ${#valid_choices[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的规则序号${NC}"
        return
    fi

    # 对应行号降序排序，避免删除时导致后续行号变化
    sorted_rule_nums=( $(for sel in "${valid_choices[@]}"; do echo "${rules[$((sel-1))]}"; done | sort -nr) )

    if [ "$AUTO_BACKUP" = true ]; then
        backup_rules
    fi

    for rule_num in "${sorted_rule_nums[@]}"; do
        # 查找规则来源
        rule_origin="外部"
        for idx in "${!rules[@]}"; do
            if [ "${rules[$idx]}" = "$rule_num" ]; then
                rule_origin="${origins[$idx]}"
                break
            fi
        done
        if [ "$rule_origin" = "外部" ]; then
            read -p "规则 #$rule_num 来源外部，确定删除? (y/n): " ext_confirm
            if [[ "$ext_confirm" != "y" && "$ext_confirm" != "Y" ]]; then
                echo "已跳过外部规则 #$rule_num"
                continue
            fi
        fi

        if $iptables_cmd -t nat -D PREROUTING "$rule_num"; then
            echo -e "${GREEN}✓ 已删除规则 #$rule_num${NC}"
            log_message "INFO" "删除规则: 行号 $rule_num"
        else
            echo -e "${RED}✗ 删除规则 #$rule_num 失败${NC}"
            log_message "ERROR" "删除规则失败: 行号 $rule_num"
        fi
    done
}

# 修改规则端口
modify_rule_ports() {
    echo -e "${YELLOW}注意: 修改规则需要先删除原规则再添加新规则${NC}"
    echo "这将暂时中断该端口的映射服务"
    read -p "确认继续? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi
    
    delete_specific_rule
    echo -e "\n现在添加新规则:"
    setup_mapping
}

# 启用/禁用规则 (通过注释实现)
toggle_rule_status() {
    echo -e "${YELLOW}此功能通过规则注释管理，暂未实现动态启用/禁用${NC}"
    echo "建议使用删除/添加规则的方式管理"
}

# --- 增强的恢复功能 ---

# 智能恢复默认设置
restore_defaults() {
    echo -e "${BLUE}恢复选项:${NC}"
    echo "1. 仅删除端口映射规则"
    echo "2. 删除规则并恢复备份"
    echo "3. 完全重置iptables (危险)"
    echo "4. 返回主菜单"
    
    read -p "请选择恢复方式 [1-4]: " restore_choice
    
    case $restore_choice in
        1) remove_mapping_rules ;;
        2) remove_and_restore ;;
        3) full_reset_iptables ;;
        4) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 仅删除映射规则
remove_mapping_rules() {
    local iptables_cmd=$(get_iptables_cmd)
    echo "正在查找并删除端口映射规则..."
    
    local rule_lines=($($iptables_cmd -t nat -L PREROUTING --line-numbers | grep "$RULE_COMMENT" | awk '{print $1}' | sort -nr))
    
    if [ ${#rule_lines[@]} -eq 0 ]; then
        echo -e "${GREEN}未找到需要删除的映射规则${NC}"
        return
    fi
    
    echo -e "${BLUE}找到 ${#rule_lines[@]} 条规则需要删除${NC}"
    
    # 自动备份
    if [ "$AUTO_BACKUP" = true ]; then
        backup_rules
    fi
    
    show_current_rules
    echo
    read -p "确认删除这些规则? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消删除操作"
        return
    fi
    
    local deleted_count=0
    local failed_count=0
    
    for line_num in "${rule_lines[@]}"; do
        if $iptables_cmd -t nat -D PREROUTING "$line_num" 2>/dev/null; then
            echo -e "${GREEN}✓ 删除规则 #${line_num}${NC}"
            ((deleted_count++))
        else
            echo -e "${RED}✗ 删除规则 #${line_num} 失败${NC}"
            ((failed_count++))
        fi
    done
    
    echo -e "\n${GREEN}删除完成: 成功 $deleted_count 条, 失败 $failed_count 条${NC}"
    log_message "INFO" "批量删除规则: 成功=$deleted_count, 失败=$failed_count"
    
    if [ $deleted_count -gt 0 ]; then
        read -p "是否永久保存当前状态? (y/n): " save_choice
        if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
            save_rules
        fi
    fi
}

# 删除规则并恢复备份
remove_and_restore() {
    remove_mapping_rules
    echo
    restore_from_backup
}

# 完全重置iptables (危险操作)
full_reset_iptables() {
    echo -e "${RED}警告: 这将完全重置iptables规则!${NC}"
    echo -e "${RED}这可能会断开SSH连接和其他网络服务!${NC}"
    echo
    echo "此操作将:"
    echo "1. 备份当前所有规则"
    echo "2. 清空所有表的所有链"
    echo "3. 设置默认策略为ACCEPT"
    echo
    read -p "您确定要继续吗? 请输入 'RESET' 确认: " confirm
    
    if [ "$confirm" != "RESET" ]; then
        echo "已取消重置操作"
        return
    fi
    
    # 强制备份
    echo "正在备份当前规则..."
    backup_rules
    
    echo "正在重置iptables..."
    
    local iptables_cmd=$(get_iptables_cmd)
    # 清空所有规则
    $iptables_cmd -F
    $iptables_cmd -X
    $iptables_cmd -t nat -F
    $iptables_cmd -t nat -X
    $iptables_cmd -t mangle -F
    $iptables_cmd -t mangle -X
    
    # 设置默认策略
    $iptables_cmd -P INPUT ACCEPT
    $iptables_cmd -P FORWARD ACCEPT
    $iptables_cmd -P OUTPUT ACCEPT
    
    echo -e "${GREEN}✓ iptables已完全重置${NC}"
    log_message "WARNING" "iptables已完全重置"
    
    read -p "是否永久保存重置后的状态? (y/n): " save_choice
    if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
        save_rules
    fi
}

# --- 一键卸载功能 ---

# 删除指定IP版本的规则
delete_rules_by_version() {
    local ip_version=$1
    local iptables_cmd
    local rule_comment="UDP_PORT_MAPPING"
    
    if [ -n "$RULE_COMMENT" ]; then
        rule_comment="$RULE_COMMENT"
    fi
    
    if [ "$ip_version" = "6" ]; then
        iptables_cmd="ip6tables"
    else
        iptables_cmd="iptables"
    fi
    
    echo "正在删除 IPv${ip_version} 规则..."
    echo "  - 调试: 使用规则注释: $rule_comment"
    
    # 检查命令是否存在
    if ! command -v "$iptables_cmd" &>/dev/null; then
        echo "  - 错误: $iptables_cmd 命令不存在"
        return 1
    fi
    
    # 获取规则列表
    local rule_lines=()
    if rule_lines=($($iptables_cmd -t nat -L PREROUTING --line-numbers 2>/dev/null | grep "$rule_comment" | awk '{print $1}' | sort -nr)); then
        echo "  - 调试: 找到 ${#rule_lines[@]} 条规则"
    else
        echo "  - 调试: 获取规则列表失败"
        rule_lines=()
    fi
    
    if [ ${#rule_lines[@]} -eq 0 ]; then
        echo "  - 未找到 IPv${ip_version} 规则"
        return 0
    fi
    
    local deleted_count=0
    for line_num in "${rule_lines[@]}"; do
        echo "  - 尝试删除 IPv${ip_version} 规则 #$line_num"
        if $iptables_cmd -t nat -D PREROUTING "$line_num" 2>/dev/null; then
            echo "  - ✓ 成功删除 IPv${ip_version} 规则 #$line_num"
            ((deleted_count++))
        else
            echo "  - ✗ 删除 IPv${ip_version} 规则 #$line_num 失败"
        fi
    done
    
    echo "  - 总计删除了 $deleted_count 条 IPv${ip_version} 规则"
    return $deleted_count
}

# 清理systemd服务
cleanup_systemd_services() {
    echo "正在清理 systemd 服务..."
    
    # 检查是否在Linux系统且systemctl可用
    if [[ "$OSTYPE" != "linux-gnu" ]] || ! command -v systemctl &>/dev/null; then
        echo "  - 当前系统不支持 systemd 或 systemctl 命令不可用"
        echo "  - 跳过 systemd 服务清理"
        return 1
    fi
    
    local services=("udp-port-mapping.service" "iptables-restore.service")
    local service_files=("/etc/systemd/system/udp-port-mapping.service" "/etc/systemd/system/iptables-restore.service")
    local operation_success=true
    local service_found=false
    
    # 停止并禁用服务
    for service in "${services[@]}"; do
        echo "  - 检查服务: $service"
        if systemctl is-enabled "$service" &>/dev/null; then
            service_found=true
            if systemctl disable "$service" 2>/dev/null; then
                echo "  - ✓ 已禁用 $service"
            else
                echo "  - ✗ 禁用 $service 失败"
                operation_success=false
            fi
        else
            echo "  - 服务 $service 未启用"
        fi
        
        if systemctl is-active "$service" &>/dev/null; then
            service_found=true
            if systemctl stop "$service" 2>/dev/null; then
                echo "  - ✓ 已停止 $service"
            else
                echo "  - ✗ 停止 $service 失败"
                operation_success=false
            fi
        else
            echo "  - 服务 $service 未运行"
        fi
    done
    
    # 删除服务文件
    for service_file in "${service_files[@]}"; do
        echo "  - 检查服务文件: $service_file"
        if [ -f "$service_file" ]; then
            service_found=true
            if rm -f "$service_file" 2>/dev/null; then
                echo "  - ✓ 已删除 $service_file"
            else
                echo "  - ✗ 删除 $service_file 失败 (可能需要权限)"
                operation_success=false
            fi
        else
            echo "  - 服务文件不存在: $service_file"
        fi
    done
    
    # 重新加载systemd
    if systemctl daemon-reload 2>/dev/null; then
        echo "  - ✓ systemd 重新加载完成"
    else
        echo "  - ✗ systemd 重新加载失败"
        operation_success=false
    fi
    
    echo "systemd 服务清理完成"
    
    # 如果没有找到任何服务或服务文件，返回失败
    if [ "$service_found" = false ]; then
        echo "  - 未找到任何 systemd 服务或文件"
        return 1
    fi
    
    # 根据操作结果返回
    if [ "$operation_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# 清理netfilter-persistent状态
cleanup_netfilter_persistent() {
    echo "正在清理 netfilter-persistent 状态..."
    
    if command -v netfilter-persistent &>/dev/null; then
        # 备份当前规则（可选）
        if [ -d "/etc/iptables" ]; then
            echo "  - 检测到 /etc/iptables 目录，可能包含 netfilter-persistent 配置"
            echo "  - 注意：netfilter-persistent 的规则文件需要手动清理"
            return 0
        else
            echo "  - 未找到 /etc/iptables 目录"
            return 1
        fi
    else
        echo "  - netfilter-persistent 命令不可用"
        return 1
    fi
}

# 完全卸载功能
complete_uninstall() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}      完全卸载模式${NC}"
    echo -e "${RED}========================================${NC}"
    echo
    echo "此模式将："
    echo "  ✓ 删除所有 IPv4 和 IPv6 映射规则"
    echo "  ✓ 清理所有 systemd 服务"
    echo "  ✓ 删除配置文件、日志和备份"
    echo "  ✓ 删除脚本文件和快捷方式"
    echo "  ✓ 尝试恢复系统到初始状态"
    echo
    echo -e "${RED}⚠ 此操作不可逆！所有数据将永久丢失！${NC}"
    echo
    
    read -p "确认执行完全卸载? (输入 FULL_UNINSTALL 来确认): " confirm
    if [[ "$confirm" != "FULL_UNINSTALL" ]]; then
        echo -e "${YELLOW}已取消完全卸载${NC}"
        return 1
    fi
    
    echo
    echo "开始执行完全卸载..."
    local success_count=0
    local fail_count=0
    echo
    
    # 1. 删除所有IP版本的规则
    echo "1. 删除所有 iptables 规则..."
    if delete_rules_by_version "4"; then
        echo "  - ✓ IPv4 规则删除成功"
        ((success_count++))
    else
        echo "  - ✗ IPv4 规则删除失败"
        ((fail_count++))
    fi
    
    if delete_rules_by_version "6"; then
        echo "  - ✓ IPv6 规则删除成功"
        ((success_count++))
    else
        echo "  - ✗ IPv6 规则删除失败"
        ((fail_count++))
    fi
    
    # 2. 清理systemd服务
    echo "2. 清理系统服务..."
    if cleanup_systemd_services; then
        echo "  - ✓ systemd 服务清理成功"
        ((success_count++))
    else
        echo "  - ✗ systemd 服务清理失败"
        ((fail_count++))
    fi
    
    # 3. 清理netfilter-persistent
    echo "3. 清理持久化配置..."
    if cleanup_netfilter_persistent; then
        echo "  - ✓ netfilter-persistent 清理成功"
        ((success_count++))
    else
        echo "  - ✗ netfilter-persistent 清理失败"
        ((fail_count++))
    fi
    
    # 4. 保存清理后的状态
    echo "4. 保存系统状态..."
    if save_rules; then
        echo "  - ✓ 系统状态保存成功"
        ((success_count++))
    else
        echo "  - ✗ 系统状态保存失败"
        ((fail_count++))
    fi
    
    # 5. 删除所有文件
    echo "5. 删除所有文件..."
    local files_success=true
    
    if [ -d "$BACKUP_DIR" ]; then
        echo "  - 正在删除备份目录: $BACKUP_DIR"
        if rm -rf "$BACKUP_DIR" 2>/dev/null; then
            echo "  - ✓ 已删除备份目录"
        else
            echo "  - ✗ 删除备份目录失败 (可能需要权限)"
            files_success=false
        fi
    else
        echo "  - 备份目录不存在: $BACKUP_DIR"
    fi
    
    if [ -f "$LOG_FILE" ]; then
        echo "  - 正在删除日志文件: $LOG_FILE"
        if rm -f "$LOG_FILE" 2>/dev/null; then
            echo "  - ✓ 已删除日志文件"
        else
            echo "  - ✗ 删除日志文件失败 (可能需要权限)"
            files_success=false
        fi
    else
        echo "  - 日志文件不存在: $LOG_FILE"
    fi
    
    if [ -d "$CONFIG_DIR" ]; then
        echo "  - 正在删除配置目录: $CONFIG_DIR"
        if rm -rf "$CONFIG_DIR" 2>/dev/null; then
            echo "  - ✓ 已删除配置目录"
        else
            echo "  - ✗ 删除配置目录失败 (可能需要权限)"
            files_success=false
        fi
    else
        echo "  - 配置目录不存在: $CONFIG_DIR"
    fi
    
    if [ "$files_success" = true ]; then
        ((success_count++))
    else
        ((fail_count++))
    fi
    
    # 6. 删除脚本文件
    echo "6. 删除脚本文件..."
    local paths=("/usr/local/bin/port_mapping_manager.sh" "/usr/local/bin/pmm" "/etc/port_mapping_manager/port_mapping_manager.sh" "/etc/port_mapping_manager/pmm" "$(dirname "$0")/pmm")
    local deleted_count=0
    local script_failed=false
    
    for p in "${paths[@]}"; do 
        if [ -f "$p" ]; then
            echo "  - 正在删除: $p"
            if rm -f "$p" 2>/dev/null; then
                echo "  - ✓ 已删除: $p"
                ((deleted_count++))
            else
                echo "  - ✗ 删除失败: $p (可能需要权限)"
                script_failed=true
            fi
        else
            echo "  - 文件不存在: $p"
        fi
    done
    
    if [ "$script_failed" = false ] && [ "$deleted_count" -gt 0 ]; then
        echo "  - ✓ 脚本文件删除成功 (共 $deleted_count 个)"
        ((success_count++))
    else
        echo "  - ✗ 脚本文件删除失败或无文件可删除"
        ((fail_count++))
    fi
    
    # 7. 删除当前脚本
    local current_script="$(realpath "$0" 2>/dev/null || echo "$0")"
    echo "  - 准备删除当前脚本: $current_script"
    
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      完全卸载完成${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo "操作统计: 成功 $success_count 项, 失败 $fail_count 项"
    
    if [ "$fail_count" -eq 0 ]; then
        echo "系统已成功恢复到安装前的状态。"
    else
        echo "部分操作失败，请检查权限或手动重试失败的项目。"
    fi
    echo "注意：某些系统级配置可能需要手动清理。"
    
    # 询问是否删除当前脚本
    echo
    read -p "是否删除当前脚本文件？(y/N): " delete_self
    if [[ "$delete_self" =~ ^[Yy]$ ]]; then
        echo "正在删除当前脚本文件..."
        if rm -f "$current_script" 2>/dev/null; then
            echo "  - ✓ 当前脚本文件已删除"
            echo "脚本已成功删除"
        else
            echo "  - ✗ 删除当前脚本文件失败 (可能需要权限)"
            echo "请手动删除: $current_script"
        fi
    else
        echo "脚本文件保留，请手动删除: $current_script"
    fi
    echo
}

# 不完全卸载功能
partial_uninstall() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}      不完全卸载模式${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo "此模式允许您选择要删除的内容："
    echo
    
    local choices=()
    local descriptions=()
    
    # 检查可用的卸载选项 - 规则检测
    local rule_comment="UDP_PORT_MAPPING"
    if [ -n "$RULE_COMMENT" ]; then
        rule_comment="$RULE_COMMENT"
    fi
    
    echo "调试: 开始检测可卸载内容..."
    
    # 检查iptables规则
    local has_rules=false
    if command -v iptables &>/dev/null; then
        if iptables -t nat -L PREROUTING 2>/dev/null | grep -q "$rule_comment"; then
            has_rules=true
            echo "调试: 检测到 IPv4 规则"
        fi
    fi
    
    if command -v ip6tables &>/dev/null; then
        if ip6tables -t nat -L PREROUTING 2>/dev/null | grep -q "$rule_comment"; then
            has_rules=true
            echo "调试: 检测到 IPv6 规则"
        fi
    fi
    
    if [ "$has_rules" = true ]; then
        choices+=("rules")
        descriptions+=("删除 iptables 映射规则")
    else
        echo "调试: 未检测到映射规则"
    fi
    
    # 检查systemd服务
    local has_systemd=false
    if [[ "$OSTYPE" == "linux-gnu" ]] && command -v systemctl &>/dev/null; then
        if [ -f "/etc/systemd/system/udp-port-mapping.service" ] || 
           [ -f "/etc/systemd/system/iptables-restore.service" ]; then
            has_systemd=true
            echo "调试: 检测到 systemd 服务文件"
        fi
    else
        echo "调试: 系统不支持 systemd 或 systemctl 不可用"
    fi
    
    if [ "$has_systemd" = true ]; then
        choices+=("systemd")
        descriptions+=("删除 systemd 服务")
    fi
    
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        choices+=("backup")
        descriptions+=("删除备份文件")
    fi
    
    if [ -f "$LOG_FILE" ] || [ -d "$CONFIG_DIR" ]; then
        choices+=("config")
        descriptions+=("删除配置和日志")
    fi
    
    # 检查脚本文件
    local has_scripts=false
    local script_paths=("/usr/local/bin/pmm" "/usr/local/bin/port_mapping_manager.sh" 
                       "/etc/port_mapping_manager/pmm" "/etc/port_mapping_manager/port_mapping_manager.sh" 
                       "$(dirname "$0")/pmm")
    
    for path in "${script_paths[@]}"; do
        if [ -f "$path" ]; then
            has_scripts=true
            echo "调试: 检测到脚本文件: $path"
            break
        fi
    done
    
    if [ "$has_scripts" = true ]; then
        choices+=("scripts")
        descriptions+=("删除脚本和快捷方式")
    else
        echo "调试: 未检测到脚本文件"
    fi
    
    if [ ${#choices[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到可卸载的内容${NC}"
        return 0
    fi
    
    # 显示选项
    for i in "${!choices[@]}"; do
        echo "$((i+1)). ${descriptions[i]}"
    done
    echo
    echo "0. 取消卸载"
    echo
    
    # 收集用户选择
    local selected=()
    while true; do
        read -p "请输入要删除的选项编号 (多个用空格分隔): " input
        
        if [[ "$input" == "0" ]]; then
            echo -e "${YELLOW}已取消卸载${NC}"
            return 0
        fi
        
        local valid=true
        for num in $input; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#choices[@]}" ]; then
                local choice="${choices[$((num-1))]}}"
                if [[ ! " ${selected[@]} " =~ " ${choice} " ]]; then
                    selected+=("$choice")
                    echo "  ✓ 已选择: ${descriptions[$((num-1))]}}"
                fi
            else
                valid=false
                break
            fi
        done
        
        if [ "$valid" = true ] && [ ${#selected[@]} -gt 0 ]; then
            break
        else
            echo -e "${RED}输入无效，请重新选择${NC}"
            selected=()
        fi
    done
    
    echo
    echo "选定的卸载内容："
    for choice in "${selected[@]}"; do
        for i in "${!choices[@]}"; do
            if [ "${choices[i]}" = "$choice" ]; then
                echo "  - ${descriptions[i]}"
                break
            fi
        done
    done
    echo
    
    read -p "确认执行选定的卸载操作? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}已取消卸载${NC}"
        return 1
    fi
    
    echo
    echo "开始执行不完全卸载..."
    local success_count=0
    local fail_count=0
    echo
    
    # 执行选定的卸载操作
    for choice in "${selected[@]}"; do
        case "$choice" in
            "rules")
                echo "1. 删除 iptables 规则..."
                local rules_success=true
                
                read -p "  删除 IPv4 规则? (Y/n): " delete_v4
                if [[ ! "$delete_v4" =~ ^[nN]$ ]]; then
                    echo "    正在删除 IPv4 规则..."
                    if delete_rules_by_version "4"; then
                        echo "    ✓ IPv4 规则删除完成"
                    else
                        echo "    ✗ IPv4 规则删除失败"
                        rules_success=false
                    fi
                else
                    echo "    跳过 IPv4 规则删除"
                fi
                
                read -p "  删除 IPv6 规则? (Y/n): " delete_v6
                if [[ ! "$delete_v6" =~ ^[nN]$ ]]; then
                    echo "    正在删除 IPv6 规则..."
                    if delete_rules_by_version "6"; then
                        echo "    ✓ IPv6 规则删除完成"
                    else
                        echo "    ✗ IPv6 规则删除失败"
                        rules_success=false
                    fi
                else
                    echo "    跳过 IPv6 规则删除"
                fi
                
                read -p "  保存当前状态? (Y/n): " save_state
                if [[ ! "$save_state" =~ ^[nN]$ ]]; then
                    echo "    正在保存当前状态..."
                    if save_rules; then
                        echo "    ✓ 状态保存完成"
                    else
                        echo "    ✗ 状态保存失败"
                        rules_success=false
                    fi
                else
                    echo "    跳过状态保存"
                fi
                
                if [ "$rules_success" = true ]; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
                ;;
            "systemd")
                echo "2. 清理 systemd 服务..."
                if [[ "$OSTYPE" == "linux-gnu" ]] && command -v systemctl &>/dev/null; then
                    if cleanup_systemd_services; then
                        echo "  ✓ systemd 服务清理完成"
                        ((success_count++))
                    else
                        echo "  ✗ systemd 服务清理失败"
                        ((fail_count++))
                    fi
                else
                    echo "  - 当前系统不支持 systemd 或 systemctl 不可用"
                    ((fail_count++))
                fi
                ;;
            "backup")
                echo "3. 删除备份文件..."
                if [ -d "$BACKUP_DIR" ]; then
                    echo "  - 正在删除备份目录: $BACKUP_DIR"
                    if rm -rf "$BACKUP_DIR" 2>/dev/null; then
                        echo "  - ✓ 已删除备份目录"
                        ((success_count++))
                    else
                        echo "  - ✗ 删除备份目录失败 (可能需要权限)"
                        ((fail_count++))
                    fi
                else
                    echo "  - 备份目录不存在: $BACKUP_DIR"
                    ((fail_count++))
                fi
                ;;
            "config")
                echo "4. 删除配置和日志..."
                local config_success=false
                local config_deleted=false
                
                if [ -f "$LOG_FILE" ]; then
                    echo "  - 正在删除日志文件: $LOG_FILE"
                    if rm -f "$LOG_FILE" 2>/dev/null; then
                        echo "  - ✓ 已删除日志文件"
                        config_deleted=true
                    else
                        echo "  - ✗ 删除日志文件失败 (可能需要权限)"
                    fi
                else
                    echo "  - 日志文件不存在: $LOG_FILE"
                fi
                
                if [ -d "$CONFIG_DIR" ]; then
                    echo "  - 正在删除配置目录: $CONFIG_DIR"
                    if rm -rf "$CONFIG_DIR" 2>/dev/null; then
                        echo "  - ✓ 已删除配置目录"
                        config_deleted=true
                    else
                        echo "  - ✗ 删除配置目录失败 (可能需要权限)"
                    fi
                else
                    echo "  - 配置目录不存在: $CONFIG_DIR"
                fi
                
                if [ "$config_deleted" = true ]; then
                    config_success=true
                    ((success_count++))
                else
                    ((fail_count++))
                fi
                ;;
            "scripts")
                echo "5. 删除脚本和快捷方式..."
                local paths=("/usr/local/bin/port_mapping_manager.sh" "/usr/local/bin/pmm" 
                           "/etc/port_mapping_manager/port_mapping_manager.sh" "/etc/port_mapping_manager/pmm" 
                           "$(dirname "$0")/pmm")
                local deleted_count=0
                local script_failed=false
                
                for p in "${paths[@]}"; do 
                    if [ -f "$p" ]; then
                        echo "  - 正在删除: $p"
                        if rm -f "$p" 2>/dev/null; then
                            echo "  - ✓ 已删除: $p"
                            ((deleted_count++))
                        else
                            echo "  - ✗ 删除失败: $p (可能需要权限)"
                            script_failed=true
                        fi
                    else
                        echo "  - 文件不存在: $p"
                    fi
                done
                
                if [ "$deleted_count" -gt 0 ]; then
                    if [ "$script_failed" = false ]; then
                        echo "  - ✓ 脚本文件删除成功 (共 $deleted_count 个)"
                        ((success_count++))
                    else
                        echo "  - ⚠ 脚本文件部分删除成功 (成功 $deleted_count 个，部分失败)"
                        ((success_count++))
                    fi
                else
                    echo "  - ✗ 未找到可删除的脚本文件"
                    ((fail_count++))
                fi
                ;;
        esac
        echo
    done
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      不完全卸载完成${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo "操作统计: 成功 $success_count 项, 失败 $fail_count 项"
    
    if [ "$fail_count" -eq 0 ]; then
        echo "已成功删除选定内容，其他内容保持不变。"
    else
        echo "部分操作失败，请检查权限或手动重试失败的项目。"
    fi
}

# 主卸载菜单
uninstall_script() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}      卸载端口映射脚本${NC}"
    echo -e "${RED}========================================${NC}"
    echo
    echo "请选择卸载模式："
    echo
    echo "1. 完全卸载"
    echo "   └─ 删除所有规则、配置、服务和脚本文件"
    echo "   └─ 恢复系统到初始状态"
    echo "   └─ ⚠ 不可逆操作，请谨慎选择"
    echo
    echo "0. 取消卸载"
    echo
    
    while true; do
        read -p "请输入选择 (0-1): " choice
        
        case "$choice" in
            1)
                complete_uninstall
                break
                ;;
            0)
                echo -e "${YELLOW}已取消卸载${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
}

# --- 主程序和菜单 ---

# 显示增强版帮助
show_enhanced_help() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    UDP端口映射脚本 Enhanced v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo
    echo -e "${CYAN}功能特性:${NC}"
    echo "• 智能端口冲突检测"
    echo "• 自动备份和恢复"
    echo "• 批量规则导入/导出"
    echo "• 实时流量监控"
    echo "• 系统诊断功能"
    echo "• 多种持久化方案"
    echo "• 详细的错误处理"
    echo
    echo -e "${CYAN}使用场景:${NC}"
    echo "• Hysteria2 机场端口跳跃"
    echo "• UDP服务负载均衡"
    echo "• 端口隐藏和伪装"
    echo
    echo -e "${CYAN}配置示例:${NC}"
    echo "连接端口: 6000-7000 (客户端连接的端口范围)"
    echo "服务端口: 3000 (实际服务监听的端口)"
    echo "效果: 客户端连接6000-7000任意端口都重定向到3000"
    echo
    echo -e "${CYAN}注意事项:${NC}"
    echo "1. 服务端口不能在连接端口范围内"
    echo "2. 确保防火墙允许相关端口的UDP流量"
    echo "3. 建议定期备份规则配置"
    echo "4. 监控系统性能，避免过多规则"
    echo
    echo -e "${CYAN}文件位置:${NC}"
    echo "配置目录: $CONFIG_DIR"
    echo "日志文件: $LOG_FILE"
    echo "备份目录: $BACKUP_DIR"
    echo
}

# 显示版本信息
show_version() {
    echo -e "${GREEN}UDP端口映射脚本 Enhanced v${SCRIPT_VERSION}${NC}"
    echo "作者: Enhanced by AI Assistant"
    echo "基于: 原始脚本 + GPT增强"
    echo "支持: Hysteria2, v2board, xboard"
    echo
    echo "更新日志:"
    echo "v3.2 - 完善更新检测功能，优化用户体验"
    echo "v3.1 - 增加更新检测功能"
    echo "v3.0 - 全面重构，增加诊断、监控、批量操作等功能"
    echo "v2.0 - 原始版本，基础端口映射功能"
}

# 检查更新功能
check_for_updates() {
    echo -e "${BLUE}正在检查更新...${NC}"
    
    # GitHub仓库信息
    local REPO_URL="https://api.github.com/repos/pjy02/Port-Mapping-Manage"
    local SCRIPT_URL="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/main/port_mapping_manager.sh"
    local INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/main/install_pmm.sh"
    
    # 临时文件
    local temp_file="/tmp/pmm_update_check_$$"
    local temp_script="/tmp/pmm_script_update_$$"
    
    # 检查curl是否可用
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}错误：curl 命令不可用，无法检查更新${NC}"
        echo -e "${YELLOW}请手动安装 curl 后重试${NC}"
        return 1
    fi
    
    # 获取最新版本信息
    if ! curl -s "$REPO_URL" > "$temp_file" 2>/dev/null; then
        echo -e "${RED}错误：无法连接到更新服务器${NC}"
        echo -e "${YELLOW}请检查网络连接或稍后重试${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 调试：显示API响应内容的前几行（已禁用）
    # echo -e "${YELLOW}调试信息：API响应内容${NC}"
    # head -10 "$temp_file" 2>/dev/null | sed 's/^/  /'
    # echo
    
    # 解析版本信息 - 从仓库信息获取
    local remote_version=""
    local release_notes=""
    local default_branch=""
    
    # 获取默认分支
    if grep -q '"default_branch"' "$temp_file"; then
        default_branch=$(grep -o '"default_branch": "[^"]*"' "$temp_file" | cut -d'"' -f4)
        # echo -e "${YELLOW}调试：默认分支: $default_branch${NC}"
    fi
    
    # 如果获取到了默认分支，尝试从该分支的脚本文件获取版本
    if [ -n "$default_branch" ]; then
        local branch_script_url="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/$default_branch/port_mapping_manager.sh"
        # echo -e "${YELLOW}调试：尝试从分支脚本获取版本${NC}"
        if curl -s "$branch_script_url" | grep -q "SCRIPT_VERSION="; then
            remote_version=$(curl -s "$branch_script_url" | grep "SCRIPT_VERSION=" | cut -d'"' -f2 | head -1)
            # echo -e "${YELLOW}调试：从分支脚本获取版本: $remote_version${NC}"
        fi
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    
    # 如果从分支脚本获取失败，尝试从main分支直接获取
    if [ -z "$remote_version" ]; then
        # echo -e "${YELLOW}调试：尝试从main分支直接获取版本信息${NC}"
        if curl -s "$SCRIPT_URL" | grep -q "SCRIPT_VERSION="; then
            remote_version=$(curl -s "$SCRIPT_URL" | grep "SCRIPT_VERSION=" | cut -d'"' -f2 | head -1)
            # echo -e "${YELLOW}调试：从main分支获取版本: $remote_version${NC}"
        fi
    fi
    
    # 检查是否成功获取版本信息
    if [ -z "$remote_version" ]; then
        echo -e "${RED}错误：无法获取远程版本信息${NC}"
        echo -e "${YELLOW}可能的原因：${NC}"
        echo "  1. GitHub API访问受限"
        echo "  2. 仓库不存在或已被删除"
        echo "  3. 网络连接问题"
        echo "  4. 仓库结构可能已更改"
        echo
        echo -e "${CYAN}建议解决方案：${NC}"
        echo "  1. 检查网络连接"
        echo "  2. 稍后重试"
        echo "  3. 手动访问仓库页面: https://github.com/pjy02/Port-Mapping-Manage"
        echo "  4. 检查仓库是否存在且可访问"
        echo
        echo -e "${GREEN}当前版本 v${SCRIPT_VERSION} 可能已经是最新版本${NC}"
        return 1
    fi
    
    echo -e "${CYAN}当前版本: v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}最新版本: v${remote_version}${NC}"
    echo
    
    # 版本比较函数
    version_compare() {
        local v1=$1 v2=$2
        if [[ "$v1" == "$v2" ]]; then
            echo "equal"
            return
        fi
        
        local IFS=.
        local i v1_parts=($v1) v2_parts=($v2)
        
        # 填充短版本号
        while [ ${#v1_parts[@]} -lt ${#v2_parts[@]} ]; do
            v1_parts+=("0")
        done
        while [ ${#v2_parts[@]} -lt ${#v1_parts[@]} ]; do
            v2_parts+=("0")
        done
        
        for ((i=0; i<${#v1_parts[@]}; i++)); do
            if [[ ${v1_parts[i]} -lt ${v2_parts[i]} ]]; then
                echo "older"
                return
            elif [[ ${v1_parts[i]} -gt ${v2_parts[i]} ]]; then
                echo "newer"
                return
            fi
        done
        
        echo "equal"
    }
    
    local comparison=$(version_compare "$SCRIPT_VERSION" "$remote_version")
    
    case $comparison in
        "equal")
            echo -e "${GREEN}✓ 您的脚本已是最新版本${NC}"
            ;;
        "newer")
            echo -e "${YELLOW}⚠ 您的脚本版本比远程版本更新${NC}"
            echo -e "${CYAN}这可能是开发版本或测试版本${NC}"
            ;;
        "older")
            echo -e "${YELLOW}🔄 发现新版本可用！${NC}"
            echo
            echo -e "${BLUE}建议更新到最新版本以获得最佳体验${NC}"
            echo
            
            # 询问是否更新
            read -p "是否要更新到最新版本? [y/N]: " update_choice
            case $update_choice in
                [yY]|[yY][eE][sS])
                    echo -e "${BLUE}正在下载更新...${NC}"
                    
                    # 下载新版本脚本
                    if ! curl -s "$SCRIPT_URL" > "$temp_script" 2>/dev/null; then
                        echo -e "${RED}错误：下载更新失败${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 验证下载的脚本
                    if [ ! -s "$temp_script" ] || ! grep -q "SCRIPT_VERSION=" "$temp_script"; then
                        echo -e "${RED}错误：下载的脚本文件无效${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 备份当前脚本
                    local backup_path="$BACKUP_DIR/script_backup_$(date +%Y%m%d_%H%M%S).sh"
                    cp "$0" "$backup_path"
                    echo -e "${GREEN}✓ 当前脚本已备份到: $backup_path${NC}"
                    
                    # 安装新版本
                    if mv "$temp_script" "$0" && chmod +x "$0"; then
                        echo -e "${GREEN}✓ 更新成功！${NC}"
                        echo -e "${YELLOW}请重新运行脚本以使用新版本${NC}"
                        log_message "INFO" "脚本已从 v${SCRIPT_VERSION} 更新到 v${remote_version}"
                        exit 0
                    else
                        echo -e "${RED}错误：更新失败${NC}"
                        echo -e "${YELLOW}备份文件位置: $backup_path${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    ;;
                *)
                    echo -e "${CYAN}更新已取消${NC}"
                    ;;
            esac
            ;;
    esac
    
    # 提供手动更新选项
    echo
    echo -e "${BLUE}手动更新方法:${NC}"
    echo "1. 运行安装脚本: curl -sL $INSTALL_SCRIPT_URL | bash"
    echo "2. 或直接下载: curl -o port_mapping_manager.sh $SCRIPT_URL"
    echo
}

# 切换IP版本
switch_ip_version() {
    if [ "$IP_VERSION" = "4" ]; then
        IP_VERSION="6"
        echo -e "${GREEN}已切换到 IPv6 模式${NC}"
    else
        IP_VERSION="4"
        echo -e "${GREEN}已切换到 IPv4 模式${NC}"
    fi
    log_message "INFO" "IP版本切换至: IPv${IP_VERSION}"
}

# 主菜单
show_main_menu() {
    clear
    local ip_version_str="IPv${IP_VERSION}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  UDP端口映射管理脚本 Enhanced v${SCRIPT_VERSION}  [当前: ${ip_version_str}]${NC}"
    echo -e "${CYAN}  https://github.com/pjy02/Port-Mapping-Manage${NC}"
    echo -e "${GREEN}=========================================${NC}"

    echo
    echo -e "${BLUE}主要功能:${NC}"
    echo "  1. 设置端口映射 (手动配置)"
    echo "  2. 使用预设配置"
    echo "  3. 查看当前规则"
    echo "  4. 规则管理 (编辑/删除) (需在对应版本下操作)"
    echo "  5. 系统诊断"
    echo
    echo -e "${BLUE}高级功能:${NC}"
    echo "  6. 批量操作 (导入/导出)"
    echo "  7. 备份管理"
    echo "  8. 实时监控"
    echo "  9. 恢复设置"
    echo
    echo -e "${BLUE}其他选项:${NC}"
    echo " 10. 永久保存当前规则"
    echo " 11. 帮助信息"
    echo " 12. 版本信息"
    echo " 13. 切换IP版本 (IPv4/IPv6)"
    echo " 14. 检查更新"
    echo " 15. 退出脚本"
    echo " 99. 卸载脚本"
    echo
    echo "-----------------------------------------"
}

# 批量操作菜单
show_batch_menu() {
    echo -e "${BLUE}批量操作选项:${NC}"
    echo "1. 从文件导入规则"
    echo "2. 导出当前规则"
    echo "3. 生成示例配置文件"
    echo "4. 返回主菜单"
    
    read -p "请选择操作 [1-4]: " batch_choice
    
    case $batch_choice in
        1) batch_import_rules ;;
        2) 
            read -p "导出文件路径 (回车使用默认): " export_path
            batch_export_rules "$export_path"
            ;;
        3) create_sample_config ;;
        4) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 生成示例配置文件
create_sample_config() {
    local sample_file="$CONFIG_DIR/sample_rules.conf"
    
    cat > "$sample_file" << EOF
# UDP端口映射规则配置文件示例
# 格式: start_port:end_port:service_port
# 
# Hysteria2 标准配置
6000:7000:3000
# Hysteria2 备用配置  
8000:9000:4000
# 大范围映射
10000:12000:5000
# 
# 注释行以#开头，空行将被忽略
EOF

    echo -e "${GREEN}✓ 示例配置文件已生成: $sample_file${NC}"
    echo "您可以编辑此文件后使用批量导入功能"
}

# 备份管理菜单
show_backup_menu() {
    echo -e "${BLUE}备份管理选项:${NC}"
    echo "1. 创建新备份"
    echo "2. 查看备份列表"
    echo "3. 恢复备份"
    echo "4. 清理旧备份"
    echo "5. 返回主菜单"
    
    read -p "请选择操作 [1-5]: " backup_choice
    
    case $backup_choice in
        1) backup_rules ;;
        2) list_backups ;;
        3) restore_from_backup ;;
        4) interactive_cleanup_backups ;;
        5) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 列出备份文件
list_backups() {
    echo -e "${BLUE}可用备份文件:${NC}"
    local backups=($(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到备份文件${NC}"
        return
    fi
    
    for i in "${!backups[@]}"; do
        local file=$(basename "${backups[$i]}")
        local size=$(du -h "${backups[$i]}" | cut -f1)
        local date=$(echo "$file" | sed 's/iptables_backup_\(.*\)\.rules/\1/' | sed 's/_/ /g')
        echo "$((i+1)). $date ($size)"
    done
}

# 主程序初始化
initialize_script() {
    # 基础检查
    check_root
    detect_system
    setup_directories
    check_dependencies
    load_config
    
    # 记录启动
    log_message "INFO" "脚本启动 v$SCRIPT_VERSION"
    
    # 显示系统信息
    if [ "$VERBOSE_MODE" = true ]; then
        echo -e "${CYAN}系统信息: $(uname -sr)${NC}"
        echo -e "${CYAN}包管理器: $PACKAGE_MANAGER${NC}"
        echo -e "${CYAN}持久化方法: $PERSISTENT_METHOD${NC}"
        echo
    fi
}

# 主程序循环
main_loop() {
    while true; do
        show_main_menu
        read -p "请选择操作 [1-15/99]: " main_choice
        
        case $main_choice in
            1) setup_mapping ;;
            2) show_port_presets ;;
            3) show_current_rules ;;
            4) edit_rules ;;
            5) diagnose_system ;;
            6) show_batch_menu ;;
            7) show_backup_menu ;;
            8) monitor_traffic ;;
            9) restore_defaults ;;
            10) save_rules ;;
            11) show_enhanced_help ;;
            12) show_version ;;
            13) switch_ip_version ;;
            14) check_for_updates ;;
            15)
                echo -e "${GREEN}感谢使用UDP端口映射脚本！${NC}"
                log_message "INFO" "脚本正常退出"
                exit 0
                ;;
            99)
                uninstall_script
                ;;
            *) 
                echo -e "${RED}无效选择，请输入 1-15 或 99${NC}"
                ;;
        esac
        
        echo
        read -p "按回车键继续..." -r
        echo
    done
}

# --- 脚本主入口 ---

# 处理命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE_MODE=true
            shift
            ;;
        -h|--help)
            show_enhanced_help
            exit 0
            ;;
        --version)
            show_version
            exit 0
            ;;
        --no-backup)
            AUTO_BACKUP=false
            shift
            ;;
        --uninstall)
            uninstall_script
            ;;
        *)
            echo "未知参数: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 主程序执行
main() {
    # 初始化
    initialize_script
    
    # 进入主循环
    main_loop
}

# 错误处理
trap 'echo -e "\n${RED}脚本被中断${NC}"; log_message "WARNING" "脚本被用户中断"; exit 1' INT TERM

# 启动脚本
main "$@"
