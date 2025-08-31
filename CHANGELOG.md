# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Backup functionality with timestamped directories
- Dry-run mode for safe testing
- SSH key and password authentication support
- Compatibility with standard WordPress, WordOps, and Bedrock setups
- Comprehensive documentation and contributing guidelines