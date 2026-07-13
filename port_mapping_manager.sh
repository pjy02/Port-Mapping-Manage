#!/bin/bash

# TCP/UDP端口映射管理脚本 Enhanced v5.0
# 适用于 Hysteria2 机场端口跳跃配置
# 增强版本包含：安全性改进、错误处理、批量操作、监控诊断、性能优化等功能

# 脚本配置
SCRIPT_VERSION="5.0"
RULE_COMMENT="udp-port-mapping-script-v4"
CONFIG_DIR="/etc/port_mapping_manager"
LOG_FILE="/var/log/udp-port-mapping.log"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/config.conf"
RULES_DB="$CONFIG_DIR/rules.db"
RESTORE_SCRIPT="$CONFIG_DIR/restore-owned-rules.sh"
PERSISTENCE_SERVICE="pmm-rules.service"
PERSISTENCE_SERVICE_FILE="/etc/systemd/system/$PERSISTENCE_SERVICE"
REPORT_DIR="$CONFIG_DIR/reports"
LAST_BACKUP_FILE=""
IMPORT_SUCCESS_COUNT=0
IMPORT_ERROR_COUNT=0
EXPORT_RULE_COUNT=0
BATCH_BACKUP_FILE=""

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
PUBLIC_IPV4=""
PUBLIC_IPV6=""
PUBLIC_IP_TIMESTAMP=0
PUBLIC_IP_TTL=600  # 公网IP检测结果缓存时间，默认10分钟

# 性能优化缓存变量
IPTABLES_CACHE_FILE=""
IPTABLES_CACHE_TIMESTAMP=0
IPTABLES_CACHE_TTL=30  # 缓存有效期30秒
RULES_CACHE=""
RULES_CACHE_TIMESTAMP=0
RULES_CACHE_V4=""
RULES_CACHE_V4_TIMESTAMP=0
RULES_CACHE_V6=""
RULES_CACHE_V6_TIMESTAMP=0

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
    return 0
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
    local cached_rules cache_timestamp

    if [ "$ip_version" = "6" ]; then
        cached_rules=$RULES_CACHE_V6
        cache_timestamp=$RULES_CACHE_V6_TIMESTAMP
    else
        cached_rules=$RULES_CACHE_V4
        cache_timestamp=$RULES_CACHE_V4_TIMESTAMP
    fi

    if [ -n "$cached_rules" ] && [ $((current_time - cache_timestamp)) -lt $IPTABLES_CACHE_TTL ]; then
        log_message "DEBUG" "使用缓存的 IPv${ip_version} iptables 规则"
        echo "$cached_rules"
        return 0
    fi

    local iptables_cmd=$(get_iptables_cmd "$ip_version")
    if [ -z "$iptables_cmd" ]; then
        log_message "ERROR" "无法获取 iptables 命令"
        return 1
    fi

    log_message "DEBUG" "刷新 iptables 规则缓存"
    if cached_rules=$($iptables_cmd -t nat -L PREROUTING -n --line-numbers 2>/dev/null); then
        if [ "$ip_version" = "6" ]; then
            RULES_CACHE_V6=$cached_rules
            RULES_CACHE_V6_TIMESTAMP=$current_time
        else
            RULES_CACHE_V4=$cached_rules
            RULES_CACHE_V4_TIMESTAMP=$current_time
        fi
        echo "$cached_rules"
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
    RULES_CACHE_V4=""
    RULES_CACHE_V4_TIMESTAMP=0
    RULES_CACHE_V6=""
    RULES_CACHE_V6_TIMESTAMP=0

    # 清理临时缓存文件
    if [ -n "$IPTABLES_CACHE_FILE" ] && [ -f "$IPTABLES_CACHE_FILE" ]; then
        rm -f "$IPTABLES_CACHE_FILE" 2>/dev/null
        IPTABLES_CACHE_FILE=""
    fi
}

# 批量获取端口状态（性能优化）
batch_check_port_status() {
    local ports=("$@")
    if [ ${#ports[@]} -eq 0 ]; then
        return 0
    fi

    log_message "DEBUG" "批量检查 ${#ports[@]} 个端口状态"

    for port_info in "${ports[@]}"; do
        IFS=':' read -r port protocol ip_version <<< "$port_info"
        ip_version=${ip_version:-$IP_VERSION}
        if is_service_listening "$ip_version" "$protocol" "$port"; then
            echo "${port}:${protocol}:${ip_version}:active"
        else
            echo "${port}:${protocol}:${ip_version}:inactive"
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
        echo -e "启动检查不会自动安装软件，请运行 install_pmm.sh 或手动安装依赖。"
        log_message "ERROR" "缺少依赖，启动阶段拒绝自动安装: ${missing_deps[*]}"
        return 1
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
    local protocol=${2:-udp}
    local ip_version=${3:-$IP_VERSION}
    local detailed=${4:-false}
    local socket_info

    socket_info=$(get_listening_socket "$ip_version" "$protocol" "$port" 2>/dev/null || true)
    if [ -n "$socket_info" ]; then
        if [ "$detailed" = true ]; then
            echo -e "${YELLOW}警告：IPv${ip_version} ${protocol^^} 端口 $port 已被占用 - $socket_info${NC}"
        else
            echo -e "${YELLOW}警告：IPv${ip_version} ${protocol^^} 端口 $port 可能已被占用。${NC}"
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
    local protocol=${4:-udp}
    local ip_version=${5:-$IP_VERSION}
    local existing_ip existing_protocol existing_start existing_end existing_target

    [ -n "$service_port" ] || true
    while IFS='|' read -r existing_ip existing_protocol existing_start existing_end existing_target; do
        [ -n "$existing_ip" ] || continue
        if [ "$ip_version" = "$existing_ip" ] && [ "$protocol" = "$existing_protocol" ] && \
           [ "$start_port" -le "$existing_end" ] && [ "$end_port" -ge "$existing_start" ]; then
            echo -e "${YELLOW}与项目规则冲突: IPv${existing_ip}/${existing_protocol} ${existing_start}-${existing_end} -> ${existing_target}${NC}"
            return 1
        fi
    done < <(extract_owned_rules)

    while IFS='|' read -r existing_ip existing_protocol existing_start existing_end; do
        [ -n "$existing_ip" ] || continue
        if [ "$ip_version" = "$existing_ip" ] && [ "$protocol" = "$existing_protocol" ] && \
           [ "$start_port" -le "$existing_end" ] && [ "$end_port" -ge "$existing_start" ]; then
            echo -e "${YELLOW}与外部 NAT 规则冲突: IPv${existing_ip}/${existing_protocol} ${existing_start}-${existing_end}${NC}"
            return 1
        fi
    done < <(extract_external_nat_ranges)

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

# --- 统一规则数据模型 -------------------------------------------------------
# 每行格式: IP版本|协议|起始端口|结束端口|目标端口
# 示例: 4|udp|6000|7000|3000
validate_rule_record() {
    local ip_version=$1 protocol=$2 start_port=$3 end_port=$4 target_port=$5

    [[ "$ip_version" =~ ^[46]$ ]] || return 1
    [[ "$protocol" =~ ^(tcp|udp)$ ]] || return 1
    [[ "$start_port" =~ ^[0-9]+$ ]] || return 1
    [[ "$end_port" =~ ^[0-9]+$ ]] || return 1
    [[ "$target_port" =~ ^[0-9]+$ ]] || return 1
    [ "$start_port" -ge 1 ] && [ "$start_port" -le 65535 ] || return 1
    [ "$end_port" -ge 1 ] && [ "$end_port" -le 65535 ] || return 1
    [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ] || return 1
    [ "$start_port" -le "$end_port" ] || return 1
    return 0
}

rule_record() {
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5"
}

rule_model_add() {
    local ip_version=$1 protocol=$2 start_port=$3 end_port=$4 target_port=$5
    local record temp_file

    if ! validate_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port"; then
        log_message "ERROR" "拒绝写入无效规则模型: $ip_version|$protocol|$start_port|$end_port|$target_port"
        return 1
    fi

    mkdir -p "$CONFIG_DIR" || return 1
    touch "$RULES_DB" || return 1
    chmod 600 "$RULES_DB" 2>/dev/null || true
    record=$(rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port")
    grep -Fxq "$record" "$RULES_DB" 2>/dev/null && return 0

    temp_file=$(mktemp "$CONFIG_DIR/.rules.db.XXXXXX") || return 1
    { cat "$RULES_DB" 2>/dev/null; printf '%s\n' "$record"; } | sort -u > "$temp_file"
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$RULES_DB"
}

rule_model_remove() {
    local ip_version=$1 protocol=$2 start_port=$3 end_port=$4 target_port=$5
    local record temp_file
    [ -f "$RULES_DB" ] || return 0

    record=$(rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port")
    temp_file=$(mktemp "$CONFIG_DIR/.rules.db.XXXXXX") || return 1
    grep -Fvx "$record" "$RULES_DB" > "$temp_file" 2>/dev/null || true
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$RULES_DB"
}

extract_owned_rules() {
    local ip_version iptables_cmd line protocol ports start_port end_port target_port

    for ip_version in 4 6; do
        iptables_cmd=$(get_iptables_cmd "$ip_version")
        command -v "$iptables_cmd" >/dev/null 2>&1 || continue

        while IFS= read -r line; do
            [[ "$line" == *"$RULE_COMMENT"* ]] || continue
            [[ "$line" == *"-j REDIRECT"* ]] || continue

            protocol=$(printf '%s\n' "$line" | sed -n 's/.* -p \(tcp\|udp\) .*/\1/p')
            ports=$(printf '%s\n' "$line" | sed -n 's/.*--dport \([0-9][0-9]*\)\(:\([0-9][0-9]*\)\)\?.*/\1|\3/p')
            target_port=$(printf '%s\n' "$line" | sed -n 's/.*--to-ports\? \([0-9][0-9]*\).*/\1/p')
            start_port=${ports%%|*}
            end_port=${ports#*|}
            [ -n "$end_port" ] || end_port=$start_port

            if validate_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port"; then
                rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port"
            fi
        done < <("$iptables_cmd" -t nat -S PREROUTING 2>/dev/null)
    done
}

extract_external_nat_ranges() {
    local ip_version iptables_cmd line protocol ports start_port end_port
    for ip_version in 4 6; do
        iptables_cmd=$(get_iptables_cmd "$ip_version")
        command -v "$iptables_cmd" >/dev/null 2>&1 || continue
        while IFS= read -r line; do
            [[ "$line" == *"--dport "* ]] || continue
            [[ "$line" == *"$RULE_COMMENT"* ]] && continue
            protocol=$(printf '%s\n' "$line" | sed -n 's/.* -p \(tcp\|udp\) .*/\1/p')
            ports=$(printf '%s\n' "$line" | sed -n 's/.*--dport \([0-9][0-9]*\)\(:\([0-9][0-9]*\)\)\?.*/\1|\3/p')
            start_port=${ports%%|*}
            end_port=${ports#*|}
            [ -n "$end_port" ] || end_port=$start_port
            if [[ "$protocol" =~ ^(tcp|udp)$ ]] && [[ "$start_port" =~ ^[0-9]+$ ]] && [[ "$end_port" =~ ^[0-9]+$ ]]; then
                printf '%s|%s|%s|%s\n' "$ip_version" "$protocol" "$start_port" "$end_port"
            fi
        done < <("$iptables_cmd" -t nat -S PREROUTING 2>/dev/null)
    done
}

# 显式操作调用此函数，把内核中带项目标记的规则同步到项目数据库。
sync_rule_model_from_kernel() {
    local temp_file
    mkdir -p "$CONFIG_DIR" || return 1
    temp_file=$(mktemp "$CONFIG_DIR/.rules.db.XXXXXX") || return 1
    extract_owned_rules | sort -u > "$temp_file"
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$RULES_DB"
    log_message "INFO" "规则数据模型已从内核同步"
}

validate_rule_model_file() {
    local line_no=0 ip_version protocol start_port end_port target_port
    local model_file=${1:-$RULES_DB}
    [ -f "$model_file" ] || return 1

    while IFS='|' read -r ip_version protocol start_port end_port target_port extra; do
        ((line_no++))
        [ -z "$ip_version$protocol$start_port$end_port$target_port$extra" ] && continue
        [ -z "$extra" ] || return 1
        validate_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port" || return 1
    done < "$model_file"
    return 0
}

apply_rule_record() {
    local ip_version=$1 protocol=$2 start_port=$3 end_port=$4 target_port=$5
    local iptables_cmd

    validate_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port" || return 1
    iptables_cmd=$(get_iptables_cmd "$ip_version")
    command -v "$iptables_cmd" >/dev/null 2>&1 || return 1

    if "$iptables_cmd" -t nat -C PREROUTING -p "$protocol" --dport "$start_port:$end_port" \
        -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port "$target_port" 2>/dev/null; then
        rule_model_add "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port"
        return $?
    fi

    "$iptables_cmd" -t nat -A PREROUTING -p "$protocol" --dport "$start_port:$end_port" \
        -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port "$target_port" || return 1
    rule_model_add "$ip_version" "$protocol" "$start_port" "$end_port" "$target_port"
}

# 保存配置到文件
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
            ports_to_check+=("$redirect_port:$protocol:$ip_version")
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
            if echo "$port_status_map" | grep -q "^${redirect_port}:${protocol}:${ip_version}:active$"; then
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
    local protocol=${3:-udp}
    local ip_version=${4:-$IP_VERSION}

    [ -n "$port_range" ] || true
    get_listening_socket "$ip_version" "$protocol" "$service_port" >/dev/null 2>&1
}

# 流量统计显示
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
        check_port_in_use "$service_port" "$protocol" "$IP_VERSION" true

        if ! check_port_conflicts "$start_port" "$end_port" "$service_port" "$protocol" "$IP_VERSION"; then
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
            backup_file="$LAST_BACKUP_FILE"
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
        rule_model_add "$IP_VERSION" "$protocol" "$start_port" "$end_port" "$service_port" || \
            log_message "WARNING" "规则已生效，但写入统一规则模型失败"
        clear_iptables_cache

        # 保存配置
        if ! save_mapping_config "$start_port" "$end_port" "$service_port" "$protocol"; then
            echo -e "${YELLOW}⚠ 配置保存失败，但规则已生效${NC}"
            log_message "WARNING" "配置保存失败"
        fi

        # 显示规则状态
        show_current_rules

        # 统一模型始终记录当前项目规则；专属服务启用后，后续变更自动保持一致。
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$PERSISTENCE_SERVICE" >/dev/null 2>&1; then
            echo -e "${GREEN}项目持久化服务已启用，本次变更已写入统一规则模型。${NC}"
        else
            read -p "是否启用项目专属持久化? (y/n): " save_choice
            if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
                if ! save_rules; then
                    echo -e "${YELLOW}⚠ 持久化配置失败，规则将在重启后失效${NC}"
                    log_message "WARNING" "规则持久化配置失败"
                fi
            else
                echo -e "${YELLOW}注意：持久化服务未启用，规则将在重启后失效。${NC}"
            fi
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
import_rules_from_file() {
    local config_file=$1
    local legacy_ip_version=${2:-$IP_VERSION}
    local line_num=0
    local raw_line ip_version protocol start_port end_port service_port extra record
    local existing_record candidate existing_ip existing_protocol existing_start existing_end existing_target
    local external_ip external_protocol external_start external_end
    local candidate_ip candidate_protocol candidate_start candidate_end candidate_target
    local success_count=0 error_count=0 backup_file
    local records=() unique_records=()

    IMPORT_SUCCESS_COUNT=0
    IMPORT_ERROR_COUNT=0

    [ -f "$config_file" ] || return 1

    # 阶段 1：完整解析，不执行任何 iptables 操作。
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_num=$((line_num + 1))

        raw_line=${raw_line%$'\r'}
        [[ -z "$raw_line" || "$raw_line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$raw_line" == *"|"* ]]; then
            IFS='|' read -r ip_version protocol start_port end_port service_port extra <<< "$raw_line"
        else
            # 兼容旧版三字段格式；旧格式没有协议和IP版本信息。
            IFS=':' read -r start_port end_port service_port extra <<< "$raw_line"
            ip_version=$legacy_ip_version
            protocol="udp"
        fi

        protocol=$(printf '%s' "$protocol" | tr '[:upper:]' '[:lower:]')

        if [ -n "$extra" ] || ! validate_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$service_port" || \
           { [ "$service_port" -ge "$start_port" ] && [ "$service_port" -le "$end_port" ]; }; then
            echo -e "${RED}第 $line_num 行无效，已跳过: $raw_line${NC}" >&2
            error_count=$((error_count + 1))
            continue
        fi

        record=$(rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$service_port")
        records+=("$record")
    done < "$config_file"

    # 任意格式错误都会使整个批次失败，不允许部分应用。
    if [ "$error_count" -gt 0 ]; then
        IMPORT_ERROR_COUNT=$error_count
        return 1
    fi

    # 去重并验证批次内部及与现有项目规则的范围冲突。
    while IFS= read -r record; do
        [ -n "$record" ] && unique_records+=("$record")
    done < <(printf '%s\n' "${records[@]}" | sed '/^$/d' | sort -u)

    for candidate in "${unique_records[@]}"; do
        IFS='|' read -r candidate_ip candidate_protocol candidate_start candidate_end candidate_target <<< "$candidate"

        while IFS= read -r existing_record; do
            [ -n "$existing_record" ] || continue
            [ "$candidate" = "$existing_record" ] && continue
            IFS='|' read -r existing_ip existing_protocol existing_start existing_end existing_target <<< "$existing_record"
            if [ "$candidate_ip" = "$existing_ip" ] && [ "$candidate_protocol" = "$existing_protocol" ] && \
               [ "$candidate_start" -le "$existing_end" ] && [ "$candidate_end" -ge "$existing_start" ]; then
                echo -e "${RED}批量导入范围冲突: $candidate 与现有规则 $existing_record${NC}" >&2
                IMPORT_ERROR_COUNT=1
                return 1
            fi
        done < <(extract_owned_rules)

        while IFS='|' read -r external_ip external_protocol external_start external_end; do
            [ -n "$external_ip" ] || continue
            if [ "$candidate_ip" = "$external_ip" ] && [ "$candidate_protocol" = "$external_protocol" ] && \
               [ "$candidate_start" -le "$external_end" ] && [ "$candidate_end" -ge "$external_start" ]; then
                echo -e "${RED}批量导入与外部 NAT 规则冲突: $candidate 与 IPv${external_ip}/${external_protocol} ${external_start}-${external_end}${NC}" >&2
                IMPORT_ERROR_COUNT=1
                return 1
            fi
        done < <(extract_external_nat_ranges)

        for record in "${records[@]}"; do
            [ "$record" = "$candidate" ] && continue
            IFS='|' read -r ip_version protocol start_port end_port service_port <<< "$record"
            if [ "$candidate_ip" = "$ip_version" ] && [ "$candidate_protocol" = "$protocol" ] && \
               [ "$candidate_start" -le "$end_port" ] && [ "$candidate_end" -ge "$start_port" ]; then
                echo -e "${RED}批次内部范围冲突: $candidate 与 $record${NC}" >&2
                IMPORT_ERROR_COUNT=1
                return 1
            fi
        done
    done

    [ ${#unique_records[@]} -gt 0 ] || return 0

    # 阶段 2：只备份一次，然后执行全部规则。
    backup_rules >/dev/null || { IMPORT_ERROR_COUNT=1; return 1; }
    backup_file=$LAST_BACKUP_FILE
    BATCH_BACKUP_FILE=$backup_file

    for record in "${unique_records[@]}"; do
        IFS='|' read -r ip_version protocol start_port end_port service_port <<< "$record"
        if apply_rule_record "$ip_version" "$protocol" "$start_port" "$end_port" "$service_port"; then
            success_count=$((success_count + 1))
        else
            echo -e "${RED}批量执行失败，正在回滚到批次前状态${NC}" >&2
            if ! restore_rules_from_backup_file "$backup_file" >/dev/null 2>&1; then
                echo -e "${RED}严重错误：批量导入失败，且无法恢复批次前备份 $backup_file${NC}" >&2
                log_message "CRITICAL" "批量导入失败且回滚失败: $backup_file"
            fi
            clear_iptables_cache
            IMPORT_SUCCESS_COUNT=0
            IMPORT_ERROR_COUNT=1
            return 1
        fi
    done

    clear_iptables_cache
    IMPORT_SUCCESS_COUNT=$success_count
    IMPORT_ERROR_COUNT=$error_count
    log_message "INFO" "批量导入: 成功=$success_count, 失败=$error_count"
    return 0
}

# 批量导入规则
batch_import_rules() {
    local config_file
    echo -e "${BLUE}批量导入规则${NC}"
    echo "请输入配置文件路径 (推荐格式: IP版本|协议|起始端口|结束端口|目标端口):"
    read -p "文件路径: " config_file

    if import_rules_from_file "$config_file" "$IP_VERSION"; then
        echo -e "${GREEN}批量导入完成: 成功 ${IMPORT_SUCCESS_COUNT:-0} 条${NC}"
    else
        echo -e "${YELLOW}批量导入完成: 成功 ${IMPORT_SUCCESS_COUNT:-0} 条, 失败 ${IMPORT_ERROR_COUNT:-0} 条${NC}"
        return 1
    fi
}

# 批量导出核心函数，始终同时导出 IPv4/IPv6 和 TCP/UDP 字段。
export_rules_to_file() {
    local export_file=$1
    sync_rule_model_from_kernel || return 1

    cat > "$export_file" << EOF
# Port Mapping Manager 规则导出文件
# 生成时间: $(date)
# 格式: IP版本|协议|起始端口|结束端口|目标端口
EOF

    cat "$RULES_DB" >> "$export_file" || return 1
    EXPORT_RULE_COUNT=$(awk 'NF {count++} END {print count+0}' "$RULES_DB" 2>/dev/null)
    log_message "INFO" "导出规则: $EXPORT_RULE_COUNT 条到 $export_file"
}

# 批量导出规则
batch_export_rules() {
    local export_file="${1:-$CONFIG_DIR/exported_rules_$(date +%Y%m%d_%H%M%S).conf}"
    echo "正在导出规则到: $export_file"
    if export_rules_to_file "$export_file"; then
        echo -e "${GREEN}✓ 已导出 ${EXPORT_RULE_COUNT:-0} 条规则到 $export_file${NC}"
        return 0
    fi
    echo -e "${RED}✗ 导出项目规则失败${NC}"
    return 1
}

# --- 新增功能：诊断和监控 ---

# 综合诊断功能
# --- 双栈诊断、监听与监控 ---------------------------------------------------
get_listening_socket() {
    local ip_version=$1 protocol=$2 port=$3
    local family_flag protocol_flag

    [ "$ip_version" = 6 ] && family_flag=-6 || family_flag=-4
    [ "$protocol" = tcp ] && protocol_flag=-t || protocol_flag=-u
    command -v ss >/dev/null 2>&1 || return 1

    ss -H -l -n -p "$family_flag" "$protocol_flag" 2>/dev/null | \
        awk -v wanted=":$port" '{
            for (i = 1; i <= NF; i++) {
                if (length($i) >= length(wanted) && substr($i, length($i) - length(wanted) + 1) == wanted) {
                    print
                    exit
                }
            }
        }'
}

is_service_listening() {
    [ -n "$(get_listening_socket "$1" "$2" "$3" 2>/dev/null)" ]
}

owned_rule_records() {
    extract_owned_rules | sort -u
}

owned_rule_count() {
    local wanted_version=${1:-all} wanted_protocol=${2:-all}
    owned_rule_records | awk -F'|' -v version="$wanted_version" -v protocol="$wanted_protocol" '
        (version == "all" || $1 == version) && (protocol == "all" || $2 == protocol) {count++}
        END {print count+0}
    '
}

collect_owned_traffic_stats() {
    local ip_version iptables_cmd line packets bytes protocol port_info target_port
    for ip_version in 4 6; do
        iptables_cmd=$(get_iptables_cmd "$ip_version")
        command -v "$iptables_cmd" >/dev/null 2>&1 || continue
        while IFS= read -r line; do
            [[ "$line" == *"$RULE_COMMENT"* ]] || continue
            packets=$(awk '{print $1}' <<< "$line")
            bytes=$(awk '{print $2}' <<< "$line")
            protocol=$(awk '{print $4}' <<< "$line")
            port_info=$(sed -n 's/.*dpts:\([0-9]*:[0-9]*\).*/\1/p' <<< "$line")
            [ -n "$port_info" ] || port_info=$(sed -n 's/.*dpt:\([0-9]*\).*/\1/p' <<< "$line")
            target_port=$(sed -n 's/.*redir ports \([0-9]*\).*/\1/p' <<< "$line")
            [[ "$packets" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || continue
            printf '%s|%s|%s|%s|%s|%s\n' \
                "$ip_version" "$protocol" "$port_info" "$target_port" "$packets" "$bytes"
        done < <("$iptables_cmd" -t nat -L PREROUTING -v -n -x 2>/dev/null)
    done
}

show_traffic_stats() {
    local ip_version protocol port_info target_port packets bytes
    local packets_v4=0 bytes_v4=0 packets_v6=0 bytes_v6=0
    while IFS='|' read -r ip_version protocol port_info target_port packets bytes; do
        [ -n "$ip_version" ] || continue
        if [ "$ip_version" = 6 ]; then
            packets_v6=$((packets_v6 + packets))
            bytes_v6=$((bytes_v6 + bytes))
        else
            packets_v4=$((packets_v4 + packets))
            bytes_v4=$((bytes_v4 + bytes))
        fi
    done < <(collect_owned_traffic_stats)

    echo -e "\n${CYAN}双栈流量统计:${NC}"
    echo "IPv4: $packets_v4 包 / $(format_bytes "$bytes_v4")"
    echo "IPv6: $packets_v6 包 / $(format_bytes "$bytes_v6")"
}

show_owned_listening_status() {
    local ip_version protocol start_port end_port target_port socket_info
    while IFS='|' read -r ip_version protocol start_port end_port target_port; do
        [ -n "$ip_version" ] || continue
        socket_info=$(get_listening_socket "$ip_version" "$protocol" "$target_port" 2>/dev/null || true)
        if [ -n "$socket_info" ]; then
            echo -e "${GREEN}✓ IPv${ip_version} ${protocol^^} $target_port 正在监听${NC}"
        else
            echo -e "${RED}✗ IPv${ip_version} ${protocol^^} $target_port 未监听${NC}"
        fi
    done < <(owned_rule_records)
}

test_network_connectivity() {
    local ip_version protocol start_port end_port target_port
    echo "本地服务可用性（按协议和地址族）:"
    while IFS='|' read -r ip_version protocol start_port end_port target_port; do
        [ -n "$ip_version" ] || continue
        if is_service_listening "$ip_version" "$protocol" "$target_port"; then
            echo "✓ IPv${ip_version} ${protocol^^} $target_port 可用"
        else
            echo "✗ IPv${ip_version} ${protocol^^} $target_port 无监听服务"
        fi
    done < <(owned_rule_records)
}

check_system_resources() {
    local mem_total mem_available mem_used mem_percent
    echo "系统负载: $(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo unknown)"
    if [ -r /proc/meminfo ]; then
        mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        if [ -n "$mem_total" ] && [ -n "$mem_available" ] && [ "$mem_total" -gt 0 ]; then
            mem_used=$((mem_total - mem_available))
            mem_percent=$((mem_used * 100 / mem_total))
            echo "内存使用率: ${mem_percent}% ($(format_bytes $((mem_used * 1024))))"
        fi
    fi
}

check_security_status() {
    local ip_version protocol start_port end_port target_port range_size high_risk=0
    local dangerous_ports=" 22 23 1433 3306 3389 5900 " dangerous=()
    while IFS='|' read -r ip_version protocol start_port end_port target_port; do
        [ -n "$ip_version" ] || continue
        range_size=$((end_port - start_port + 1))
        [ "$range_size" -gt 100 ] && high_risk=$((high_risk + 1))
        [[ "$dangerous_ports" == *" $target_port "* ]] && \
            dangerous+=("IPv${ip_version}/${protocol}:$target_port")
    done < <(owned_rule_records)
    echo "大范围映射: $high_risk"
    if [ ${#dangerous[@]} -gt 0 ]; then
        echo -e "${YELLOW}敏感目标端口: ${dangerous[*]}${NC}"
    else
        echo "未发现敏感目标端口"
    fi
}

provide_troubleshooting_suggestions() {
    local ip_version protocol start_port end_port target_port missing=()
    while IFS='|' read -r ip_version protocol start_port end_port target_port; do
        [ -n "$ip_version" ] || continue
        is_service_listening "$ip_version" "$protocol" "$target_port" || \
            missing+=("IPv${ip_version}/${protocol^^}:$target_port")
    done < <(owned_rule_records)
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}存在映射但没有对应监听服务: ${missing[*]}${NC}"
    else
        echo "所有项目规则均有匹配地址族和协议的监听服务"
    fi
}

generate_diagnostic_report() {
    local report_file ip_version protocol start_port end_port target_port status
    mkdir -p "$REPORT_DIR" || return 1
    report_file="$REPORT_DIR/diagnostic_report_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "Port Mapping Manager diagnostic report"
        echo "Generated: $(date -Is 2>/dev/null || date)"
        echo "Version: $SCRIPT_VERSION"
        echo "Kernel: $(uname -sr)"
        echo
        echo "Rule summary:"
        echo "IPv4 TCP: $(owned_rule_count 4 tcp)"
        echo "IPv4 UDP: $(owned_rule_count 4 udp)"
        echo "IPv6 TCP: $(owned_rule_count 6 tcp)"
        echo "IPv6 UDP: $(owned_rule_count 6 udp)"
        echo
        echo "Rules and listening state:"
        while IFS='|' read -r ip_version protocol start_port end_port target_port; do
            [ -n "$ip_version" ] || continue
            if is_service_listening "$ip_version" "$protocol" "$target_port"; then status=listening; else status=not-listening; fi
            echo "IPv${ip_version}|${protocol}|${start_port}|${end_port}|${target_port}|${status}"
        done < <(owned_rule_records)
        echo
        echo "Traffic:"
        collect_owned_traffic_stats
        echo
        echo "Listening sockets:"
        ss -H -lntup 2>/dev/null || true
    } > "$report_file"
    chmod 600 "$report_file" 2>/dev/null || true
    echo -e "${GREEN}诊断报告已保存: $report_file${NC}"
}

diagnose_system() {
    local total
    echo -e "${BLUE}========== 双栈系统诊断 ==========${NC}"
    echo "系统: $(uname -sr)"
    echo "IPv4 TCP规则: $(owned_rule_count 4 tcp)"
    echo "IPv4 UDP规则: $(owned_rule_count 4 udp)"
    echo "IPv6 TCP规则: $(owned_rule_count 6 tcp)"
    echo "IPv6 UDP规则: $(owned_rule_count 6 udp)"
    total=$(owned_rule_count)
    echo "项目规则总数: $total"
    echo
    show_owned_listening_status
    echo
    show_traffic_stats
    echo
    check_system_resources
    check_security_status
    provide_troubleshooting_suggestions
    echo
    read -p "是否生成持久化诊断报告? (y/N): " generate_report
    [[ "$generate_report" =~ ^[Yy]$ ]] && generate_diagnostic_report
}

monitor_traffic() {
    echo "1. 双栈总流量"
    echo "2. 双栈逐规则流量"
    echo "3. TCP/UDP、IPv4/IPv6 连接与监听"
    echo "4. 系统性能"
    echo "5. 返回"
    read -p "请选择 [1-5]: " monitor_mode
    case "$monitor_mode" in
        1) monitor_simple ;;
        2) monitor_detailed ;;
        3) monitor_connections ;;
        4) monitor_performance ;;
        5) return ;;
        *) return 1 ;;
    esac
}

monitor_simple() {
    local prev_packets=0 prev_bytes=0 current_packets current_bytes packet_rate byte_rate
    local ip_version protocol port_info target_port packets bytes
    trap 'echo; return' INT
    while true; do
        current_packets=0
        current_bytes=0
        while IFS='|' read -r ip_version protocol port_info target_port packets bytes; do
            [ -n "$ip_version" ] || continue
            current_packets=$((current_packets + packets))
            current_bytes=$((current_bytes + bytes))
        done < <(collect_owned_traffic_stats)
        packet_rate=$((current_packets - prev_packets))
        byte_rate=$((current_bytes - prev_bytes))
        printf '%s packets=%d bytes=%s rate=%dpps/%s/s listeners=%d\n' \
            "$(date '+%H:%M:%S')" "$current_packets" "$(format_bytes "$current_bytes")" \
            "$packet_rate" "$(format_bytes "$byte_rate")" \
            "$(ss -H -lntup 2>/dev/null | wc -l)"
        prev_packets=$current_packets
        prev_bytes=$current_bytes
        sleep 1
    done
}

monitor_detailed() {
    local ip_version protocol port_info target_port packets bytes status
    trap 'echo; return' INT
    while true; do
        clear
        printf '%-5s %-5s %-15s %-8s %-12s %-12s %-14s\n' IP Proto Source Target Packets Bytes Listener
        while IFS='|' read -r ip_version protocol port_info target_port packets bytes; do
            [ -n "$ip_version" ] || continue
            if is_service_listening "$ip_version" "$protocol" "$target_port"; then status=up; else status=down; fi
            printf '%-5s %-5s %-15s %-8s %-12s %-12s %-14s\n' \
                "IPv$ip_version" "$protocol" "$port_info" "$target_port" "$packets" \
                "$(format_bytes "$bytes")" "$status"
        done < <(collect_owned_traffic_stats)
        sleep 2
    done
}

monitor_connections() {
    trap 'echo; return' INT
    while true; do
        clear
        echo "IPv4 TCP listening/established:"
        ss -H -4 -lntp 2>/dev/null | head -10
        ss -H -4 -ntp state established 2>/dev/null | head -10
        echo "IPv4 UDP listening:"
        ss -H -4 -lnup 2>/dev/null | head -10
        echo "IPv6 TCP listening/established:"
        ss -H -6 -lntp 2>/dev/null | head -10
        ss -H -6 -ntp state established 2>/dev/null | head -10
        echo "IPv6 UDP listening:"
        ss -H -6 -lnup 2>/dev/null | head -10
        sleep 3
    done
}

monitor_performance() {
    trap 'echo; return' INT
    while true; do
        clear
        check_system_resources
        echo "IPv4 rules: $(owned_rule_count 4)"
        echo "IPv6 rules: $(owned_rule_count 6)"
        echo "TCP rules: $(owned_rule_count all tcp)"
        echo "UDP rules: $(owned_rule_count all udp)"
        sleep 2
    done
}

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
    # 只收集带项目标记的 REDIRECT 规则，禁止管理外部规则。
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
    done < <($iptables_cmd -t nat -L PREROUTING --line-numbers | grep "REDIRECT" | grep -F "$RULE_COMMENT")

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

    sync_rule_model_from_kernel || log_message "WARNING" "删除后同步规则模型失败"
    clear_iptables_cache
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
    echo "1. 仅删除项目端口映射规则"
    echo "2. 从项目规则备份恢复"
    echo "3. 返回主菜单"

    read -p "请选择恢复方式 [1-3]: " restore_choice

    case $restore_choice in
        1) remove_mapping_rules ;;
        2) restore_from_backup ;;
        3) return ;;
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
    sync_rule_model_from_kernel || log_message "WARNING" "批量删除后同步规则模型失败"
    clear_iptables_cache

    if [ $deleted_count -gt 0 ] && command -v systemctl >/dev/null 2>&1 && \
       systemctl is-enabled "$PERSISTENCE_SERVICE" >/dev/null 2>&1; then
        echo -e "${GREEN}项目持久化服务已启用，删除结果已同步到统一规则模型。${NC}"
    fi
}

# 删除规则并恢复备份
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
    echo "• 项目专属、幂等的 systemd 持久化"
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
    echo "│ 11. 持久化检查/显式修复            │"
    echo "│ 12. 非破坏性持久化测试             │"
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
    echo "• 重启后丢失: 运行 '11. 持久化检查/显式修复'"
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
    echo "v5.0 - 项目边界与统一规则模型"
    echo "     • 持久化只恢复项目拥有的规则"
    echo "     • 启动检查与显式修复分离"
    echo "     • 卸载不再接管系统防火墙文件或依赖"
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
    local trust_file="$CONFIG_DIR/trusted-release.conf"
    local trusted_ref="${PMM_TRUSTED_REF:-}"
    local trusted_manifest_sha256="${PMM_TRUSTED_MANIFEST_SHA256:-}"
    local remote_base manifest_file candidate_script actual_manifest_sha256 expected_script_sha256
    local actual_script_sha256 remote_version backup_path replacement

    if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1 || \
       ! command -v install >/dev/null 2>&1; then
        echo -e "${RED}更新校验需要 curl、sha256sum 和 install${NC}"
        return 1
    fi

    # 信任锚只能来自安装时写入的只读配置，或管理员通过环境变量显式提供。
    if [ -z "$trusted_ref" ] && [ -f "$trust_file" ]; then
        trusted_ref=$(awk -F= '$1 == "RELEASE_REF" {print substr($0, index($0, "=") + 1)}' "$trust_file" | head -n1)
    fi
    if [ -z "$trusted_manifest_sha256" ] && [ -f "$trust_file" ]; then
        trusted_manifest_sha256=$(awk -F= '$1 == "MANIFEST_SHA256" {print $2}' "$trust_file" | head -n1)
    fi

    if [[ ! "$trusted_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || \
       [[ ! "$trusted_manifest_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${RED}拒绝更新：缺少有效的受信任发布引用或清单摘要${NC}"
        echo "请通过经过验证的新安装器更新信任锚，或显式设置："
        echo "  PMM_TRUSTED_REF=<tag-or-commit>"
        echo "  PMM_TRUSTED_MANIFEST_SHA256=<sha256>"
        return 1
    fi

    remote_base="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/$trusted_ref"
    manifest_file=$(mktemp /tmp/pmm-manifest.XXXXXX) || return 1
    candidate_script=$(mktemp /tmp/pmm-update.XXXXXX) || { rm -f "$manifest_file"; return 1; }
    register_temp_file "$manifest_file"
    register_temp_file "$candidate_script"

    echo -e "${BLUE}正在检查受信任发布: $trusted_ref${NC}"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 30 "$remote_base/release-manifest.sha256" \
        -o "$manifest_file" || return 1

    actual_manifest_sha256=$(sha256sum "$manifest_file" | awk '{print $1}')
    if [ "${actual_manifest_sha256,,}" != "${trusted_manifest_sha256,,}" ]; then
        echo -e "${RED}拒绝更新：发布清单 SHA-256 与信任锚不匹配${NC}"
        return 1
    fi

    expected_script_sha256=$(awk '$2 == "port_mapping_manager.sh" && $1 ~ /^[0-9a-fA-F]{64}$/ {print $1}' "$manifest_file")
    if [[ ! "$expected_script_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${RED}拒绝更新：清单中缺少主脚本摘要${NC}"
        return 1
    fi

    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 60 "$remote_base/port_mapping_manager.sh" \
        -o "$candidate_script" || return 1
    actual_script_sha256=$(sha256sum "$candidate_script" | awk '{print $1}')
    if [ "${actual_script_sha256,,}" != "${expected_script_sha256,,}" ]; then
        echo -e "${RED}拒绝更新：主脚本 SHA-256 校验失败${NC}"
        return 1
    fi
    bash -n "$candidate_script" || {
        echo -e "${RED}拒绝更新：候选脚本语法检查失败${NC}"
        return 1
    }

    remote_version=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$candidate_script" | head -n1)
    [ -n "$remote_version" ] || {
        echo -e "${RED}拒绝更新：候选脚本缺少版本信息${NC}"
        return 1
    }

    echo "当前版本: $SCRIPT_VERSION"
    echo "受信任发布版本: $remote_version"
    if [ "$remote_version" = "$SCRIPT_VERSION" ]; then
        echo -e "${GREEN}当前脚本已与受信任发布一致${NC}"
        return 0
    fi

    read -p "校验已通过，是否安装受信任版本? (y/N): " update_choice
    [[ "$update_choice" =~ ^[Yy]$ ]] || return 0
    [ -w "$0" ] || { echo -e "${RED}当前脚本不可写，无法更新${NC}"; return 1; }

    mkdir -p "$BACKUP_DIR" || return 1
    backup_path="$BACKUP_DIR/script_backup_$(date +%Y%m%d_%H%M%S).sh"
    cp -- "$0" "$backup_path" || return 1
    replacement="${0}.verified.$$"
    install -m 0755 "$candidate_script" "$replacement" || return 1
    if mv -f -- "$replacement" "$0"; then
        log_message "INFO" "脚本已通过受信任清单从 v$SCRIPT_VERSION 更新到 v$remote_version"
        echo -e "${GREEN}受信任更新安装成功，请重新运行 pmm${NC}"
        return 0
    fi

    rm -f -- "$replacement"
    echo -e "${RED}更新替换失败，原脚本未被修改${NC}"
    return 1
}

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

# 公网IP检测（带缓存）
get_public_ip() {
    local version="$1"
    local current_time=$(date +%s)
    local cached_value=""
    local last_time=0

    case "$version" in
        4)
            cached_value="$PUBLIC_IPV4"
            last_time=$PUBLIC_IP_TIMESTAMP
            ;;
        6)
            cached_value="$PUBLIC_IPV6"
            last_time=$PUBLIC_IP_TIMESTAMP
            ;;
        *)
            echo "未知版本"
            return
            ;;
    esac

    if [ -n "$cached_value" ] && [ $((current_time - last_time)) -lt $PUBLIC_IP_TTL ]; then
        echo "$cached_value"
        return
    fi

    if ! command -v curl &>/dev/null; then
        echo "未安装 curl"
        return
    fi

    local curl_opts=("-s" "--connect-timeout" "3" "--max-time" "5" "--retry" "1" "--retry-delay" "1")
    local service_urls=()
    local curl_flag="-4"
    local result=""

    if [ "$version" = "6" ]; then
        service_urls=("https://api64.ipify.org" "https://ipv6.ip.sb")
        curl_flag="-6"
    else
        service_urls=("https://api.ipify.org" "https://ip.sb")
    fi

    local ip_regex
    if [ "$version" = "6" ]; then
        ip_regex='^[0-9a-fA-F:]+$'
    else
        ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    fi

    for service_url in "${service_urls[@]}"; do
        result=$(curl "$curl_flag" "${curl_opts[@]}" "$service_url" 2>/dev/null)
        if [[ -n "$result" && "$result" =~ $ip_regex ]]; then
            break
        fi
        result=""
    done

    # IPv6 再尝试从本机全局地址获取
    if [ -z "$result" ] && [ "$version" = "6" ] && command -v ip &>/dev/null; then
        result=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)
        [[ -n "$result" && "$result" =~ $ip_regex ]] || result=""
    fi

    if [[ -n "$result" && "$result" =~ $ip_regex ]]; then
        if [ "$version" = "6" ]; then
            PUBLIC_IPV6="$result"
        else
            PUBLIC_IPV4="$result"
        fi
        PUBLIC_IP_TIMESTAMP=$current_time
        echo "$result"
    else
        echo "检测失败"
    fi
}

# 主菜单
show_main_menu() {
    clear
    local ip_version_str="IPv${IP_VERSION}"
    local public_ipv4=$(get_public_ip 4)
    local public_ipv6=$(get_public_ip 6)
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  UDP端口映射管理脚本 Enhanced v${SCRIPT_VERSION}  [当前: ${ip_version_str}]${NC}"
    echo -e "${CYAN}  https://github.com/pjy02/Port-Mapping-Manage${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${YELLOW}  公网IPv4: ${public_ipv4}${NC}"
    echo -e "${YELLOW}  公网IPv6: ${public_ipv6}${NC}"

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
    echo " 11. 持久化检查/显式修复"
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
# Port Mapping Manager 统一规则模型示例
# 格式: IP版本|协议|起始端口|结束端口|目标端口
#
# Hysteria2 标准配置
4|udp|6000|7000|3000
# Hysteria2 备用配置
4|udp|8000|9000|4000
# IPv6 TCP 映射
6|tcp|10000|12000|5000
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
backup_rules() {
    local backup_file
    mkdir -p "$BACKUP_DIR" || return 1
    sync_rule_model_from_kernel || return 1
    backup_file="$BACKUP_DIR/owned_rules_$(date +%Y%m%d_%H%M%S)_$$.db"
    cp "$RULES_DB" "$backup_file" || return 1
    LAST_BACKUP_FILE="$backup_file"
    chmod 600 "$backup_file" 2>/dev/null || true
    cleanup_old_backups
    echo -e "${GREEN}✓ 项目规则已备份到: $backup_file${NC}"
}

# 兼容旧调用点；统一模型是唯一规则配置来源，不再生成 mappings.conf。
save_mapping_config() {
    rule_model_add "$IP_VERSION" "${4:-udp}" "$1" "$2" "$3"
}

cleanup_old_backups() {
    local max_backups=${MAX_BACKUPS:-10}
    local backup_count excess
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' 2>/dev/null | wc -l)
    if [ "$backup_count" -gt "$max_backups" ]; then
        excess=$((backup_count - max_backups))
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' -printf '%T@ %p\n' 2>/dev/null | \
            sort -n | head -n "$excess" | cut -d' ' -f2- | while IFS= read -r file; do rm -f -- "$file"; done
    fi
}

list_backups() {
    local files=() file
    while IFS= read -r file; do files+=("$file"); done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' -printf '%T@ %p\n' 2>/dev/null | \
            sort -nr | cut -d' ' -f2-
    )
    [ ${#files[@]} -gt 0 ] || { echo -e "${YELLOW}未找到项目规则备份${NC}"; return 0; }
    for i in "${!files[@]}"; do
        echo "$((i+1)). $(basename "${files[$i]}") ($(grep -cve '^[[:space:]]*$' "${files[$i]}" 2>/dev/null || echo 0) 条规则)"
    done
}

restore_rules_from_backup_file() {
    local selected=$1
    local current_backup had_model=false

    validate_rule_model_file "$selected" || { echo -e "${RED}备份格式无效${NC}"; return 1; }
    current_backup=$(mktemp) || return 1
    if [ -f "$RULES_DB" ]; then
        cp "$RULES_DB" "$current_backup"
        had_model=true
    fi
    if delete_all_owned_rules && cp "$selected" "$RULES_DB" && create_restore_script && "$RESTORE_SCRIPT"; then
        rm -f "$current_backup"
        clear_iptables_cache
        return 0
    fi

    delete_all_owned_rules >/dev/null 2>&1 || true
    if [ "$had_model" = true ]; then
        cp "$current_backup" "$RULES_DB"
    else
        : > "$RULES_DB"
    fi
    rm -f "$current_backup"
    create_restore_script && "$RESTORE_SCRIPT" >/dev/null 2>&1 || true
    return 1
}

restore_from_backup() {
    local files=() file choice selected
    while IFS= read -r file; do files+=("$file"); done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' -printf '%T@ %p\n' 2>/dev/null | \
            sort -nr | cut -d' ' -f2-
    )
    [ ${#files[@]} -gt 0 ] || { echo -e "${YELLOW}未找到项目规则备份${NC}"; return 1; }
    list_backups
    read -p "选择要恢复的备份序号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ] || return 1
    selected=${files[$((choice-1))]}
    read -p "只替换项目拥有的规则，确认恢复? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    if restore_rules_from_backup_file "$selected"; then
        echo -e "${GREEN}✓ 项目规则恢复成功${NC}"
        return 0
    fi
    echo -e "${RED}项目规则恢复失败，已尝试回滚${NC}"
    return 1
}

interactive_cleanup_backups() {
    local files=() file choices sel
    while IFS= read -r file; do files+=("$file"); done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' -printf '%T@ %p\n' 2>/dev/null | \
            sort -nr | cut -d' ' -f2-
    )
    [ ${#files[@]} -gt 0 ] || { echo -e "${YELLOW}未找到项目规则备份${NC}"; return 0; }
    list_backups
    read -p "输入要删除的序号（空格分隔），或输入 all: " choices
    if [ "$choices" = all ]; then
        for file in "${files[@]}"; do rm -f -- "$file"; done
        return 0
    fi
    choices=$(printf '%s\n' "$choices" | tr -cs '0-9' ' ')
    for sel in $choices; do
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#files[@]} ]; then
            rm -f -- "${files[$((sel-1))]}"
        fi
    done
}

# --- 项目专属持久化实现 -----------------------------------------------------
# 以下定义替代旧版的全量 iptables-save/restore 方案。持久化只读取 RULES_DB，
# 只创建带 RULE_COMMENT 的 REDIRECT 规则，不接管系统其他防火墙规则。
create_restore_script() {
    mkdir -p "$CONFIG_DIR" || return 1
    cat > "$RESTORE_SCRIPT" <<EOF
#!/bin/bash
set -u

RULES_DB="$RULES_DB"
RULE_COMMENT="$RULE_COMMENT"
LOG_FILE="$LOG_FILE"

log_restore() {
    printf '[%s] [pmm-restore] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" >> "\$LOG_FILE" 2>/dev/null || true
}

[ -f "\$RULES_DB" ] || { log_restore "规则数据库不存在，无需恢复"; exit 0; }
failures=0

while IFS='|' read -r ip_version protocol start_port end_port target_port extra; do
    [ -z "\${ip_version}\${protocol}\${start_port}\${end_port}\${target_port}\${extra}" ] && continue
    if [ -n "\${extra:-}" ] || ! [[ "\$ip_version" =~ ^[46]$ ]] || ! [[ "\$protocol" =~ ^(tcp|udp)$ ]] ||
       ! [[ "\$start_port" =~ ^[0-9]+$ ]] || ! [[ "\$end_port" =~ ^[0-9]+$ ]] || ! [[ "\$target_port" =~ ^[0-9]+$ ]]; then
        log_restore "忽略无效记录: \$ip_version|\$protocol|\$start_port|\$end_port|\$target_port"
        failures=1
        continue
    fi

    [ "\$ip_version" = "6" ] && cmd=ip6tables || cmd=iptables
    command -v "\$cmd" >/dev/null 2>&1 || { log_restore "命令不存在: \$cmd"; failures=1; continue; }

    if "\$cmd" -t nat -C PREROUTING -p "\$protocol" --dport "\$start_port:\$end_port" \
        -m comment --comment "\$RULE_COMMENT" -j REDIRECT --to-port "\$target_port" 2>/dev/null; then
        continue
    fi

    if ! "\$cmd" -t nat -A PREROUTING -p "\$protocol" --dport "\$start_port:\$end_port" \
        -m comment --comment "\$RULE_COMMENT" -j REDIRECT --to-port "\$target_port"; then
        log_restore "恢复失败: IPv\$ip_version \$protocol \$start_port-\$end_port -> \$target_port"
        failures=1
    fi
done < "\$RULES_DB"

exit "\$failures"
EOF
    chmod 700 "$RESTORE_SCRIPT"
}

cleanup_legacy_persistence_hooks() {
    local changed=false temp_file service_file service_name

    # 只移除明确引用本项目旧恢复脚本的 root crontab 行。
    if command -v crontab >/dev/null 2>&1 && crontab -l >/dev/null 2>&1; then
        temp_file=$(mktemp) || return 1
        crontab -l 2>/dev/null | grep -Fv "$CONFIG_DIR/restore-rules.sh" > "$temp_file" || true
        if ! cmp -s "$temp_file" <(crontab -l 2>/dev/null); then
            crontab "$temp_file" && changed=true
        fi
        rm -f "$temp_file"
    fi

    # 对共享文件只删除本项目写入的精确行，不删除文件本身。
    if [ -f /etc/rc.local ] && grep -Fq "$CONFIG_DIR/restore-rules.sh" /etc/rc.local; then
        temp_file=$(mktemp) || return 1
        grep -Fv "$CONFIG_DIR/restore-rules.sh" /etc/rc.local | \
            grep -Fv '# Port Mapping Manager - 恢复 iptables 规则' > "$temp_file" || true
        cat "$temp_file" > /etc/rc.local && changed=true
        rm -f "$temp_file"
    fi

    if [ -f /etc/network/if-up.d/iptables-restore ] && \
       grep -Eq "Port Mapping Manager|$CONFIG_DIR/restore-rules.sh" /etc/network/if-up.d/iptables-restore; then
        rm -f /etc/network/if-up.d/iptables-restore && changed=true
    fi

    # 旧服务名不具备唯一性，只有内容明确指向本项目时才删除。
    for service_name in udp-port-mapping.service iptables-restore.service; do
        service_file="/etc/systemd/system/$service_name"
        if [ -f "$service_file" ] && grep -Eq "$CONFIG_DIR|UDP Port Mapping Rules" "$service_file"; then
            systemctl disable --now "$service_name" >/dev/null 2>&1 || true
            rm -f "$service_file"
            changed=true
        fi
    done

    [ "$changed" = true ] && command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

setup_systemd_service() {
    command -v systemctl >/dev/null 2>&1 || {
        echo -e "${RED}当前系统不支持 systemd，无法配置项目持久化服务${NC}"
        return 1
    }
    create_restore_script || return 1

    cat > "$PERSISTENCE_SERVICE_FILE" <<EOF
[Unit]
Description=Port Mapping Manager owned rules
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || return 1
    systemctl enable "$PERSISTENCE_SERVICE" || return 1
    systemctl start "$PERSISTENCE_SERVICE"
}

check_persistence_config() {
    local issues=0
    echo -e "${BLUE}========== 持久化只读检查 ==========${NC}"

    if validate_rule_model_file; then
        echo -e "${GREEN}✓ 统一规则数据库有效: $RULES_DB${NC}"
    else
        echo -e "${YELLOW}⚠ 规则数据库不存在或格式无效${NC}"
        ((issues++))
    fi

    if [ -x "$RESTORE_SCRIPT" ] && bash -n "$RESTORE_SCRIPT" 2>/dev/null; then
        echo -e "${GREEN}✓ 项目恢复脚本有效${NC}"
    else
        echo -e "${YELLOW}⚠ 项目恢复脚本缺失或无效${NC}"
        ((issues++))
    fi

    if [ -f "$PERSISTENCE_SERVICE_FILE" ] && grep -Fq "$RESTORE_SCRIPT" "$PERSISTENCE_SERVICE_FILE"; then
        echo -e "${GREEN}✓ 项目专属 systemd 服务文件有效${NC}"
    else
        echo -e "${YELLOW}⚠ 项目专属 systemd 服务未配置${NC}"
        ((issues++))
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$PERSISTENCE_SERVICE" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ $PERSISTENCE_SERVICE 已启用${NC}"
    else
        echo -e "${YELLOW}⚠ $PERSISTENCE_SERVICE 未启用${NC}"
        ((issues++))
    fi

    if grep -RqsF "$CONFIG_DIR/restore-rules.sh" /etc/systemd/system /etc/rc.local /etc/network/if-up.d 2>/dev/null || \
       { command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$CONFIG_DIR/restore-rules.sh"; }; then
        echo -e "${YELLOW}⚠ 检测到旧版持久化启动项；显式修复时可安全迁移${NC}"
        ((issues++))
    fi

    echo "检查完成：发现 $issues 个问题。本操作没有修改系统。"
    [ "$issues" -eq 0 ]
}

repair_persistence_config() {
    echo -e "${BLUE}========== 显式修复持久化 ==========${NC}"
    echo "此操作将同步项目规则、创建 $PERSISTENCE_SERVICE，并清理明确属于本项目的旧启动项。"
    read -p "确认执行修复? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消修复"; return 0; }

    sync_rule_model_from_kernel || return 1
    cleanup_legacy_persistence_hooks || return 1
    if setup_systemd_service; then
        echo -e "${GREEN}✓ 项目专属持久化已修复${NC}"
        return 0
    fi
    echo -e "${RED}✗ 持久化修复失败${NC}"
    return 1
}

check_and_fix_persistence() {
    echo "1. 只读检查（不修改系统）"
    echo "2. 显式修复"
    echo "3. 返回"
    read -p "请选择 [1-3]: " persistence_choice
    case "$persistence_choice" in
        1) check_persistence_config ;;
        2) repair_persistence_config ;;
        3) return 0 ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
}

save_rules() {
    echo -e "${BLUE}正在持久化项目拥有的规则...${NC}"
    sync_rule_model_from_kernel || return 1
    cleanup_legacy_persistence_hooks || return 1
    if setup_systemd_service; then
        echo -e "${GREEN}✓ 已持久化 $(grep -cve '^[[:space:]]*$' "$RULES_DB" 2>/dev/null || echo 0) 条项目规则${NC}"
        return 0
    fi
    return 1
}

verify_persistence_config() {
    check_persistence_config
}

test_persistence_config() {
    echo -e "${BLUE}========== 非破坏性持久化测试 ==========${NC}"
    check_persistence_config || return 1
    echo "测试将幂等执行项目恢复脚本，不会清空或覆盖系统规则。"
    read -p "确认测试? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    if "$RESTORE_SCRIPT"; then
        echo -e "${GREEN}✓ 恢复脚本执行成功${NC}"
        clear_iptables_cache
        return 0
    fi
    echo -e "${RED}✗ 恢复脚本执行失败${NC}"
    return 1
}

# --- 项目边界内的卸载实现 ---------------------------------------------------
delete_all_owned_rules() {
    local ip_version iptables_cmd line_num deleted=0 failed=0

    for ip_version in 4 6; do
        iptables_cmd=$(get_iptables_cmd "$ip_version")
        command -v "$iptables_cmd" >/dev/null 2>&1 || continue

        while true; do
            line_num=$("$iptables_cmd" -t nat -L PREROUTING --line-numbers -n 2>/dev/null | \
                grep -F "$RULE_COMMENT" | head -n1 | awk '{print $1}')
            [ -n "$line_num" ] || break
            if "$iptables_cmd" -t nat -D PREROUTING "$line_num"; then
                ((deleted++))
            else
                ((failed++))
                break
            fi
        done
    done

    clear_iptables_cache
    echo "已删除 $deleted 条项目规则，失败 $failed 条。"
    [ "$failed" -eq 0 ]
}

remove_owned_systemd_services() {
    local service_name service_file changed=false
    command -v systemctl >/dev/null 2>&1 || return 0

    if [ -f "$PERSISTENCE_SERVICE_FILE" ]; then
        systemctl disable --now "$PERSISTENCE_SERVICE" >/dev/null 2>&1 || true
        rm -f "$PERSISTENCE_SERVICE_FILE" || return 1
        changed=true
    fi

    # 兼容清理旧版本服务，但必须先验证文件确实指向本项目。
    for service_name in udp-port-mapping.service iptables-restore.service; do
        service_file="/etc/systemd/system/$service_name"
        if [ -f "$service_file" ] && grep -Eq "$CONFIG_DIR|UDP Port Mapping Rules" "$service_file"; then
            systemctl disable --now "$service_name" >/dev/null 2>&1 || true
            rm -f "$service_file" || return 1
            changed=true
        fi
    done

    [ "$changed" = true ] && systemctl daemon-reload || true
}

remove_owned_launchers() {
    local launcher
    for launcher in /usr/local/bin/pmm /usr/bin/pmm; do
        if [ -f "$launcher" ] && grep -Fq '/etc/port_mapping_manager/port_mapping_manager.sh' "$launcher"; then
            rm -f "$launcher" || return 1
        fi
    done
}

complete_uninstall() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}卸载需要 root 权限，请使用 sudo pmm --uninstall${NC}"
        return 1
    fi
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}      安全卸载 Port Mapping Manager${NC}"
    echo -e "${RED}========================================${NC}"
    echo "卸载只会删除："
    echo "  • 带有 $RULE_COMMENT 标记的 IPv4/IPv6 规则"
    echo "  • 本项目的 systemd 服务、恢复脚本、配置、日志和启动器"
    echo "  • 旧版本明确写入的 crontab/rc.local/if-up 启动项"
    echo
    echo "不会删除 /etc/iptables/rules.*，不会禁用系统 netfilter-persistent，"
    echo "不会卸载 iptables 或其他软件包，也不会修改第三方防火墙规则。"
    read -p "输入 UNINSTALL_PMM 确认卸载: " confirm
    [ "$confirm" = "UNINSTALL_PMM" ] || { echo "已取消卸载"; return 0; }

    local failures=0
    delete_all_owned_rules || ((failures++))
    remove_owned_systemd_services || ((failures++))
    cleanup_legacy_persistence_hooks || ((failures++))
    remove_owned_launchers || ((failures++))

    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR" || ((failures++))
    fi
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE" || ((failures++))
    fi

    if [ "$failures" -eq 0 ]; then
        echo -e "${GREEN}✓ 项目资源已安全卸载${NC}"
        return 0
    fi
    echo -e "${YELLOW}⚠ 卸载完成，但有 $failures 个步骤失败，请查看输出${NC}"
    return 1
}

uninstall_script() {
    complete_uninstall
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

    # 启动阶段禁止隐式修复、安装软件或修改系统启动项。
    # 这里只执行本地规则数据库的只读验证；修复必须由用户从菜单 11 显式触发。
    if [ -f "$RULES_DB" ] && ! validate_rule_model_file; then
        log_message "WARNING" "规则数据库格式无效，请从菜单 11 显式检查"
    fi

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
        --ip-version)
            if [[ "${2:-}" =~ ^[46]$ ]]; then
                IP_VERSION=$2
                shift 2
            else
                echo "--ip-version 需要参数 4 或 6"
                exit 1
            fi
            ;;
        --uninstall)
            uninstall_script
            exit $?
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
    initialize_script || return 1

    # 进入主循环
    main_loop
}



# 启动脚本；PMM_SOURCE_ONLY=true 供只读测试加载函数定义。
if [ "${PMM_SOURCE_ONLY:-false}" != "true" ]; then
    main "$@"
fi
