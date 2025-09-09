#!/bin/bash

# WordPress Migration Script with rclone and SSH
# Version: 2.0.0
# Usage: ./script [push|pull] [subcommand] [options] [config-file]
# No args: Run migration wizard to create config

set -euo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wordpress-rclone-migrations"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
TEMP_DIR="$(mktemp -d)"
ACTION=""
SUBCOMMAND=""
SKIP_CONFIRMATION=false
DRY_RUN=false

CONFIG_FILE=""
LOG_FILE=""
LOCK_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    remove_lock_dir
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    [[ -n "$LOG_FILE" ]] && log_to_file "INFO" "=== WordPress Migration Ended ==="
}
trap cleanup EXIT

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; log_to_file "INFO" "$1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; log_to_file "SUCCESS" "$1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; log_to_file "WARNING" "$1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; log_to_file "ERROR" "$1"; }

# Enhanced logging functions
log_to_file() {
    local level="$1"
    local message="$2"
    [[ -n "$LOG_FILE" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

setup_logging() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local log_dir="$SCRIPT_DIR/logs"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/migration_$timestamp.log"
    log_to_file "INFO" "=== WordPress Migration Started ==="
    log_to_file "INFO" "Script: $0"
    log_to_file "INFO" "Arguments: $*"
    log_to_file "INFO" "Working Directory: $(pwd)"
    log_to_file "INFO" "User: $(whoami)"
}

# Atomic directory locking
create_lock_dir() {
    local config_name="$1"
    local lock_base_dir="/tmp/wp-migrate-locks"
    LOCK_DIR="$lock_base_dir/${config_name}.lock"
    
    # Ensure lock base directory exists
    mkdir -p "$lock_base_dir"
    
    # Atomic lock creation - mkdir fails if directory exists
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOCK_DIR/timestamp"
        log_info "Created lock directory: $LOCK_DIR (PID: $$)"
    else
        log_error "Migration already running for config: $config_name"
        log_error "Lock directory: $LOCK_DIR"
        # Show lock info if available
        if [[ -f "$LOCK_DIR/pid" ]]; then
            local lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
            local lock_time=$(cat "$LOCK_DIR/timestamp" 2>/dev/null)
            log_error "Lock created by PID $lock_pid at $lock_time"
        fi
        exit 1
    fi
}

remove_lock_dir() {
    if [[ -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR"
        log_info "Removed lock directory: $LOCK_DIR"
    fi
}

# Confirmation function for safety
confirm_operation() {
    local operation="$1"
    local source="$2"
    local destination="$3"
    local warning="$4"
    
    if [[ "$SKIP_CONFIRMATION" == "true" ]]; then
        log_info "Skipping confirmation (-y flag)"
        return 0
    fi
    
    echo -e "\n${operation} CONFIRMATION"
    echo "==================="
    echo "Source:      $source"
    echo "Destination: $destination"
    echo -e "\nWARNING: $warning"
    echo
    read -p "Continue? [y/N]: " -r
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        log_info "Operation cancelled by user"
        exit 0
    fi
}

# Pre-flight validation
validate_disk_space() {
    local path="$1"
    local required_mb="$2"
    
    log_info "Checking disk space for: $path"
    
    if [[ ! -d "$(dirname "$path")" ]]; then
        log_error "Directory does not exist: $(dirname "$path")"
        return 1
    fi
    
    local available_kb=$(df "$(dirname "$path")" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    log_info "Available space: ${available_mb}MB, Required: ${required_mb}MB"
    
    if [[ $available_mb -lt $required_mb ]]; then
        log_error "Insufficient disk space. Available: ${available_mb}MB, Required: ${required_mb}MB"
        return 1
    fi
    
    log_success "Disk space validation passed"
    return 0
}

validate_permissions() {
    local path="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    
    log_info "Validating write permissions for: $path"
    
    local test_file="$path/.wp-migration-test-$$"
    local test_cmd="touch '$test_file' && rm -f '$test_file'"
    
    if [[ -n "$ssh_host" ]]; then
        # Remote permission test
        if [[ "$use_ssh_key" == "true" ]]; then
            if ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$test_cmd" &>/dev/null; then
                log_success "Remote write permissions validated"
                return 0
            fi
        else
            if SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$test_cmd" &>/dev/null; then
                log_success "Remote write permissions validated"
                return 0
            fi
        fi
        log_error "No write permission for remote path: $path"
        return 1
    else
        # Local permission test
        if touch "$test_file" && rm -f "$test_file" &>/dev/null; then
            log_success "Local write permissions validated"
            return 0
        else
            log_error "No write permission for local path: $path"
            return 1
        fi
    fi
}

run_preflight_checks() {
    log_info "Running pre-flight validation checks..."
    
    # Estimate required space (conservative: 1GB for safety)
    local required_space_mb=1024
    
    if [[ "$ACTION" == "pull" ]]; then
        # Pull operation: check local space and permissions
        if ! validate_disk_space "$src_wp_root" $required_space_mb; then
            return 1
        fi
        if ! validate_permissions "$src_wp_content" "" "" "" "" ""; then
            return 1
        fi
    else
        # Push operation: check remote space and permissions
        if ! validate_permissions "$dest_wp_content" "$dest_ssh_host" "$dest_ssh_user" "$dest_ssh_key" "$dest_use_ssh_key" "${dest_ssh_pass:-}"; then
            return 1
        fi
    fi
    
    log_success "All pre-flight checks passed"
    return 0
}

# Parse command line arguments
parse_args() {
    # First argument is the action (if provided)
    if [[ $# -gt 0 ]]; then
        case $1 in
            push|pull)
                ACTION="$1"
                shift
                # Check for subcommand (db/media)
                if [[ $# -gt 0 && ("$1" == "db" || "$1" == "media") ]]; then
                    SUBCOMMAND="$1"
                    shift
                fi
                ;;
            help|-h|--help)
                show_help
                exit 0
                ;;
            *)
                # If first arg is not an action, it might be a config file (old usage)
                if [[ -f "$CONFIG_DIR/$1" || "$1" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                    log_error "Old command syntax detected. Please use new syntax:"
                    log_error "  Old: $0 $1"
                    log_error "  New: $0 push $1"
                    log_error "Run '$0 help' for updated usage."
                    exit 1
                else
                    log_error "Unknown command: $1"
                    log_error "Run '$0 help' for usage information."
                    exit 1
                fi
                ;;
        esac
    fi
    
    # Parse remaining options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes)
                SKIP_CONFIRMATION=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;

            --config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$CONFIG_FILE" ]]; then
                    CONFIG_FILE="$1"
                else
                    log_error "Unknown option: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# Show help
show_help() {
    cat << EOF
WordPress Migration Script v2.0.0

Usage:
  $0                                    Run migration wizard (create config)
  $0 <action> [subcommand] [options] <config-file>   Run migration operations

Actions:
  push              Deploy local changes to remote (local → remote)
  pull              Pull remote changes to local (remote → local)

Subcommands:
  db                Sync database only
  media             Sync media files only (uploads directory)

Options:
  -y, --yes         Skip confirmation prompts (for automation)
  --dry-run         Show what would be done without executing
  --config-dir DIR  Use custom config directory
  -h, --help        Show this help message

Examples:
  $0                                    # Create new migration config
  $0 push site.dev-to-site.com-a1b2c3d4        # Deploy everything
  $0 push db site.dev-to-site.com-a1b2c3d4     # Deploy database only
  $0 push media site.dev-to-site.com-a1b2c3d4  # Deploy media files only
  $0 pull site.dev-to-site.com-a1b2c3d4        # Pull everything
  $0 pull db site.dev-to-site.com-a1b2c3d4     # Pull database only
  $0 pull media site.dev-to-site.com-a1b2c3d4  # Pull media files only
  $0 push -y --dry-run site.dev-to-site.com-a1b2c3d4  # Preview deployment

Migration workflow:
  1. $0                                 # Create config
  2. $0 push <config>                   # Deploy changes
EOF
}

# Check dependencies
check_dependencies() {
    local deps=("rclone" "ssh" "wp")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Check for sshpass (optional for password auth)
    if ! command -v "sshpass" &> /dev/null; then
        log_warning "sshpass not found - SSH password authentication will not be available"
        log_info "Install sshpass to enable SSH password authentication"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Please install: ${missing[*]}"
        exit 1
    fi
}

# Test SSH connection with key
test_ssh_connection() {
    local host="$1"
    local user="$2"
    local key="$3"
    
    log_info "Testing SSH key connection to $user@$host..."
    
    if ssh -i "$key" -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection successful"
        return 0
    else
        log_error "SSH connection failed"
        return 1
    fi
}

# Test SSH connection with password
test_ssh_password_connection() {
    local host="$1"
    local user="$2"
    local pass="$3"
    
    log_info "Testing SSH password connection to $user@$host..."
    
    if SSHPASS="$pass" sshpass -e ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=yes "$user@$host" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection successful"
        return 0
    else
        log_error "SSH connection failed"
        return 1
    fi
}

# Test rclone remote
test_rclone_remote() {
    local remote="$1"
    
    log_info "Testing rclone remote: $remote"
    
    if rclone lsd "$remote:" --max-depth 1 &>/dev/null; then
        log_success "rclone remote accessible"
        return 0
    else
        log_error "rclone remote test failed"
        return 1
    fi
}

# Test WP-CLI database connection
test_wpcli_connection() {
    local ssh_host="$1"
    local ssh_user="$2"
    local ssh_key="$3"
    local wp_root="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    
    log_info "Testing WP-CLI database connection..."
    
    local test_cmd="cd '$wp_root' && wp db check"
    
    if [[ "$use_ssh_key" == "true" ]]; then
        if ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$test_cmd" &>/dev/null; then
            log_success "WP-CLI database connection successful"
            return 0
        else
            log_error "WP-CLI database connection failed"
            return 1
        fi
    else
        if SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$test_cmd" &>/dev/null; then
            log_success "WP-CLI database connection successful"
            return 0
        else
            log_error "WP-CLI database connection failed"
            return 1
        fi
    fi
}

# Generate random hash
generate_hash() {
    head -c 4 /dev/urandom | xxd -p
}

# Test local WP-CLI database connection
test_local_wpcli_connection() {
    local wp_root="$1"
    
    log_info "Testing local WP-CLI database connection..."
    
    if (cd "$wp_root" && wp db check) &>/dev/null; then
        log_success "Local WP-CLI database connection successful"
        return 0
    else
        log_error "Local WP-CLI database connection failed"
        return 1
    fi
}

# Create rclone remote with SSH key
create_rclone_remote_key() {
    local remote_name="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    
    log_info "Creating rclone remote with SSH key: $remote_name"
    
    rclone config create "$remote_name" sftp \
        host="$ssh_host" \
        user="$ssh_user" \
        key_file="$ssh_key" \
        shell_type="unix" \
        md5sum_command="md5sum" \
        sha1sum_command="sha1sum" \
        set_modtime="false" \
        &>/dev/null
    
    log_success "rclone remote created: $remote_name"
}

# Create rclone remote with SSH password
create_rclone_remote_password() {
    local remote_name="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_pass="$4"
    
    log_info "Creating rclone remote with SSH password: $remote_name"
    
    rclone config create "$remote_name" sftp \
        host="$ssh_host" \
        user="$ssh_user" \
        pass="$(rclone obscure "$ssh_pass")" \
        shell_type="unix" \
        md5sum_command="md5sum" \
        sha1sum_command="sha1sum" \
        set_modtime="false" \
        &>/dev/null
    
    log_success "rclone remote created: $remote_name"
}

# Wizard mode - create migration config
run_wizard() {
    log_info "WordPress Migration Wizard"
    echo
    
    # Create configs directory
    if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        log_warning "Cannot create config directory: $CONFIG_DIR"
        log_info "Falling back to local configs directory"
        CONFIG_DIR="$SCRIPT_DIR/configs"
        mkdir -p "$CONFIG_DIR"
    fi
    
    log_info "Using config directory: $CONFIG_DIR"
    
    # Collect source information
    echo -e "${BLUE}=== SOURCE (Local) Configuration ===${NC}"
    read -p "WordPress root path: " -e -i "/var/www/html" SRC_WP_ROOT
    read -p "wp-content path: " -e -i "$SRC_WP_ROOT/wp-content" SRC_WP_CONTENT
    read -p "wp-config.php path: " -e -i "$SRC_WP_ROOT/wp-config.php" SRC_WP_CONFIG
    
    # Test local WP-CLI database connection
    if ! test_local_wpcli_connection "$SRC_WP_ROOT"; then
        log_error "Local WP-CLI database connection failed. Check wp-config.php and WordPress installation."
        exit 1
    fi
    
    # Collect destination information
    echo -e "${BLUE}=== DESTINATION (Remote) Configuration ===${NC}"
    read -p "SSH hostname: " DEST_SSH_HOST
    read -p "SSH username: " DEST_SSH_USER
    read -p "Use SSH key authentication? (true/false): " -e -i "true" USE_SSH_KEY
    
    if [[ "$USE_SSH_KEY" == "true" ]]; then
        read -p "SSH key path: " -e -i "$HOME/.ssh/id_rsa" DEST_SSH_KEY
        DEST_SSH_PASS=""
    else
        read -p "SSH password: " -s DEST_SSH_PASS
        echo
        DEST_SSH_KEY=""
    fi
    
    read -p "Remote WordPress root: " DEST_WP_ROOT
    read -p "Remote wp-content path: " -e -i "$DEST_WP_ROOT/wp-content" DEST_WP_CONTENT
    read -p "Remote wp-config.php path: " -e -i "$DEST_WP_ROOT/wp-config.php" DEST_WP_CONFIG
    
    # Test SSH connection
    if [[ "$USE_SSH_KEY" == "true" ]]; then
        if ! test_ssh_connection "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY"; then
            log_error "SSH connection failed. Please check credentials and key."
            exit 1
        fi
    else
        if ! test_ssh_password_connection "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_PASS"; then
            log_error "SSH connection failed. Please check credentials."
            exit 1
        fi
    fi
    
    # Test remote WP-CLI database connection
    if ! test_wpcli_connection "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_WP_ROOT" "$USE_SSH_KEY" "$DEST_SSH_PASS"; then
        log_error "Remote WP-CLI database connection failed. Check wp-config.php and WordPress installation."
        exit 1
    fi
    
    # URL configuration
    echo -e "${BLUE}=== URL Configuration ===${NC}"
    read -p "Source URL (e.g., https://site.dev): " SOURCE_URL
    read -p "Destination URL (e.g., https://site.com): " DEST_URL
    
    # Sync options
    echo -e "${BLUE}=== Sync Options ===${NC}"
    read -p "Exclude patterns (comma-separated): " -e -i "*.log,cache/*,node_modules/*,/.git/*" EXCLUDE_PATTERNS
    read -p "Sync wp-config.php? (true/false): " -e -i "false" SYNC_WP_CONFIG
    read -p "Fix file permissions? (true/false): " -e -i "true" FIX_PERMISSIONS
    read -p "Web server user: " -e -i "www-data" WEB_USER
    read -p "Web server group: " -e -i "www-data" WEB_GROUP
    
    # Generate config filename
    local site_hash=$(generate_hash)
    local src_domain=$(echo "$SOURCE_URL" | sed 's|https\?://||' | sed 's|/.*||')
    local dest_domain=$(echo "$DEST_URL" | sed 's|https\?://||' | sed 's|/.*||')
    CONFIG_FILE="$src_domain-to-$dest_domain-$site_hash"
    local config_path="$CONFIG_DIR/$CONFIG_FILE"
    
    # Create rclone remote
    local rclone_remote="wp-$site_hash"
    if [[ "$USE_SSH_KEY" == "true" ]]; then
        create_rclone_remote_key "$rclone_remote" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY"
    else
        create_rclone_remote_password "$rclone_remote" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_PASS"
    fi
    
    # Test rclone remote
    if ! test_rclone_remote "$rclone_remote"; then
        log_error "rclone remote test failed"
        exit 1
    fi
    
    # Create config file (without database credentials)
    cat > "$config_path" << EOF
# WordPress Migration Configuration
# Generated: $(date)
# Database credentials are extracted from wp-config.php files

[source]
wp_root=$SRC_WP_ROOT
wp_content=$SRC_WP_CONTENT
wp_config=$SRC_WP_CONFIG

[destination]
ssh_host=$DEST_SSH_HOST
ssh_user=$DEST_SSH_USER
ssh_key=$DEST_SSH_KEY
use_ssh_key=$USE_SSH_KEY
rclone_remote=$rclone_remote
wp_root=$DEST_WP_ROOT
wp_content=$DEST_WP_CONTENT
wp_config=$DEST_WP_CONFIG

[urls]
source_url=$SOURCE_URL
destination_url=$DEST_URL

[options]
exclude=$EXCLUDE_PATTERNS
sync_wp_config=${SYNC_WP_CONFIG:-false}
fix_permissions=${FIX_PERMISSIONS:-true}
web_user=$WEB_USER
web_group=$WEB_GROUP
rclone_flags=--transfers=4 --checkers=8 --progress
last_sync=never
EOF
    
    # Set secure permissions
    chmod 600 "$config_path"
    
    log_success "Configuration saved: $CONFIG_FILE"
    log_info "Config location: $config_path"
    echo
    log_info "To run migration:"
    echo "  $0 $CONFIG_FILE"
    echo
    log_info "To pull changes from remote:"
    echo "  $0 --reverse $CONFIG_FILE"
    echo
    log_info "To preview changes:"
    echo "  $0 --dry-run $CONFIG_FILE"
}

# Load configuration file
load_config() {
    local config_path="$CONFIG_DIR/$CONFIG_FILE"
    
    if [[ ! -f "$config_path" ]]; then
        log_error "Configuration file not found: $config_path"
        exit 1
    fi
    
    # Parse INI-style config file
    local section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Check for section headers
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Parse key=value pairs
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Create variables with section prefix
            case "$section" in
                "source")
                    declare -g "src_${key}"="$value"
                    ;;
                "destination")
                    declare -g "dest_${key}"="$value"
                    ;;
                "urls")
                    declare -g "${key}"="$value"
                    ;;
                "options")
                    declare -g "${key}"="$value"
                    ;;
            esac
        fi
    done < "$config_path"
    
    log_info "Loaded configuration: $CONFIG_FILE"
    
    # Test WP-CLI database connections
    log_info "Testing WP-CLI database connections..."
    
    # Test local WP-CLI connection
    if ! test_local_wpcli_connection "$src_wp_root"; then
        log_error "Local WP-CLI database connection failed"
        exit 1
    fi
    
    # Test remote WP-CLI connection
    if ! test_wpcli_connection "$dest_ssh_host" "$dest_ssh_user" "$dest_ssh_key" "$dest_wp_root" "$dest_use_ssh_key" "${dest_ssh_pass:-}"; then
        log_error "Remote WP-CLI database connection failed"
        exit 1
    fi
}

# Sync files using rclone
sync_files() {
    local src="$1"
    local dest="$2"
    local exclude_file="$TEMP_DIR/exclude.txt"
    
    # Create exclude file
    echo "$exclude" | tr ',' '\n' > "$exclude_file"
    
    # Add wp-config.php to exclude if not syncing
    if [[ "${sync_wp_config:-false}" != "true" ]]; then
        echo "wp-config.php" >> "$exclude_file"
    fi
    
    log_info "Syncing files: $src -> $dest"
    
    local rclone_cmd="rclone sync"
    [[ "$DRY_RUN" == "true" ]] && rclone_cmd="rclone sync --dry-run"
    
    $rclone_cmd "$src" "$dest" \
        --exclude-from "$exclude_file" \
        --update \
        --checksum \
        $rclone_flags
    
    log_success "File sync completed"
}

# Export database using WP-CLI
export_database_wpcli() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local output_file="$7"
    
    log_info "Exporting database using WP-CLI"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would export database to: $output_file"
        return 0
    fi
    
    local export_cmd="cd '$wp_root' && wp db export --gzip '$output_file'"
    
    if [[ -n "$ssh_host" ]]; then
        # Remote export
        if [[ "$use_ssh_key" == "true" ]]; then
            ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$export_cmd"
        else
            SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$export_cmd"
        fi
    else
        # Local export
        (cd "$wp_root" && wp db export --gzip "$output_file")
    fi
    
    log_success "Database exported successfully"
}

# Import database using WP-CLI
import_database_wpcli() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local input_file="$7"
    
    log_info "Importing database using WP-CLI"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would import database from: $input_file"
        return 0
    fi
    
    local import_cmd="cd '$wp_root' && wp db import '$input_file'"
    
    if [[ -n "$ssh_host" ]]; then
        # Remote import
        if [[ "$use_ssh_key" == "true" ]]; then
            ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$import_cmd"
        else
            SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$import_cmd"
        fi
    else
        # Local import
        (cd "$wp_root" && wp db import "$input_file")
    fi
    
    log_success "Database imported successfully"
}

# Replace URLs in database using WP-CLI
replace_urls() {
    local wp_root="$1"
    local old_url="$2"
    local new_url="$3"
    local ssh_host="$4"
    local ssh_user="$5"
    local ssh_key="$6"
    local use_ssh_key="$7"
    local ssh_pass="$8"
    
    log_info "Replacing URLs: $old_url -> $new_url"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would replace URLs using WP-CLI"
        return 0
    fi
    
    local replace_cmd="cd '$wp_root' && wp search-replace '$old_url' '$new_url' --skip-columns=guid"
    
    if [[ -n "$ssh_host" ]]; then
        # Remote URL replacement
        if [[ "$use_ssh_key" == "true" ]]; then
            if ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$replace_cmd"; then
                log_success "URL replacement completed using remote WP-CLI"
            else
                log_error "Remote WP-CLI search-replace failed"
                return 1
            fi
        else
            if SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$replace_cmd"; then
                log_success "URL replacement completed using remote WP-CLI"
            else
                log_error "Remote WP-CLI search-replace failed"
                return 1
            fi
        fi
    else
        # Local URL replacement
        if (cd "$wp_root" && wp search-replace "$old_url" "$new_url" --skip-columns=guid); then
            log_success "URL replacement completed using local WP-CLI"
        else
            log_error "Local WP-CLI search-replace failed"
            return 1
        fi
    fi
}

# Fix file permissions
fix_file_permissions() {
    local remote_path="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local web_user="$5"
    local web_group="$6"
    
    log_info "Fixing file permissions on remote server"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would fix file permissions"
        return 0
    fi
    
    ssh -i "$ssh_key" "$ssh_user@$ssh_host" "
        sudo chown -R $web_user:$web_group '$remote_path'
        find '$remote_path' -type d -exec chmod 755 {} \;
        find '$remote_path' -type f -exec chmod 644 {} \;
    "
    
    log_success "File permissions fixed"
}

# Update last sync timestamp
update_last_sync() {
    local config_path="$CONFIG_DIR/$CONFIG_FILE"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    sed -i "s/last_sync=.*/last_sync=$timestamp/" "$config_path"
}

# Main migration function
run_migration() {
    local sync_type="full"
    [[ -n "$SUBCOMMAND" ]] && sync_type="$SUBCOMMAND"
    
    log_info "Starting WordPress migration ($sync_type)"
    [[ "$REVERSE" == "true" ]] && log_info "Running in REVERSE mode"
    [[ "$DRY_RUN" == "true" ]] && log_info "Running in DRY RUN mode"
    
    # Set source and destination based on reverse flag
    if [[ "$REVERSE" == "true" ]]; then
        # Reverse: remote -> local
        SRC_ROOT="$dest_wp_root"
        SRC_CONTENT="$dest_wp_content"
        SRC_SSH_HOST="$dest_ssh_host"
        SRC_SSH_USER="$dest_ssh_user"
        SRC_SSH_KEY="$dest_ssh_key"
        SRC_USE_SSH_KEY="$dest_use_ssh_key"
        SRC_SSH_PASS="${dest_ssh_pass:-}"
        
        DEST_ROOT="$src_wp_root"
        DEST_CONTENT="$src_wp_content"
        DEST_SSH_HOST=""
        DEST_SSH_USER=""
        DEST_SSH_KEY=""
        DEST_USE_SSH_KEY=""
        DEST_SSH_PASS=""
        
        OLD_URL="$destination_url"
        NEW_URL="$source_url"
    else
        # Normal: local -> remote
        SRC_ROOT="$src_wp_root"
        SRC_CONTENT="$src_wp_content"
        SRC_SSH_HOST=""
        SRC_SSH_USER=""
        SRC_SSH_KEY=""
        SRC_USE_SSH_KEY=""
        SRC_SSH_PASS=""
        
        DEST_ROOT="$dest_wp_root"
        DEST_CONTENT="$dest_wp_content"
        DEST_SSH_HOST="$dest_ssh_host"
        DEST_SSH_USER="$dest_ssh_user"
        DEST_SSH_KEY="$dest_ssh_key"
        DEST_USE_SSH_KEY="$dest_use_ssh_key"
        DEST_SSH_PASS="${dest_ssh_pass:-}"
        
        OLD_URL="$source_url"
        NEW_URL="$destination_url"
    fi
    
    # File synchronization (skip if db-only)
    if [[ "$sync_type" != "db" ]]; then
        local src_path="$SRC_CONTENT"
        local dest_path="$DEST_CONTENT"
        
        # Media-only sync: target uploads directory
        if [[ "$sync_type" == "media" ]]; then
            src_path="$SRC_CONTENT/uploads"
            if [[ "$REVERSE" == "true" ]]; then
                dest_path="$DEST_CONTENT/uploads"
                sync_files "$dest_rclone_remote:$src_path" "$dest_path"
            else
                dest_path="$DEST_CONTENT/uploads"
                sync_files "$src_path" "$dest_rclone_remote:$dest_path"
            fi
        else
            # Full file sync
            if [[ "$REVERSE" == "true" ]]; then
                sync_files "$dest_rclone_remote:$src_path" "$dest_path"
            else
                sync_files "$src_path" "$dest_rclone_remote:$dest_path"
            fi
        fi
    fi
    
    # Database migration (skip if media-only)
    if [[ "$sync_type" != "media" ]]; then
        local db_dump="database.sql.gz"
        
        # Export source database
        export_database_wpcli "$SRC_ROOT" "$SRC_SSH_HOST" "$SRC_SSH_USER" "$SRC_SSH_KEY" "$SRC_USE_SSH_KEY" "$SRC_SSH_PASS" "$db_dump"
        
        # Transfer database file if needed
        if [[ "$REVERSE" == "true" ]]; then
            # Transfer from remote to local
            rclone copy "$dest_rclone_remote:$db_dump" "$TEMP_DIR/"
            mv "$TEMP_DIR/$db_dump" "$DEST_ROOT/$db_dump"
        else
            # Transfer from local to remote
            rclone copy "$SRC_ROOT/$db_dump" "$dest_rclone_remote:"
        fi
        
        # Import to destination database
        import_database_wpcli "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS" "$db_dump"
        
        # Replace URLs using WP-CLI
        replace_urls "$DEST_ROOT" "$OLD_URL" "$NEW_URL" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS"
        
        # Clean up database file
        if [[ "$DRY_RUN" != "true" ]]; then
            if [[ -n "$DEST_SSH_HOST" ]]; then
                # Remove from remote server
                if [[ "$DEST_USE_SSH_KEY" == "true" ]]; then
                    ssh -i "$DEST_SSH_KEY" "$DEST_SSH_USER@$DEST_SSH_HOST" "rm -f '$DEST_ROOT/$db_dump'"
                else
                    SSHPASS="$DEST_SSH_PASS" sshpass -e ssh "$DEST_SSH_USER@$DEST_SSH_HOST" "rm -f '$DEST_ROOT/$db_dump'"
                fi
            else
                # Remove from local
                rm -f "$DEST_ROOT/$db_dump"
            fi
            
            # Remove from source if local
            [[ -z "$SRC_SSH_HOST" ]] && rm -f "$SRC_ROOT/$db_dump"
        fi
    fi
    
    # Fix permissions (only for normal migration to remote and not db-only)
    if [[ "$REVERSE" == "false" && "${fix_permissions:-true}" == "true" && "$sync_type" != "db" ]]; then
        fix_file_permissions "$DEST_ROOT" "$dest_ssh_host" "$dest_ssh_user" "$dest_ssh_key" "$web_user" "$web_group"
    fi
    
    # Update last sync timestamp
    [[ "$DRY_RUN" == "false" ]] && update_last_sync
    
    log_success "Migration ($sync_type) completed successfully!"
}



# Main function
main() {
    parse_args "$@"
    setup_logging "$@"
    check_dependencies
    
    case "$ACTION" in
        "")
            # No action specified - run migration wizard
            run_wizard
            ;;
        "push")
            # Push: local → remote migration
            if [[ -z "$CONFIG_FILE" ]]; then
                log_error "Config file required for push operation"
                log_info "Usage: $0 push [db|media] <config-file>"
                exit 1
            fi
            load_config
            local sync_desc="everything"
            [[ "$SUBCOMMAND" == "db" ]] && sync_desc="database only"
            [[ "$SUBCOMMAND" == "media" ]] && sync_desc="media files only"
            confirm_operation "PUSH" "Local WordPress ($src_wp_root) - $sync_desc" "$dest_ssh_host:$dest_wp_root" "This will overwrite remote WordPress data!"
            create_lock_dir "$(basename "$CONFIG_FILE")"
            if run_preflight_checks; then
                run_migration
            else
                log_error "Pre-flight checks failed. Push aborted."
                exit 1
            fi
            ;;
        "pull")
            # Pull: remote → local migration
            if [[ -z "$CONFIG_FILE" ]]; then
                log_error "Config file required for pull operation"
                log_info "Usage: $0 pull [db|media] <config-file>"
                exit 1
            fi
            load_config
            local sync_desc="everything"
            [[ "$SUBCOMMAND" == "db" ]] && sync_desc="database only"
            [[ "$SUBCOMMAND" == "media" ]] && sync_desc="media files only"
            confirm_operation "PULL" "$dest_ssh_host:$dest_wp_root - $sync_desc" "Local WordPress ($src_wp_root)" "This will overwrite local WordPress data!"
            create_lock_dir "$(basename "$CONFIG_FILE")"
            # Set reverse flag for pull operation
            REVERSE=true
            if run_preflight_checks; then
                run_migration
            else
                log_error "Pre-flight checks failed. Pull aborted."
                exit 1
            fi
            ;;

        *)
            log_error "Unknown action: $ACTION"
            log_info "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
}

# Run main function
main "$@"