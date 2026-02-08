# WordPress Rclone Migrations

Fast, secure, and reliable WordPress migrations using rclone and SSH with minimal dependencies.

This script provides a complete WordPress migration solution that handles both files and databases. With wizard-driven configuration, bidirectional sync capabilities, and selective sync options, it offers the best combination of security, reliability, and ease of use for WordPress site migrations.

## Overview

1. **Wizard Mode**: Interactive setup creates reusable migration configurations with connection testing.
2. **Credential Extraction**: Securely extracts database credentials from `wp-config.php` files at runtime.
3. **File Synchronization**: Uses rclone for incremental file transfers with smart exclusions.
4. **Database Migration**: Creates SQL dumps with URL replacement for seamless site transitions.
5. **Bidirectional Sync**: Supports both push (local → remote) and pull (remote → local) operations.
6. **Selective Sync**: Database-only or media-only sync for targeted updates.
7. **Security First**: Uses SSH keys and rclone's secure credential management.
8. **Dry Run Mode**: Preview all changes before execution.
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

2. **Execute operations** using the generated config:
   ```bash
   # Deploy local changes to remote
   ./wordpress-rclone-migrations.sh push site.dev-to-site.com-a1b2c3d4
   
   # Deploy database only
   ./wordpress-rclone-migrations.sh push db site.dev-to-site.com-a1b2c3d4
   
   # Deploy media files only
   ./wordpress-rclone-migrations.sh push media site.dev-to-site.com-a1b2c3d4
   
   # Deploy plugins only
   ./wordpress-rclone-migrations.sh push plugins site.dev-to-site.com-a1b2c3d4
   
   # Deploy themes only
   ./wordpress-rclone-migrations.sh push themes site.dev-to-site.com-a1b2c3d4
   
   # Pull remote changes to local
   ./wordpress-rclone-migrations.sh pull site.dev-to-site.com-a1b2c3d4
   
   # Pull database only
   ./wordpress-rclone-migrations.sh pull db site.dev-to-site.com-a1b2c3d4
   
   # Pull media files only
   ./wordpress-rclone-migrations.sh pull media site.dev-to-site.com-a1b2c3d4
   
   # Pull plugins only
   ./wordpress-rclone-migrations.sh pull plugins site.dev-to-site.com-a1b2c3d4
   
   # Pull themes only
   ./wordpress-rclone-migrations.sh pull themes site.dev-to-site.com-a1b2c3d4
   
   # Preview changes without executing
   ./wordpress-rclone-migrations.sh push --dry-run site.dev-to-site.com-a1b2c3d4
   
   # Skip confirmation prompts (for automation)
   ./wordpress-rclone-migrations.sh push -y site.dev-to-site.com-a1b2c3d4
   ```

3. **View help** for all available options:
   ```bash
   ./wordpress-rclone-migrations.sh help
   ```

## Configuration

The script uses configuration files stored in user's config directory. Example configurations are provided in the `config-examples/` directory.

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

# Optional: Custom directory paths for non-standard WordPress setups
[paths]
src_uploads_dir=/custom/uploads
src_plugins_dir=/custom/plugins
src_themes_dir=/custom/themes
dest_uploads_dir=/var/www/site/uploads
dest_plugins_dir=/var/www/site/plugins
dest_themes_dir=/var/www/site/themes

# Search and replace patterns during database migration
[search_replace]
patterns=https://site.dev|https://site.com
patterns=/local/path|/remote/path
patterns=dev.domain.com|domain.com
```

**Note**: Database operations use WP-CLI which automatically reads credentials from wp-config.php files.

## Migration Process

The script performs a complete WordPress migration in the following steps:

### File Synchronization
- **wp-content focus**: Syncs wp-content directories by default (themes, plugins, uploads)
- **Selective sync**: Database-only, media-only, or full sync options
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



### Production Safety Features
- **Comprehensive logging**: All operations logged to timestamped files in `logs/` directory
- **Lock file management**: Prevents concurrent migrations with automatic stale lock cleanup
- **Pre-flight validation**: Checks disk space and write permissions before migration
- **Operation tracking**: Detailed logs with INFO/SUCCESS/WARNING/ERROR levels
- **Safe execution**: Early validation prevents partial migrations and data corruption



### Default Exclusions
- Log files (`*.log`)
- Cache directories (`cache/*`)
- Node modules (`node_modules/*`)
- Git repositories (`/.git/*`)
- wp-config.php (configurable)

## Security

**The script prioritizes security in all operations:**

- **SSH Key Authentication**: Preferred method with no passwords transmitted or stored
- **Secure Password Handling**: SSH passwords use environment variables to avoid process list exposure
- **rclone Credential Management**: SSH credentials stored securely in rclone config
- **Runtime Credential Extraction**: Database passwords never stored in config files
- **Secure Config Files**: Migration configs have 600 permissions
- **Connection Validation**: Tests all connections before migration
- **Encrypted Transfers**: All data transmitted over encrypted SSH connections

## Command Reference

### Actions
- **push**: Deploy local changes to remote (local → remote)
- **pull**: Pull remote changes to local (remote → local)

### Subcommands
- **db**: Sync database only
- **media**: Sync media files only (uploads directory)
- **plugins**: Sync plugins only (plugins directory)
- **themes**: Sync themes only (themes directory)

### Options
- **-y, --yes**: Skip confirmation prompts (for automation)
- **--dry-run**: Preview changes without executing
- **--config-dir DIR**: Use custom config directory

### WordPress Setup Support

The script works with any WordPress configuration by specifying exact paths:

**Standard WordPress**: `/var/www/html`  
**WordOps**: `/var/www/site.com/htdocs`  
**Bedrock**: `/var/www/site/web` with config in `/var/www/site/config/`  
**Flywheel Local**: `/Users/username/Local Sites/mysite/app/public`  
**Custom**: Specify exact paths during wizard setup

### Custom Directory Paths

For non-standard WordPress setups with custom plugin, theme, or upload directories, you can override the default paths:

**During wizard setup**: Specify custom directory paths when prompted

**In config file**: Add `[paths]` section with custom directories:
```ini
[paths]
src_uploads_dir=/custom/uploads
src_plugins_dir=/app/plugins
src_themes_dir=/app/themes
dest_uploads_dir=/var/www/uploads
dest_plugins_dir=/var/www/plugins
dest_themes_dir=/var/www/themes
```

**Supports WordPress constants**:
- `WP_CONTENT_DIR` - Custom content directory
- `WP_PLUGIN_DIR` - Custom plugins directory
- `UPLOADS` - Custom uploads directory

**Automatic fallbacks**: Uses standard `wp-content/` subdirectories if not specified

### Configurable Search and Replace

Beyond URL replacement, you can define multiple search and replace patterns for database migration:

**In config file**: Add `[search_replace]` section with custom patterns:
```ini
[search_replace]
patterns=https://site.dev|https://site.com
patterns=/local/path|/remote/path
patterns=dev.domain.com|domain.com
patterns=staging.site.com|site.com
```

**Default behavior**: URL replacement is automatically included based on source_url and destination_url

**Use cases**:
- Replace development/staging URLs with production URLs
- Update file paths that differ between environments
- Replace domain names in serialized data
- Update API endpoints or service URLs

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
├── config-examples/              # Example configurations
│   └── flywheel-local-to-wordops.config
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
- **Old command syntax**: Use new action-based commands (push/pull instead of flags)

### Debug Steps

1. **Dry run**: `./wordpress-rclone-migrations.sh push --dry-run config-file`
2. **Manual SSH test**: `ssh -i ~/.ssh/id_rsa user@hostname`
3. **rclone test**: `rclone lsd remote-name:`
4. **WP-CLI test**: `ssh user@hostname "cd /wp/root && wp db check"`

## Contributing

Pull requests and suggestions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Semantic Versioning (SemVer)
- Conventional Commits
- Development workflow
- Testing requirements

## Migration Workflow

```bash
# 1. Create configuration
./wordpress-rclone-migrations.sh

# 2. Deploy changes (full or selective)
./wordpress-rclone-migrations.sh push site.dev-to-site.com-a1b2c3d4        # Everything
./wordpress-rclone-migrations.sh push db site.dev-to-site.com-a1b2c3d4     # Database only
./wordpress-rclone-migrations.sh push media site.dev-to-site.com-a1b2c3d4  # Media only
./wordpress-rclone-migrations.sh push plugins site.dev-to-site.com-a1b2c3d4 # Plugins only
./wordpress-rclone-migrations.sh push themes site.dev-to-site.com-a1b2c3d4  # Themes only
```

This script focuses on:
- **Fast**: Incremental sync, parallel transfers
- **Secure**: SSH keys, encrypted connections, secure credential storage  
- **Reliable**: Connection testing, atomic operations, error handling
- **Safe**: Confirmation prompts, dry-run mode, comprehensive logging

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

**Test in a non-production environment before deploying!**

This script performs file and database operations that can overwrite data. Always backup your sites before migration and test the process thoroughly in a safe environment.