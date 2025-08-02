#!/bin/bash

#
# Description: Core functions for managing port mapping rules.
#

# Show current mapping rules with enhanced details
show_current_rules() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}      当前映射规则 (Enhanced View)${NC}"
    echo -e "${BLUE}=========================================${NC}"
    
    local rules=$(iptables -t nat -L PREROUTING -n --line-numbers)
    
    if [ -z "$rules" ]; then
        echo -e "${YELLOW}未找到由本脚本创建的映射规则。${NC}"
        return
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
    echo -e "${GREEN}共 $rule_count 条规则 | 🟢=活跃 🔴=非活跃${NC}"
    
    show_traffic_stats
}

# Check if a rule is active by checking if the service port is listening
check_rule_active() {
    local port_range=$1
    local service_port=$2
    
    if ss -ulnp | grep -q ":$service_port "; then
        return 0
    fi
    return 1
}

# Show traffic statistics for script-created rules
show_traffic_stats() {
    echo -e "\n${CYAN}流量统计概览：${NC}"
    local total_packets=0
    local total_bytes=0
    
    while read -r line; do
        if echo "$line" | grep -q "$RULE_COMMENT"; then
            local packets=$(echo "$line" | awk '{print $1}' | tr -d '[]')
            local bytes=$(echo "$line" | awk '{print $2}' | tr -d '[]')
            if [[ "$packets" =~ ^[0-9]+$ ]] && [[ "$bytes" =~ ^[0-9]+$ ]]; then
                total_packets=$((total_packets + packets))
                total_bytes=$((total_bytes + bytes))
            fi
        fi
    done < <(iptables -t nat -L PREROUTING -v -n)
    
    echo "总数据包: $total_packets"
    echo "总字节数: $(format_bytes $total_bytes)"
}

# Format bytes into a human-readable format (KB, MB, GB)
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

# Show port presets for quick setup
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

# Setup mapping with a preset configuration
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

# Enhanced interactive mapping setup
setup_mapping() {
    local start_port end_port service_port protocol

    while true; do
        echo -e "${BLUE}请输入端口映射配置：${NC}"
        read -p "连接端口（起始）: " start_port
        read -p "连接端口（终止）: " end_port
        read -p "服务端口: " service_port
        read -p "协议 (1=TCP, 2=UDP): " protocol
        case "$protocol" in
            1|tcp|TCP) protocol="tcp" ;;
            2|udp|UDP) protocol="udp" ;;
            *) echo -e "${RED}错误：请输入 1(=TCP) 或 2(=UDP)${NC}"; continue ;;
        esac

        if ! validate_port "$start_port" "起始端口" || \
           ! validate_port "$end_port" "终止端口" || \
           ! validate_port "$service_port" "服务端口"; then
            continue
        fi

        if [ "$start_port" -gt "$end_port" ]; then
            echo -e "${RED}错误：起始端口不能大于终止端口。${NC}"
            continue
        fi

        if [ "$service_port" -ge "$start_port" ] && [ "$service_port" -le "$end_port" ]; then
            echo -e "${RED}错误：服务端口不能在连接端口范围内！${NC}"
            continue
        fi

        check_port_in_use "$service_port" true
        
        if ! check_port_conflicts "$start_port" "$end_port" "$service_port"; then
            read -p "发现端口冲突，是否继续? (y/n): " continue_choice
            if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
                continue
            fi
        fi

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

# Core function to add a mapping rule
add_mapping_rule() {
    local start_port=$1
    local end_port=$2
    local service_port=$3
    local protocol=${4:-udp}
    
    if [ "$AUTO_BACKUP" = true ]; then
        echo "正在备份当前规则..."
        backup_rules
    fi

    echo "正在添加端口映射规则..."
    
    if iptables -t nat -A PREROUTING -p $protocol --dport "$start_port:$end_port" \
       -m comment --comment "$RULE_COMMENT" \
       -j REDIRECT --to-port "$service_port" 2>/dev/null; then
        
        echo -e "${GREEN}✓ 映射规则添加成功: ${protocol^^} ${start_port}-${end_port} -> ${service_port}${NC}"
        log_message "INFO" "添加规则: ${protocol^^} ${start_port}-${end_port} -> ${service_port}"
        
        save_mapping_config # Save the new rule to the config file
        
        show_current_rules
        
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