#!/bin/bash
#
# Port Mapping Manager (PMM) - Modular Version
# Version: 4.0
# Author: Your Name/Organization
# License: MIT
#
# This is the main entry point for the script. It sources library files
# and runs the main application loop.

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

# Initializes the script environment.
initialize_script() {
    check_root
    setup_directories
    log_message "INFO" "--- PMM v$SCRIPT_VERSION Started ---"
    check_dependencies
    load_config
    interactive_backup_cleanup
}

# Main loop to display menu and handle user input.
main_loop() {
    while true; do
        show_main_menu
        case $choice in
            1) show_current_rules ;; 
            2) setup_mapping ;; 
            3) toggle_rule_menu ;; # New option
            4) delete_specific_rule ;; 
            5) backup_menu_handler ;; 
            6) batch_menu_handler ;; 
            7) diagnose_system ;; 
            8) uninstall_script ; exit 0 ;; # Exit after uninstall
            h|H) show_enhanced_help ;; 
            q|Q) echo "Exiting."; log_message "INFO" "--- PMM Session Ended ---"; break ;; 
            *) echo -e "${C_RED}Invalid option. Please try again.${C_RESET}" ;; 
        esac
    done
}

# Handler for the backup submenu.
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
            *) echo -e "${C_RED}Invalid option.${C_RESET}" ;; 
        esac
    done
}

# Handler for the batch operations submenu.
batch_menu_handler() {
    while true; do
        show_batch_menu
        case $batch_choice in
            1) bulk_import_from_file ;; 
            # 2) bulk_export_to_file ;; # This function needs to be implemented in lib_core
            b|B) break ;; 
            *) echo -e "${C_RED}Invalid option.${C_RESET}" ;; 
        esac
    done
}


# --- Main Entry Point ---
main() {
    # Handle command-line arguments
    if [ "$#" -gt 0 ]; then
        case "$1" in
            --help|-h) show_enhanced_help ;; 
            --version|-v) show_version ;; 
            --list|-l) show_current_rules ;; 
            --diagnose|-d) diagnose_system ;; 
            *) echo -e "${C_RED}Unknown argument: $1. Use -h for help.${C_RESET}" ;; 
        esac
        exit 0
    fi

    initialize_script
    main_loop
}

# Run the main function
main "$@"
