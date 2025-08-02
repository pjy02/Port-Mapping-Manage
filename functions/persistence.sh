#!/bin/bash

#
# Description: Functions for handling iptables rules persistence.
#

# Check for persistent package and determine the method
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

# Create a systemd service for rule persistence
create_systemd_service() {
    local service_file="/etc/systemd/system/udp-port-mapping.service"
    
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

# Show instructions for manual rule persistence
show_manual_save_instructions() {
    echo -e "${BLUE}手动持久化规则说明：${NC}"
    echo "1. 将当前规则保存到文件:"
    echo "   iptables-save > /etc/iptables/rules.v4"
    echo "2. 添加到系统启动脚本:"
    echo "   echo 'iptables-restore < /etc/iptables/rules.v4' >> /etc/rc.local"
    echo "3. 或使用crontab在重启时恢复:"
    echo "   echo '@reboot iptables-restore < /etc/iptables/rules.v4' | crontab -"
}

# Enhanced rule saving function
save_rules() {
    echo "正在保存iptables规则..."
    
    case $PERSISTENT_METHOD in
        "netfilter-persistent")
            if netfilter-persistent save; then
                echo -e "${GREEN}✓ 规则已通过netfilter-persistent永久保存${NC}"
                log_message "INFO" "规则永久保存成功"
                return 0
            fi
            ;;
        "service")
            if service iptables save 2>/dev/null; then
                echo -e "${GREEN}✓ 规则已通过service命令永久保存${NC}"
                log_message "INFO" "规则永久保存成功"
                return 0
            fi
            ;;
        "systemd")
            local rules_file="$CONFIG_DIR/current.rules"
            if iptables-save > "$rules_file"; then
                echo -e "${GREEN}✓ 规则已保存到 $rules_file${NC}"
                log_message "INFO" "规则保存到文件: $rules_file"
                return 0
            fi
            ;;
    esac
    
    echo -e "${RED}✗ 规则保存失败${NC}"
    log_message "ERROR" "规则保存失败"
    show_manual_save_instructions
    return 1
}