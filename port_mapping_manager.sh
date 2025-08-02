#!/bin/bash

#
# Port-Mapping-Manage v2.0
# Author: GPT-4 & Your Name
# Description: A powerful and flexible iptables port mapping management script.
#

# --- Global Variables and Default Configuration ---
SCRIPT_DIR="$(cd \"$(dirname \"$0\")\" && pwd)"

# --- Source Required Files ---
# Load configuration first, as it defines paths for other modules
if [ -f "$SCRIPT_DIR/conf/pmm.conf" ]; then
    source "$SCRIPT_DIR/conf/pmm.conf"
else
    echo "Error: Configuration file pmm.conf not found!" >&2
    exit 1
fi

# Source all function modules
for func_file in "$SCRIPT_DIR"/functions/*.sh; do
    if [ -f "$func_file" ]; then
        source "$func_file"
    else
        echo "Warning: Could not load function file: $func_file" >&2
    fi
done

# --- Script Initialization ---
initialize_script() {
    check_root
    detect_system
    setup_directories
    check_dependencies
    load_config
}

# --- Main Execution Logic ---
main() {
    # Setup trap for interruption
    trap 'echo "\nScript interrupted. Exiting."; exit 1' INT

    # Command-line argument parsing
    case "$1" in
        -h|--help)
            show_enhanced_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        --uninstall)
            uninstall_script
            exit 0
            ;;
        --no-backup)
            AUTO_BACKUP=false
            ;;
    esac

    initialize_script

    # Apply mapping rules from config file on startup
    if [[ -f "$MAPPING_CONFIG_FILE" && -s "$MAPPING_CONFIG_FILE" ]]; then
        echo "正在从配置文件应用映射规则..."
        # We just need to source it, as it contains iptables commands
        bash "$MAPPING_CONFIG_FILE"
        echo "规则应用完成。"
    fi
    
    # Enter the main interactive loop
    while true; do
        show_main_menu
        read -p "按 Enter 返回主菜单..." key
    done
}

# --- Run the main function ---
main "$@"
