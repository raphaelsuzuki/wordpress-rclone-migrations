# WordPress Rclone Migrations

Fast, secure, and reliable WordPress migrations using rclone and SSH with minimal dependencies.

This script provides a complete WordPress migration solution that handles both files and databases. With wizard-driven configuration and bidirectional sync capabilities, it offers the best combination of security, reliability, and ease of use for WordPress site migrations.

## Overview

1. **Wizard Mode**: Interactive setup creates reusable migration configurations with connection testing.
2. **Credential Extraction**: Securely extracts database credentials from `wp-config.php` files at runtime.
3. **File Synchronization**: Uses rclone for incremental file transfers with smart exclusions.
4. **Database Migration**: Creates SQL dumps with URL replacement for seamless site transitions.
5. **Bidirectional Sync**: Supports both push (local → remote) and pull (remote → local) operations.
6. **Security First**: Uses SSH keys and rclone's secure credential management.
7. **Dry Run Mode**: Preview all changes before execution.
8. **Backup Mode**: Create basic backups of remote WordPress sites, with no compression, retention policy or restore funcionalities.
9. **Production Safety**: Comprehensive logging, lock file management, and pre-flight validation.
10. **Broad Compatibility**: Compatible with most WordPress setups, including WordOps and custom configurations.

## Requirements

### Core Dependencies

- **`rclone`** (local machine)
  - File synchronization between local and remote servers
  - Creates secure SFTP remotes for encrypted file transfers
  - Handles incremental sync with checksums and compression
  - Transfers database dump files between servers

- **`wp-cli`** (both source and destination servers)
  - Database export: `wp db export --gzip` creates compressed SQL dumps
  - Database import: `wp db import` restores databases from SQL files
  - Database testing: `wp db check` validates database connections
  - URL replacement: `wp search-replace` updates WordPress URLs in serialized data

- **`ssh`** (both local and remote)
  - Remote command execution for WP-CLI operations
  - Secure authentication using SSH keys or passwords
  - File permission management on remote servers
  - Connection testing and validation

### Optional Dependencies

- **`sshpass`** (local machine, only for SSH password authentication)
  - Enables SSH password authentication when SSH keys are not available
  - Automatically provides passwords to SSH commands
  - Not required if using SSH key-based authentication



## Limitations

- **SSH Access Required**: Both key-based and password authentication supported
- **SFTP Compatibility**: Remote server must support SFTP for rclone file transfers
- **WP-CLI Availability**: Must be installed and functional on both source and destination servers
- **WordPress Configuration**: Valid wp-config.php files required for database operations
- **SSH Password Auth**: Requires `sshpass` package if not using SSH keys

## Usage

1. **Run the wizard** to create a migration configuration:
   ```bash
   ./wordpress-rclone-migrations.sh
   ```

2. **Execute migrations** using the generated config:
   ```bash
   # Normal migration (local → remote)
   ./wordpress-rclone-migrations.sh site.dev-to-site.com-a1b2c3d4
   
   # Pull from remote (remote → local)
   ./wordpress-rclone-migrations.sh --reverse site.dev-to-site.com-a1b2c3d4
   
   # Preview changes without executing
   ./wordpress-rclone-migrations.sh --dry-run site.dev-to-site.com-a1b2c3d4
   
   # Create backup of remote site
   ./wordpress-rclone-migrations.sh --backup site.dev-to-site.com-a1b2c3d4
   
   # Create backup in custom location
   ./wordpress-rclone-migrations.sh --backup --backup-dir /path/to/backups site.dev-to-site.com-a1b2c3d4
   ```

3. **View help** for all available options:
   ```bash
   ./wordpress-rclone-migrations.sh --help
   ```

## Configuration

The script uses configuration files stored in the `configs/` directory. Each migration gets a unique config file named `source-to-destination-hash`.

### Wizard Configuration

The wizard will prompt for:
- **Source paths**: WordPress root, wp-content, and wp-config.php locations
- **Destination details**: SSH hostname, username, key file, and remote paths
- **URLs**: Source and destination URLs for database replacement
- **Sync options**: Exclusion patterns, permissions, and rclone settings

### Configuration Examples

```bash
# Standard WordPress setup
./wordpress-rclone-migrations.sh
# Follow prompts for standard /var/www/html setup

# WordOps setup (wp-config outside web root)
# Specify: wp_config=/var/www/site.com/wp-config.php

# Bedrock setup
# Specify: wp_config=/var/www/site/config/application.php
```

### Configuration File Structure

```ini
[source]
wp_root=/var/www/html
wp_content=/var/www/html/wp-content
wp_config=/var/www/html/wp-config.php

[destination]
ssh_host=production.com
ssh_user=deploy
ssh_key=/home/user/.ssh/id_rsa
rclone_remote=wp-a1b2c3d4
wp_root=/var/www/site.com/htdocs
wp_content=/var/www/site.com/htdocs/wp-content
wp_config=/var/www/site.com/wp-config.php

[urls]
source_url=https://site.dev
destination_url=https://site.com

[options]
exclude=*.log,cache/*,node_modules/*,/.git/*
sync_wp_config=false
fix_permissions=true
web_user=www-data
web_group=www-data
rclone_flags=--transfers=4 --checkers=8 --progress
last_sync=2024-01-15T10:30:00Z
```

**Note**: Database operations use WP-CLI which automatically reads credentials from wp-config.php files.

## Migration Process

The script performs a complete WordPress migration in the following steps:

### File Synchronization
- **wp-content focus**: Syncs wp-content directories by default (themes, plugins, uploads)
- **Incremental sync**: Only transfers changed files using rclone
- **Smart exclusions**: Skips cache, logs, and development files by default
- **Permission preservation**: Maintains file timestamps and permissions
- **Configurable scope**: Choose to include/exclude wp-config.php and other files

### Database Migration
- **WP-CLI export/import**: Uses `wp db export` and `wp db import` for all database operations
- **Automatic compression**: Built-in gzip compression for efficient transfers
- **WordPress-native**: Handles WordPress database specifics automatically
- **URL replacement**: Updates all WordPress URLs using WP-CLI:
  - Uses `wp search-replace` for proper serialized data handling
  - Updates `wp_options`, `wp_posts`, `wp_comments`, `wp_postmeta`
  - Handles WordPress serialized data correctly
  - Preserves post GUIDs (skips guid column)
- **Localhost MySQL support**: Works with databases that only listen on localhost

### Backup Process
- **Timestamped backups**: Creates backups with `YYYYMMDD_HHMMSS` format
- **Complete site backup**: Includes both wp-content files and compressed database
- **User-configurable location**: Saves backups to specified directory or `./backups/` by default
- **Backup manifest**: Creates `backup_info.txt` with backup details and contents
- **Automatic cleanup**: Removes temporary database files from remote server

### Production Safety Features
- **Comprehensive logging**: All operations logged to timestamped files in `logs/` directory
- **Lock file management**: Prevents concurrent migrations with automatic stale lock cleanup
- **Pre-flight validation**: Checks disk space and write permissions before migration
- **Operation tracking**: Detailed logs with INFO/SUCCESS/WARNING/ERROR levels
- **Safe execution**: Early validation prevents partial migrations and data corruption

### Manual Restore from Backup
To restore from a backup, use these manual steps:

```bash
# 1. Restore files
rsync -av /path/to/backup/files/ /var/www/html/wp-content/

# 2. Restore database
cd /var/www/html
wp db import /path/to/backup/backup_YYYYMMDD_HHMMSS.sql.gz

# 3. Fix URLs if restoring to different domain
wp search-replace 'https://old-domain.com' 'https://new-domain.com'

# 4. Fix file permissions if needed
sudo chown -R www-data:www-data /var/www/html/wp-content
```

### Default Exclusions
- Log files (`*.log`)
- Cache directories (`cache/*`)
- Node modules (`node_modules/*`)
- Git repositories (`/.git/*`)
- wp-config.php (configurable)

## Security

**The script prioritizes security in all operations:**

- **SSH Key Authentication**: No passwords transmitted or stored
- **rclone Credential Management**: SSH credentials stored securely in rclone config
- **Runtime Credential Extraction**: Database passwords never stored in config files
- **Secure Config Files**: Migration configs have 600 permissions
- **Connection Validation**: Tests all connections before migration
- **Encrypted Transfers**: All data transmitted over encrypted SSH connections

## WordPress Setup Support

The script works with any WordPress configuration by specifying exact paths:

### Standard WordPress
```ini
wp_root=/var/www/html
wp_content=/var/www/html/wp-content
wp_config=/var/www/html/wp-config.php
```

### WordOps
```ini
wp_root=/var/www/site.com/htdocs
wp_content=/var/www/site.com/htdocs/wp-content
wp_config=/var/www/site.com/wp-config.php
```

### Bedrock
```ini
wp_root=/var/www/site/web
wp_content=/var/www/site/web/app
wp_config=/var/www/site/config/application.php
```

### Flywheel Local
```ini
wp_root=/Users/username/Local Sites/mysite/app/public
wp_content=/Users/username/Local Sites/mysite/app/public/wp-content
wp_config=/Users/username/Local Sites/mysite/app/public/wp-config.php
```

### Custom Structures
Specify exact paths for each component during wizard setup.

## Advanced Configuration

### Custom Exclusions
Modify exclude patterns in config file:
```ini
exclude=*.log,cache/*,tmp/*,uploads/cache/*,node_modules/*,*.zip
```

### Performance Tuning
Adjust rclone transfer settings:
```ini
rclone_flags=--transfers=8 --checkers=16 --progress --bwlimit=10M
```

### Permission Management
Configure file ownership on remote server:
```ini
fix_permissions=true
web_user=www-data
web_group=www-data
```

## File Structure

```
wordpress-rclone-migrations/
├── wordpress-rclone-migrations.sh # Main migration script
├── test-setup.sh                 # Dependency validation script
├── configs/                      # Migration configurations
│   ├── site1.dev-to-site1.com-a1b2c3d4
│   ├── site2.dev-to-site2.com-b2c3d4e5
│   └── example.config            # Configuration template
├── backups/                      # Backup storage (created automatically)
│   └── site1.dev-to-site1.com-a1b2c3d4_20241215_143022/
├── logs/                         # Operation logs (created automatically)
│   └── migration_20241215_143022.log
└── README.md                     # This documentation
```

## Troubleshooting

- **SSH connection fails**: Verify SSH key permissions (`chmod 600 ~/.ssh/id_rsa`) and test manual connection
- **rclone remote issues**: Check `rclone listremotes` and test with `rclone lsd remote-name:`
- **WP-CLI not found**: Ensure WP-CLI is installed on both source and destination servers
- **Database export/import fails**: Verify wp-config.php paths and WordPress installation
- **Permission denied**: Ensure script can read WordPress files and write to temp directories
- **wp-config.php not found**: Check file paths, especially for WordOps/Bedrock setups
- **URL replacement fails**: Verify source and destination URLs are correctly specified
- **Dependency missing**: Run `./test-setup.sh` to validate all required tools

### Debug Steps

1. **Test setup**: `./test-setup.sh`
2. **Dry run**: `./wordpress-rclone-migrations.sh --dry-run config-file`
3. **Manual SSH test**: `ssh -i ~/.ssh/id_rsa user@hostname`
4. **rclone test**: `rclone lsd remote-name:`
5. **WP-CLI test**: `ssh user@hostname "cd /wp/root && wp db check"`

## Contributing

Pull requests and suggestions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Semantic Versioning (SemVer)
- Conventional Commits
- Development workflow
- Testing requirements

This script focuses on:
- **Fast**: Incremental sync, parallel transfers
- **Secure**: SSH keys, encrypted connections, secure credential storage  
- **Reliable**: Connection testing, atomic operations, error handling

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

**Test in a non-production environment before deploying!**

This script performs file and database operations that can overwrite data. Always backup your sites before migration and test the process thoroughly in a safe environment.