# Restic Backup to Backblaze B2

Automated, secure backup solution using [Restic](https://restic.net/) with [Backblaze B2](https://www.backblaze.com/b2/cloud-storage.html) cloud storage.

_Simple, reliable backups from Linux to Backblaze B2 with encryption, retry logic, and systemd integration._

---
<br>

## Features

- **Secure**: AES-256 encryption, strict file permissions (0600), comprehensive input validation
- **Reliable**: Automatic retry logic with configurable attempts for network failures
- **Minimal**: Single bash script with only restic as a dependency
- **Portable**: XDG Base Directory compliant, runs on any Linux distribution
- **Systemd-Ready**: Clean exit codes and console output designed for systemd timers
- **Simple**: Clear configuration files, no complex setup

---
<br>


## Directory Structure
### Configuration File Locations

```
~/.config/restic/
├── config.env                  # B2 credentials and repository path (0600)
├── repository.password         # Repository encryption password (0600)
├── backup-paths.conf           # Paths to backup (0644)
└── exclude-patterns.conf       # Exclusion patterns (0644)
```

### config.env

Contains Backblaze B2 credentials and repository configuration.

**Required variables:**
- `B2_ACCOUNT_ID` - Application Key ID from Backblaze
- `B2_ACCOUNT_KEY` - Application Key from Backblaze  
- `RESTIC_REPOSITORY` - Repository path in format `b2:bucket-name:path`

**Optional variables:**
- `MAX_RETRIES` - Number of retry attempts on network failure (default: 3)
- `RETRY_DELAY` - Seconds to wait between retries (default: 30)

**Example:**
```bash
B2_ACCOUNT_ID="0123456789abcdef01234567"
B2_ACCOUNT_KEY="K001aBcDeFgHiJkLmNoPqRsTuVwXyZ"
RESTIC_REPOSITORY="b2:my-backup-bucket:restic"
```

### repository.password

Contains the encryption password for the restic repository. This is auto-generated and should be stored securely in a password manager as a backup.

### backup-paths.conf

List of paths to back up, one per line. Supports:
- Absolute paths: `/etc/nginx`
- Tilde expansion: `~/Documents`
- Comments: Lines starting with `#`
- Empty lines (ignored)

**Example:**
```bash
# User data
~/Documents
~/Pictures
~/.ssh

# System configs (if running as root)
/etc
```

### exclude-patterns.conf

Exclusion patterns using restic's syntax. Supports:
- Glob patterns: `**/*.log`
- Directory exclusions: `**/node_modules/**`
- Comments: Lines starting with `#`

**Example:**
```bash
# Caches
**/.cache/**
**/cache/**

# Development
**/node_modules/**
**/__pycache__/**
```

---
<br>

## Installation

### 1. Install Restic

```bash
# Debian/Ubuntu
sudo apt install restic

# Fedora/RHEL
sudo dnf install restic

# Arch Linux
sudo pacman -S restic
```

### 2. Install Backup Script

```shell
# Download the script
wget https://raw.githubusercontent.com/Git-User76/Restic-Automatic-Backup-to-B2/restic-backup.sh
chmod u+x restic-backup.sh

# Place it in your current user's $PATH
mkdir -p ~/.local/bin
mv restic-backup.sh ~/.local/bin/restic-backup.sh
```

---
<br>

## Configuration

### Step 1: Create Configuration Directory

```shell
mkdir -p ~/.config/restic
```

<br>

### Step 2: Create Configuration Files

Create the following files in `~/.config/restic/`:

```shell
touch ~/.config/restic/config.env
touch ~/.config/restic/repository.password
touch ~/.config/restic/backup-paths.conf
touch ~/.config/restic/exclude-patterns.conf
```

<br>

### Step 3: Set Configuration File Permissions

```shell
# Secure permissions for sensitive files
chmod 600 ~/.config/restic/config.env
chmod 600 ~/.config/restic/repository.password

# Standard permissions for path and exclusion configs
chmod 644 ~/.config/restic/backup-paths.conf
chmod 644 ~/.config/restic/exclude-patterns.conf
```

<br>

### Step 4: Configure B2 Credentials

Get your Backblaze B2 credentials:
1. Log in to [Backblaze](https://secure.backblaze.com/)
2. Navigate to **App Keys** (under Account menu)
3. Create a new application key with read/write access
4. Copy the **Application Key ID** and **Application Key**

Edit `~/.config/restic/config.env`:

```shell
# Backblaze B2 Credentials
B2_ACCOUNT_ID="your_key_id_here"
B2_ACCOUNT_KEY="your_application_key_here"

# Repository path: b2:bucket-name:optional/path
RESTIC_REPOSITORY="b2:your-bucket-name:restic-backups"
```

**Important**: The B2 bucket must already exist. Create it in the Backblaze web interface before initializing the repository.

<br>

### Step 5: Generate Restic Repository Password

```shell
# Generate a strong random password
head -c 32 /dev/urandom | base64 > ~/.config/restic/repository.password

# You can also just put the password you want in ~/.config/restic/repository.password
echo "mypassword" > ~/.config/restic/repository.password

# IMPORTANT: Save this password in a secure location (password manager)
# You cannot recover your backups without it!
```

<br>

### Step 6: Configure Backup Paths

Edit `~/.config/restic/backup-paths.conf` (one path per line):

```shell
# Example backup-paths.conf file
# Home directory files
~/Documents
~/Pictures
/var/www
```

<br>

### Step 7: Configure File Patterns to Exclude

Edit `~/.config/restic/exclude-patterns.conf`:

```shell
# Example exclude-patterns.conf file
# Cache directories
**/.cache/**
**/cache/**

# Log files
**/*.log
**/logs/**

# Temporary files
**/*.tmp
**/*.temp
**/tmp/**

# Large media caches
~/.local/share/Trash/**
~/.thumbnails/**
```

<br>

### Step 8: Initialize Repository

**This is a one-time operation** - only run once per repository:

```shell
# Load credentials
source ~/.config/restic/config.env
export RESTIC_PASSWORD_FILE=~/.config/restic/repository.password

# Initialize the restic repository
restic -r $RESTIC_REPOSITORY init
```

You should see:
```
created restic repository 1a2b3c4d5e at b2:your-bucket-name:restic-backups
```

---
<br>

## Usage

### Manual Backup

```shell
# Run the backup script (once in your $PATH)
restic-backup.sh
```

**Expected output on success:**
```
=============================================
               BACKUP SUCCESSFUL
=============================================
Timestamp:      2025-10-04 14:32:15
Repository:     b2:my-bucket:restic-backups
Source Dirs:    /home/user/Documents /home/user/Pictures

-------------- Restic Summary ---------------
Files:          15 new, 3 changed, 1247 unmodified
Dirs:           2 new, 1 changed, 89 unmodified
Data Added:     42.3 MiB
Total Processed: 1.2 GiB
Duration:       2m 15s
Snapshot ID:    a1b2c3d4
---------------------------------------------
```

<br>

### Automated Backups with Systemd Timers

#### Create User Service File

Create `~/.config/systemd/user/restic-backup.service`

```ini
# ~/.config/systemd/user/restic-backup.service
# Systemd service unit for automated restic backups to B2

[Unit]
Description=Restic Backup to Backblaze B2
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# Execute the backup script
ExecStart=~/.local/bin/restic-backup.sh

# Timeout (4 hours should be enough for most backups)
TimeoutStartSec=4h
```

#### Create User Timer File

Create `~/.config/systemd/user/restic-backup.timer`.

```ini
# ~/.config/systemd/user/restic-backup.timer
# Systemd timer for automated restic backups to Backblaze B2 every 2 weeks

[Unit]
Description=Schedule Restic backups to B2 every 2 weeks
Requires=restic-backup.service

[Timer]
# Run every 2 weeks (bi-weekly) - configure with your own schedule
OnCalendar=*-*-01,15 02:30:00
# Also run 10 minutes after boot if a scheduled run was missed
OnBootSec=10min
# If the system was powered down when a backup should have run, run it when powered on
Persistent=true
# Randomize start time by up to 30 minutes to avoid load spikes
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
```

#### Enable and Start Timer

```bash
# Reload systemd configuration
systemctl --user daemon-reload

# Enable timer to start on boot
systemctl --user enable restic-backup.timer

# Start timer now
systemctl --user start restic-backup.timer

# Check timer status
systemctl --user status restic-backup.timer

# View all timers
systemctl --user list-timers
```

#### View Backup Logs

```bash
# Follow live logs
journalctl --user -u restic-backup.service -f

# View last 50 lines
journalctl --user -u restic-backup.service -n 50

# View logs from today
journalctl --user -u restic-backup.service --since today

# View logs with specific priority
journalctl --user -u restic-backup.service -p err
```

#### Results
Now, the backup to B2 is scheduled to run as configured in the systemd timer. Success and failure output will be visible in the systemd journal.


<br>

### Restore Data

#### List Snapshots

```bash
# Load configuration
source ~/.config/restic/config.env
export RESTIC_PASSWORD_FILE=~/.config/restic/repository.password

# List all snapshots
restic snapshots

# List latest 10 snapshots
restic snapshots --latest 10
```

#### Restore Complete Snapshot

```bash
# Restore latest snapshot to /tmp/restore
restic restore latest --target /tmp/restore

# Restore specific snapshot by ID
restic restore a1b2c3d4 --target /tmp/restore
```

#### Restore Specific Files/Directories

```bash
# Restore only Documents folder from latest
restic restore latest --target /tmp/restore --include ~/Documents

# Restore specific file
restic restore latest --target /tmp/restore --include ~/Documents/important.txt

# Restore with path pattern
restic restore latest --target /tmp/restore --include '**/*.pdf'
```

<br>

### Repository Maintenance

#### Check Repository Health

```bash
source ~/.config/restic/config.env
export RESTIC_PASSWORD_FILE=~/.config/restic/repository.password

# Quick check
restic check

# Thorough check (reads all data)
restic check --read-data
```

#### View Statistics

```bash
# Repository statistics
restic stats

# Statistics for specific snapshot
restic stats latest

# Raw data statistics
restic stats --mode raw-data
```

#### Cleanup Old Snapshots

```bash
# Remove snapshots older than 30 days
restic forget --keep-within 30d

# Keep last 7 daily, 4 weekly, 12 monthly snapshots
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12

# Combine forget with prune to free space
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

---