# Port Mapping Manager 安全修复报告

## 🔍 发现的高优先级安全问题

### 1. 输入验证不足
**问题**: 用户输入缺乏充分的验证和清理，存在命令注入风险
**位置**: `sanitize_input()` 函数、各种用户输入处理
**风险等级**: 高

### 2. 文件权限设置不当
**问题**: 敏感文件（配置文件、备份文件）权限过于宽松
**位置**: `setup_directories()`, `backup_rules()` 函数
**风险等级**: 高

### 3. 命令注入漏洞
**问题**: 在构建iptables命令时直接使用用户输入
**位置**: `add_mapping_rule()` 函数中的iptables命令执行
**风险等级**: 高

### 4. 批量导入安全漏洞
**问题**: 批量导入功能缺乏文件内容安全检查
**位置**: `batch_import_rules()` 函数
**风险等级**: 中高

## 🛠️ 具体修复方案

### 修复1: 增强输入验证函数

```bash
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
```

### 修复2: 安全的文件权限设置

```bash
# 安全创建必要的目录和文件
setup_directories() {
    # 创建目录时设置安全权限
    if ! mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null; then
        echo -e "${RED}错误：无法创建配置目录${NC}"
        log_message "ERROR" "无法创建配置目录: $CONFIG_DIR"
        return 1
    fi
    
    # 设置目录权限 - 只有root可以访问
    chmod 700 "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null
    
    # 创建日志文件
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}警告：无法创建日志文件 $LOG_FILE${NC}"
    else
        # 设置日志文件权限 - 只有root可以读写
        chmod 600 "$LOG_FILE" 2>/dev/null
    fi
    
    # 设置配置文件权限（如果存在）
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null
    fi
    
    log_message "INFO" "目录和文件权限设置完成"
}
```

### 修复3: 防止命令注入的安全命令执行

```bash
# 安全增强的映射规则添加函数
add_mapping_rule() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local protocol=${4:-udp}
    
    # 严格的参数验证 - 防止命令注入
    start_port=$(sanitize_input "$start_port" "port")
    end_port=$(sanitize_input "$end_port" "port")
    service_port=$(sanitize_input "$service_port" "port")
    protocol=$(sanitize_input "$protocol" "protocol")
    
    # 验证清理后的参数
    if [ -z "$start_port" ] || [ -z "$end_port" ] || [ -z "$service_port" ] || [ -z "$protocol" ]; then
        echo -e "${RED}✗ 参数验证失败，存在无效输入${NC}"
        log_message "ERROR" "add_mapping_rule: 参数验证失败"
        return 1
    fi
    
    # 构建安全的命令参数数组 - 防止命令注入
    local iptables_cmd
    iptables_cmd=$(get_iptables_cmd)
    
    local cmd_args=(
        "-t" "nat"
        "-A" "PREROUTING"
        "-p" "$protocol"
        "--dport" "$start_port:$end_port"
        "-m" "comment"
        "--comment" "$RULE_COMMENT"
        "-j" "REDIRECT"
        "--to-port" "$service_port"
    )
    
    # 安全执行命令
    if "$iptables_cmd" "${cmd_args[@]}" 2>/dev/null; then
        echo -e "${GREEN}✓ 映射规则添加成功${NC}"
        log_message "INFO" "添加规则成功: ${protocol^^} ${start_port}-${end_port} -> ${service_port}"
    else
        local exit_code=$?
        echo -e "${RED}✗ 添加规则失败${NC}"
        log_message "ERROR" "添加规则失败"
        return $exit_code
    fi
}
```

### 修复4: 安全的批量导入功能

```bash
# 安全的批量导入规则函数
batch_import_rules() {
    echo -e "${BLUE}批量导入规则${NC}"
    echo -n "文件路径: "
    read -r config_file_input
    
    # 安全清理文件路径
    local config_file
    config_file=$(sanitize_input "$config_file_input" "path")
    
    if [ -z "$config_file" ]; then
        echo -e "${RED}无效的文件路径${NC}"
        return 1
    fi
    
    # 验证文件存在性和可读性
    if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
        echo -e "${RED}文件不存在或不可读: $config_file${NC}"
        return 1
    fi
    
    # 检查文件大小（防止过大文件攻击）
    local file_size
    file_size=$(stat -c%s "$config_file" 2>/dev/null)
    if [ -n "$file_size" ] && [ "$file_size" -gt 1048576 ]; then  # 1MB限制
        echo -e "${RED}文件过大 (>1MB)，拒绝处理${NC}"
        return 1
    fi
    
    # 检查文件内容安全性
    if grep -q '[;&|`$(){}[\]\\]' "$config_file"; then
        echo -e "${RED}文件包含危险字符，拒绝处理${NC}"
        return 1
    fi
    
    # 安全处理文件内容...
}
```

## 🔒 额外安全建议

### 1. 日志安全
- 防止日志注入攻击
- 限制日志文件大小
- 定期轮转日志文件

### 2. 权限最小化
- 所有配置文件设置为600权限
- 备份目录设置为700权限
- 临时文件使用安全的临时目录

### 3. 输入长度限制
- 限制所有用户输入的最大长度
- 防止缓冲区溢出攻击

### 4. 错误处理
- 统一的错误处理机制
- 避免在错误信息中泄露敏感信息

## 📋 修复优先级

1. **立即修复** (高危)
   - 命令注入漏洞
   - 输入验证不足

2. **尽快修复** (中高危)
   - 文件权限问题
   - 批量导入安全漏洞

3. **计划修复** (中危)
   - 日志安全改进
   - 错误处理统一

## 🧪 测试建议

1. **安全测试**
   - 尝试输入恶意字符串
   - 测试路径遍历攻击
   - 验证文件权限设置

2. **功能测试**
   - 确保修复后功能正常
   - 测试各种边界条件
   - 验证错误处理机制

3. **性能测试**
   - 确保安全修复不影响性能
   - 测试大量规则处理能力

## 📝 修复记录

- [ ] 输入验证函数增强
- [ ] 文件权限安全设置
- [ ] 命令注入漏洞修复
- [ ] 批量导入安全加固
- [ ] 统一错误处理机制
- [ ] 日志安全改进

---

**注意**: 在应用这些修复之前，请务必备份原始脚本文件，并在测试环境中验证所有功能正常工作。