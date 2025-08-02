#!/bin/bash

#
# Description: Functions for displaying menus and user interface elements.
#

# Enhanced help display
show_enhanced_help() {
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}        Port-Mapping-Manage v${VERSION} - 帮助文档      ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "一个强大而灵活的iptables端口映射管理脚本\n"
    
    echo -e "${CYAN}主要特性:${NC}"
    echo "  - TCP/UDP端口范围映射"
    echo "  - 交互式菜单和命令行模式"
    echo "  - 规则持久化与自动备份"
    echo "  - 批量导入/导出规则"
    echo "  - 实时流量监控与系统诊断"
    echo "  - 增强的错误处理和日志记录\n"

    echo -e "${CYAN}使用示例:${NC}"
    echo "  - ${GREEN}./pmm${NC}: 启动交互式菜单"
    echo "  - ${GREEN}./pmm -v${NC}: 显示版本信息"
    echo "  - ${GREEN}./pmm -h${NC}: 显示此帮助信息"
    echo "  - ${GREEN}./pmm --uninstall${NC}: 卸载脚本\n"

    echo -e "${CYAN}配置文件位置:${NC}"
    echo "  - 主配置文件: ${CONFIG_FILE}"
    echo "  - 日志文件:   ${LOG_FILE}"
    echo "  - 备份目录:   ${BACKUP_DIR}"
}

# Show script version
show_version() {
    echo "Port-Mapping-Manage v${VERSION}"
    echo "作者: GPT-4"
    echo "更新日志:"
    echo " - 2024-07-15: 重构代码，模块化，增强功能"
    echo " - 2024-07-14: 初始版本"
}

# Main interactive menu
show_main_menu() {
    clear
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}        端口映射管理器 v${VERSION}             ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo "1. 设置端口映射 (交互式/预设)"
    echo "2. 查看当前规则与流量"
    echo "3. 编辑现有规则"
    echo "4. 系统诊断"
    echo "5. 批量操作 (导入/导出)"
    echo "6. 备份管理"
    echo "7. 实时流量监控"
    echo "8. 恢复/重置iptables"
    echo "9. 显示帮助"
    echo "10. 退出"
    echo -e "${BLUE}============================================${NC}"
    read -p "请输入选项 [1-10]: " choice
    
    case $choice in
        1) show_port_presets ;; 
        2) show_current_rules ;; 
        3) edit_rules ;; 
        4) diagnose_system ;; 
        5) show_batch_menu ;; 
        6) show_backup_menu ;; 
        7) monitor_traffic ;; 
        8) restore_defaults ;; 
        9) show_enhanced_help ;; 
        10) exit 0 ;; 
        *) echo -e "${RED}无效的选项${NC}" ;; 
    esac
}

# Batch operations menu
show_batch_menu() {
    echo -e "\n${BLUE}批量操作菜单:${NC}"
    echo "1. 从文件导入规则"
    echo "2. 导出当前规则到文件"
    echo "3. 生成示例配置文件"
    echo "4. 返回主菜单"
    read -p "请选择操作 [1-4]: " batch_choice

    case $batch_choice in
        1) batch_import_rules ;; 
        2) batch_export_rules ;; 
        3) create_sample_config ;; 
        4) return ;; 
        *) echo -e "${RED}无效选择${NC}" ;; 
    esac
}

# Create a sample config file for batch import
create_sample_config() {
    local sample_file="./sample_rules.conf"
    cat > "$sample_file" << EOF
# 示例规则配置文件
# 格式: start_port:end_port:service_port
# 注释行以 '#' 开头

6000:7000:3000
8000:9000:4000
EOF
    echo -e "${GREEN}✓ 示例配置文件已生成: ${sample_file}${NC}"
}

# Backup management menu
show_backup_menu() {
    echo -e "\n${BLUE}备份管理菜单:${NC}"
    echo "1. 创建手动备份"
    echo "2. 列出现有备份"
    echo "3. 从备份恢复"
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

# List existing backup files
list_backups() {
    echo -e "${BLUE}可用备份列表:${NC}"
    if [ -z "$(ls -A $BACKUP_DIR)" ]; then
        echo "未找到备份文件。"
        return
    fi
    
    ls -lh "$BACKUP_DIR" | awk '{print $9, $5, $6, $7, $8}'
}