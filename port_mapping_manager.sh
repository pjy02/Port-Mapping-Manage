#!/bin/bash
#
# 端口映射管理器 (PMM) - 模块化版本
# 版本: 4.0
# 作者: Your Name/Organization
# 许可证: MIT
#
# 这是脚本的主入口点。它加载库文件并运行主应用程序循环。

# --- Global Variables ---
readonly SCRIPT_VERSION="4.0"
readonly SCRIPT_NAME="Port Mapping Manager"
CONFIG_DIR="/etc/port_mapping_manager"
CONFIG_FILE="$CONFIG_DIR/port_mapping_manager.conf"
BACKUP_DIR="$CONFIG_DIR/backups"
LOG_DIR="/var/log/port_mapping_manager"
LOG_FILE="$LOG_DIR/port_mapping_manager.log"
LIBS_DIR="$(dirname "$0")/libs"

# --- Source Library Files ---
source "$LIBS_DIR/lib_utils.sh"
source "$LIBS_DIR/lib_iptables.sh"
source "$LIBS_DIR/lib_ui.sh"
source "$LIBS_DIR/lib_core.sh"

# --- Main Application Logic ---

# 初始化脚本环境。
initialize_script() {
    check_root
    setup_directories
    log_message "INFO" "--- PMM v$SCRIPT_VERSION 已启动 ---"
    check_dependencies
    load_config
    interactive_backup_cleanup
}

# 主循环，用于显示菜单和处理用户输入。
main_loop() {
    while true; do
        show_main_menu
        case $choice in
            1) show_current_rules ;; 
            2) setup_mapping ;; 
            3) toggle_rule_menu ;; # 新选项
            4) delete_specific_rule ;; 
            5) backup_menu_handler ;; 
            6) batch_menu_handler ;; 
            7) diagnose_system ;; 
            8) uninstall_script ; exit 0 ;; # 卸载后退出
            h|H) show_enhanced_help ;; 
            q|Q) echo "正在退出."; log_message "INFO" "--- PMM 会话结束 ---"; break ;; 
            *) echo -e "${C_RED}无效选项。请再试一次。${C_RESET}" ;; 
        esac
    done
}

# 备份子菜单的处理程序。
backup_menu_handler() {
    while true; do
        show_backup_menu
        case $backup_choice in
            1) backup_rules ;; 
            2) list_backups ;; 
            3) restore_rules_from_backup ;; 
            4) clean_old_backups ;; 
            5) full_reset_iptables ;; 
            b|B) break ;; 
            *) echo -e "${C_RED}无效选项。${C_RESET}" ;; 
        esac
    done
}

# 批量操作子菜单的处理程序。
batch_menu_handler() {
    while true; do
        show_batch_menu
        case $batch_choice in
            1) bulk_import_from_file ;; 
            # 2) bulk_export_to_file ;; # 此功能需要在 lib_core 中实现
            b|B) break ;; 
            *) echo -e "${C_RED}无效选项。${C_RESET}" ;; 
        esac
    done
}


# --- 主入口点 ---
main() {
    # 处理命令行参数
    if [ "$#" -gt 0 ]; then
        case "$1" in
            --help|-h) show_enhanced_help ;; 
            --version|-v) show_version ;; 
            --list|-l) show_current_rules ;; 
            --diagnose|-d) diagnose_system ;; 
            *) echo -e "${C_RED}未知参数: $1. 使用 -h 获取帮助。${C_RESET}" ;; 
        esac
        exit 0
    fi

    initialize_script
    main_loop
}

# 运行主函数
main "$@"
