#!/bin/bash
# ~/bin/restic-backup.sh
# Production-ready restic backup script for systemd

set -euo pipefail

# Configuration from environment variables (set by systemd)
REPO="${RESTIC_REPOSITORY}"
CACHE_DIR="${RESTIC_CACHE_DIR:-$HOME/.cache/restic}"
LOGDIR="${HOME}/.local/share/restic-logs"
LOGFILE="${LOGDIR}/backup-$(date +%Y-%m).log"

# Create necessary directories
mkdir -p "$CACHE_DIR" "$LOGDIR"

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOGFILE"
}

# Error handling
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Backup failed with exit code $exit_code"
        # Optional: Send notification
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -u critical "Backup Failed" "Restic backup failed - check logs"
        fi
    fi
    exit $exit_code
}
trap cleanup EXIT

log "INFO" "Starting restic backup..."

# Verify environment variables
required_vars=("RESTIC_REPOSITORY" "RESTIC_PASSWORD_FILE" "B2_ACCOUNT_ID" "B2_ACCOUNT_KEY")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "ERROR" "Required environment variable $var is not set"
        exit 1
    fi
done

# Verify password file exists and is readable
if [[ ! -r "$RESTIC_PASSWORD_FILE" ]]; then
    log "ERROR" "Password file $RESTIC_PASSWORD_FILE not readable"
    exit 1
fi

# Files and directories to backup
BACKUP_PATHS=(
    # Core shell configuration
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.zshrc"
    "$HOME/.profile"
    
    # Development tools
    "$HOME/.gitconfig"
    "$HOME/.vimrc"
    "$HOME/.tmux.conf"
    "$HOME/.config/nvim"
    
    # SSH configuration and keys
    "$HOME/.ssh"
    
    # GPG keys and configuration  
    "$HOME/.gnupg"
    
    # Password management
    "$HOME/.password-store"
    
    # Custom scripts
    "$HOME/bin"
    "$HOME/.local/bin"
    
    # Application configs with potential secrets
    "$HOME/.config/rclone"
    "$HOME/.aws"
    "$HOME/.docker/config.json"
    
    # Add your specific paths here
)

# Exclude patterns
EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.log"
    "*.cache"
    "*~"
    ".DS_Store"
    "node_modules"
    "__pycache__"
)

# Build exclude arguments
EXCLUDE_ARGS=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_ARGS+=(--exclude "$pattern")
done

# Filter existing paths (avoid errors for missing directories)
EXISTING_PATHS=()
for path in "${BACKUP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        EXISTING_PATHS+=("$path")
    else
        log "WARN" "Path does not exist, skipping: $path"
    fi
done

if [[ ${#EXISTING_PATHS[@]} -eq 0 ]]; then
    log "ERROR" "No backup paths exist!"
    exit 1
fi

# Perform backup
log "INFO" "Backing up ${#EXISTING_PATHS[@]} paths..."
restic backup \
    --repo "$REPO" \
    --tag "automated-backup" \
    --tag "$(date +%Y-%m-%d)" \
    --tag "$(hostname)" \
    "${EXCLUDE_ARGS[@]}" \
    "${EXISTING_PATHS[@]}" 2>&1 | tee -a "$LOGFILE"

log "INFO" "Backup completed successfully"

# Cleanup old snapshots
log "INFO" "Cleaning up old snapshots..."
restic forget \
    --repo "$REPO" \
    --tag "automated-backup" \
    --keep-daily 30 \
    --keep-weekly 12 \
    --keep-monthly 12 \
    --keep-yearly 5 \
    --prune 2>&1 | tee -a "$LOGFILE"

log "INFO" "Cleanup completed"

# Optional: Verify backup integrity (monthly)
if [[ $(date +%d) == "01" ]]; then
    log "INFO" "Running monthly repository check..."
    restic check --repo "$REPO" 2>&1 | tee -a "$LOGFILE"
    log "INFO" "Repository check completed"
fi

# Success notification
if command -v notify-send >/dev/null 2>&1; then
    notify-send "Backup Complete" "Restic backup completed successfully"
fi

log "INFO" "All backup operations completed successfully"