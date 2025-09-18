# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2024-12-15

### Added
- **Plugins and themes sync**: New subcommands for selective component synchronization
- **Configurable directory paths**: Support for custom uploads, plugins, and themes directories
- **Custom path wizard prompts**: Optional directory configuration during setup
- **Non-standard WordPress support**: Handle custom WP_CONTENT_DIR and WP_PLUGIN_DIR setups

### Commands
```bash
./script push plugins config-file    # Deploy plugins only
./script push themes config-file     # Deploy themes only
./script pull plugins config-file    # Pull plugins only
./script pull themes config-file     # Pull themes only
```

### Configuration
```ini
[paths]
src_uploads_dir=/custom/uploads
src_plugins_dir=/custom/plugins
src_themes_dir=/custom/themes
dest_uploads_dir=/var/www/site/uploads
dest_plugins_dir=/var/www/site/plugins
dest_themes_dir=/var/www/site/themes
```

### Enhanced
- Updated documentation with new features and examples
- Improved config examples with custom paths section
- Maintained backward compatibility with standard wp-content structure

## [2.0.0] - 2024-12-15

### Added
- **Action-based command structure**: `push` and `pull` actions for clear intent
- **Selective Sync**: Database-only and media-only sync with `db` and `media` subcommands
- **User confirmation prompts**: Safety confirmations for all destructive operations
- **Automation support**: `-y` flag to skip confirmations for scripted deployments
- **Backward compatibility detection**: Helpful migration messages for old syntax
- **Enhanced performance**: Targeted sync operations for faster deployments

### Changed
- **BREAKING**: Command syntax changed from flags to actions
  - Old: `./script config-file`
  - New: `./script push config-file`
- **BREAKING**: Removed backup and restore functionality for simplicity
- Help system redesigned with focus on core migration features
- All destructive operations now require user confirmation
- Migration confirmation messages show sync scope (full/db/media)

### Examples
```bash
# Full migration
./script push config-file
./script pull config-file

# Selective sync
./script push db config-file     # Database only
./script pull media config-file  # Media only
```

### Migration Guide
- `./script config` → `./script push config`
- `./script --reverse config` → `./script pull config`
- Add `-y` flag for automation: `./script push -y config`

## [1.1.0] - 2024-12-15

### Added
- Comprehensive logging system with timestamped log files
- Lock file management to prevent concurrent migrations
- Pre-flight validation for disk space and write permissions
- Stale lock detection and automatic cleanup
- Enhanced error tracking with detailed operation logs

### Changed
- All operations now logged to both console and file
- Migration process includes safety checks before execution
- Improved error handling with better context information

### Security
- Lock files prevent conflicting migration processes
- Write permission validation before making changes

## [1.0.0] - 2024-12-15

### Added
- Initial WordPress migration script with rclone and WP-CLI
- Wizard-driven configuration setup
- Bidirectional sync (local ↔ remote)
- WP-CLI database operations (export/import/URL replacement)
- Dry-run mode for safe testing
- SSH key and password authentication support
- Compatibility with standard WordPress, WordOps, and Bedrock setups
- Comprehensive documentation and contributing guidelines