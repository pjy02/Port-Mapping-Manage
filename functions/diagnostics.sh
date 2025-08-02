#!/bin/bash

#
# Description: Functions for system diagnostics and traffic monitoring.
#

# Comprehensive system diagnosis
diagnose_system() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}           系统诊断报告              ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    
    # 1. System Info
    echo -e "${CYAN}1. 系统信息:${NC}"
    echo "   - 主机名: $(hostname)"
    echo "   - 操作系统: $(lsb_release -d -s)"
    echo "   - 内核版本: $(uname -r)"
    echo "   - 当前用户: $(whoami)"
    echo
    
    # 2. Dependency Check
    echo -e "${CYAN}2. 依赖检查:${NC}"
    check_dependencies true
    echo
    
    # 3. Kernel Modules
    echo -e "${CYAN}3. 内核模块检查:${NC}"
    if lsmod | grep -q 'ip_tables'; then echo -e "   - ${GREEN}ip_tables: 已加载${NC}"; else echo -e "   - ${RED}ip_tables: 未加载${NC}"; fi
    if lsmod | grep -q 'nf_nat'; then echo -e "   - ${GREEN}nf_nat: 已加载${NC}"; else echo -e "   - ${RED}nf_nat: 未加载${NC}"; fi
    if lsmod | grep -q 'nf_conntrack'; then echo -e "   - ${GREEN}nf_conntrack: 已加载${NC}"; else echo -e "   - ${RED}nf_conntrack: 未加载${NC}"; fi
    echo
    
    # 4. Port Listening Status
    echo -e "${CYAN}4. 端口监听状态 (UDP):${NC}"
    ss -ulnp | head -n 10
    echo
    
    # 5. Firewall Status
    echo -e "${CYAN}5. 防火墙状态 (iptables):${NC}"
    iptables -L -n -v | head -n 15
    echo
    
    # 6. Rule Statistics
    echo -e "${CYAN}6. 规则统计:${NC}"
    show_traffic_stats
    echo
    
    # 7. Performance & Suggestions
    echo -e "${CYAN}7. 性能与建议:${NC}"
    if [ $(sysctl net.core.rmem_max) -lt 26214400 ]; then
        echo -e "   - ${YELLOW}建议调高UDP缓冲区大小以提升性能: sysctl -w net.core.rmem_max=26214400${NC}"
    else
        echo -e "   - ${GREEN}UDP缓冲区配置良好${NC}"
    fi
    
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${GREEN}诊断完成${NC}"
}

# Real-time traffic monitoring
monitor_traffic() {
    echo -e "${BLUE}实时流量监控 (按 Ctrl+C 退出)${NC}"
    echo "时间               总包数   总流量    速率(包/秒)  速率(字节/秒)"
    echo "------------------------------------------------------------------"

    local last_packets=0 last_bytes=0 last_time=$(date +%s)

    trap 'echo "\n监控已停止"; trap - INT; return' INT

    while true; do
        local current_packets=0 current_bytes=0
        
        # Use a more robust way to parse iptables output
        while read -r pkts bytes _; do
            current_packets=$((current_packets + pkts))
            current_bytes=$((current_bytes + bytes))
        done < <(iptables -t nat -L PREROUTING -v -n | grep "$RULE_COMMENT" | awk '{print $1, $2}')

        local current_time=$(date +%s)
        local time_diff=$((current_time - last_time))
        
        if [ $time_diff -gt 0 ]; then
            local packet_rate=$(((current_packets - last_packets) / time_diff))
            local byte_rate=$(((current_bytes - last_bytes) / time_diff))
        else
            local packet_rate=0
            local byte_rate=0
        fi
        
        printf "%-20s %-8s %-10s %-12s %-15s\r" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \ 
            "$current_packets" \ 
            "$(format_bytes $current_bytes)" \ 
            "$packet_rate" \ 
            "$(format_bytes $byte_rate)"

        last_packets=$current_packets
        last_bytes=$current_bytes
        last_time=$current_time
        
        sleep 1
    done
}