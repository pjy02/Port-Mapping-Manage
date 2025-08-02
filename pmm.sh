#!/bin/bash

# Main script for Port Mapping Manager

# --- Initialization ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all modules
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/utils.sh"
source "$SCRIPT_DIR/modules/core.sh"
source "$SCRIPT_DIR/modules/ui.sh"

# --- Main Logic ---

# Initialize the script environment
initialize_script() {
    setup_directories
    load_config
    check_root
    detect_system
    check_dependencies
    check_persistent_package
}

# Main loop for interactive menu
main_loop() {
    while true; do
        show_main_menu
        read -p "Enter your choice [0-10]: " choice
        case $choice in
            1) setup_mapping ;; # Add New Mapping
            2) delete_specific_rule ;; # Delete Mapping
            3) show_current_rules ;; # View Mappings
            4) show_traffic_stats_menu ;; # View Traffic Stats
            5) show_batch_menu ;; # Batch Operations
            6) show_backup_menu ;; # Backup and Restore
            7) diagnose_system ;; # Run Diagnostics
            8) monitor_traffic ;; # Live Traffic Monitor
            9) uninstall_script ;; # Uninstall
            10) show_enhanced_help ;; # Help
            0) echo -e "${GREEN}Exiting...${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid option. Please try again.${NC}" ;;
        esac
        echo -e "\n${YELLOW}Press [Enter] to continue...${NC}"
        read -n 1
    done
}

# Main function to handle command-line arguments
main() {
    initialize_script

    if [ "$#" -gt 0 ]; then
        case "$1" in
            --add) add_mapping_rule "$2" "$3" "$4" ;;
            --delete) delete_specific_rule "$2" ;;
            --list) show_current_rules ;;
            --backup) backup_rules ;;
            --restore) restore_from_backup "$2" ;;
            --help) show_enhanced_help ;;
            --version) show_version ;;
            *)
                echo -e "${RED}Invalid command-line argument: $1${NC}"
                show_enhanced_help
                ;;
        esac
    else
        main_loop
    fi
}

# --- Script Entry Point ---
trap 'echo -e "\n${RED}An unexpected error occurred. Exiting.${NC}"; exit 1' ERR
main "$@"
