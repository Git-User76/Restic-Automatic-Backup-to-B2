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
readonly BASE_RETRY_DELAY=30

# Exit codes
readonly EXIT_CONFIG_ERROR=10
readonly EXIT_PERMISSION_ERROR=11
readonly EXIT_BACKUP_ERROR=12
readonly EXIT_NETWORK_ERROR=13
readonly EXIT_VERIFICATION_ERROR=14

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
    
    # Verify password file permissions (Linux-specific stat)
    local perms
    perms=$(stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null || echo "000")
    if [[ ${perms} -gt 600 ]]; then
        local error_msg="Password file has insecure permissions: ${perms}"$'\n'
        error_msg+="Run: chmod 600 ${PASSWORD_FILE}"
        exit_with_error "Configuration validation" "${EXIT_CONFIG_ERROR}" "${error_msg}"
    fi
}

# Safely load and validate environment variables
load_environment() {
    local line key value
    
    # Parse environment file safely without executing it
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        
        # Remove 'export ' prefix if present
        line="${line#export }"
        
        # Extract key and value
        if [[ "${line}" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            
            # Remove surrounding quotes if present
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            
            # Validate key is a safe variable name
            if [[ ! "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                exit_with_error "Environment validation" "${EXIT_CONFIG_ERROR}" \
                    "Invalid variable name in ${ENV_FILE}: ${key}"
            fi
            
            # Export the variable
            export "${key}=${value}"
        fi
    done < "${ENV_FILE}"
    
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
}

# Check backup paths are accessible with proper sanitization
validate_backup_paths() {
    local inaccessible=()
    local path line
    
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        
        path="${line}"
        
        # Expand tilde to home directory
        path="${path/#\~/${HOME}}"
        
        # Resolve to absolute path and validate (this is the real security check)
        if ! path=$(realpath -m "${path}" 2>/dev/null); then
            exit_with_error "Path validation" "${EXIT_CONFIG_ERROR}" \
                "Invalid path format: ${line}"
        fi
        
        # Check existence and readability
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

# Verify backup integrity
verify_backup() {
    echo ""
    echo "Verifying backup integrity..."
    
    local verify_output
    local verify_code
    
    # Use conditional execution instead of set +e
    if verify_output=$(restic check --read-data-subset=5% 2>&1); then
        verify_code=0
        echo "✓ Backup verification successful"
    else
        verify_code=$?
        local error_msg="Backup verification failed (exit code: ${verify_code}):"$'\n'
        error_msg+=$(echo "${verify_output}" | head -20)
        exit_with_error "Backup verification" "${EXIT_VERIFICATION_ERROR}" "${error_msg}"
    fi
}

# Execute backup with retry logic and exponential backoff
execute_backup() {
    local attempt=1
    local output
    local exit_code
    
    # Build backup paths array with proper sanitization
    local paths=()
    local line path
    
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        
        path="${line}"
        
        # Expand tilde and resolve path
        path="${path/#\~/${HOME}}"
        path=$(realpath -m "${path}" 2>/dev/null) || continue
        
        paths+=("${path}")
    done < "${BACKUP_PATHS_FILE}"
    
    while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
        # Use conditional execution instead of toggling set -e
        if output=$(restic backup \
            --exclude-file="${EXCLUDE_FILE}" \
            --json \
            "${paths[@]}" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
        
        if [[ ${exit_code} -eq 0 ]]; then
            # Parse summary from JSON output - extract valid JSON lines
            local summary
            summary=$(echo "${output}" | grep -E '^\{.*\}$' | tail -n1)
            
            # Fallback to empty JSON if no valid JSON found
            [[ -z "${summary}" ]] && summary='{}'
            
            # Initialize variables
            local snapshot_id="N/A"
            local files_new=0 files_changed=0 files_unmodified=0
            local dirs_new=0 dirs_changed=0 dirs_unmodified=0
            local data_added=0 total_bytes=0
            local duration=""
            
            if command -v jq &> /dev/null && [[ "${summary}" != "{}" ]]; then
                snapshot_id=$(echo "${summary}" | jq -r '.snapshot_id // "N/A"' 2>/dev/null | cut -c1-8)
                files_new=$(echo "${summary}" | jq -r '.files_new // 0' 2>/dev/null)
                files_changed=$(echo "${summary}" | jq -r '.files_changed // 0' 2>/dev/null)
                files_unmodified=$(echo "${summary}" | jq -r '.files_unmodified // 0' 2>/dev/null)
                dirs_new=$(echo "${summary}" | jq -r '.dirs_new // 0' 2>/dev/null)
                dirs_changed=$(echo "${summary}" | jq -r '.dirs_changed // 0' 2>/dev/null)
                dirs_unmodified=$(echo "${summary}" | jq -r '.dirs_unmodified // 0' 2>/dev/null)
                data_added=$(echo "${summary}" | jq -r '.data_added // 0' 2>/dev/null)
                total_bytes=$(echo "${summary}" | jq -r '.total_bytes_processed // 0' 2>/dev/null)
                
                local duration_sec
                duration_sec=$(echo "${summary}" | jq -r '.total_duration // 0' 2>/dev/null)
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
            local data_added_fmt
            local total_bytes_fmt
            data_added_fmt=$(numfmt --to=iec-i --suffix=B "${data_added}" 2>/dev/null || echo "${data_added} bytes")
            total_bytes_fmt=$(numfmt --to=iec-i --suffix=B "${total_bytes}" 2>/dev/null || echo "${total_bytes} bytes")
            
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
            
            # Verify backup integrity
            verify_backup
            
            return 0
        fi
        
        # Check for network errors
        if echo "${output}" | grep -qiE 'network|connection|timeout|unreachable|B2|backblaze'; then
            if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
                # Exponential backoff: delay increases with each attempt
                local backoff=$((BASE_RETRY_DELAY * (2 ** (attempt - 1))))
                echo "Network error detected. Retrying in ${backoff} seconds... (Attempt ${attempt}/${MAX_RETRIES})"
                sleep "${backoff}"
                ((attempt++))
                continue
            else
                local error_msg="Network error after ${MAX_RETRIES} attempts:"$'\n'
                error_msg+=$(echo "${output}" | head -20)
                exit_with_error "Network connection to B2" "${EXIT_NETWORK_ERROR}" "${error_msg}"
            fi
        else
            # Non-network error
            local error_msg
            error_msg=$(echo "${output}" | head -20)
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