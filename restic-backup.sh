#!/usr/bin/env bash

#############################################################################
# Restic Backup Script for Backblaze B2
# Performs automated backups using restic with retry logic and validation
#############################################################################

set -euo pipefail

# Configuration paths
readonly CONFIG_DIR="${HOME}/.config/restic"
readonly ENV_FILE="${CONFIG_DIR}/config.env"
readonly PASSWORD_FILE="${CONFIG_DIR}/repository.password"
readonly BACKUP_PATHS_FILE="${CONFIG_DIR}/backup-paths.conf"
readonly EXCLUDE_FILE="${CONFIG_DIR}/exclude-patterns.conf"

# Retry settings
readonly MAX_RETRIES=3
readonly RETRY_DELAY=30

# Exit codes
readonly EXIT_CONFIG_ERROR=10
readonly EXIT_PERMISSION_ERROR=11
readonly EXIT_BACKUP_ERROR=12
readonly EXIT_NETWORK_ERROR=13

# Get timestamp
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Formatting functions
print_header() {
    echo "============================================="
    echo "               $1"
    echo "============================================="
}

print_separator() {
    echo "---------------------------------------------"
}

# Error handler with formatted output
exit_with_error() {
    local task="$1"
    local exit_code="$2"
    local error_msg="$3"
    
    print_header "BACKUP FAILED"
    echo "Timestamp:       ${TIMESTAMP}"
    echo "Task:            ${task}"
    echo "Exit Code:       ${exit_code}"
    echo ""
    echo "---------------- ERROR ----------------------"
    echo "${error_msg}"
    echo ""
    print_separator
    exit "${exit_code}"
}

# Validate configuration files exist
validate_config_files() {
    local missing=()
    
    [[ -f "${ENV_FILE}" ]] || missing+=("${ENV_FILE}")
    [[ -f "${PASSWORD_FILE}" ]] || missing+=("${PASSWORD_FILE}")
    [[ -f "${BACKUP_PATHS_FILE}" ]] || missing+=("${BACKUP_PATHS_FILE}")
    [[ -f "${EXCLUDE_FILE}" ]] || missing+=("${EXCLUDE_FILE}")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        local error_msg="Missing configuration files:"$'\n'
        printf -v error_msg "%s%s\n" "${error_msg}" "$(printf '%s\n' "${missing[@]}")"
        exit_with_error "Configuration validation" "${EXIT_CONFIG_ERROR}" "${error_msg}"
    fi
    
    # Verify password file permissions
    local perms=$(stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null || echo "000")
    if [[ ${perms} -gt 600 ]]; then
        local error_msg="Password file has insecure permissions: ${perms}"$'\n'
        error_msg+="Run: chmod 600 ${PASSWORD_FILE}"
        exit_with_error "Configuration validation" "${EXIT_CONFIG_ERROR}" "${error_msg}"
    fi
}

# Load and validate environment variables
load_environment() {
    # Source environment file
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    
    # Validate required variables
    local missing=()
    [[ -z "${B2_ACCOUNT_ID:-}" ]] && missing+=("B2_ACCOUNT_ID")
    [[ -z "${B2_ACCOUNT_KEY:-}" ]] && missing+=("B2_ACCOUNT_KEY")
    [[ -z "${RESTIC_REPOSITORY:-}" ]] && missing+=("RESTIC_REPOSITORY")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        local error_msg="Missing environment variables in ${ENV_FILE}:"$'\n'
        printf -v error_msg "%s%s" "${error_msg}" "$(printf '%s\n' "${missing[@]}")"
        exit_with_error "Environment validation" "${EXIT_CONFIG_ERROR}" "${error_msg}"
    fi
    
    # Set password file if RESTIC_PASSWORD not already set
    [[ -z "${RESTIC_PASSWORD:-}" ]] && export RESTIC_PASSWORD_FILE="${PASSWORD_FILE}"
    
    # Export B2 credentials for restic
    export B2_ACCOUNT_ID
    export B2_ACCOUNT_KEY
    export RESTIC_REPOSITORY
}

# Check backup paths are accessible
validate_backup_paths() {
    local inaccessible=()
    
    while IFS= read -r path || [[ -n "${path}" ]]; do
        [[ -z "${path}" || "${path}" =~ ^[[:space:]]*# ]] && continue
        path="${path/#\~/${HOME}}"
        
        if [[ ! -e "${path}" ]]; then
            inaccessible+=("${path} (not found)")
        elif [[ ! -r "${path}" ]]; then
            inaccessible+=("${path} (not readable)")
        fi
    done < "${BACKUP_PATHS_FILE}"
    
    if [[ ${#inaccessible[@]} -gt 0 ]]; then
        local error_msg="Inaccessible backup paths:"$'\n'
        printf -v error_msg "%s%s" "${error_msg}" "$(printf '%s\n' "${inaccessible[@]}")"
        exit_with_error "Permission check" "${EXIT_PERMISSION_ERROR}" "${error_msg}"
    fi
}

# Execute backup with retry logic
execute_backup() {
    local attempt=1
    local output
    local exit_code
    
    # Build backup paths array
    local paths=()
    while IFS= read -r path || [[ -n "${path}" ]]; do
        [[ -z "${path}" || "${path}" =~ ^[[:space:]]*# ]] && continue
        paths+=("${path/#\~/${HOME}}")
    done < "${BACKUP_PATHS_FILE}"
    
    while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
        set +e
        output=$(restic backup \
            --exclude-file="${EXCLUDE_FILE}" \
            --json \
            "${paths[@]}" 2>&1)
        exit_code=$?
        set -e
        
        if [[ ${exit_code} -eq 0 ]]; then
            # Parse summary from JSON output
            local summary
            summary=$(echo "${output}" | tail -n1)
            
            # Initialize variables
            local snapshot_id="N/A"
            local files_new=0 files_changed=0 files_unmodified=0
            local dirs_new=0 dirs_changed=0 dirs_unmodified=0
            local data_added=0 total_bytes=0
            local duration=""
            
            if command -v jq &> /dev/null; then
                snapshot_id=$(echo "${summary}" | jq -r '.snapshot_id // "N/A"' | cut -c1-8)
                files_new=$(echo "${summary}" | jq -r '.files_new // 0')
                files_changed=$(echo "${summary}" | jq -r '.files_changed // 0')
                files_unmodified=$(echo "${summary}" | jq -r '.files_unmodified // 0')
                dirs_new=$(echo "${summary}" | jq -r '.dirs_new // 0')
                dirs_changed=$(echo "${summary}" | jq -r '.dirs_changed // 0')
                dirs_unmodified=$(echo "${summary}" | jq -r '.dirs_unmodified // 0')
                data_added=$(echo "${summary}" | jq -r '.data_added // 0')
                total_bytes=$(echo "${summary}" | jq -r '.total_bytes_processed // 0')
                
                local duration_sec=$(echo "${summary}" | jq -r '.total_duration // 0')
                if [[ -n "${duration_sec}" && "${duration_sec}" != "0" ]]; then
                    local dur_int=${duration_sec%.*}
                    local minutes=$((dur_int / 60))
                    local seconds=$((dur_int % 60))
                    duration="${minutes}m ${seconds}s"
                else
                    duration="N/A"
                fi
            fi
            
            # Format sizes
            local data_added_fmt=$(numfmt --to=iec-i --suffix=B "${data_added}" 2>/dev/null || echo "${data_added} bytes")
            local total_bytes_fmt=$(numfmt --to=iec-i --suffix=B "${total_bytes}" 2>/dev/null || echo "${total_bytes} bytes")
            
            # Print success message
            print_header "BACKUP SUCCESSFUL"
            echo "Timestamp:      ${TIMESTAMP}"
            echo "Repository:     ${RESTIC_REPOSITORY}"
            echo "Source Dirs:    ${paths[*]}"
            echo ""
            echo "-------------- Restic Summary ---------------"
            echo "Files:          ${files_new} new, ${files_changed} changed, ${files_unmodified} unmodified"
            echo "Dirs:           ${dirs_new} new, ${dirs_changed} changed, ${dirs_unmodified} unmodified"
            echo "Data Added:     ${data_added_fmt}"
            echo "Total Processed: ${total_bytes_fmt}"
            [[ "${duration}" != "N/A" ]] && echo "Duration:       ${duration}"
            echo "Snapshot ID:    ${snapshot_id}"
            echo ""
            print_separator
            
            return 0
        fi
        
        # Check for network errors
        if echo "${output}" | grep -qiE 'network|connection|timeout|unreachable|B2|backblaze'; then
            if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
                echo "Network error detected. Retrying in ${RETRY_DELAY} seconds... (Attempt ${attempt}/${MAX_RETRIES})"
                sleep ${RETRY_DELAY}
                ((attempt++))
                continue
            else
                local error_msg="Network error after ${MAX_RETRIES} attempts:"$'\n'
                error_msg+=$(echo "${output}" | head -20)
                exit_with_error "Network connection to B2" "${EXIT_NETWORK_ERROR}" "${error_msg}"
            fi
        else
            # Non-network error
            local error_msg=$(echo "${output}" | head -20)
            exit_with_error "Backup execution" "${EXIT_BACKUP_ERROR}" "${error_msg}"
        fi
    done
}

# Main execution
main() {
    validate_config_files
    load_environment
    validate_backup_paths
    execute_backup
}

main "$@"