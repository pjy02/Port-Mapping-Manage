#!/bin/bash

#
# Description: Functions for batch operations on mapping rules.
#

# Batch import rules from a file
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
        
        # Skip empty lines and comments
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

# Batch export rules to a file
batch_export_rules() {
    local export_file="${1:-$CONFIG_DIR/exported_rules_$(date +%Y%m%d_%H%M%S).conf}"
    
    echo "正在导出规则到: $export_file"
    
    # Write header to the file
    cat > "$export_file" << EOF
# UDP端口映射规则导出文件
# 生成时间: $(date)
# 格式: start_port:end_port:service_port
# 
EOF
    
    # Extract and write rules
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