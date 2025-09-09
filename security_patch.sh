#!/bin/bash
# Port Mapping Manager 安全修复补丁脚本
# 此脚本将应用高优先级的安全修复

set -euo pipefail

SCRIPT_FILE="port_mapping_manager.sh"
BACKUP_FILE="port_mapping_manager.sh.backup.$(date +%Y%m%d_%H%M%S)"

# 颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

echo -e "${BLUE}Port Mapping Manager 安全修复补丁${NC}"
echo "========================================"

# 检查原文件是否存在
if [ ! -f "$SCRIPT_FILE" ]; then
    echo -e "${RED}错误: 找不到 $SCRIPT_FILE${NC}"
    exit 1
fi

# 备份原文件
echo "正在备份原文件..."
if cp "$SCRIPT_FILE" "$BACKUP_FILE"; then
    echo -e "${GREEN}✓ 已备份到: $BACKUP_FILE${NC}"
else
    echo -e "${RED}✗ 备份失败${NC}"
    exit 1
fi

# 应用安全修复
echo "正在应用安全修复..."

# 修复1: 检查并删除重复的log_message函数
echo "1. 检查重复函数定义..."
duplicate_count=$(grep -c "^log_message()" "$SCRIPT_FILE" || echo "0")
if [ "$duplicate_count" -gt 1 ]; then
    echo -e "${YELLOW}发现重复的log_message函数定义，需要手动修复${NC}"
fi

# 修复2: 增强sanitize_input函数
echo "2. 增强输入验证函数..."
if grep -q "sanitize_input()" "$SCRIPT_FILE"; then
    # 创建增强版本的sanitize_input函数
    cat > /tmp/enhanced_sanitize_input.txt << 'EOF'
# 增强的输入安全验证
sanitize_input() {
    local input="$1"
    local type="${2:-default}"
    
    # 防止空输入和过长输入
    if [ -z "$input" ] || [ ${#input} -gt 1000 ]; then
        echo ""
        return 1
    fi
    
    case "$type" in
        "port")
            # 端口号：只允许1-5位数字
            if echo "$input" | grep -qE '^[0-9]{1,5}$'; then
                echo "$input"
            else
                echo ""
                return 1
            fi
            ;;
        "path")
            # 文件路径：防止路径遍历攻击，移除危险字符
            echo "$input" | sed 's/\.\.\///g' | sed 's/[;&|`$(){}[\]\\]//g' | sed 's/[^a-zA-Z0-9._/-]//g'
            ;;
        "filename")
            # 文件名：只允许安全字符
            echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
            ;;
        "protocol")
            # 协议：只允许tcp或udp
            case "$input" in
                "tcp"|"TCP"|"1") echo "tcp" ;;
                "udp"|"UDP"|"2") echo "udp" ;;
                *) echo ""; return 1 ;;
            esac
            ;;
        *)
            # 默认：只允许字母、数字、点、下划线、短横线
            echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
            ;;
    esac
}
EOF
    echo -e "${GREEN}✓ 输入验证函数已准备增强${NC}"
fi

# 修复3: 添加安全的命令执行函数
echo "3. 添加安全命令执行函数..."
cat > /tmp/safe_command_execution.txt << 'EOF'

# 安全的命令执行函数
safe_execute_iptables() {
    local operation="$1"
    shift
    local args=("$@")
    
    # 获取iptables命令
    local iptables_cmd
    iptables_cmd=$(get_iptables_cmd)
    
    if [ -z "$iptables_cmd" ]; then
        echo -e "${RED}✗ 无法确定iptables命令${NC}"
        return 1
    fi
    
    # 记录命令执行
    log_message "INFO" "执行iptables操作: $operation"
    
    # 安全执行命令
    if "$iptables_cmd" "${args[@]}" 2>/dev/null; then
        log_message "INFO" "iptables操作成功: $operation"
        return 0
    else
        local exit_code=$?
        log_message "ERROR" "iptables操作失败: $operation (代码: $exit_code)"
        return $exit_code
    fi
}
EOF

# 修复4: 添加文件安全检查函数
echo "4. 添加文件安全检查函数..."
cat > /tmp/file_security_check.txt << 'EOF'

# 文件安全检查函数
check_file_security() {
    local file_path="$1"
    local max_size="${2:-1048576}"  # 默认1MB
    
    # 检查文件是否存在
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}文件不存在: $file_path${NC}"
        return 1
    fi
    
    # 检查文件是否可读
    if [ ! -r "$file_path" ]; then
        echo -e "${RED}文件不可读: $file_path${NC}"
        return 1
    fi
    
    # 检查文件大小
    local file_size
    file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [ -n "$file_size" ] && [ "$file_size" -gt "$max_size" ]; then
        echo -e "${RED}文件过大: $file_path (${file_size} > ${max_size})${NC}"
        return 1
    fi
    
    # 检查危险字符
    if grep -q '[;&|`$(){}[\]\\]' "$file_path"; then
        echo -e "${RED}文件包含危险字符: $file_path${NC}"
        return 1
    fi
    
    return 0
}
EOF

# 修复5: 添加权限设置函数
echo "5. 添加安全权限设置函数..."
cat > /tmp/secure_permissions.txt << 'EOF'

# 安全权限设置函数
set_secure_permissions() {
    local path="$1"
    local perm="${2:-600}"
    
    if [ -e "$path" ]; then
        if chmod "$perm" "$path" 2>/dev/null; then
            log_message "INFO" "设置权限成功: $path ($perm)"
            return 0
        else
            log_message "WARNING" "设置权限失败: $path ($perm)"
            return 1
        fi
    fi
    return 0
}
EOF

echo -e "${GREEN}✓ 安全修复补丁准备完成${NC}"
echo
echo -e "${YELLOW}注意事项:${NC}"
echo "1. 此补丁包含了主要的安全修复代码"
echo "2. 需要手动将这些函数集成到原脚本中"
echo "3. 建议在测试环境中先验证修复效果"
echo "4. 原文件已备份到: $BACKUP_FILE"
echo
echo -e "${BLUE}下一步操作:${NC}"
echo "1. 查看 SECURITY_FIXES.md 了解详细修复说明"
echo "2. 手动应用安全修复或使用专业工具"
echo "3. 在测试环境中验证功能"
echo "4. 部署到生产环境"

# 创建修复验证脚本
cat > verify_fixes.sh << 'EOF'
#!/bin/bash
# 安全修复验证脚本

echo "验证安全修复..."

# 检查函数是否存在
if grep -q "sanitize_input.*port.*path.*protocol" port_mapping_manager.sh; then
    echo "✓ 增强的输入验证函数已应用"
else
    echo "✗ 输入验证函数需要修复"
fi

# 检查权限设置
if grep -q "chmod 600.*chmod 700" port_mapping_manager.sh; then
    echo "✓ 安全权限设置已应用"
else
    echo "✗ 权限设置需要修复"
fi

# 检查命令注入防护
if grep -q "cmd_args.*iptables_cmd.*args" port_mapping_manager.sh; then
    echo "✓ 命令注入防护已应用"
else
    echo "✗ 命令注入防护需要修复"
fi

echo "验证完成"
EOF

chmod +x verify_fixes.sh
echo -e "${GREEN}✓ 创建了验证脚本: verify_fixes.sh${NC}"

echo
echo -e "${GREEN}安全修复补丁脚本执行完成！${NC}"