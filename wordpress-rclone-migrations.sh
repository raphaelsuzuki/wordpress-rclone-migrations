#!/bin/bash

# WordPress Migration Script with rclone and SSH
# Version: 2.0.0
# Usage: ./script [push|pull] [subcommand] [options] [config-file]
# No args: Run migration wizard to create config

set -Eeuo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wordpress-rclone-migrations"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"

# Create temp directory with secure permissions
OLD_UMASK=$(umask)
umask 077
TEMP_DIR="$(mktemp -d)"
umask "$OLD_UMASK"

ACTION=""
SUBCOMMAND=""
SKIP_CONFIRMATION=false
DRY_RUN=false
REVERSE=false

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
    local exit_code=$?
    remove_lock_dir
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    [[ -n "$LOG_FILE" ]] && log_to_file "INFO" "=== WordPress Migration Ended with exit code: $exit_code ==="
}

# Error handler for unexpected failures
error_handler() {
    local line_no=$1
    local error_code=$2
    log_error "Unexpected error on line $line_no (exit code: $error_code)"
    log_error "Cleaning up..."
    
    # Try to remove temp files but keep lock for debugging
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    
    if [[ -n "$LOG_FILE" ]]; then
        log_to_file "ERROR" "Script failed on line $line_no with exit code $error_code"
        log_to_file "INFO" "Check log file for details: $LOG_FILE"
    fi
    
    exit "$error_code"
}

trap cleanup EXIT
trap 'error_handler $LINENO $?' ERR

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

validate_paths_exist() {
    local src_path="$1"
    local dest_path="$2"
    local src_ssh_host="$3"
    local dest_ssh_host="$4"
    local src_ssh_user="$5"
    local dest_ssh_user="$6"
    local src_ssh_key="$7"
    local dest_ssh_key="$8"
    local src_use_ssh_key="$9"
    local dest_use_ssh_key="${10}"
    local src_ssh_pass="${11}"
    local dest_ssh_pass="${12}"
    
    log_info "Validating source and destination paths exist"
    
    # Check source path
    if [[ -n "$src_ssh_host" ]]; then
        if [[ "$src_use_ssh_key" == "true" ]]; then
            if ! ssh -i "$src_ssh_key" "$src_ssh_user@$src_ssh_host" "test -d '$src_path'" &>/dev/null; then
                log_error "Source path does not exist: $src_ssh_host:$src_path"
                return 1
            fi
        else
            if ! SSHPASS="$src_ssh_pass" sshpass -e ssh "$src_ssh_user@$src_ssh_host" "test -d '$src_path'" &>/dev/null; then
                log_error "Source path does not exist: $src_ssh_host:$src_path"
                return 1
            fi
        fi
    else
        if [[ ! -d "$src_path" ]]; then
            log_error "Source path does not exist: $src_path"
            return 1
        fi
    fi
    
    # Check destination path
    if [[ -n "$dest_ssh_host" ]]; then
        if [[ "$dest_use_ssh_key" == "true" ]]; then
            if ! ssh -i "$dest_ssh_key" "$dest_ssh_user@$dest_ssh_host" "test -d '$dest_path'" &>/dev/null; then
                log_error "Destination path does not exist: $dest_ssh_host:$dest_path"
                return 1
            fi
        else
            if ! SSHPASS="$dest_ssh_pass" sshpass -e ssh "$dest_ssh_user@$dest_ssh_host" "test -d '$dest_path'" &>/dev/null; then
                log_error "Destination path does not exist: $dest_ssh_host:$dest_path"
                return 1
            fi
        fi
    else
        if [[ ! -d "$dest_path" ]]; then
            log_error "Destination path does not exist: $dest_path"
            return 1
        fi
    fi
    
    log_success "Path validation passed"
    return 0
}

run_preflight_checks() {
    log_info "Running pre-flight validation checks..."
    
    # Estimate required space (conservative: 1GB for safety)
    local required_space_mb=1024
    
    # Determine source and destination based on action
    local check_src_wp_root check_dest_wp_root
    local check_src_wp_content check_dest_wp_content
    local check_src_ssh_host check_dest_ssh_host
    local check_src_ssh_user check_dest_ssh_user
    local check_src_ssh_key check_dest_ssh_key
    local check_src_use_ssh_key check_dest_use_ssh_key
    local check_src_ssh_pass check_dest_ssh_pass
    
    if [[ "$ACTION" == "pull" ]]; then
        # Pull: remote -> local
        check_src_wp_root="$dest_wp_root"
        check_dest_wp_root="$src_wp_root"
        check_src_wp_content="$dest_wp_content"
        check_dest_wp_content="$src_wp_content"
        check_src_ssh_host="$dest_ssh_host"
        check_dest_ssh_host=""
        check_src_ssh_user="$dest_ssh_user"
        check_dest_ssh_user=""
        check_src_ssh_key="$dest_ssh_key"
        check_dest_ssh_key=""
        check_src_use_ssh_key="$dest_use_ssh_key"
        check_dest_use_ssh_key="false"
        check_src_ssh_pass="${dest_ssh_pass:-}"
        check_dest_ssh_pass=""
        
        if ! validate_disk_space "$src_wp_root" $required_space_mb; then
            return 1
        fi
    else
        # Push: local -> remote
        check_src_wp_root="$src_wp_root"
        check_dest_wp_root="$dest_wp_root"
        check_src_wp_content="$src_wp_content"
        check_dest_wp_content="$dest_wp_content"
        check_src_ssh_host=""
        check_dest_ssh_host="$dest_ssh_host"
        check_src_ssh_user=""
        check_dest_ssh_user="$dest_ssh_user"
        check_src_ssh_key=""
        check_dest_ssh_key="$dest_ssh_key"
        check_src_use_ssh_key="false"
        check_dest_use_ssh_key="$dest_use_ssh_key"
        check_src_ssh_pass=""
        check_dest_ssh_pass="${dest_ssh_pass:-}"
    fi
    
    # Validate paths exist
    if ! validate_paths_exist \
        "$check_src_wp_content" "$check_dest_wp_content" \
        "$check_src_ssh_host" "$check_dest_ssh_host" \
        "$check_src_ssh_user" "$check_dest_ssh_user" \
        "$check_src_ssh_key" "$check_dest_ssh_key" \
        "$check_src_use_ssh_key" "$check_dest_use_ssh_key" \
        "$check_src_ssh_pass" "$check_dest_ssh_pass"; then
        return 1
    fi
    
    # Validate write permissions
    if [[ "$ACTION" == "pull" ]]; then
        if ! validate_permissions "$src_wp_content" "" "" "" "" ""; then
            return 1
        fi
    else
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
                # Check for subcommand (db/media/plugins/themes)
                if [[ $# -gt 0 && ("$1" == "db" || "$1" == "media" || "$1" == "plugins" || "$1" == "themes") ]]; then
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
  plugins           Sync plugins only (plugins directory)
  themes            Sync themes only (themes directory)

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
  $0 push plugins site.dev-to-site.com-a1b2c3d4 # Deploy plugins only
  $0 push themes site.dev-to-site.com-a1b2c3d4  # Deploy themes only
  $0 pull site.dev-to-site.com-a1b2c3d4        # Pull everything
  $0 pull db site.dev-to-site.com-a1b2c3d4     # Pull database only
  $0 pull media site.dev-to-site.com-a1b2c3d4  # Pull media files only
  $0 pull plugins site.dev-to-site.com-a1b2c3d4 # Pull plugins only
  $0 pull themes site.dev-to-site.com-a1b2c3d4  # Pull themes only
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
        log_info "Using SSH key authentication (recommended for security)"
    else
        log_warning "SSH password authentication is less secure than SSH keys"
        log_info "Consider using SSH key authentication for better security"
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
    
    # Custom directory paths (optional)
    echo -e "${BLUE}=== Custom Directory Paths (Optional) ===${NC}"
    echo "Leave blank to use defaults (wp-content/uploads, wp-content/plugins, wp-content/themes)"
    read -p "Source uploads directory: " -e SRC_UPLOADS_CUSTOM
    read -p "Source plugins directory: " -e SRC_PLUGINS_CUSTOM
    read -p "Source themes directory: " -e SRC_THEMES_CUSTOM
    read -p "Destination uploads directory: " -e DEST_UPLOADS_CUSTOM
    read -p "Destination plugins directory: " -e DEST_PLUGINS_CUSTOM
    read -p "Destination themes directory: " -e DEST_THEMES_CUSTOM
    
    # Sync options
    echo -e "${BLUE}=== Sync Options ===${NC}"
    read -p "Exclude patterns (comma-separated): " -e -i "*.log,cache/*,node_modules/*,/.git/*" EXCLUDE_PATTERNS
    read -p "Sync wp-config.php? (true/false): " -e -i "false" SYNC_WP_CONFIG
    read -p "Fix file permissions? (true/false): " -e -i "true" FIX_PERMISSIONS
    read -p "Web server user: " -e -i "www-data" WEB_USER
    read -p "Web server group: " -e -i "www-data" WEB_GROUP
    
    # Generate config filename
    local site_hash=$(generate_hash)
    # Use bash parameter expansion instead of sed
    local src_domain="${SOURCE_URL#*://}"  # Remove protocol
    src_domain="${src_domain%%/*}"          # Remove path
    local dest_domain="${DEST_URL#*://}"
    dest_domain="${dest_domain%%/*}"
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
    
    # Create config file with secure permissions from the start
    OLD_UMASK=$(umask)
    umask 077
    
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
    
    umask "$OLD_UMASK"
    
    # Verify secure permissions (defense in depth)
    chmod 600 "$config_path"
    
    # Add custom paths section if any custom paths were specified
    if [[ -n "$SRC_UPLOADS_CUSTOM" || -n "$SRC_PLUGINS_CUSTOM" || -n "$SRC_THEMES_CUSTOM" || -n "$DEST_UPLOADS_CUSTOM" || -n "$DEST_PLUGINS_CUSTOM" || -n "$DEST_THEMES_CUSTOM" ]]; then
        cat >> "$config_path" << EOF

[paths]
EOF
        [[ -n "$SRC_UPLOADS_CUSTOM" ]] && echo "src_uploads_dir=$SRC_UPLOADS_CUSTOM" >> "$config_path"
        [[ -n "$SRC_PLUGINS_CUSTOM" ]] && echo "src_plugins_dir=$SRC_PLUGINS_CUSTOM" >> "$config_path"
        [[ -n "$SRC_THEMES_CUSTOM" ]] && echo "src_themes_dir=$SRC_THEMES_CUSTOM" >> "$config_path"
        [[ -n "$DEST_UPLOADS_CUSTOM" ]] && echo "dest_uploads_dir=$DEST_UPLOADS_CUSTOM" >> "$config_path"
        [[ -n "$DEST_PLUGINS_CUSTOM" ]] && echo "dest_plugins_dir=$DEST_PLUGINS_CUSTOM" >> "$config_path"
        [[ -n "$DEST_THEMES_CUSTOM" ]] && echo "dest_themes_dir=$DEST_THEMES_CUSTOM" >> "$config_path"
        # Ensure permissions remain secure after append
        chmod 600 "$config_path"
    fi
    
    # Add search and replace section with default URL replacement
    cat >> "$config_path" << EOF

# Search and replace patterns during database migration
# Format: patterns=search_text|replacement_text
# SECURITY: Do not include special characters: \$ \` ; & > < '
# Maximum length: 500 characters per pattern
[search_replace]
patterns=$SOURCE_URL|$DEST_URL
EOF
    
    # Ensure final permissions are secure
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
    
    # Validate config file permissions for security
    local config_perms=$(stat -c %a "$config_path" 2>/dev/null || stat -f %A "$config_path" 2>/dev/null || echo "000")
    if [[ ! "$config_perms" =~ ^[0-7]00$ ]]; then
        log_error "Configuration file has insecure permissions: $config_perms"
        log_error "Config file should not be readable by group or others"
        log_info "Fix with: chmod 600 '$config_path'"
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
                "paths")
                    declare -g "${key}"="$value"
                    ;;
                "search_replace")
                    # Parse pipe-separated search/replace patterns
                    if [[ "$key" == "patterns" ]]; then
                        [[ -z "${search_replace_pairs:-}" ]] && declare -gA search_replace_pairs
                        
                        # Split on pipe character
                        if [[ "$value" == *"|"* ]]; then
                            local search_text="${value%%|*}"
                            local replace_text="${value#*|}"
                            
                            # Basic validation during config loading
                            if [[ ${#search_text} -gt 500 || ${#replace_text} -gt 500 ]]; then
                                log_warning "Skipping oversized search/replace pattern: ${search_text:0:50}..."
                                continue
                            fi
                            
                            search_replace_pairs["$search_text"]="$replace_text"
                        else
                            log_warning "Invalid search/replace pattern format (missing |): $value"
                        fi
                    fi
                    ;;
            esac
        fi
    done < "$config_path"
    
    # Set default paths if not specified in config
    [[ -z "${src_uploads_dir:-}" ]] && src_uploads_dir="$src_wp_content/uploads"
    [[ -z "${src_plugins_dir:-}" ]] && src_plugins_dir="$src_wp_content/plugins"
    [[ -z "${src_themes_dir:-}" ]] && src_themes_dir="$src_wp_content/themes"
    [[ -z "${dest_uploads_dir:-}" ]] && dest_uploads_dir="$dest_wp_content/uploads"
    [[ -z "${dest_plugins_dir:-}" ]] && dest_plugins_dir="$dest_wp_content/plugins"
    [[ -z "${dest_themes_dir:-}" ]] && dest_themes_dir="$dest_wp_content/themes"
    
    # Initialize optional SSH password variables (avoid unbound variable errors)
    [[ -z "${dest_ssh_pass:-}" ]] && dest_ssh_pass=""
    [[ -z "${src_ssh_pass:-}" ]] && src_ssh_pass=""
    [[ -z "${rclone_flags:-}" ]] && rclone_flags="--transfers=4 --checkers=8 --progress"
    [[ -z "${fix_permissions:-}" ]] && fix_permissions="true"
    [[ -z "${sync_wp_config:-}" ]] && sync_wp_config="false"
    
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

# Backup database before migration (for rollback)
backup_database() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local backup_suffix="$7"
    
    log_info "Creating database backup before migration" >&2
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create database backup" >&2
        return 0
    fi
    
    # Store backup outside document root and return absolute path for safe cleanup.
    local backup_file=""
    local backup_tmp_dir="${TMPDIR:-/tmp}"

    if [[ -n "$ssh_host" ]]; then
        local remote_mktemp_cmd="mktemp -p '$backup_tmp_dir' 'database_backup_${backup_suffix}_XXXX.sql.gz'"
        if [[ "$use_ssh_key" == "true" ]]; then
            backup_file=$(ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$remote_mktemp_cmd")
        else
            backup_file=$(SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$remote_mktemp_cmd")
        fi
    else
        backup_file=$(mktemp -p "$backup_tmp_dir" "database_backup_${backup_suffix}_XXXX.sql.gz")
    fi

    local backup_cmd="cd '$wp_root' && wp db export --gzip '$backup_file' >/dev/null"
    
    if [[ -n "$ssh_host" ]]; then
        if [[ "$use_ssh_key" == "true" ]]; then
            ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$backup_cmd"
        else
            SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$backup_cmd"
        fi
    else
        (cd "$wp_root" && wp db export --gzip "$backup_file" >/dev/null)
    fi
    
    log_success "Database backup created: $backup_file" >&2
    printf '%s\n' "$backup_file"
}

# Restore database from backup
restore_database() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local backup_file="$7"
    
    log_warning "Restoring database from backup: $backup_file"
    
    local restore_cmd="cd '$wp_root' && wp db import '$backup_file'"
    
    if [[ -n "$ssh_host" ]]; then
        if [[ "$use_ssh_key" == "true" ]]; then
            ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$restore_cmd"
        else
            SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$restore_cmd"
        fi
    else
        (cd "$wp_root" && wp db import "$backup_file")
    fi
    
    log_success "Database restored from backup"
}

# Remove backup dump after migration completes or rollback finishes.
cleanup_backup_file() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local backup_file="$7"

    [[ -z "$backup_file" || "$DRY_RUN" == "true" ]] && return 0

    local cleanup_cmd="cd '$wp_root' && rm -f '$backup_file'"

    if [[ -n "$ssh_host" ]]; then
        if [[ "$use_ssh_key" == "true" ]]; then
            if ! ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$cleanup_cmd"; then
                log_warning "Could not remove remote backup file: $backup_file"
            fi
        else
            if ! SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$cleanup_cmd"; then
                log_warning "Could not remove remote backup file: $backup_file"
            fi
        fi
    else
        if ! rm -f "$backup_file"; then
            log_warning "Could not remove local backup file: $backup_file"
        fi
    fi
}

# Perform rollback with best-effort backup recopy and guaranteed restore attempt.
rollback_destination_db() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    local backup_file="$7"
    local temp_backup_copy="$8"
    local rclone_remote_name="$9"

    if [[ -n "$ssh_host" && -n "$temp_backup_copy" && -f "$temp_backup_copy" ]]; then
        if ! rclone copy "$temp_backup_copy" "$rclone_remote_name:$(dirname "$backup_file")/"; then
            log_warning "Could not copy local backup cache back to remote; attempting restore from existing remote backup"
        fi
    fi

    if ! restore_database "$wp_root" "$ssh_host" "$ssh_user" "$ssh_key" "$use_ssh_key" "$ssh_pass" "$backup_file"; then
        log_error "Rollback failed: could not restore destination database from backup"
        return 1
    fi

    cleanup_backup_file "$wp_root" "$ssh_host" "$ssh_user" "$ssh_key" "$use_ssh_key" "$ssh_pass" "$backup_file"
    [[ -n "$temp_backup_copy" ]] && rm -f "$temp_backup_copy"

    return 0
}

# Validate search/replace input for security
validate_search_replace_input() {
    local input="$1"
    local type="$2"  # "search" or "replace"
    
    # Check for dangerous characters that could cause command injection
    if [[ "$input" =~ [\$\`\;\&\>\<] ]]; then
        log_error "Invalid character in $type text: $input"
        log_error "Search/replace patterns cannot contain: \$ \` ; & > <"
        return 1
    fi
    
    # Check for single quotes (WP-CLI uses single quotes)
    if [[ "$input" == *"'"* ]]; then
        log_error "Single quotes not allowed in $type text: $input"
        return 1
    fi
    
    # Check length (prevent extremely long inputs)
    if [[ ${#input} -gt 500 ]]; then
        log_error "$type text too long (max 500 characters): $input"
        return 1
    fi
    
    return 0
}

# Replace URLs and other patterns in database using WP-CLI
replace_urls() {
    local wp_root="$1"
    local ssh_host="$2"
    local ssh_user="$3"
    local ssh_key="$4"
    local use_ssh_key="$5"
    local ssh_pass="$6"
    
    log_info "Running search and replace operations"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run search and replace using WP-CLI"
        for search_text in "${!search_replace_pairs[@]}"; do
            local replace_text="${search_replace_pairs[$search_text]}"
            log_info "[DRY RUN] Would replace: $search_text -> $replace_text"
        done
        return 0
    fi
    
    # Process each search/replace pair
    for search_text in "${!search_replace_pairs[@]}"; do
        local replace_text="${search_replace_pairs[$search_text]}"
        
        # Validate inputs for security
        if ! validate_search_replace_input "$search_text" "search"; then
            log_error "Skipping unsafe search pattern: $search_text"
            continue
        fi
        
        if ! validate_search_replace_input "$replace_text" "replace"; then
            log_error "Skipping unsafe replace pattern: $replace_text"
            continue
        fi
        
        log_info "Replacing: $search_text -> $replace_text"
        
        # Use printf to safely escape the command
        local replace_cmd
        printf -v replace_cmd "cd %q && wp search-replace %q %q --skip-columns=guid" "$wp_root" "$search_text" "$replace_text"
        
        if [[ -n "$ssh_host" ]]; then
            # Remote replacement
            if [[ "$use_ssh_key" == "true" ]]; then
                if ! ssh -i "$ssh_key" "$ssh_user@$ssh_host" "$replace_cmd"; then
                    log_error "Remote WP-CLI search-replace failed for: $search_text"
                    return 1
                fi
            else
                if ! SSHPASS="$ssh_pass" sshpass -e ssh "$ssh_user@$ssh_host" "$replace_cmd"; then
                    log_error "Remote WP-CLI search-replace failed for: $search_text"
                    return 1
                fi
            fi
        else
            # Local replacement
            if ! (cd "$wp_root" && wp search-replace "$search_text" "$replace_text" --skip-columns=guid); then
                log_error "Local WP-CLI search-replace failed for: $search_text"
                return 1
            fi
        fi
    done
    
    log_success "All search and replace operations completed"
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
        SRC_UPLOADS="$dest_uploads_dir"
        SRC_PLUGINS="$dest_plugins_dir"
        SRC_THEMES="$dest_themes_dir"
        SRC_SSH_HOST="$dest_ssh_host"
        SRC_SSH_USER="$dest_ssh_user"
        SRC_SSH_KEY="$dest_ssh_key"
        SRC_USE_SSH_KEY="$dest_use_ssh_key"
        SRC_SSH_PASS="${dest_ssh_pass:-}"
        
        DEST_ROOT="$src_wp_root"
        DEST_CONTENT="$src_wp_content"
        DEST_UPLOADS="$src_uploads_dir"
        DEST_PLUGINS="$src_plugins_dir"
        DEST_THEMES="$src_themes_dir"
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
        SRC_UPLOADS="$src_uploads_dir"
        SRC_PLUGINS="$src_plugins_dir"
        SRC_THEMES="$src_themes_dir"
        SRC_SSH_HOST=""
        SRC_SSH_USER=""
        SRC_SSH_KEY=""
        SRC_USE_SSH_KEY=""
        SRC_SSH_PASS=""
        
        DEST_ROOT="$dest_wp_root"
        DEST_CONTENT="$dest_wp_content"
        DEST_UPLOADS="$dest_uploads_dir"
        DEST_PLUGINS="$dest_plugins_dir"
        DEST_THEMES="$dest_themes_dir"
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
        
        # Selective sync: target specific directories
        if [[ "$sync_type" == "media" ]]; then
            src_path="$SRC_UPLOADS"
            if [[ "$REVERSE" == "true" ]]; then
                dest_path="$DEST_UPLOADS"
                sync_files "$dest_rclone_remote:$src_path" "$dest_path"
            else
                dest_path="$DEST_UPLOADS"
                sync_files "$src_path" "$dest_rclone_remote:$dest_path"
            fi
        elif [[ "$sync_type" == "plugins" ]]; then
            src_path="$SRC_PLUGINS"
            if [[ "$REVERSE" == "true" ]]; then
                dest_path="$DEST_PLUGINS"
                sync_files "$dest_rclone_remote:$src_path" "$dest_path"
            else
                dest_path="$DEST_PLUGINS"
                sync_files "$src_path" "$dest_rclone_remote:$dest_path"
            fi
        elif [[ "$sync_type" == "themes" ]]; then
            src_path="$SRC_THEMES"
            if [[ "$REVERSE" == "true" ]]; then
                dest_path="$DEST_THEMES"
                sync_files "$dest_rclone_remote:$src_path" "$dest_path"
            else
                dest_path="$DEST_THEMES"
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
    
    # Database migration (skip if files-only)
    if [[ "$sync_type" != "media" && "$sync_type" != "plugins" && "$sync_type" != "themes" ]]; then
        local db_dump="database.sql.gz"
        local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
        local db_backup_file=""
        local temp_backup_copy=""
        
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
        
        # Create backup of destination database before import (for rollback)
        if [[ "$DRY_RUN" != "true" ]]; then
            db_backup_file=$(backup_database "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS" "$backup_timestamp")
            
            # Transfer backup to local temp for safety
            if [[ -n "$DEST_SSH_HOST" ]]; then
                rclone copy "$dest_rclone_remote:$db_backup_file" "$TEMP_DIR/"
                temp_backup_copy="$TEMP_DIR/$(basename "$db_backup_file")"
            fi
        fi
        
        # Import to destination database and run post-import DB mutations.
        local db_mutation_failed=false
        if ! import_database_wpcli "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS" "$db_dump"; then
            db_mutation_failed=true
        elif ! replace_urls "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS"; then
            db_mutation_failed=true
        fi
        
        # If import/search-replace failed, restore from backup.
        if [[ "$db_mutation_failed" == "true" && "$DRY_RUN" != "true" ]]; then
            log_error "Database import/search-replace failed - attempting rollback"

            if ! rollback_destination_db \
                "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" \
                "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS" "$db_backup_file" \
                "$temp_backup_copy" "$dest_rclone_remote"; then
                exit 1
            fi
            
            log_error "Database restored from backup. Please check the source database and try again."
            exit 1
        fi

        log_success "Database import and search/replace completed"
        
        # Clean up database files
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

            # Remove destination backup dump from success path.
            cleanup_backup_file "$DEST_ROOT" "$DEST_SSH_HOST" "$DEST_SSH_USER" "$DEST_SSH_KEY" "$DEST_USE_SSH_KEY" "$DEST_SSH_PASS" "$db_backup_file"
            [[ -n "$temp_backup_copy" ]] && rm -f "$temp_backup_copy"
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
                log_info "Usage: $0 push [db|media|plugins|themes] <config-file>"
                exit 1
            fi
            load_config
            local sync_desc="everything"
            [[ "$SUBCOMMAND" == "db" ]] && sync_desc="database only"
            [[ "$SUBCOMMAND" == "media" ]] && sync_desc="media files only"
            [[ "$SUBCOMMAND" == "plugins" ]] && sync_desc="plugins only"
            [[ "$SUBCOMMAND" == "themes" ]] && sync_desc="themes only"
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
                log_info "Usage: $0 pull [db|media|plugins|themes] <config-file>"
                exit 1
            fi
            load_config
            local sync_desc="everything"
            [[ "$SUBCOMMAND" == "db" ]] && sync_desc="database only"
            [[ "$SUBCOMMAND" == "media" ]] && sync_desc="media files only"
            [[ "$SUBCOMMAND" == "plugins" ]] && sync_desc="plugins only"
            [[ "$SUBCOMMAND" == "themes" ]] && sync_desc="themes only"
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