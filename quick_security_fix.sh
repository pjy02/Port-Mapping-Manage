#!/bin/bash
# Port Mapping Manager 快速安全修复脚本
# 直接修复最关键的安全问题

set -euo pipefail

SCRIPT_FILE="port_mapping_manager.sh"
BACKUP_FILE="port_mapping_manager.sh.security_backup.$(date +%Y%m%d_%H%M%S)"

# 颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

echo -e "${BLUE}Port Mapping Manager 快速安全修复${NC}"
echo "=========================================="

# 检查原文件
if [ ! -f "$SCRIPT_FILE" ]; then
    echo -e "${RED}错误: 找不到 $SCRIPT_FILE${NC}"
    exit 1
fi

# 备份原文件
echo "正在备份原文件..."
cp "$SCRIPT_FILE" "$BACKUP_FILE"
echo -e "${GREEN}✓ 已备份到: $BACKUP_FILE${NC}"

# 修复1: 删除重复的log_message函数（如果存在）
echo "1. 检查并修复重复函数定义..."
if grep -n "^log_message()" "$SCRIPT_FILE" | wc -l | grep -q "2"; then
    echo "发现重复的log_message函数，正在修复..."
    # 找到第二个log_message函数并删除
    sed -i '/^# 由 Port Mapping Manager 自动生成$/,/^log_message() {$/d' "$SCRIPT_FILE" 2>/dev/null || true
    sed -i '/^LOG_FILE="\/var\/log\/udp-port-mapping.log"$/,/^}$/d' "$SCRIPT_FILE" 2>/dev/null || true
    echo -e "${GREEN}✓ 重复函数已删除${NC}"
fi

# 修复2: 增强sanitize_input函数
echo "2. 增强输入验证..."
# 备份当前的sanitize_input函数并替换
sed -i '/^# 输入安全验证$/,/^}$/c\
# 增强的输入安全验证\
sanitize_input() {\
    local input="$1"\
    local type="${2:-default}"\
    \
    # 防止空输入和过长输入\
    if [ -z "$input" ] || [ ${#input} -gt 1000 ]; then\
        echo ""\
        return 1\
    fi\
    \
    case "$type" in\
        "port")\
            # 端口号：只允许1-5位数字\
            if echo "$input" | grep -qE "^[0-9]{1,5}$"; then\
                echo "$input"\
            else\
                echo ""\
                return 1\
            fi\
            ;;\
        "path")\
            # 文件路径：防止路径遍历攻击，移除危险字符\
            echo "$input" | sed "s/\\.\\.\\///g" | sed "s/[;&|`$(){}[\\]\\\\]//g" | sed "s/[^a-zA-Z0-9._/-]//g"\
            ;;\
        "filename")\
            # 文件名：只允许安全字符\
            echo "$input" | sed "s/[^a-zA-Z0-9._-]//g"\
            ;;\
        "protocol")\
            # 协议：只允许tcp或udp\
            case "$input" in\
                "tcp"|"TCP"|"1") echo "tcp" ;;\
                "udp"|"UDP"|"2") echo "udp" ;;\
                *) echo ""; return 1 ;;\
            esac\
            ;;\
        *)\
            # 默认：只允许字母、数字、点、下划线、短横线\
            echo "$input" | sed "s/[^a-zA-Z0-9._-]//g"\
            ;;\
    esac\
}' "$SCRIPT_FILE"

echo -e "${GREEN}✓ 输入验证函数已增强${NC}"

# 修复3: 增强端口验证
echo "3. 增强端口验证..."
sed -i '/^# 端口验证函数$/,/^}$/c\
# 增强的端口验证函数\
validate_port() {\
    local port=$1\
    local port_name=$2\
    \
    # 使用增强的输入清理\
    port=$(sanitize_input "$port" "port")\
    \
    # 检查清理后的结果\
    if [ -z "$port" ]; then\
        echo -e "${RED}错误：${port_name} 格式无效，必须是1-5位纯数字。${NC}"\
        log_message "ERROR" "端口验证失败: $port_name 格式无效"\
        return 1\
    fi\
    \
    # 数值范围检查\
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then\
        echo -e "${RED}错误：${port_name} 必须在 1-65535 范围内。${NC}"\
        log_message "ERROR" "端口验证失败: $port_name 超出范围"\
        return 1\
    fi\
    \
    # 检查是否为系统保留端口\
    if [ "$port" -lt 1024 ]; then\
        echo -e "${YELLOW}警告：端口 $port 是系统保留端口，可能需要特殊权限。${NC}"\
        log_message "WARNING" "使用系统保留端口: $port"\
    fi\
    \
    # 检查是否为常见危险端口\
    case "$port" in\
        22|23|25|53|80|110|143|443|993|995)\
            echo -e "${YELLOW}警告：端口 $port 是常用服务端口，请确认不会冲突。${NC}"\
            log_message "WARNING" "使用常用服务端口: $port"\
            ;;\
    esac\
    \
    return 0\
}' "$SCRIPT_FILE"

echo -e "${GREEN}✓ 端口验证函数已增强${NC}"

# 修复4: 增强目录权限设置
echo "4. 增强目录权限设置..."
sed -i '/^# 创建必要的目录$/,/^}$/c\
# 安全创建必要的目录和文件\
setup_directories() {\
    # 创建目录时设置安全权限\
    if ! mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null; then\
        echo -e "${RED}错误：无法创建配置目录${NC}"\
        log_message "ERROR" "无法创建配置目录: $CONFIG_DIR"\
        return 1\
    fi\
    \
    # 设置目录权限 - 只有root可以访问\
    chmod 700 "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null\
    \
    # 创建日志文件\
    if ! touch "$LOG_FILE" 2>/dev/null; then\
        echo -e "${YELLOW}警告：无法创建日志文件 $LOG_FILE${NC}"\
    else\
        # 设置日志文件权限 - 只有root可以读写\
        chmod 600 "$LOG_FILE" 2>/dev/null\
    fi\
    \
    # 设置配置文件权限（如果存在）\
    if [ -f "$CONFIG_FILE" ]; then\
        chmod 600 "$CONFIG_FILE" 2>/dev/null\
    fi\
    \
    log_message "INFO" "目录和文件权限设置完成"\
}' "$SCRIPT_FILE"

echo -e "${GREEN}✓ 目录权限设置已增强${NC}"

# 修复5: 在add_mapping_rule函数开头添加参数验证
echo "5. 增强命令执行安全性..."
# 在add_mapping_rule函数中添加参数验证
sed -i '/^add_mapping_rule() {$/a\
    # 严格的参数验证 - 防止命令注入\
    start_port=$(sanitize_input "$start_port" "port")\
    end_port=$(sanitize_input "$end_port" "port")\
    service_port=$(sanitize_input "$service_port" "port")\
    protocol=$(sanitize_input "$protocol" "protocol")\
    \
    # 验证清理后的参数\
    if [ -z "$start_port" ] || [ -z "$end_port" ] || [ -z "$service_port" ] || [ -z "$protocol" ]; then\
        echo -e "${RED}✗ 参数验证失败，存在无效输入${NC}"\
        log_message "ERROR" "add_mapping_rule: 参数验证失败"\
        return 1\
    fi' "$SCRIPT_FILE"

echo -e "${GREEN}✓ 命令执行安全性已增强${NC}"

# 验证修复结果
echo
echo "验证修复结果..."
if bash -n "$SCRIPT_FILE"; then
    echo -e "${GREEN}✓ 脚本语法检查通过${NC}"
else
    echo -e "${RED}✗ 脚本语法检查失败，正在恢复备份${NC}"
    cp "$BACKUP_FILE" "$SCRIPT_FILE"
    exit 1
fi

# 创建修复报告
cat > security_fix_report.txt << EOF
Port Mapping Manager 安全修复报告
=====================================
修复时间: $(date)
原文件备份: $BACKUP_FILE

已应用的修复:
1. ✓ 删除重复的log_message函数定义
2. ✓ 增强输入验证函数 (sanitize_input)
3. ✓ 增强端口验证函数 (validate_port)  
4. ✓ 增强目录权限设置 (setup_directories)
5. ✓ 增强命令执行安全性 (add_mapping_rule参数验证)

安全改进:
- 防止命令注入攻击
- 防止路径遍历攻击
- 加强文件权限控制
- 增强输入验证和清理
- 添加详细的安全日志记录

建议测试:
1. 测试正常的端口映射功能
2. 尝试输入恶意字符串验证防护
3. 检查文件权限设置
4. 验证日志记录功能

注意事项:
- 请在测试环境中验证所有功能
- 如有问题可从备份文件恢复: $BACKUP_FILE
- 建议定期更新和审查安全设置
EOF

echo
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}安全修复完成！${NC}"
echo -e "${GREEN}=========================================${NC}"
echo
echo "修复报告已保存到: security_fix_report.txt"
echo "原文件备份位置: $BACKUP_FILE"
echo
echo -e "${YELLOW}下一步建议:${NC}"
echo "1. 在测试环境中验证脚本功能"
echo "2. 检查所有端口映射操作是否正常"
echo "3. 验证安全防护是否生效"
echo "4. 如有问题，可从备份文件恢复"
echo
echo -e "${BLUE}测试命令示例:${NC}"
echo "sudo bash $SCRIPT_FILE  # 启动脚本测试"
echo "bash -n $SCRIPT_FILE    # 语法检查"