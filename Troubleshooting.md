# Troubleshooting

## Permission Errors

**Error:** `Password file has insecure permissions: 644`

**Solution:**
```shell
chmod 600 ~/.config/restic/repository.password
chmod 600 ~/.config/restic/config.env
```

<br>

## Missing Configuration Files

**Error:** `Missing configuration files`

**Solution:**
```shell
# Verify all required files exist
ls -la ~/.config/restic/

# Expected files:
# config.env
# repository.password
# backup-paths.conf
# exclude-patterns.conf

# Create any missing files
touch ~/.config/restic/{config.env,repository.password,backup-paths.conf,exclude-patterns.conf}
```

<br>

## Network Errors

**Error:** `Network error after 3 attempts`

**Troubleshooting:**
```shell
# Test B2 connectivity
curl -I https://api.backblazeb2.com

# Verify credentials
source ~/.config/restic/config.env
restic -r $RESTIC_REPOSITORY snapshots

# Check firewall rules
sudo iptables -L -n | grep 443
```

**Solution:**
- Verify internet connection
- Check B2 service status: https://status.backblaze.com/
- Verify credentials in `config.env`
- Increase `RETRY_DELAY` in config.env

<br>

## Repository Locked

**Error:** `unable to create lock: repository is already locked`

**Cause:** Previous backup was interrupted or is still running.

**Solution:**
```shell
# Check if backup is actually running
ps aux | grep restic

# If not running, unlock the repository
source ~/.config/restic/config.env
export RESTIC_PASSWORD_FILE=~/.config/restic/repository.password
restic unlock

# WARNING: Only unlock if you're certain no backup is running!
```

<br>

## Invalid Credentials

**Error:** `unable to open repository: Account ID or Application Key is wrong`

**Solution:**
```shell
# Verify credentials in Backblaze console
# Re-download Application Key (can only be viewed once)
# Update ~/.config/restic/config.env with correct values

# Test credentials
source ~/.config/restic/config.env
restic -r $RESTIC_REPOSITORY snapshots
```

<br>

## Backup Paths Not Found

**Error:** `Inaccessible backup paths: /path/to/dir (not found)`

**Solution:**
```bash
# Verify paths exist
cat ~/.config/restic/backup-paths.conf

# Check each path
ls -ld ~/Documents ~/Pictures

# Remove or comment out non-existent paths
nano ~/.config/restic/backup-paths.conf
# or
vim ~/.config/restic/backup-paths.conf
```

---
<br><br>

# Exit Codes

The script uses specific exit codes for better systemd integration:

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Success | Backup completed successfully |
| 10 | Configuration Error | Check config files exist and are valid |
| 11 | Permission Error | Fix file permissions (chmod 600) |
| 12 | Backup Error | Check logs for restic errors |
| 13 | Network Error | Check internet connection and B2 status |
