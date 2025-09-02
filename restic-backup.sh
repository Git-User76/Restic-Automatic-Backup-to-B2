#!/usr/bin/env bash

#############################################################################
# Restic Backup Script for Backblaze B2
# 
# This script performs automated backups to Backblaze B2 using restic.
# Configuration files are expected in ~/.config/restic/
#############################################################################

set -euo pipefail

# Configuration
readonly CONFIG_DIR="$HOME/.config/restic"
readonly ENV_FILE="$CONFIG_DIR/restic.env"
readonly PASSWORD_FILE="$CONFIG_DIR/repository.password"
readonly BACKUP_PATHS_FILE="$CONFIG_DIR/backup-paths.conf"
readonly EXCLUDE_PATTERNS_FILE="$CONFIG_DIR/exclude-patterns.conf"

# Retry configuration
readonly MAX_RETRIES=3
readonly RETRY_DELAY=30

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_CONFIG_ERROR=10
readonly EXIT_PERMISSION_ERROR=11
readonly EXIT_BACKUP_ERROR=12
readonly EXIT_NETWORK_ERROR=13

# Timestamp for logging
readonly TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

#############################################################################
# Helper Functions
#############################################################################

print_header() {
    echo "============================================================"
    echo "                        $1"
    echo "============================================================"
}

print_separator() {
    echo "------------------------------------------------------------"
}

check_config_files() {
    local missing_files=()
    
    [[ ! -f "$ENV_FILE" ]] && missing_files+=("$ENV_FILE")
    [[ ! -f "$PASSWORD_FILE" ]] && missing_files+=("$PASSWORD_FILE")
    [[ ! -f "$BACKUP_PATHS_FILE" ]] && missing_files+=("$BACKUP_PATHS_FILE")
    [[ ! -f "$EXCLUDE_PATTERNS_FILE" ]] && missing_files+=("$EXCLUDE_PATTERNS_FILE")
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        print_header "BACKUP FAILED"
        echo "Timestamp:       $TIMESTAMP"
        echo "Task:            Configuration validation"
        echo "Exit Code:       $EXIT_CONFIG_ERROR"
        echo ""
        echo "------------------------- ERROR --------------------------"
        echo "Missing configuration files:"
        printf '%s\n' "${missing_files[@]}"
        echo ""
        print_separator
        exit $EXIT_CONFIG_ERROR
    fi
}

load_environment() {
    # Source environment variables
    source "$ENV_FILE"
    
    # Verify required environment variables
    local missing_vars=()
    [[ -z "${B2_ACCOUNT_ID:-}" ]] && missing_vars+=("B2_ACCOUNT_ID")
    [[ -z "${B2_ACCOUNT_KEY:-}" ]] && missing_vars+=("B2_ACCOUNT_KEY")
    [[ -z "${RESTIC_REPOSITORY:-}" ]] && missing_vars+=("RESTIC_REPOSITORY")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_header "BACKUP FAILED"
        echo "Timestamp:       $TIMESTAMP"
        echo "Task:            Environment validation"
        echo "Exit Code:       $EXIT_CONFIG_ERROR"
        echo ""
        echo "------------------------- ERROR --------------------------"
        echo "Missing environment variables in $ENV_FILE:"
        printf '%s\n' "${missing_vars[@]}"
        echo ""
        print_separator
        exit $EXIT_CONFIG_ERROR
    fi
    
    # Set password file path
    if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
    fi
}

check_backup_paths_permissions() {
    local inaccessible_paths=()
    
    while IFS= read -r path || [[ -n "$path" ]]; do
        # Skip empty lines and comments
        [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
        
        # Expand tilde if present
        path="${path/#\~/$HOME}"
        
        if [[ ! -e "$path" ]]; then
            inaccessible_paths+=("$path (does not exist)")
        elif [[ ! -r "$path" ]]; then
            inaccessible_paths+=("$path (not readable)")
        fi
    done < "$BACKUP_PATHS_FILE"
    
    if [[ ${#inaccessible_paths[@]} -gt 0 ]]; then
        print_header "BACKUP FAILED"
        echo "Timestamp:       $TIMESTAMP"
        echo "Task:            Permission check"
        echo "Exit Code:       $EXIT_PERMISSION_ERROR"
        echo ""
        echo "------------------------- ERROR --------------------------"
        echo "Inaccessible backup paths:"
        printf '%s\n' "${inaccessible_paths[@]}"
        echo ""
        print_separator
        exit $EXIT_PERMISSION_ERROR
    fi
}

run_backup_with_retry() {
    local attempt=1
    local backup_output=""
    local backup_exit_code=0
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        # Prepare backup paths array
        local backup_paths=()
        while IFS= read -r path || [[ -n "$path" ]]; do
            # Skip empty lines and comments
            [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
            # Expand tilde if present
            path="${path/#\~/$HOME}"
            backup_paths+=("$path")
        done < "$BACKUP_PATHS_FILE"
        
        # Run restic backup
        set +e
        backup_output=$(restic backup \
            --exclude-file="$EXCLUDE_PATTERNS_FILE" \
            --json \
            "${backup_paths[@]}" 2>&1)
        backup_exit_code=$?
        set -e
        
        if [[ $backup_exit_code -eq 0 ]]; then
            # Parse JSON output for statistics
            local snapshot_id=""
            local files_new=0
            local files_changed=0
            local files_unmodified=0
            local dirs_new=0
            local dirs_changed=0
            local dirs_unmodified=0
            local data_added=0
            local total_files_processed=0
            local duration=0
            
            # Extract summary from last JSON line
            if command -v jq &> /dev/null; then
                local summary=$(echo "$backup_output" | tail -n1)
                snapshot_id=$(echo "$summary" | jq -r '.snapshot_id // empty' | cut -c1-8)
                files_new=$(echo "$summary" | jq -r '.files_new // 0')
                files_changed=$(echo "$summary" | jq -r '.files_changed // 0')
                files_unmodified=$(echo "$summary" | jq -r '.files_unmodified // 0')
                dirs_new=$(echo "$summary" | jq -r '.dirs_new // 0')
                dirs_changed=$(echo "$summary" | jq -r '.dirs_changed // 0')
                dirs_unmodified=$(echo "$summary" | jq -r '.dirs_unmodified // 0')
                data_added=$(echo "$summary" | jq -r '.data_added // 0')
                total_files_processed=$(echo "$summary" | jq -r '.total_files_processed // 0')
                duration=$(echo "$summary" | jq -r '.total_duration // 0')
            else
                # Fallback: basic parsing without jq
                snapshot_id=$(echo "$backup_output" | grep -oP '"snapshot_id":"\K[^"]+' | tail -1 | cut -c1-8)
            fi
            
            # Format data sizes
            local data_added_formatted=$(numfmt --to=iec-i --suffix=B "$data_added" 2>/dev/null || echo "$data_added bytes")
            local total_processed_formatted=$(numfmt --to=iec-i --suffix=B "$total_files_processed" 2>/dev/null || echo "$total_files_processed bytes")
            
            # Format duration
            local duration_formatted=""
            if [[ -n "$duration" && "$duration" != "0" ]]; then
                local duration_int=${duration%.*}
                local minutes=$((duration_int / 60))
                local seconds=$((duration_int % 60))
                duration_formatted="${minutes} minutes ${seconds} seconds"
            else
                duration_formatted="N/A"
            fi
            
            # Print success message
            print_header "BACKUP SUCCESSFUL"
            echo "Timestamp:      $TIMESTAMP"
            echo "Repository:     $RESTIC_REPOSITORY"
            echo "Source Dirs:    ${backup_paths[*]}"
            echo ""
            echo "-------------------- Restic Summary --------------------"
            echo "Files:          $files_new new, $files_changed changed, $files_unmodified unmodified"
            echo "Dirs:           $dirs_new new, $dirs_changed changed, $dirs_unmodified unmodified"
            echo "Data Added:     $data_added_formatted"
            echo "Total Processed: $total_processed_formatted"
            echo "Duration:       $duration_formatted"
            [[ -n "$snapshot_id" ]] && echo "Snapshot ID:    $snapshot_id"
            echo ""
            print_separator
            
            return $EXIT_SUCCESS
        fi
        
        # Check if it's a network-related error
        if echo "$backup_output" | grep -qE "(network|connection|timeout|unreachable|B2|backblaze)" ; then
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                echo "Network error detected. Retrying in $RETRY_DELAY seconds... (Attempt $attempt/$MAX_RETRIES)"
                sleep $RETRY_DELAY
                ((attempt++))
                continue
            else
                print_header "BACKUP FAILED"
                echo "Timestamp:       $TIMESTAMP"
                echo "Task:            Network connection to B2"
                echo "Exit Code:       $EXIT_NETWORK_ERROR"
                echo ""
                echo "------------------------- ERROR --------------------------"
                echo "Network error after $MAX_RETRIES attempts:"
                echo "$backup_output" | head -20
                echo ""
                print_separator
                exit $EXIT_NETWORK_ERROR
            fi
        else
            # Non-network error
            print_header "BACKUP FAILED"
            echo "Timestamp:       $TIMESTAMP"
            echo "Task:            Attempting to back up to $RESTIC_REPOSITORY"
            echo "Exit Code:       $backup_exit_code"
            echo ""
            echo "------------------------- ERROR --------------------------"
            echo "$backup_output" | head -20
            echo ""
            print_separator
            exit $EXIT_BACKUP_ERROR
        fi
    done
}

#############################################################################
# Main Execution
#############################################################################

main() {
    # Validate configuration files exist
    check_config_files
    
    # Load environment variables
    load_environment
    
    # Check permissions for backup paths
    check_backup_paths_permissions
    
    # Run backup with retry logic
    run_backup_with_retry
}

# Execute main function
main "$@"