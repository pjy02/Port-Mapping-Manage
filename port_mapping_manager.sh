#!/bin/bash

# TCP/UDP端口映射管理脚本 Enhanced v4.0
# 适用于 Hysteria2 机场端口跳跃配置
# 增强版本包含：安全性改进、错误处理、批量操作、监控诊断、性能优化等功能

# 脚本配置
SCRIPT_VERSION="4.0"
RULE_COMMENT="udp-port-mapping-script-v4"
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

# 性能优化缓存变量
IPTABLES_CACHE_FILE=""
IPTABLES_CACHE_TIMESTAMP=0
IPTABLES_CACHE_TTL=30  # 缓存有效期30秒
RULES_CACHE=""
RULES_CACHE_TIMESTAMP=0

# 临时文件跟踪数组
TEMP_FILES=()

# 信号处理器 - 清理临时文件
cleanup_temp_files() {
    local exit_code=${1:-0}
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        log_message "INFO" "清理 ${#TEMP_FILES[@]} 个临时文件"
        for temp_file in "${TEMP_FILES[@]}"; do
            if [ -f "$temp_file" ]; then
                rm -f "$temp_file" 2>/dev/null
                log_message "DEBUG" "已清理临时文件: $temp_file"
            fi
        done
        TEMP_FILES=()
    fi
    
    # 清理缓存文件
    if [ -n "$IPTABLES_CACHE_FILE" ] && [ -f "$IPTABLES_CACHE_FILE" ]; then
        rm -f "$IPTABLES_CACHE_FILE" 2>/dev/null
    fi
    
    # 如果是异常退出，记录日志
    if [ "$exit_code" -ne 0 ]; then
        log_message "WARNING" "脚本异常退出，已清理临时文件"
    fi
}

# 注册临时文件
register_temp_file() {
    local temp_file="$1"
    if [ -n "$temp_file" ]; then
        TEMP_FILES+=("$temp_file")
        log_message "DEBUG" "注册临时文件: $temp_file"
    fi
}

# 设置信号处理器
trap 'cleanup_temp_files 1; exit 1' INT TERM
trap 'cleanup_temp_files 0' EXIT

# --- 日志和安全函数 ---

# 日志记录函数
log_message() {
    local level=$1
    local message=$2
    local function_name=${3:-"${FUNCNAME[1]}"}  # 自动获取调用函数名
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    
    # 确保日志目录存在
    if [ -n "$LOG_FILE" ]; then
        local log_dir=$(dirname "$LOG_FILE")
        [ ! -d "$log_dir" ] && mkdir -p "$log_dir" 2>/dev/null
    fi
    
    # 构建日志条目
    local log_entry="[$timestamp] [PID:$pid] [$level] [$function_name] $message"
    
    # 写入日志文件
    if [ -n "$LOG_FILE" ]; then
        echo "$log_entry" >> "$LOG_FILE" 2>/dev/null
    fi
    
    # 根据级别和详细模式决定是否显示到控制台
    case "$level" in
        "ERROR"|"CRITICAL")
            echo -e "${RED}[$level] $message${NC}" >&2
            ;;
        "WARNING")
            [ "$VERBOSE_MODE" = true ] && echo -e "${YELLOW}[$level] $message${NC}"
            ;;
        "INFO")
            [ "$VERBOSE_MODE" = true ] && echo -e "${GREEN}[$level] $message${NC}"
            ;;
        "DEBUG")
            [ "$VERBOSE_MODE" = true ] && echo -e "${CYAN}[$level] $message${NC}"
            ;;
    esac
}

# 输入安全验证
sanitize_input() {
    local input="$1"
    local type="${2:-default}"
    
    case "$type" in
        "port")
            # 端口号只允许数字
            echo "$input" | sed 's/[^0-9]//g'
            ;;
        "filename")
            # 文件名允许字母数字和安全字符
            echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
            ;;
        "ip")
            # IP地址允许数字、点号和冒号(IPv6)
            echo "$input" | sed 's/[^0-9a-fA-F.:]//g'
            ;;
        "protocol")
            # 协议只允许字母
            echo "$input" | sed 's/[^a-zA-Z]//g' | tr '[:upper:]' '[:lower:]'
            ;;
        *)
            # 默认清理：只允许数字、字母、短横线、下划线
            echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
            ;;
    esac
}

# 验证环境变量和系统状态
validate_environment() {
    local errors=0
    
    # 检查必要的环境变量
    if [ -z "$CONFIG_DIR" ]; then
        echo -e "${RED}错误: CONFIG_DIR 未设置${NC}"
        log_message "ERROR" "CONFIG_DIR 环境变量未设置"
        ((errors++))
    elif [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${YELLOW}警告: CONFIG_DIR 目录不存在，正在创建...${NC}"
        if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
            echo -e "${RED}错误: 无法创建 CONFIG_DIR: $CONFIG_DIR${NC}"
            log_message "ERROR" "无法创建 CONFIG_DIR: $CONFIG_DIR"
            ((errors++))
        fi
    fi
    
    if [ -z "$BACKUP_DIR" ]; then
        echo -e "${RED}错误: BACKUP_DIR 未设置${NC}"
        log_message "ERROR" "BACKUP_DIR 环境变量未设置"
        ((errors++))
    elif [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${YELLOW}警告: BACKUP_DIR 目录不存在，正在创建...${NC}"
        if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
            echo -e "${RED}错误: 无法创建 BACKUP_DIR: $BACKUP_DIR${NC}"
            log_message "ERROR" "无法创建 BACKUP_DIR: $BACKUP_DIR"
            ((errors++))
        fi
    fi
    
    if [ -z "$LOG_FILE" ]; then
        echo -e "${RED}错误: LOG_FILE 未设置${NC}"
        log_message "ERROR" "LOG_FILE 环境变量未设置"
        ((errors++))
    else
        # 确保日志文件目录存在
        local log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            if ! mkdir -p "$log_dir" 2>/dev/null; then
                echo -e "${RED}错误: 无法创建日志目录: $log_dir${NC}"
                ((errors++))
            fi
        fi
        # 确保日志文件可写
        if ! touch "$LOG_FILE" 2>/dev/null; then
            echo -e "${RED}错误: 无法写入日志文件: $LOG_FILE${NC}"
            ((errors++))
        fi
    fi
    
    if [ -z "$IP_VERSION" ]; then
        echo -e "${YELLOW}警告: IP_VERSION 未设置，使用默认值 4${NC}"
        IP_VERSION="4"
        log_message "WARNING" "IP_VERSION 未设置，使用默认值 4"
    elif [[ ! "$IP_VERSION" =~ ^[46]$ ]]; then
        echo -e "${RED}错误: IP_VERSION 必须是 4 或 6${NC}"
        log_message "ERROR" "IP_VERSION 值无效: $IP_VERSION"
        ((errors++))
    fi
    
    if [ -z "$RULE_COMMENT" ]; then
        echo -e "${YELLOW}警告: RULE_COMMENT 未设置，使用默认值${NC}"
        RULE_COMMENT="udp-port-mapping-script-v3"
        log_message "WARNING" "RULE_COMMENT 未设置，使用默认值"
    fi
    
    # 检查关键命令的可用性
    local required_commands=("iptables" "iptables-save" "ss" "grep" "awk" "sed")
    if [ "$IP_VERSION" = "6" ]; then
        required_commands+=("ip6tables" "ip6tables-save")
    fi
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}错误: 必需命令不可用: $cmd${NC}"
            log_message "ERROR" "必需命令不可用: $cmd"
            ((errors++))
        fi
    done
    
    # 检查权限
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 需要 root 权限${NC}"
        log_message "ERROR" "权限不足，需要 root 权限"
        ((errors++))
    fi
    
    # 检查 iptables 功能
    local iptables_cmd=$(get_iptables_cmd)
    if ! $iptables_cmd -t nat -L >/dev/null 2>&1; then
        echo -e "${RED}错误: $iptables_cmd NAT 功能不可用${NC}"
        log_message "ERROR" "$iptables_cmd NAT 功能不可用"
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        log_message "INFO" "环境验证通过"
        return 0
    else
        log_message "ERROR" "环境验证失败，发现 $errors 个问题"
        return $errors
    fi
}

# --- 性能优化缓存函数 ---

# 缓存 iptables 规则
cache_iptables_rules() {
    local ip_version=${1:-$IP_VERSION}
    local current_time=$(date +%s)
    local cache_key="iptables_${ip_version}"
    
    # 检查缓存是否仍然有效
    if [ -n "$RULES_CACHE" ] && [ $((current_time - RULES_CACHE_TIMESTAMP)) -lt $IPTABLES_CACHE_TTL ]; then
        log_message "DEBUG" "使用缓存的 iptables 规则"
        echo "$RULES_CACHE"
        return 0
    fi
    
    local iptables_cmd=$(get_iptables_cmd "$ip_version")
    if [ -z "$iptables_cmd" ]; then
        log_message "ERROR" "无法获取 iptables 命令"
        return 1
    fi
    
    log_message "DEBUG" "刷新 iptables 规则缓存"
    if RULES_CACHE=$($iptables_cmd -t nat -L PREROUTING -n --line-numbers 2>/dev/null); then
        RULES_CACHE_TIMESTAMP=$current_time
        echo "$RULES_CACHE"
        return 0
    else
        log_message "ERROR" "获取 iptables 规则失败"
        return 1
    fi
}

# 清除缓存
clear_iptables_cache() {
    log_message "DEBUG" "清除 iptables 缓存"
    RULES_CACHE=""
    RULES_CACHE_TIMESTAMP=0
    
    # 清理临时缓存文件
    if [ -n "$IPTABLES_CACHE_FILE" ] && [ -f "$IPTABLES_CACHE_FILE" ]; then
        rm -f "$IPTABLES_CACHE_FILE" 2>/dev/null
        IPTABLES_CACHE_FILE=""
    fi
}

# 批量获取端口状态（性能优化）
batch_check_port_status() {
    local ports=("$@")
    local tcp_ports=()
    local udp_ports=()
    
    if [ ${#ports[@]} -eq 0 ]; then
        return 0
    fi
    
    log_message "DEBUG" "批量检查 ${#ports[@]} 个端口状态"
    
    # 一次性获取所有监听端口
    local tcp_listening=$(ss -tlnp 2>/dev/null | awk '{print $4}' | grep -o ':[0-9]*$' | sed 's/://' | sort -n | uniq)
    local udp_listening=$(ss -ulnp 2>/dev/null | awk '{print $4}' | grep -o ':[0-9]*$' | sed 's/://' | sort -n | uniq)
    
    # 检查每个端口
    for port_info in "${ports[@]}"; do
        local port=$(echo "$port_info" | cut -d: -f1)
        local protocol=$(echo "$port_info" | cut -d: -f2)
        
        if [ "$protocol" = "tcp" ]; then
            if echo "$tcp_listening" | grep -q "^${port}$"; then
                echo "${port}:tcp:active"
            else
                echo "${port}:tcp:inactive"
            fi
        else
            if echo "$udp_listening" | grep -q "^${port}$"; then
                echo "${port}:udp:active"
            else
                echo "${port}:udp:inactive"
            fi
        fi
    done
}

# 优化的规则计数
count_mapping_rules() {
    local ip_version=${1:-$IP_VERSION}
    
    # 尝试从缓存获取
    local rules
    if ! rules=$(cache_iptables_rules "$ip_version"); then
        return 0
    fi
    
    # 计算包含脚本注释的规则数量
    echo "$rules" | grep -c "$RULE_COMMENT" 2>/dev/null || echo "0"
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
    local ip_version=${1:-$IP_VERSION}  # 接受参数，默认使用全局变量
    if [ "$ip_version" = "6" ]; then
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
        return 1
    fi
    return 0
}

# 交互式清理备份文件
interactive_cleanup_backups() {
    # 使用更兼容的方式处理文件列表
    local backup_files
    backup_files=$(ls -1t "$BACKUP_DIR"/iptables_backup_*.rules 2>/dev/null)
    
    if [ -z "$backup_files" ]; then
        echo -e "${YELLOW}未找到备份文件${NC}"
        return
    fi
    
    echo -e "${BLUE}备份列表:${NC}"
    local i=1
    local backup_array=()
    while IFS= read -r backup_file; do
        if [ -f "$backup_file" ]; then
            backup_array+=("$backup_file")
            local file=$(basename "$backup_file")
            local size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
            local date=$(echo "$file" | sed 's/iptables_backup_\(.*\)\.rules/\1/' | sed 's/_/ /g')
            echo "$i. $date ($size)"
            ((i++))
        fi
    done <<< "$backup_files"
    
    if [ ${#backup_array[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到有效的备份文件${NC}"
        return
    fi
    
    echo
    read -p "请输入要删除的备份序号(可输入多个，用空格、逗号等分隔，输入 all 删除全部): " choices
    
    if [ "$choices" = "all" ]; then
        local deleted_count=0
        for backup_file in "${backup_array[@]}"; do
            if rm -f "$backup_file"; then
                ((deleted_count++))
            fi
        done
        echo -e "${GREEN}✓ 已删除 $deleted_count 个备份文件${NC}"
        log_message "INFO" "删除全部备份文件: $deleted_count 个"
        return
    fi

    # 将所有非数字字符转换为空格作为分隔符
    choices=$(echo "$choices" | tr -cs '0-9' ' ')
    local deleted=0
    
    # 使用更兼容的方式处理选择的序号
    for sel in $choices; do
        sel=$(echo "$sel" | xargs)  # 去除空白字符
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#backup_array[@]} ]; then
            local target="${backup_array[$((sel-1))]}"
            if [ -f "$target" ] && rm -f "$target"; then
                echo -e "${GREEN}✓ 删除备份: $(basename "$target")${NC}"
                ((deleted++))
            else
                echo -e "${RED}✗ 无法删除: $(basename "$target")${NC}"
            fi
        elif [ -n "$sel" ]; then
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
        return 1
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
            return 1
            ;;
    esac
}

# --- 增强的验证函数 ---

# 端口验证函数
validate_port() {
    local port=$1
    local port_name=$2
    
    # 输入清理
    port=$(sanitize_input "$port" "port")
    
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
    
    # 根据当前IP版本获取对应的iptables命令
    local iptables_cmd=$(get_iptables_cmd)
    
    # 检查现有iptables规则冲突
    local conflicts=$($iptables_cmd -t nat -L PREROUTING -n | grep -E "dpt:($start_port|$end_port|$service_port)([^0-9]|$)")
    
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
    local protocol=${4:-"udp"}
    
    # 验证参数
    if [ -z "$start_port" ] || [ -z "$end_port" ] || [ -z "$service_port" ]; then
        echo -e "${RED}错误: save_mapping_config 参数不完整${NC}"
        log_message "ERROR" "save_mapping_config 参数不完整: start=$start_port, end=$end_port, service=$service_port"
        return 1
    fi
    
    # 验证配置目录
    if [ -z "$CONFIG_DIR" ]; then
        echo -e "${RED}错误: CONFIG_DIR 未设置${NC}"
        log_message "ERROR" "CONFIG_DIR 未设置"
        return 1
    fi
    
    # 确保配置目录存在
    if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        echo -e "${RED}错误: 无法创建配置目录: $CONFIG_DIR${NC}"
        log_message "ERROR" "无法创建配置目录: $CONFIG_DIR"
        return 1
    fi
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local config_file="$CONFIG_DIR/mappings.conf"
    
    # 尝试写入配置
    if ! cat >> "$config_file" << EOF
# 添加时间: $(date)
# 协议: $protocol, IP版本: IPv$IP_VERSION
MAPPING_${timestamp}_START=$start_port
MAPPING_${timestamp}_END=$end_port
MAPPING_${timestamp}_SERVICE=$service_port
MAPPING_${timestamp}_PROTOCOL=$protocol
MAPPING_${timestamp}_IP_VERSION=$IP_VERSION

EOF
    then
        echo -e "${RED}错误: 无法写入配置文件: $config_file${NC}"
        log_message "ERROR" "无法写入配置文件: $config_file"
        return 1
    fi
    
    # 验证写入是否成功
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}错误: 配置文件创建失败: $config_file${NC}"
        log_message "ERROR" "配置文件创建失败: $config_file"
        return 1
    fi
    
    log_message "INFO" "配置已保存: ${protocol^^} ${start_port}-${end_port} -> ${service_port}"
    return 0
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
    
    log_message "DEBUG" "显示 IPv${ip_version} 规则"
    echo -e "\n${YELLOW}--- IPv${ip_version} 规则 ---${NC}"

    # 使用缓存获取规则
    local rules
    if ! rules=$(cache_iptables_rules "$ip_version"); then
        echo -e "${RED}获取 IPv${ip_version} 规则失败${NC}"
        return 0
    fi

    if [ -z "$rules" ] || [[ $(echo "$rules" | wc -l) -le 2 ]]; then
        echo -e "${YELLOW}未找到 IPv${ip_version} 映射规则。${NC}"
        return 0
    fi

    printf "%-4s %-18s %-8s %-15s %-15s %-20s %-10s %-6s\n" \
        "No." "Type" "Prot" "Source" "Destination" "PortRange" "DstPort" "From"
    echo "---------------------------------------------------------------------------------"

    # 收集所有需要检查状态的端口信息
    local ports_to_check=()
    local rule_data=()
    local rule_count=0
    
    while IFS= read -r rule; do
        if [[ "$rule" =~ ^Chain[[:space:]] ]] || [[ "$rule" =~ ^num[[:space:]] ]]; then
            continue
        fi
        
        local line_num=$(echo "$rule" | awk '{print $1}')
        local target=$(echo "$rule" | awk '{print $2}')
        local protocol=$(echo "$rule" | awk '{print $3}')
        # 将协议数值转换为协议名称
        case "$protocol" in
            6) protocol="tcp" ;;
            17) protocol="udp" ;;
            0) protocol="all" ;;
        esac
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

        # 存储规则数据
        rule_data+=("$line_num|$target|$protocol|$source|$destination|$port_range|$redirect_port|$origin")
        
        # 收集端口检查信息
        if [ -n "$redirect_port" ] && [ -n "$protocol" ]; then
            ports_to_check+=("$redirect_port:$protocol")
        fi
        
        ((rule_count++))
    done <<< "$rules"

    # 批量检查端口状态（性能优化）
    local port_status_map=""
    if [ ${#ports_to_check[@]} -gt 0 ]; then
        log_message "DEBUG" "批量检查 ${#ports_to_check[@]} 个端口状态"
        port_status_map=$(batch_check_port_status "${ports_to_check[@]}")
    fi

    # 显示规则
    for rule_info in "${rule_data[@]}"; do
        IFS='|' read -r line_num target protocol source destination port_range redirect_port origin <<< "$rule_info"
        
        local status="🔴"
        if [ -n "$redirect_port" ] && [ -n "$protocol" ]; then
            if echo "$port_status_map" | grep -q "^${redirect_port}:${protocol}:active$"; then
                status="🟢"
            fi
        fi

        printf "%-4s %-18s %-8s %-15s %-15s %-20s %-10s %-6s %s\n" \
            "$line_num" "$target" "$protocol" "$source" "$destination" \
            "$port_range" "$redirect_port" "$origin" "$status"
    done

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
    local protocol=${3:-"udp"}  # 添加协议参数，默认为udp
    
    # 根据协议检查服务端口是否在监听
    if [ "$protocol" = "tcp" ]; then
        if ss -tlnp | grep -q ":$service_port "; then
            return 0
        fi
    else
        if ss -ulnp | grep -q ":$service_port "; then
            return 0
        fi
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
    
    # 验证环境变量
    if ! validate_environment; then
        echo -e "${RED}✗ 环境验证失败，无法继续${NC}"
        return 1
    fi
    
    # 自动备份
    local backup_file=""
    if [ "$AUTO_BACKUP" = true ]; then
        echo "正在备份当前规则..."
        if backup_rules; then
            backup_file="$BACKUP_DIR/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
            log_message "INFO" "备份成功: $backup_file"
        else
            echo -e "${YELLOW}⚠ 备份失败，但继续执行${NC}"
            log_message "WARNING" "规则备份失败"
        fi
    fi

    echo "正在添加端口映射规则..."
    
    # 根据IP_VERSION获取对应的iptables命令
    local iptables_cmd=$(get_iptables_cmd)
    if [ -z "$iptables_cmd" ]; then
        echo -e "${RED}✗ 无法获取 iptables 命令${NC}"
        log_message "ERROR" "无法获取 iptables 命令"
        return 1
    fi

    # 验证 iptables 命令可用性
    if ! command -v "$iptables_cmd" &>/dev/null; then
        echo -e "${RED}✗ $iptables_cmd 命令不可用${NC}"
        log_message "ERROR" "$iptables_cmd 命令不可用"
        return 1
    fi

    # 添加规则
    local rule_output
    rule_output=$($iptables_cmd -t nat -A PREROUTING -p $protocol --dport "$start_port:$end_port" \
       -m comment --comment "$RULE_COMMENT" \
       -j REDIRECT --to-port "$service_port" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ 映射规则添加成功: ${protocol^^} ${start_port}-${end_port} -> ${service_port}${NC}"
        log_message "INFO" "添加规则: ${protocol^^} ${start_port}-${end_port} -> ${service_port}"
        
        # 保存配置
        if ! save_mapping_config "$start_port" "$end_port" "$service_port" "$protocol"; then
            echo -e "${YELLOW}⚠ 配置保存失败，但规则已生效${NC}"
            log_message "WARNING" "配置保存失败"
        fi
        
        # 显示规则状态
        show_current_rules
        
        # 询问是否永久保存
        read -p "是否将规则永久保存? (y/n): " save_choice
        if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
            if ! save_rules; then
                echo -e "${YELLOW}⚠ 永久保存失败，规则仅为临时规则${NC}"
                log_message "WARNING" "规则永久保存失败"
            fi
        else
            echo -e "${YELLOW}注意：规则仅为临时规则，重启后将失效。${NC}"
        fi
        
    else
        echo -e "${RED}✗ 添加规则失败${NC}"
        if [ -n "$rule_output" ]; then
            echo -e "${RED}错误详情: $rule_output${NC}"
            log_message "ERROR" "添加规则失败: $rule_output"
        fi
        handle_iptables_error $exit_code "添加规则"
        
        # 如果有备份，询问是否恢复
        if [ "$AUTO_BACKUP" = true ] && [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            read -p "是否恢复到添加规则前的状态? (y/n): " restore_choice
            if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
                if $iptables_cmd-restore < "$backup_file" 2>/dev/null; then
                    echo -e "${GREEN}✓ 已恢复到备份状态${NC}"
                    log_message "INFO" "已恢复到备份状态: $backup_file"
                else
                    echo -e "${RED}✗ 恢复备份失败${NC}"
                    log_message "ERROR" "恢复备份失败: $backup_file"
                fi
            fi
        fi
        
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
    
    # 检查并清理可能存在的旧服务
    if [ -f "$service_file" ]; then
        echo "正在清理旧的 systemd 服务..."
        systemctl disable udp-port-mapping.service 2>/dev/null
        systemctl stop udp-port-mapping.service 2>/dev/null
        rm -f "$service_file"
        systemctl daemon-reload
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=UDP Port Mapping Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $CONFIG_DIR/current.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable udp-port-mapping.service
    echo -e "${GREEN}已创建systemd服务用于规则持久化${NC}"
}

# 显示手动保存说明
show_manual_save_instructions() {
    echo -e "${BLUE}========== 手动持久化规则说明 ==========${NC}"
    echo
    echo -e "${YELLOW}如果自动持久化失败，您可以尝试以下手动方法：${NC}"
    echo
    
    echo -e "${CYAN}方法1: 使用系统持久化包${NC}"
    case $PACKAGE_MANAGER in
        "apt")
            echo "  # 安装 iptables-persistent"
            echo "  apt-get update && apt-get install -y iptables-persistent"
            echo "  # 保存规则"
            echo "  iptables-save > /etc/iptables/rules.v4"
            echo "  ip6tables-save > /etc/iptables/rules.v6"
            echo "  # 或使用命令"
            echo "  netfilter-persistent save"
            ;;
        "yum"|"dnf")
            echo "  # 安装 iptables-services"
            echo "  $PACKAGE_MANAGER install -y iptables-services"
            echo "  # 启用服务"
            echo "  systemctl enable iptables ip6tables"
            echo "  # 保存规则"
            echo "  service iptables save"
            echo "  service ip6tables save"
            ;;
        *)
            echo "  # 根据您的发行版安装相应的持久化包"
            echo "  # 然后保存规则到系统默认位置"
            ;;
    esac
    
    echo
    echo -e "${CYAN}方法2: 使用 rc.local${NC}"
    echo "  # 编辑 /etc/rc.local 文件"
    echo "  nano /etc/rc.local"
    echo "  # 在 'exit 0' 之前添加："
    echo "  $CONFIG_DIR/restore-rules.sh"
    echo "  # 确保文件可执行"
    echo "  chmod +x /etc/rc.local"
    
    echo
    echo -e "${CYAN}方法3: 使用 crontab${NC}"
    echo "  # 添加开机任务"
    echo "  (crontab -l 2>/dev/null; echo '@reboot $CONFIG_DIR/restore-rules.sh') | crontab -"
    
    echo
    echo -e "${CYAN}方法4: 手动创建 systemd 服务${NC}"
    echo "  # 创建服务文件"
    echo "  cat > /etc/systemd/system/iptables-restore.service <<EOF"
    echo "  [Unit]"
    echo "  Description=Restore iptables rules"
    echo "  After=network.target"
    echo "  "
    echo "  [Service]"
    echo "  Type=oneshot"
    echo "  ExecStart=$CONFIG_DIR/restore-rules.sh"
    echo "  RemainAfterExit=yes"
    echo "  "
    echo "  [Install]"
    echo "  WantedBy=multi-user.target"
    echo "  EOF"
    echo "  # 启用服务"
    echo "  systemctl daemon-reload"
    echo "  systemctl enable iptables-restore.service"
    
    echo
    echo -e "${CYAN}方法5: 网络接口启动脚本 (Debian/Ubuntu)${NC}"
    echo "  # 创建接口启动脚本"
    echo "  cat > /etc/network/if-up.d/iptables-restore <<EOF"
    echo "  #!/bin/bash"
    echo "  if [ \"\$IFACE\" != \"lo\" ]; then"
    echo "      $CONFIG_DIR/restore-rules.sh"
    echo "  fi"
    echo "  EOF"
    echo "  chmod +x /etc/network/if-up.d/iptables-restore"
    
    echo
    echo -e "${GREEN}验证持久化是否生效：${NC}"
    echo "1. 重启系统: reboot"
    echo "2. 检查规则: iptables -t nat -L PREROUTING -n"
    echo "3. 查看服务状态: systemctl status iptables-restore.service"
    echo "4. 查看日志: journalctl -u iptables-restore.service"
    
    echo
    echo -e "${YELLOW}注意事项：${NC}"
    echo "• 规则文件位置: $CONFIG_DIR/current.rules.v4 和 current.rules.v6"
    echo "• 恢复脚本位置: $CONFIG_DIR/restore-rules.sh"
    echo "• 确保脚本有执行权限: chmod +x $CONFIG_DIR/restore-rules.sh"
    echo "• 建议定期备份规则文件"
    
    echo
    echo -e "${BLUE}=========================================${NC}"
}

# 检查和修复持久化配置
check_and_fix_persistence() {
    echo -e "${BLUE}========== 检查持久化配置 ==========${NC}"
    local service_file="/etc/systemd/system/iptables-restore.service"
    local restore_script="$CONFIG_DIR/restore-rules.sh"
    local fixed=false
    local issues_found=0
    
    echo "正在进行全面的持久化配置检查..."
    echo
    
    # 1. 检查规则文件是否存在
    echo "1. 检查规则文件..."
    local rules_exist=false
    if [ -f "$CONFIG_DIR/current.rules.v4" ]; then
        echo "  ✓ IPv4 规则文件存在: $CONFIG_DIR/current.rules.v4"
        rules_exist=true
    else
        echo "  ✗ IPv4 规则文件不存在"
        ((issues_found++))
    fi
    
    if [ -f "$CONFIG_DIR/current.rules.v6" ]; then
        echo "  ✓ IPv6 规则文件存在: $CONFIG_DIR/current.rules.v6"
        rules_exist=true
    else
        echo "  ✗ IPv6 规则文件不存在"
        ((issues_found++))
    fi
    
    if [ "$rules_exist" = false ]; then
        echo "  ⚠ 未找到任何规则文件，尝试保存当前规则..."
        if save_rules; then
            echo "  ✓ 规则保存成功"
            fixed=true
        else
            echo "  ✗ 规则保存失败"
            return 1
        fi
    fi
    
    # 2. 检查恢复脚本
    echo
    echo "2. 检查恢复脚本..."
    if [ -f "$restore_script" ]; then
        if [ -x "$restore_script" ]; then
            echo "  ✓ 恢复脚本存在且可执行: $restore_script"
        else
            echo "  ⚠ 恢复脚本存在但不可执行，正在修复..."
            chmod +x "$restore_script"
            echo "  ✓ 恢复脚本权限已修复"
            fixed=true
        fi
    else
        echo "  ✗ 恢复脚本不存在，正在创建..."
        create_restore_script
        echo "  ✓ 恢复脚本已创建"
        fixed=true
        ((issues_found++))
    fi
    
    # 3. 检查 systemd 服务
    echo
    echo "3. 检查 systemd 服务..."
    if [ -f "$service_file" ]; then
        echo "  ✓ systemd 服务文件存在: $service_file"
        
        # 检查服务是否启用
        if systemctl is-enabled iptables-restore.service >/dev/null 2>&1; then
            echo "  ✓ systemd 服务已启用"
        else
            echo "  ⚠ systemd 服务未启用，正在启用..."
            if systemctl enable iptables-restore.service; then
                echo "  ✓ systemd 服务已启用"
                fixed=true
            else
                echo "  ✗ systemd 服务启用失败"
                ((issues_found++))
            fi
        fi
        
        # 检查服务配置是否正确
        if grep -q "$restore_script" "$service_file" 2>/dev/null; then
            echo "  ✓ systemd 服务配置正确"
        else
            echo "  ⚠ systemd 服务配置不正确，正在修复..."
            setup_systemd_service
            echo "  ✓ systemd 服务配置已修复"
            fixed=true
        fi
        
        # 测试服务是否能正常启动
        echo "  正在测试 systemd 服务..."
        if systemctl start iptables-restore.service 2>/dev/null; then
            echo "  ✓ systemd 服务测试成功"
        else
            echo "  ⚠ systemd 服务测试失败，查看详细信息:"
            echo "    journalctl -u iptables-restore.service --no-pager -n 5"
            ((issues_found++))
        fi
    else
        echo "  ✗ systemd 服务文件不存在，正在创建..."
        if setup_systemd_service; then
            echo "  ✓ systemd 服务创建成功"
            fixed=true
        else
            echo "  ✗ systemd 服务创建失败"
            ((issues_found++))
        fi
    fi
    
    # 4. 检查系统持久化方法
    echo
    echo "4. 检查系统持久化方法..."
    case $PERSISTENT_METHOD in
        "netfilter-persistent")
            if command -v netfilter-persistent &> /dev/null; then
                echo "  ✓ netfilter-persistent 可用"
                if [ -f "/etc/iptables/rules.v4" ] || [ -f "/etc/iptables/rules.v6" ]; then
                    echo "  ✓ 系统持久化文件存在"
                else
                    echo "  ⚠ 系统持久化文件不存在，正在创建..."
                    mkdir -p /etc/iptables
                    [ -f "$CONFIG_DIR/current.rules.v4" ] && cp "$CONFIG_DIR/current.rules.v4" /etc/iptables/rules.v4
                    [ -f "$CONFIG_DIR/current.rules.v6" ] && cp "$CONFIG_DIR/current.rules.v6" /etc/iptables/rules.v6
                    echo "  ✓ 系统持久化文件已创建"
                    fixed=true
                fi
            else
                echo "  ⚠ netfilter-persistent 不可用"
            fi
            ;;
        "service")
            if command -v service &> /dev/null; then
                echo "  ✓ service 命令可用"
                local service_available=false
                [ -f "/etc/init.d/iptables" ] && echo "  ✓ iptables 服务可用" && service_available=true
                [ -f "/etc/init.d/ip6tables" ] && echo "  ✓ ip6tables 服务可用" && service_available=true
                [ "$service_available" = false ] && echo "  ⚠ iptables 服务不可用"
            else
                echo "  ⚠ service 命令不可用"
            fi
            ;;
        *)
            echo "  ⚠ 未检测到系统持久化方法"
            ;;
    esac
    
    # 5. 检查 fallback 机制
    echo
    echo "5. 检查 fallback 持久化机制..."
    local fallback_count=0
    
    # 检查 crontab
    if crontab -l 2>/dev/null | grep -q "$restore_script"; then
        echo "  ✓ crontab 任务已配置"
        ((fallback_count++))
    else
        echo "  - crontab 任务未配置"
    fi
    
    # 检查 rc.local
    if [ -f "/etc/rc.local" ] && grep -q "$restore_script" /etc/rc.local; then
        echo "  ✓ rc.local 脚本已配置"
        ((fallback_count++))
    else
        echo "  - rc.local 脚本未配置"
    fi
    
    # 检查网络接口脚本
    if [ -f "/etc/network/if-up.d/iptables-restore" ]; then
        echo "  ✓ 网络接口启动脚本已配置"
        ((fallback_count++))
    else
        echo "  - 网络接口启动脚本未配置"
    fi
    
    if [ $fallback_count -eq 0 ]; then
        echo "  ⚠ 未找到 fallback 机制，建议配置..."
        read -p "  是否现在配置 fallback 机制? (y/N): " setup_fallback
        if [[ "$setup_fallback" =~ ^[Yy]$ ]]; then
            setup_fallback_persistence
            fixed=true
        fi
    else
        echo "  ✓ 已配置 $fallback_count 个 fallback 机制"
    fi
    
    # 6. 进行完整性测试
    echo
    echo "6. 进行完整性测试..."
    if [ -f "$restore_script" ] && [ -x "$restore_script" ]; then
        echo "  正在测试恢复脚本..."
        # 创建测试环境（不实际执行恢复）
        if bash -n "$restore_script"; then
            echo "  ✓ 恢复脚本语法检查通过"
        else
            echo "  ✗ 恢复脚本语法检查失败"
            ((issues_found++))
        fi
    fi
    
    # 总结结果
    echo
    echo -e "${BLUE}========== 检查结果总结 ==========${NC}"
    
    if [ $issues_found -eq 0 ]; then
        if [ "$fixed" = true ]; then
            echo -e "${GREEN}✓ 发现并修复了一些配置问题${NC}"
            echo -e "${GREEN}✓ 持久化配置现在工作正常${NC}"
            log_message "INFO" "持久化配置检查完成，已修复问题"
        else
            echo -e "${GREEN}✓ 持久化配置完全正常${NC}"
            log_message "INFO" "持久化配置检查完成，无问题"
        fi
        
        echo
        echo "已配置的持久化方法："
        systemctl is-enabled iptables-restore.service >/dev/null 2>&1 && echo "• systemd 服务"
        [ -f "/etc/iptables/rules.v4" ] && echo "• 系统持久化文件"
        crontab -l 2>/dev/null | grep -q "$restore_script" && echo "• crontab 任务"
        [ -f "/etc/rc.local" ] && grep -q "$restore_script" /etc/rc.local && echo "• rc.local 脚本"
        
        echo
        echo -e "${CYAN}建议测试持久化是否生效：${NC}"
        echo "1. 重启系统验证规则是否自动恢复"
        echo "2. 或手动测试: $restore_script"
        
        return 0
    else
        echo -e "${YELLOW}⚠ 发现 $issues_found 个问题${NC}"
        if [ "$fixed" = true ]; then
            echo -e "${YELLOW}⚠ 部分问题已修复，但仍有问题需要手动处理${NC}"
        else
            echo -e "${RED}✗ 持久化配置存在问题，需要手动修复${NC}"
        fi
        
        echo
        echo -e "${CYAN}建议操作：${NC}"
        echo "1. 查看详细错误信息"
        echo "2. 尝试重新运行: 选择菜单 '10. 永久保存当前规则'"
        echo "3. 或参考手动配置说明"
        
        log_message "WARNING" "持久化配置检查发现 $issues_found 个问题"
        return 1
    fi
}

# 增强的规则保存
save_rules() {
    local rules_file_v4="$CONFIG_DIR/current.rules.v4"
    local rules_file_v6="$CONFIG_DIR/current.rules.v6"
    local save_success=false
    local persistence_success=false

    echo -e "${BLUE}正在保存 iptables 规则...${NC}"
    
    # 确保配置目录存在
    mkdir -p "$CONFIG_DIR"
    
    # 保存IPv4规则
    if command -v iptables-save &> /dev/null; then
        echo "正在保存 IPv4 规则..."
        if iptables-save > "$rules_file_v4" 2>/dev/null; then
            echo -e "${GREEN}✓ IPv4规则已保存到 $rules_file_v4${NC}"
            log_message "INFO" "IPv4规则保存到文件: $rules_file_v4"
            save_success=true
        else
            echo -e "${RED}✗ IPv4规则保存失败${NC}"
            log_message "ERROR" "IPv4规则保存失败"
        fi
    else
        echo -e "${YELLOW}⚠ iptables-save 命令不可用${NC}"
    fi
    
    # 保存IPv6规则
    if command -v ip6tables-save &> /dev/null; then
        echo "正在保存 IPv6 规则..."
        if ip6tables-save > "$rules_file_v6" 2>/dev/null; then
            echo -e "${GREEN}✓ IPv6规则已保存到 $rules_file_v6${NC}"
            log_message "INFO" "IPv6规则保存到文件: $rules_file_v6"
            save_success=true
        else
            echo -e "${RED}✗ IPv6规则保存失败${NC}"
            log_message "ERROR" "IPv6规则保存失败"
        fi
    else
        echo -e "${YELLOW}⚠ ip6tables-save 命令不可用${NC}"
    fi
    
    if [ "$save_success" = false ]; then
        echo -e "${RED}✗ 规则保存失败，无法继续配置持久化${NC}"
        log_message "ERROR" "规则保存失败"
        return 1
    fi
    
    echo -e "${BLUE}正在配置持久化机制...${NC}"
    
    # 方法1: 尝试使用系统原生持久化方法
    echo "1. 尝试系统原生持久化方法..."
    case $PERSISTENT_METHOD in
        "netfilter-persistent")
            if command -v netfilter-persistent &> /dev/null; then
                # 确保规则文件在正确位置
                mkdir -p /etc/iptables
                cp "$rules_file_v4" /etc/iptables/rules.v4 2>/dev/null
                cp "$rules_file_v6" /etc/iptables/rules.v6 2>/dev/null
                
                if netfilter-persistent save 2>/dev/null; then
                    echo -e "${GREEN}✓ 规则已通过 netfilter-persistent 永久保存${NC}"
                    log_message "INFO" "规则通过 netfilter-persistent 永久保存"
                    persistence_success=true
                else
                    echo -e "${YELLOW}⚠ netfilter-persistent 保存失败${NC}"
                fi
            fi
            ;;
        "service")
            if command -v service &> /dev/null; then
                local service_success=false
                if [ -f "/etc/init.d/iptables" ] && service iptables save 2>/dev/null; then
                    echo -e "${GREEN}✓ IPv4 规则已通过 service 命令永久保存${NC}"
                    service_success=true
                fi
                if [ -f "/etc/init.d/ip6tables" ] && service ip6tables save 2>/dev/null; then
                    echo -e "${GREEN}✓ IPv6 规则已通过 service 命令永久保存${NC}"
                    service_success=true
                fi
                if [ "$service_success" = true ]; then
                    log_message "INFO" "规则通过 service 命令永久保存"
                    persistence_success=true
                else
                    echo -e "${YELLOW}⚠ service 命令保存失败${NC}"
                fi
            fi
            ;;
        *)
            echo -e "${YELLOW}⚠ 未检测到系统原生持久化方法${NC}"
            ;;
    esac
    
    # 方法2: 尝试安装并使用持久化包
    if [ "$persistence_success" = false ]; then
        echo "2. 尝试安装持久化包..."
        if install_persistence_package; then
            # 重新尝试系统持久化
            case $PACKAGE_MANAGER in
                "apt")
                    mkdir -p /etc/iptables
                    cp "$rules_file_v4" /etc/iptables/rules.v4 2>/dev/null
                    cp "$rules_file_v6" /etc/iptables/rules.v6 2>/dev/null
                    if netfilter-persistent save 2>/dev/null; then
                        echo -e "${GREEN}✓ 规则已通过新安装的 iptables-persistent 保存${NC}"
                        persistence_success=true
                    fi
                    ;;
                "yum"|"dnf")
                    if service iptables save 2>/dev/null && service ip6tables save 2>/dev/null; then
                        echo -e "${GREEN}✓ 规则已通过新安装的 iptables-services 保存${NC}"
                        persistence_success=true
                    fi
                    ;;
            esac
        fi
    fi
    
    # 方法3: 使用 systemd 服务
    echo "3. 配置 systemd 服务..."
    if setup_systemd_service; then
        echo -e "${GREEN}✓ systemd 服务配置成功${NC}"
        persistence_success=true
    else
        echo -e "${YELLOW}⚠ systemd 服务配置失败${NC}"
    fi
    
    # 方法4: 设置 fallback 机制
    echo "4. 设置 fallback 持久化机制..."
    setup_fallback_persistence
    
    # 验证持久化配置
    echo -e "${BLUE}正在验证持久化配置...${NC}"
    if verify_persistence_config; then
        echo -e "${GREEN}✓ 持久化配置验证成功${NC}"
        persistence_success=true
    else
        echo -e "${YELLOW}⚠ 持久化配置验证失败${NC}"
    fi
    
    # 总结结果
    echo
    echo -e "${BLUE}========== 持久化配置总结 ==========${NC}"
    if [ "$persistence_success" = true ]; then
        echo -e "${GREEN}✓ 规则已成功保存并配置持久化${NC}"
        echo -e "${GREEN}✓ 系统重启后规则将自动恢复${NC}"
        log_message "INFO" "规则持久化配置完成"
        
        # 显示配置的持久化方法
        echo
        echo "已配置的持久化方法："
        if systemctl is-enabled iptables-restore.service >/dev/null 2>&1; then
            echo "• systemd 服务: iptables-restore.service"
        fi
        if [ -f "/etc/iptables/rules.v4" ] || [ -f "/etc/iptables/rules.v6" ]; then
            echo "• 系统持久化文件: /etc/iptables/rules.*"
        fi
        if crontab -l 2>/dev/null | grep -q "$CONFIG_DIR/restore-rules.sh"; then
            echo "• crontab 任务: @reboot"
        fi
        if [ -f "/etc/rc.local" ] && grep -q "$CONFIG_DIR/restore-rules.sh" /etc/rc.local; then
            echo "• rc.local 脚本"
        fi
        
        return 0
    else
        echo -e "${RED}✗ 持久化配置失败${NC}"
        echo -e "${YELLOW}规则已保存到文件，但可能需要手动配置持久化${NC}"
        log_message "ERROR" "持久化配置失败"
        show_manual_save_instructions
        return 1
    fi
}

# 验证持久化配置
verify_persistence_config() {
    local verification_passed=false
    
    echo "正在验证持久化配置..."
    
    # 检查 systemd 服务
    if systemctl is-enabled iptables-restore.service >/dev/null 2>&1; then
        echo "✓ systemd 服务已启用"
        verification_passed=true
    fi
    
    # 检查规则文件
    if [ -f "$CONFIG_DIR/current.rules.v4" ] || [ -f "$CONFIG_DIR/current.rules.v6" ]; then
        echo "✓ 规则文件存在"
        verification_passed=true
    fi
    
    # 检查恢复脚本
    if [ -f "$CONFIG_DIR/restore-rules.sh" ] && [ -x "$CONFIG_DIR/restore-rules.sh" ]; then
        echo "✓ 恢复脚本可执行"
        verification_passed=true
    fi
    
    # 检查系统持久化文件
    if [ -f "/etc/iptables/rules.v4" ] || [ -f "/etc/iptables/rules.v6" ]; then
        echo "✓ 系统持久化文件存在"
        verification_passed=true
    fi
    
    return $([[ "$verification_passed" == "true" ]] && echo 0 || echo 1)
}

# 测试持久化配置
test_persistence_config() {
    echo -e "${BLUE}========== 测试持久化配置 ==========${NC}"
    echo
    echo "此功能将测试持久化配置是否能正确工作"
    echo -e "${YELLOW}注意：测试过程中会临时清空 iptables 规则，然后恢复${NC}"
    echo
    read -p "确认开始测试? (y/N): " confirm_test
    
    if [[ ! "$confirm_test" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}测试已取消${NC}"
        return 0
    fi
    
    local test_success=true
    local restore_script="$CONFIG_DIR/restore-rules.sh"
    
    echo
    echo -e "${BLUE}开始持久化测试...${NC}"
    
    # 1. 备份当前规则
    echo "1. 备份当前规则..."
    local backup_file="/tmp/iptables_test_backup_$(date +%s).rules"
    if iptables-save > "$backup_file" 2>/dev/null; then
        echo "  ✓ 当前规则已备份到: $backup_file"
    else
        echo "  ✗ 规则备份失败"
        return 1
    fi
    
    # 2. 检查恢复脚本是否存在
    echo
    echo "2. 检查恢复脚本..."
    if [ -f "$restore_script" ] && [ -x "$restore_script" ]; then
        echo "  ✓ 恢复脚本存在且可执行: $restore_script"
    else
        echo "  ✗ 恢复脚本不存在或不可执行"
        echo "  请先运行 '10. 永久保存当前规则' 或 '11. 检查和修复持久化配置'"
        rm -f "$backup_file"
        return 1
    fi
    
    # 3. 检查规则文件
    echo
    echo "3. 检查规则文件..."
    local rules_exist=false
    if [ -f "$CONFIG_DIR/current.rules.v4" ]; then
        echo "  ✓ IPv4 规则文件存在"
        rules_exist=true
    fi
    if [ -f "$CONFIG_DIR/current.rules.v6" ]; then
        echo "  ✓ IPv6 规则文件存在"
        rules_exist=true
    fi
    
    if [ "$rules_exist" = false ]; then
        echo "  ✗ 未找到规则文件"
        rm -f "$backup_file"
        return 1
    fi
    
    # 4. 保存当前映射规则数量
    echo
    echo "4. 记录当前映射规则..."
    local current_rules_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$RULE_COMMENT" || echo "0")
    echo "  当前映射规则数量: $current_rules_count"
    
    # 5. 清空 NAT 表中的映射规则（模拟重启后的状态）
    echo
    echo "5. 清空映射规则（模拟重启状态）..."
    
    # 只删除我们的映射规则，保留其他规则
    local deleted_count=0
    while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q "$RULE_COMMENT"; do
        local line_num=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "$RULE_COMMENT" | head -1 | awk '{print $1}')
        if [ -n "$line_num" ]; then
            iptables -t nat -D PREROUTING "$line_num" 2>/dev/null
            ((deleted_count++))
        else
            break
        fi
    done
    
    echo "  ✓ 已删除 $deleted_count 条映射规则"
    
    # 6. 验证规则已被清空
    echo
    echo "6. 验证规则清空状态..."
    local remaining_rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$RULE_COMMENT" || echo "0")
    if [ "$remaining_rules" -eq 0 ]; then
        echo "  ✓ 映射规则已清空"
    else
        echo "  ⚠ 仍有 $remaining_rules 条映射规则未清空"
    fi
    
    # 7. 执行恢复脚本
    echo
    echo "7. 执行恢复脚本..."
    echo "  正在运行: $restore_script"
    
    if "$restore_script" 2>&1; then
        echo "  ✓ 恢复脚本执行成功"
    else
        echo "  ✗ 恢复脚本执行失败"
        test_success=false
    fi
    
    # 8. 验证规则是否恢复
    echo
    echo "8. 验证规则恢复情况..."
    sleep 2  # 等待规则生效
    
    local restored_rules_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$RULE_COMMENT" || echo "0")
    echo "  恢复后映射规则数量: $restored_rules_count"
    
    if [ "$restored_rules_count" -eq "$current_rules_count" ]; then
        echo "  ✓ 规则数量匹配，恢复成功"
    elif [ "$restored_rules_count" -gt 0 ]; then
        echo "  ⚠ 规则数量不完全匹配，但部分恢复成功"
        echo "    原始: $current_rules_count, 恢复: $restored_rules_count"
    else
        echo "  ✗ 规则恢复失败，未找到映射规则"
        test_success=false
    fi
    
    # 9. 测试 systemd 服务
    echo
    echo "9. 测试 systemd 服务..."
    if systemctl is-enabled iptables-restore.service >/dev/null 2>&1; then
        echo "  ✓ systemd 服务已启用"
        
        # 测试服务启动
        if systemctl restart iptables-restore.service 2>/dev/null; then
            echo "  ✓ systemd 服务重启成功"
            
            # 检查服务状态
            if systemctl is-active iptables-restore.service >/dev/null 2>&1; then
                echo "  ✓ systemd 服务运行正常"
            else
                echo "  ⚠ systemd 服务状态异常"
                echo "    查看日志: journalctl -u iptables-restore.service"
            fi
        else
            echo "  ✗ systemd 服务重启失败"
            test_success=false
        fi
    else
        echo "  ⚠ systemd 服务未启用"
    fi
    
    # 10. 清理测试备份
    echo
    echo "10. 清理测试文件..."
    if rm -f "$backup_file"; then
        echo "  ✓ 测试备份文件已清理"
    fi
    
    # 测试结果总结
    echo
    echo -e "${BLUE}========== 测试结果总结 ==========${NC}"
    
    if [ "$test_success" = true ] && [ "$restored_rules_count" -gt 0 ]; then
        echo -e "${GREEN}✓ 持久化配置测试通过${NC}"
        echo -e "${GREEN}✓ 规则能够正确恢复${NC}"
        echo -e "${GREEN}✓ 系统重启后规则应该会自动恢复${NC}"
        
        echo
        echo -e "${CYAN}测试统计：${NC}"
        echo "• 原始规则数量: $current_rules_count"
        echo "• 恢复规则数量: $restored_rules_count"
        echo "• 恢复成功率: $(( restored_rules_count * 100 / (current_rules_count > 0 ? current_rules_count : 1) ))%"
        
        log_message "INFO" "持久化配置测试通过"
        return 0
    else
        echo -e "${RED}✗ 持久化配置测试失败${NC}"
        echo -e "${YELLOW}⚠ 建议检查配置或重新设置持久化${NC}"
        
        echo
        echo -e "${CYAN}建议操作：${NC}"
        echo "1. 运行 '11. 检查和修复持久化配置'"
        echo "2. 重新运行 '10. 永久保存当前规则'"
        echo "3. 检查系统日志: journalctl -u iptables-restore.service"
        echo "4. 手动测试恢复脚本: $restore_script"
        
        log_message "ERROR" "持久化配置测试失败"
        return 1
    fi
}

# 创建规则恢复脚本
create_restore_script() {
    local restore_script="$CONFIG_DIR/restore-rules.sh"
    
    cat > "$restore_script" <<'EOF'
#!/bin/bash
# 端口映射规则恢复脚本
# 由 Port Mapping Manager 自动生成

LOG_FILE="/var/log/udp-port-mapping.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
}

echo "开始恢复 iptables 规则..."
log_message "INFO" "开始恢复 iptables 规则"

# 恢复 IPv4 规则
if [ -f "/etc/port_mapping_manager/current.rules.v4" ]; then
    if /sbin/iptables-restore < "/etc/port_mapping_manager/current.rules.v4" 2>/dev/null; then
        echo "✓ IPv4 规则恢复成功"
        log_message "INFO" "IPv4 规则恢复成功"
    else
        echo "✗ IPv4 规则恢复失败"
        log_message "ERROR" "IPv4 规则恢复失败"
        return 1
    fi
else
    echo "- 未找到 IPv4 规则文件"
    log_message "WARNING" "未找到 IPv4 规则文件"
fi

# 恢复 IPv6 规则
if [ -f "/etc/port_mapping_manager/current.rules.v6" ]; then
    if /sbin/ip6tables-restore < "/etc/port_mapping_manager/current.rules.v6" 2>/dev/null; then
        echo "✓ IPv6 规则恢复成功"
        log_message "INFO" "IPv6 规则恢复成功"
    else
        echo "✗ IPv6 规则恢复失败"
        log_message "ERROR" "IPv6 规则恢复失败"
        return 1
    fi
else
    echo "- 未找到 IPv6 规则文件"
    log_message "WARNING" "未找到 IPv6 规则文件"
fi

echo "规则恢复完成"
log_message "INFO" "规则恢复完成"
EOF

    chmod +x "$restore_script"
    echo -e "${GREEN}✓ 规则恢复脚本已创建: $restore_script${NC}"
    log_message "INFO" "规则恢复脚本已创建: $restore_script"
}

# 检测并安装持久化包
install_persistence_package() {
    echo "正在检查持久化包..."
    
    case $PACKAGE_MANAGER in
        "apt")
            if ! dpkg -l | grep -q iptables-persistent; then
                echo "正在安装 iptables-persistent..."
                if apt-get update && apt-get install -y iptables-persistent; then
                    echo -e "${GREEN}✓ iptables-persistent 安装成功${NC}"
                    return 0
                else
                    echo -e "${YELLOW}⚠ iptables-persistent 安装失败，将使用 systemd 方式${NC}"
                    return 1
                fi
            else
                echo -e "${GREEN}✓ iptables-persistent 已安装${NC}"
                return 0
            fi
            ;;
        "yum"|"dnf")
            if ! rpm -q iptables-services >/dev/null 2>&1; then
                echo "正在安装 iptables-services..."
                if $PACKAGE_MANAGER install -y iptables-services; then
                    systemctl enable iptables ip6tables 2>/dev/null
                    echo -e "${GREEN}✓ iptables-services 安装成功${NC}"
                    return 0
                else
                    echo -e "${YELLOW}⚠ iptables-services 安装失败，将使用 systemd 方式${NC}"
                    return 1
                fi
            else
                echo -e "${GREEN}✓ iptables-services 已安装${NC}"
                systemctl enable iptables ip6tables 2>/dev/null
                return 0
            fi
            ;;
        *)
            echo -e "${YELLOW}⚠ 未知包管理器，将使用 systemd 方式${NC}"
            return 1
            ;;
    esac
}

# 配置 systemd 服务以实现持久化
setup_systemd_service() {
    local service_file="/etc/systemd/system/iptables-restore.service"
    local restore_script="$CONFIG_DIR/restore-rules.sh"
    
    # 检查并清理可能存在的旧服务
    if [ -f "$service_file" ]; then
        echo "正在清理旧的 systemd 服务..."
        systemctl disable iptables-restore.service 2>/dev/null
        systemctl stop iptables-restore.service 2>/dev/null
        rm -f "$service_file"
        systemctl daemon-reload
    fi
    
    # 创建恢复脚本
    create_restore_script
    
    echo "正在创建 systemd 服务..."
    cat > "$service_file" <<EOF
[Unit]
Description=Restore iptables port mapping rules
After=network.target
Wants=network.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=$restore_script
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    if systemctl enable iptables-restore.service; then
        echo -e "${GREEN}✓ systemd 服务已创建并启用${NC}"
        log_message "INFO" "systemd 服务已创建并启用"
    else
        echo -e "${RED}✗ systemd 服务启用失败${NC}"
        log_message "ERROR" "systemd 服务启用失败"
        return 1
    fi
    
    # 立即测试服务是否正常工作
    echo "正在测试 systemd 服务..."
    if systemctl start iptables-restore.service; then
        echo -e "${GREEN}✓ systemd 服务测试成功${NC}"
        log_message "INFO" "systemd 服务测试成功"
        
        # 检查服务状态
        if systemctl is-active iptables-restore.service >/dev/null 2>&1; then
            echo -e "${GREEN}✓ 服务运行状态正常${NC}"
        else
            echo -e "${YELLOW}⚠ 服务状态异常，请检查日志${NC}"
            echo "查看日志: journalctl -u iptables-restore.service"
        fi
        return 0
    else
        echo -e "${RED}✗ systemd 服务测试失败${NC}"
        log_message "ERROR" "systemd 服务测试失败"
        echo "查看详细错误: journalctl -u iptables-restore.service"
        return 1
    fi
}

# 设置多种持久化方式的fallback机制
setup_fallback_persistence() {
    echo "正在设置 fallback 持久化机制..."
    
    # 方法1: 添加到 rc.local
    if [ -f "/etc/rc.local" ]; then
        if ! grep -q "$CONFIG_DIR/restore-rules.sh" /etc/rc.local; then
            # 备份原文件
            cp /etc/rc.local /etc/rc.local.bak.$(date +%Y%m%d_%H%M%S)
            
            # 在 exit 0 之前添加恢复脚本
            sed -i '/^exit 0/i # Port Mapping Manager - 恢复 iptables 规则' /etc/rc.local
            sed -i "/^exit 0/i $CONFIG_DIR/restore-rules.sh" /etc/rc.local
            
            chmod +x /etc/rc.local
            echo -e "${GREEN}✓ 已添加到 rc.local${NC}"
        fi
    fi
    
    # 方法2: 创建 crontab 任务
    local cron_entry="@reboot $CONFIG_DIR/restore-rules.sh"
    if ! crontab -l 2>/dev/null | grep -q "$CONFIG_DIR/restore-rules.sh"; then
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
        echo -e "${GREEN}✓ 已添加到 crontab${NC}"
    fi
    
    # 方法3: 创建网络接口启动脚本 (适用于某些发行版)
    local if_up_dir="/etc/network/if-up.d"
    if [ -d "$if_up_dir" ]; then
        local if_up_script="$if_up_dir/iptables-restore"
        cat > "$if_up_script" <<EOF
#!/bin/bash
# Port Mapping Manager - 网络接口启动时恢复规则
if [ "\$IFACE" = "lo" ]; then
    exit 0
fi
$CONFIG_DIR/restore-rules.sh
EOF
        chmod +x "$if_up_script"
        echo -e "${GREEN}✓ 已创建网络接口启动脚本${NC}"
    fi
    
    log_message "INFO" "Fallback 持久化机制设置完成"
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
    local sorted_rule_nums=()
    while IFS= read -r rule_num; do
        sorted_rule_nums+=("$rule_num")
    done < <(for sel in "${valid_choices[@]}"; do echo "${rules[$((sel-1))]}"; done | sort -nr)

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

# 权限检查函数
check_uninstall_permissions() {
    local errors=0
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        echo "  ✗ 错误: 需要 root 权限执行卸载操作"
        ((errors++))
    else
        echo "  ✓ Root 权限检查通过"
    fi
    
    # 检查 iptables 命令
    for cmd in iptables ip6tables; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "  ✗ 错误: $cmd 命令不可用"
            ((errors++))
        else
            echo "  ✓ $cmd 命令可用"
        fi
    done
    
    # 检查 systemctl 命令（如果系统支持）
    if command -v systemctl &>/dev/null; then
        echo "  ✓ systemctl 命令可用"
        
        # 检查 systemd 目录权限
        if [ -d "/etc/systemd/system" ] && [ ! -w "/etc/systemd/system" ]; then
            echo "  ✗ 错误: 没有 /etc/systemd/system 目录写权限"
            ((errors++))
        else
            echo "  ✓ systemd 目录权限正常"
        fi
    else
        echo "  ⚠ systemctl 命令不可用，将跳过 systemd 服务清理"
    fi
    
    # 检查关键目录的写权限
    local dirs_to_check=()
    [ -d "$CONFIG_DIR" ] && dirs_to_check+=("$CONFIG_DIR")
    [ -d "$BACKUP_DIR" ] && dirs_to_check+=("$BACKUP_DIR")
    [ -d "$(dirname "$LOG_FILE")" ] && dirs_to_check+=("$(dirname "$LOG_FILE")")
    
    for dir in "${dirs_to_check[@]}"; do
        if [ ! -w "$dir" ]; then
            echo "  ✗ 错误: 没有目录写权限: $dir"
            ((errors++))
        else
            echo "  ✓ 目录权限正常: $dir"
        fi
    done
    
    # 检查当前脚本是否可删除
    local current_script="$(realpath "$0" 2>/dev/null || echo "$0")"
    local script_dir="$(dirname "$current_script")"
    if [ ! -w "$script_dir" ]; then
        echo "  ⚠ 警告: 无法删除当前脚本文件 (目录无写权限): $script_dir"
        echo "    脚本功能不受影响，但需要手动删除脚本文件"
    else
        echo "  ✓ 当前脚本可删除"
    fi
    
    return $errors
}

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
    
    # 使用更安全的规则删除方法（逐个删除，避免行号变化问题）
    local deleted_count=0
    local max_attempts=100  # 防止无限循环
    local attempts=0
    
    echo "  - 开始删除 IPv${ip_version} 规则..."
    
    while [ $attempts -lt $max_attempts ]; do
        # 获取第一个匹配的规则行号
        local line_num=$($iptables_cmd -t nat -L PREROUTING --line-numbers 2>/dev/null | grep "$rule_comment" | head -1 | awk '{print $1}')
        
        if [ -z "$line_num" ]; then
            echo "  - 没有更多 IPv${ip_version} 规则需要删除"
            break
        fi
        
        echo "  - 尝试删除 IPv${ip_version} 规则 #$line_num"
        if $iptables_cmd -t nat -D PREROUTING "$line_num" 2>/dev/null; then
            echo "  - ✓ 成功删除 IPv${ip_version} 规则 #$line_num"
            ((deleted_count++))
        else
            echo "  - ✗ 删除 IPv${ip_version} 规则 #$line_num 失败"
            break
        fi
        
        ((attempts++))
    done
    
    if [ $attempts -eq $max_attempts ]; then
        echo "  - ⚠ 达到最大删除尝试次数，可能存在无法删除的规则"
    fi
    
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
    
    # 安全停止服务函数
    safe_stop_service() {
        local service=$1
        local timeout=10
        local success=true
        
        # 先禁用服务
        if systemctl is-enabled "$service" &>/dev/null; then
            if systemctl disable "$service" 2>/dev/null; then
                echo "  - ✓ 已禁用 $service"
            else
                echo "  - ✗ 禁用 $service 失败"
                success=false
            fi
        fi
        
        # 停止服务
        if systemctl is-active "$service" &>/dev/null; then
            echo "  - 正在停止 $service..."
            if systemctl stop "$service" 2>/dev/null; then
                # 等待服务完全停止
                local count=0
                while systemctl is-active "$service" &>/dev/null && [ $count -lt $timeout ]; do
                    sleep 1
                    ((count++))
                done
                
                if systemctl is-active "$service" &>/dev/null; then
                    echo "  - ⚠ 服务 $service 未能在 ${timeout}s 内停止"
                    success=false
                else
                    echo "  - ✓ 已停止 $service"
                fi
            else
                echo "  - ✗ 停止 $service 失败"
                success=false
            fi
        fi
        
        return $([ "$success" = true ] && echo 0 || echo 1)
    }
    
    # 停止并禁用服务
    for service in "${services[@]}"; do
        echo "  - 检查服务: $service"
        if systemctl list-unit-files "$service" &>/dev/null; then
            service_found=true
            if safe_stop_service "$service"; then
                echo "  - ✓ 服务 $service 处理成功"
            else
                echo "  - ✗ 服务 $service 处理失败"
                operation_success=false
            fi
        else
            echo "  - 服务 $service 不存在"
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
    
    # 权限检查
    echo "正在检查卸载权限..."
    if ! check_uninstall_permissions; then
        echo -e "${RED}权限检查失败，无法继续卸载${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ 权限检查通过${NC}"
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
    local deleted_count=0
    local script_failed=false
    
    # 智能查找脚本文件位置
    local script_paths=()
    
    # 添加常见安装路径
    script_paths+=("/usr/local/bin/port_mapping_manager.sh")
    script_paths+=("/usr/local/bin/pmm")
    script_paths+=("/usr/bin/port_mapping_manager.sh")
    script_paths+=("/usr/bin/pmm")
    script_paths+=("/etc/port_mapping_manager/port_mapping_manager.sh")
    script_paths+=("/etc/port_mapping_manager/pmm")
    
    # 添加当前脚本目录下的相关文件
    local current_dir="$(dirname "$0")"
    script_paths+=("$current_dir/pmm")
    script_paths+=("$current_dir/port_mapping_manager.sh")
    
    # 查找 PATH 中的脚本
    if command -v pmm >/dev/null 2>&1; then
        local pmm_path="$(command -v pmm)"
        script_paths+=("$pmm_path")
        echo "  - 发现 PATH 中的 pmm: $pmm_path"
    fi
    
    # 查找可能的符号链接
    for path in "${script_paths[@]}"; do
        if [ -L "$path" ]; then
            local target="$(readlink "$path" 2>/dev/null)"
            if [ -n "$target" ]; then
                script_paths+=("$target")
                echo "  - 发现符号链接目标: $path -> $target"
            fi
        fi
    done
    
    # 去重并删除文件
    local unique_paths=()
    while IFS= read -r path; do
        unique_paths+=("$path")
    done < <(printf '%s\n' "${script_paths[@]}" | sort -u)
    
    for p in "${unique_paths[@]}"; do 
        if [ -f "$p" ]; then
            echo "  - 正在删除: $p"
            if rm -f "$p" 2>/dev/null; then
                echo "  - ✓ 已删除: $p"
                ((deleted_count++))
            else
                echo "  - ✗ 删除失败: $p (可能需要权限)"
                script_failed=true
            fi
        elif [ -L "$p" ]; then
            echo "  - 正在删除符号链接: $p"
            if rm -f "$p" 2>/dev/null; then
                echo "  - ✓ 已删除符号链接: $p"
                ((deleted_count++))
            else
                echo "  - ✗ 删除符号链接失败: $p (可能需要权限)"
                script_failed=true
            fi
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
        echo "正在准备删除当前脚本..."
        
        # 创建临时清理脚本，使用安全的延迟删除
        local cleanup_script="/tmp/pmm_cleanup_$$.sh"
        register_temp_file "$cleanup_script"
        cat > "$cleanup_script" << EOF
#!/bin/bash
# 临时清理脚本 - 自动生成
sleep 3
echo "正在删除脚本文件: $current_script"
if rm -f "$current_script" 2>/dev/null; then
    echo "✓ 脚本文件删除成功"
else
    echo "✗ 脚本文件删除失败，请手动删除: $current_script"
fi
# 删除自身
rm -f "$0" 2>/dev/null
EOF
        
        if chmod +x "$cleanup_script" 2>/dev/null; then
            echo "  - ✓ 清理脚本已创建: $cleanup_script"
            echo "  - 脚本将在3秒后自动删除"
            echo "  - 正在启动后台清理进程..."
            
            # 启动后台清理进程
            nohup "$cleanup_script" >/dev/null 2>&1 &
            local cleanup_pid=$!
            
            echo "  - ✓ 清理进程已启动 (PID: $cleanup_pid)"
            echo "  - 当前脚本将在退出后被自动删除"
        else
            echo "  - ✗ 创建清理脚本失败，请手动删除: $current_script"
            rm -f "$cleanup_script" 2>/dev/null
        fi
    else
        echo "脚本文件保留，如需删除请手动执行: rm -f $current_script"
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
    echo -e "${BLUE}    端口映射管理脚本 Enhanced v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo
    echo -e "${CYAN}🚀 核心功能特性:${NC}"
    echo "• 智能端口冲突检测与解决"
    echo "• 自动备份和一键恢复"
    echo "• 批量规则导入/导出"
    echo "• 实时流量监控和统计"
    echo "• 全面系统诊断功能"
    echo "• 多种持久化方案支持"
    echo "• 增强的错误处理和日志"
    echo "• IPv4/IPv6 双栈支持"
    echo "• 性能优化和缓存机制"
    echo "• 安全的输入验证和清理"
    echo
    echo -e "${CYAN}🎯 主要使用场景:${NC}"
    echo "• Hysteria2 机场端口跳跃配置"
    echo "• Xray/V2Ray 代理服务端口管理"
    echo "• UDP/TCP 服务负载均衡"
    echo "• 端口隐藏和流量伪装"
    echo "• 网络测试工具 (iperf) 端口管理"
    echo "• 大规模端口转发需求"
    echo
    echo -e "${CYAN}📝 配置示例:${NC}"
    echo "┌─ 基础配置 ─────────────────────────┐"
    echo "│ 连接端口: 6000-7000 (客户端连接)   │"
    echo "│ 服务端口: 3000 (实际服务监听)      │"
    echo "│ 协议类型: UDP/TCP                  │"
    echo "│ 效果: 6000-7000 → 3000            │"
    echo "└───────────────────────────────────┘"
    echo
    echo -e "${CYAN}⚠️  重要注意事项:${NC}"
    echo "1. 🔒 需要 root 权限运行"
    echo "2. 🚫 服务端口不能在连接端口范围内"
    echo "3. 🔥 确保防火墙允许相关端口流量"
    echo "4. 💾 建议定期备份规则配置"
    echo "5. 📊 监控系统性能，避免过多规则"
    echo "6. 🔄 重启后规则自动恢复 (需配置持久化)"
    echo
    echo -e "${CYAN}📂 文件和目录位置:${NC}"
    echo "配置目录: $CONFIG_DIR"
    echo "日志文件: $LOG_FILE"
    echo "备份目录: $BACKUP_DIR"
    echo "缓存目录: /tmp/pmm_cache"
    echo
    echo -e "${CYAN}🛠️  主要功能菜单:${NC}"
    echo "┌─ 基础操作 ─────────────────────────┐"
    echo "│ 1.  设置端口映射 (手动配置)        │"
    echo "│ 2.  使用预设配置                   │"
    echo "│ 3.  查看当前规则                   │"
    echo "│ 4.  规则管理 (编辑/删除)           │"
    echo "│ 5.  系统诊断                       │"
    echo "└───────────────────────────────────┘"
    echo "┌─ 高级功能 ─────────────────────────┐"
    echo "│ 6.  批量操作 (导入/导出)           │"
    echo "│ 7.  备份管理                       │"
    echo "│ 8.  实时监控                       │"
    echo "│ 9.  恢复设置                       │"
    echo "└───────────────────────────────────┘"
    echo "┌─ 持久化配置 ───────────────────────┐"
    echo "│ 10. 永久保存当前规则               │"
    echo "│ 11. 检查和修复持久化配置           │"
    echo "│ 12. 测试持久化配置                 │"
    echo "└───────────────────────────────────┘"
    echo "┌─ 系统管理 ─────────────────────────┐"
    echo "│ 13. 帮助信息 (当前页面)            │"
    echo "│ 14. 版本信息                       │"
    echo "│ 15. 切换IP版本 (IPv4/IPv6)         │"
    echo "│ 16. 检查更新                       │"
    echo "│ 17. 退出脚本                       │"
    echo "│ 99. 卸载脚本                       │"
    echo "└───────────────────────────────────┘"
    echo
    echo -e "${CYAN}🔧 命令行参数:${NC}"
    echo "--verbose, -v     : 启用详细输出模式"
    echo "--no-backup      : 跳过自动备份"
    echo "--ip-version 4|6 : 指定 IP 版本"
    echo "--help, -h       : 显示帮助信息"
    echo
    echo -e "${CYAN}💡 使用技巧:${NC}"
    echo "• 首次使用建议先运行 '5. 系统诊断' 检查环境"
    echo "• 添加规则后使用 '10. 永久保存当前规则' 确保重启后生效"
    echo "• 定期使用 '7. 备份管理' 备份重要配置"
    echo "• 使用 '8. 实时监控' 观察端口使用情况"
    echo "• 遇到问题时查看日志文件: $LOG_FILE"
    echo
    echo -e "${CYAN}🆘 故障排除:${NC}"
    echo "• 规则不生效: 检查防火墙设置和 iptables 服务状态"
    echo "• 重启后丢失: 运行 '11. 检查和修复持久化配置'"
    echo "• 端口冲突: 脚本会自动检测并提示解决方案"
    echo "• 权限问题: 确保以 root 用户运行脚本"
    echo
    echo -e "${GREEN}📞 获取支持:${NC}"
    echo "• 查看详细日志: tail -f $LOG_FILE"
    echo "• 系统诊断报告: 选择菜单选项 8"
    echo "• GitHub Issues: 报告问题和建议"
    echo
}

# 显示版本信息
show_version() {
    echo -e "${GREEN}端口映射管理脚本 Enhanced v${SCRIPT_VERSION}${NC}"
    echo "作者: Enhanced by AI Assistant"
    echo "基于: 原始脚本 + AI 全面增强"
    echo "支持: Hysteria2, Xray, V2Ray, iperf, 通用端口转发"
    echo
    echo "更新日志:"
    echo "v4.0 - 🚀 重大更新: 全面代码重构和功能增强"
    echo "     • 修复所有已知问题和安全漏洞"
    echo "     • 增强错误处理和输入验证"
    echo "     • 性能优化和缓存机制"
    echo "     • 改进日志记录和调试功能"
    echo "     • 完善卸载功能和权限检查"
    echo "     • IPv4/IPv6 双栈完整支持"
    echo "     • 数组处理兼容性修复"
    echo "     • 变量验证和环境检查增强"
    echo "v3.6 - 完善更新检测功能，优化用户体验"
    echo "v3.2 - 增加更新检测功能"
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
    
    # 注册临时文件以便自动清理
    register_temp_file "$temp_file"
    register_temp_file "$temp_script"
    
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
    
    # 版本比较函数（改进的兼容性版本）
    version_compare() {
        local v1=$1 v2=$2
        if [ "$v1" = "$v2" ]; then
            echo "equal"
            return
        fi
        
        # 使用更兼容的方式处理版本号
        local v1_major v1_minor v1_patch
        local v2_major v2_minor v2_patch
        
        # 解析版本号
        v1_major=$(echo "$v1" | cut -d. -f1)
        v1_minor=$(echo "$v1" | cut -d. -f2 2>/dev/null || echo "0")
        v1_patch=$(echo "$v1" | cut -d. -f3 2>/dev/null || echo "0")
        
        v2_major=$(echo "$v2" | cut -d. -f1)
        v2_minor=$(echo "$v2" | cut -d. -f2 2>/dev/null || echo "0")
        v2_patch=$(echo "$v2" | cut -d. -f3 2>/dev/null || echo "0")
        
        # 比较主版本号
        if [ "$v1_major" -lt "$v2_major" ]; then
            echo "older"
            return
        elif [ "$v1_major" -gt "$v2_major" ]; then
            echo "newer"
            return
        fi
        
        # 比较次版本号
        if [ "$v1_minor" -lt "$v2_minor" ]; then
            echo "older"
            return
        elif [ "$v1_minor" -gt "$v2_minor" ]; then
            echo "newer"
            return
        fi
        
        # 比较补丁版本号
        if [ "$v1_patch" -lt "$v2_patch" ]; then
            echo "older"
            return
        elif [ "$v1_patch" -gt "$v2_patch" ]; then
            echo "newer"
            return
        fi
        
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
                    
                    # 下载新版本脚本（增强安全性）
                    echo -e "${CYAN}正在从安全连接下载...${NC}"
                    if ! curl -s --connect-timeout 10 --max-time 60 --fail \
                        -H "User-Agent: Port-Mapping-Manager/$SCRIPT_VERSION" \
                        -H "Accept: text/plain" \
                        "$SCRIPT_URL" > "$temp_script" 2>/dev/null; then
                        echo -e "${RED}错误：下载更新失败${NC}"
                        echo -e "${YELLOW}可能的原因：网络连接问题或服务器不可用${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 增强的脚本验证
                    echo -e "${CYAN}正在验证下载的文件...${NC}"
                    
                    # 检查文件大小（应该大于最小合理大小）
                    local file_size=$(wc -c < "$temp_script" 2>/dev/null || echo "0")
                    if [ "$file_size" -lt 10000 ]; then
                        echo -e "${RED}错误：下载的文件太小，可能不完整${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 验证脚本基本结构
                    if [ ! -s "$temp_script" ] || \
                       ! grep -q "SCRIPT_VERSION=" "$temp_script" || \
                       ! grep -q "#!/bin/bash" "$temp_script" || \
                       ! grep -q "Port-Mapping-Manage" "$temp_script"; then
                        echo -e "${RED}错误：下载的脚本文件无效或损坏${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 验证下载的版本号
                    local downloaded_version=$(grep "SCRIPT_VERSION=" "$temp_script" | cut -d'"' -f2 | head -1)
                    if [ "$downloaded_version" != "$remote_version" ]; then
                        echo -e "${YELLOW}警告：下载的版本号与预期不符${NC}"
                        echo -e "${YELLOW}预期: v${remote_version}, 实际: v${downloaded_version}${NC}"
                    fi
                    
                    echo -e "${GREEN}✓ 文件验证通过${NC}"
                    
                    # 备份当前脚本（增强错误处理）
                    local backup_path="$BACKUP_DIR/script_backup_$(date +%Y%m%d_%H%M%S).sh"
                    
                    # 确保备份目录存在
                    if [ ! -d "$BACKUP_DIR" ]; then
                        if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
                            echo -e "${RED}错误：无法创建备份目录 $BACKUP_DIR${NC}"
                            rm -f "$temp_script"
                            return 1
                        fi
                    fi
                    
                    # 执行备份并验证
                    if ! cp "$0" "$backup_path" 2>/dev/null; then
                        echo -e "${RED}错误：备份当前脚本失败${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    echo -e "${GREEN}✓ 当前脚本已备份到: $backup_path${NC}"
                    
                    # 安装新版本（改进的自更新机制）
                    local current_version="$SCRIPT_VERSION"
                    
                    # 检查是否有足够权限修改脚本文件
                    if [ ! -w "$0" ]; then
                        echo -e "${RED}错误：没有权限修改脚本文件${NC}"
                        echo -e "${YELLOW}请使用 sudo 运行或检查文件权限${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    # 使用更安全的方式替换脚本
                    local temp_backup="${0}.updating.$$"
                    if ! mv "$0" "$temp_backup" 2>/dev/null; then
                        echo -e "${RED}错误：无法创建临时备份${NC}"
                        rm -f "$temp_script"
                        return 1
                    fi
                    
                    if mv "$temp_script" "$0" && chmod +x "$0"; then
                        # 记录更新日志（使用正确的版本号）
                        log_message "INFO" "脚本已从 v${current_version} 更新到 v${remote_version}"
                        
                        # 清理临时备份
                        rm -f "$temp_backup" 2>/dev/null
                        
                        echo -e "${GREEN}✓ 更新成功！${NC}"
                        echo -e "${YELLOW}脚本已从 v${current_version} 更新到 v${remote_version}${NC}"
                        echo -e "${CYAN}请重新运行脚本以使用新版本功能${NC}"
                        exit 0
                    else
                        # 恢复原始脚本
                        echo -e "${RED}错误：更新失败，正在恢复原始脚本...${NC}"
                        if mv "$temp_backup" "$0" 2>/dev/null; then
                            echo -e "${GREEN}✓ 原始脚本已恢复${NC}"
                        else
                            echo -e "${RED}严重错误：无法恢复原始脚本！${NC}"
                            echo -e "${YELLOW}备份文件位置: $backup_path${NC}"
                        fi
                        rm -f "$temp_script" "$temp_backup" 2>/dev/null
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
    echo " 11. 检查和修复持久化配置"
    echo " 12. 测试持久化配置"
    echo " 13. 帮助信息"
    echo " 14. 版本信息"
    echo " 15. 切换IP版本 (IPv4/IPv6)"
    echo " 16. 检查更新"
    echo " 17. 退出脚本"
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
    if ! check_root; then
        echo -e "${RED}初始化失败：需要root权限${NC}"
        return 1
    fi
    
    detect_system
    setup_directories
    
    if ! check_dependencies; then
        echo -e "${RED}初始化失败：依赖检查未通过${NC}"
        return 1
    fi
    
    load_config
    
    # 记录启动
    log_message "INFO" "脚本启动 v$SCRIPT_VERSION"
    
    # 自动检查和修复持久化配置
    echo -e "${BLUE}正在检查持久化配置...${NC}"
    if ! check_and_fix_persistence; then
        echo -e "${YELLOW}⚠ 持久化配置检查发现问题，请手动检查${NC}"
        echo -e "${YELLOW}  可以选择菜单中的 '11. 检查和修复持久化配置' 选项${NC}"
    fi
    echo
    
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
        read -p "请选择操作 [1-17/99]: " main_choice
        
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
            11) check_and_fix_persistence ;;
            12) test_persistence_config ;;
            13) show_enhanced_help ;;
            14) show_version ;;
            15) switch_ip_version ;;
            16) check_for_updates ;;
            17)
                echo -e "${GREEN}感谢使用UDP端口映射脚本！${NC}"
                log_message "INFO" "脚本正常退出"
                exit 0
                ;;
            99)
                uninstall_script
                ;;
            *) 
                echo -e "${RED}无效选择，请输入 1-17 或 99${NC}"
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



# 启动脚本
main "$@"
