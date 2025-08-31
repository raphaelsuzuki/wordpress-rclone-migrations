#!/bin/bash

# WordPress Migration Script with rclone and SSH
# Usage: ./wordpress-migrate.sh [--reverse] [--dry-run] [config-file]
# No args: Run wizard to create config

set -euo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wordpress-rclone-migrations"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
TEMP_DIR="/tmp/wp-migrate-$$"
REVERSE=false
DRY_RUN=false
BACKUP=false
BACKUP_DIR=""
CONFIG_FILE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --reverse)
                REVERSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
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
                CONFIG_FILE="$1"
                shift
                ;;
        esac
    done
}

# Show help
show_help() {
    cat << EOF
WordPress Migration Script

Usage:
  $0                           Run wizard to create migration config
  $0 [options] <config-file>   Run migration with existing config

Options:
  --reverse         Pull changes from remote to local
  --dry-run         Show what would be done without executing
  --backup          Create timestamped backup of remote site (files + database)
  --backup-dir DIR  Specify backup directory (default: ./backups)
  --config-dir DIR  Use custom config directory (default: ~/.config/wordpress-rclone-migrations)
  -h, --help        Show this help message

Examples:
  $0                                    # Create new migration config
  $0 site.dev-to-site.com-a1b2c3d4     # Run migration
  $0 --reverse site.dev-to-site.com-a1b2c3d4  # Pull from remote
  $0 --dry-run site.dev-to-site.com-a1b2c3d4  # Preview changes
  $0 --backup site.dev-to-site.com-a1b2c3d4   # Create backup
  $0 --backup --backup-dir /backups site.dev-to-site.com-a1b2c3d4  # Custom backup location
  $0 --config-dir ./configs site.dev-to-site.com-a1b2c3d4  # Use local configs
EOF
}

# Check dependencies
check_dependencies() {
    local deps=("rclone" "ssh")
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
    
    # Check for WP-CLI (required for database operations)
    if ! command -v "wp" &> /dev/null; then
        log_warning "WP-CLI not found locally - ensure it's installed on both source and destination servers"
        log_info "Install WP-CLI locally for local WordPress operations"
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
    
    if sshpass -p "$pass" ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=yes "$user@$host" "echo 'SSH connection successful'" &>/dev/null; then
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
        if sshpass -p "$ssh_pass" ssh "$ssh_user@$ssh_host" "$test_cmd" &>/dev/null; then
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
            sshpass -p "$ssh_pass" ssh "$ssh_user@$ssh_host" "$export_cmd"
        fi
    else
        # Local export
        eval "$export_cmd"
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
            sshpass -p "$ssh_pass" ssh "$ssh_user@$ssh_host" "$import_cmd"
        fi
    else
        # Local import
        eval "$import_cmd"
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
            if sshpass -p "$ssh_pass" ssh "$ssh_user@$ssh_host" "$replace_cmd"; then
                log_success "URL replacement completed using remote WP-CLI"
            else
                log_error "Remote WP-CLI search-replace failed"
                return 1
            fi
        fi
    else
        # Local URL replacement
        if eval "$replace_cmd"; then
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
    log_info "Starting WordPress migration"
    [[ "$REVERSE" == "true" ]] && log_info "Running in REVERSE mode"
    [[ "$DRY_RUN" == "true" ]] && log_info "Running in DRY RUN mode"
    
    # Create temp directory
    mkdir -p "$TEMP_DIR"
    
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
        
        # File sync: remote -> local
        sync_files "$dest_rclone_remote:$SRC_CONTENT" "$DEST_CONTENT"
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
        
        # File sync: local -> remote
        sync_files "$SRC_CONTENT" "$dest_rclone_remote:$DEST_CONTENT"
    fi
    
    # Database migration using WP-CLI
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
                sshpass -p "$DEST_SSH_PASS" ssh "$DEST_SSH_USER@$DEST_SSH_HOST" "rm -f '$DEST_ROOT/$db_dump'"
            fi
        else
            # Remove from local
            rm -f "$DEST_ROOT/$db_dump"
        fi
        
        # Remove from source if local
        [[ -z "$SRC_SSH_HOST" ]] && rm -f "$SRC_ROOT/$db_dump"
    fi
    
    # Fix permissions (only for normal migration to remote)
    if [[ "$REVERSE" == "false" && "${fix_permissions:-true}" == "true" ]]; then
        fix_file_permissions "$DEST_ROOT" "$dest_ssh_host" "$dest_ssh_user" "$dest_ssh_key" "$web_user" "$web_group"
    fi
    
    # Update last sync timestamp
    [[ "$DRY_RUN" == "false" ]] && update_last_sync
    
    log_success "Migration completed successfully!"
}

# Backup function - creates timestamped backup of remote site
run_backup() {
    log_info "Starting WordPress backup from remote server"
    [[ "$DRY_RUN" == "true" ]] && log_info "Running in DRY RUN mode"
    
    # Create backup directory with timestamp
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local base_backup_dir="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
    local backup_dir="$base_backup_dir/$(basename "$CONFIG_FILE")_$timestamp"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$backup_dir"
        log_info "Backup directory: $backup_dir"
    else
        log_info "[DRY RUN] Would create backup directory: $backup_dir"
    fi
    
    # Backup files using rclone
    log_info "Backing up files from remote server..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would backup files: $dest_rclone_remote:$dest_wp_content -> $backup_dir/files"
    else
        rclone copy "$dest_rclone_remote:$dest_wp_content" "$backup_dir/files" \
            --progress \
            --transfers=4 \
            --checkers=8
        log_success "Files backed up to: $backup_dir/files"
    fi
    
    # Backup database using WP-CLI
    log_info "Backing up database from remote server..."
    local db_backup="backup_$timestamp.sql.gz"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would export database to: $backup_dir/$db_backup"
    else
        # Export database on remote server
        export_database_wpcli "$dest_wp_root" "$dest_ssh_host" "$dest_ssh_user" "$dest_ssh_key" "$dest_use_ssh_key" "${dest_ssh_pass:-}" "$db_backup"
        
        # Download database backup
        rclone copy "$dest_rclone_remote:$db_backup" "$backup_dir/"
        
        # Clean up remote database file
        if [[ "$dest_use_ssh_key" == "true" ]]; then
            ssh -i "$dest_ssh_key" "$dest_ssh_user@$dest_ssh_host" "rm -f '$dest_wp_root/$db_backup'"
        else
            sshpass -p "${dest_ssh_pass}" ssh "$dest_ssh_user@$dest_ssh_host" "rm -f '$dest_wp_root/$db_backup'"
        fi
        
        log_success "Database backed up to: $backup_dir/$db_backup"
    fi
    
    # Create backup info file
    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$backup_dir/backup_info.txt" << EOF
WordPress Backup Information
============================
Backup Date: $(date)
Config File: $CONFIG_FILE
Remote Host: $dest_ssh_host
Remote Path: $dest_wp_root
Source URL: $destination_url

Contents:
- files/: WordPress wp-content directory
- $db_backup: Compressed database dump
EOF
        log_success "Backup info saved to: $backup_dir/backup_info.txt"
    fi
    
    log_success "Backup completed successfully!"
    [[ "$DRY_RUN" != "true" ]] && log_info "Backup location: $backup_dir"
}

# Main function
main() {
    parse_args "$@"
    check_dependencies
    
    if [[ -z "$CONFIG_FILE" ]]; then
        # No config file provided - run wizard
        run_wizard
    else
        # Config file provided - run migration or backup
        load_config
        if [[ "$BACKUP" == "true" ]]; then
            run_backup
        else
            run_migration
        fi
    fi
}

# Run main function
main "$@"