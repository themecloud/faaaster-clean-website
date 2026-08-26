#!/bin/bash

#===============================================================================
# WP Checksum Verification & Repair Script
# Verifies checksums for WordPress core and plugins; themes are inventory-only.
# Reinstalls any components that fail checksum verification.
#===============================================================================

set -euo pipefail

# Configuration
DEFAULT_WP_PATH="/app/www"
LOG_FILE="/app/conf/faaaster-clean.log"
DEFAULT_WP_USER="www-data"
WP_USER=""
DRY_RUN=false
VERBOSE=false
FORCE_CLEAN=false
FIX_PERMISSIONS=false

# WP-CLI wrapper to run as the target user with safe defaults
# Skips plugins and themes to avoid executing potentially malicious code
# Works whether running as root or as www-data directly
wp_cli() {
    local current_user
    current_user=$(id -un)

    if [[ "$current_user" == "$WP_USER" ]]; then
        # Already running as the target user, no sudo needed
        wp --skip-plugins --skip-themes "$@"
    else
        # Running as root (or another user), use sudo
        sudo -u "$WP_USER" wp --skip-plugins --skip-themes "$@"
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
is_root() {
    [[ $(id -u) -eq 0 ]]
}

# Run command that requires root privileges (chown, chattr)
# Silently skips if not root
run_as_root() {
    if is_root; then
        "$@"
    else
        # Not root, skip silently (already logged warning at start)
        return 0
    fi
}

# Arrays to track failures
declare -a FAILED_PLUGINS=()
declare -a SKIPPED_PLUGINS=()
CORE_FAILED=false
THEMES_INVENTORIED=0

#===============================================================================
# Functions
#===============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Verify WordPress checksums and repair any mismatched files.

OPTIONS:
    -p, --path PATH       Path to WordPress installation (default: $DEFAULT_WP_PATH)
    -u, --user USER       User to run WP-CLI as and set file ownership (default: $DEFAULT_WP_USER)
                          Common values: www-data (Debian/Ubuntu), apache (CentOS/RHEL),
                          nginx, _www (macOS), or your hosting account username
    -d, --dry-run         Preview actions without making changes
    -v, --verbose         Show detailed output
    -f, --force-clean     Scan and clean critical files (wp-config.php, mu-plugins, etc.)
    --fix-permissions     Fix ownership and permissions on all WP files, plugins, themes
    -h, --help            Show this help message

EXAMPLES:
    $(basename "$0")                      # Run with defaults (user: www-data)
    $(basename "$0") --dry-run            # Preview what would be done
    $(basename "$0") -p /var/www/html     # Specify WordPress path
    $(basename "$0") -u nginx             # Run as nginx user
    $(basename "$0") -u apache -p /var/www/html  # CentOS with custom path
    $(basename "$0") --force-clean        # Also scan/clean critical files
    $(basename "$0") --fix-permissions    # Fix all file permissions first

EOF
    exit 0
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # Write to log file
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true

    # Output to console with colors
    case "$level" in
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} $message"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        DRY-RUN)
            echo -e "${YELLOW}[DRY-RUN]${NC} $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

verbose_log() {
    if [[ "$VERBOSE" == true ]]; then
        log "INFO" "$1"
    fi
}

append_unique() {
    local value="$1"
    shift
    local -n target_array="$1"

    if [[ ! " ${target_array[*]} " =~ " ${value} " ]]; then
        target_array+=("$value")
    fi
}

detect_wp_path() {
    # Try to detect WordPress path programmatically
    local detected_path=""

    # Check if we're already in a WordPress directory
    if [[ -f "wp-config.php" ]]; then
        detected_path="$(pwd)"
    elif [[ -f "../wp-config.php" ]]; then
        detected_path="$(cd .. && pwd)"
    # Check common locations
    elif [[ -f "$DEFAULT_WP_PATH/wp-config.php" ]]; then
        detected_path="$DEFAULT_WP_PATH"
    elif [[ -f "/var/www/html/wp-config.php" ]]; then
        detected_path="/var/www/html"
    elif [[ -f "/var/www/wordpress/wp-config.php" ]]; then
        detected_path="/var/www/wordpress"
    fi

    echo "$detected_path"
}

check_wp_cli() {
    if ! command -v wp &> /dev/null; then
        log "ERROR" "WP-CLI is not installed or not in PATH"
        exit 1
    fi
    verbose_log "WP-CLI found: $(wp_cli --version)"
}

check_wp_installation() {
    local wp_path="$1"

    if [[ ! -d "$wp_path" ]]; then
        log "ERROR" "WordPress directory does not exist: $wp_path"
        exit 1
    fi

    if [[ ! -f "$wp_path/wp-config.php" ]]; then
        log "ERROR" "wp-config.php not found in: $wp_path"
        exit 1
    fi

    # Verify WP-CLI can connect
    if ! wp_cli core version --path="$wp_path" &> /dev/null; then
        log "ERROR" "WP-CLI cannot connect to WordPress at: $wp_path"
        exit 1
    fi

    log "INFO" "WordPress installation verified at: $wp_path"
}

verify_core_checksum() {
    local wp_path="$1"

    log "INFO" "Verifying WordPress core checksums..."

    local checksum_output
    if checksum_output=$(wp_cli core verify-checksums --path="$wp_path" 2>&1); then
        log "SUCCESS" "WordPress core checksums verified successfully"
        return 0
    else
        log "WARNING" "WordPress core checksum verification failed"
        verbose_log "Details: $checksum_output"
        return 1
    fi
}

delete_rogue_core_files() {
    local wp_path="$1"

    # Run checksum verification and extract files that "should not exist"
    local checksum_output
    checksum_output=$(wp_cli core verify-checksums --path="$wp_path" 2>&1 || true)

    # Parse "File should not exist" warnings and delete those files
    local rogue_files=()
    while IFS= read -r line; do
        if [[ "$line" =~ "File should not exist:" ]]; then
            # Extract the file path after "File should not exist: "
            local rogue_file
            rogue_file=$(echo "$line" | sed -n 's/.*File should not exist: //p' | tr -d '\r')
            if [[ -n "$rogue_file" ]]; then
                rogue_files+=("$rogue_file")
            fi
        fi
    done <<< "$checksum_output"

    if [[ ${#rogue_files[@]} -eq 0 ]]; then
        verbose_log "No rogue files found"
        return 0
    fi

    log "WARNING" "Found ${#rogue_files[@]} rogue files to delete"

    for rogue_file in "${rogue_files[@]}"; do
        local full_path="$wp_path/$rogue_file"
        if [[ -f "$full_path" ]]; then
            log "INFO" "Deleting rogue file: $rogue_file"
            # Remove immutable attribute if present (Linux) + parent dir
            chattr -i "$(dirname "$full_path")" 2>/dev/null || true
            chattr -i "$full_path" 2>/dev/null || true
            # Remove on macOS
            chflags nouchg "$(dirname "$full_path")" 2>/dev/null || true
            chflags nouchg "$full_path" 2>/dev/null || true
            chmod u+w "$(dirname "$full_path")" 2>/dev/null || true
            if ! rm -f "$full_path" 2>/dev/null; then
                log "ERROR" "Failed to delete rogue file: $rogue_file (check permissions)"
            fi
        elif [[ -d "$full_path" ]]; then
            log "INFO" "Deleting rogue directory: $rogue_file"
            chattr -R -i "$full_path" 2>/dev/null || true
            chflags -R nouchg "$full_path" 2>/dev/null || true
            chmod -R u+w "$full_path" 2>/dev/null || true
            if ! rm -rf "$full_path" 2>/dev/null; then
                log "ERROR" "Failed to delete rogue directory: $rogue_file (check permissions)"
            fi
        fi
    done

    # Clean up empty directories left behind
    find "$wp_path/wp-admin" "$wp_path/wp-includes" -type d -empty -delete 2>/dev/null || true

    log "SUCCESS" "Deleted ${#rogue_files[@]} rogue files"
}

fix_core_permissions() {
    local wp_path="$1"

    # Remove immutable attributes (Linux chattr, macOS chflags)
    # This is needed when malware sets immutable flags to prevent cleanup

    log "INFO" "Removing immutable attributes from wp-admin and wp-includes..."

    # Linux: remove immutable attribute
    if command -v chattr &> /dev/null; then
        chattr -R -i "$wp_path/wp-admin" 2>/dev/null || true
        chattr -R -i "$wp_path/wp-includes" 2>/dev/null || true
        # Also handle root level files
        for f in "$wp_path"/*.php "$wp_path"/.htaccess; do
            [[ -f "$f" ]] && chattr -i "$f" 2>/dev/null || true
        done
    fi

    # macOS: remove user immutable flag
    if command -v chflags &> /dev/null; then
        chflags -R nouchg "$wp_path/wp-admin" 2>/dev/null || true
        chflags -R nouchg "$wp_path/wp-includes" 2>/dev/null || true
        for f in "$wp_path"/*.php "$wp_path"/.htaccess; do
            [[ -f "$f" ]] && chflags nouchg "$f" 2>/dev/null || true
        done
    fi

    # Fix ownership to www-data (requires root)
    if is_root; then
        log "INFO" "Fixing ownership to $WP_USER..."
        chown -R "$WP_USER:$WP_USER" "$wp_path/wp-admin" 2>/dev/null || true
        chown -R "$WP_USER:$WP_USER" "$wp_path/wp-includes" 2>/dev/null || true
    fi

    # Fix permissions: directories 755, files 644
    log "INFO" "Fixing file permissions..."
    find "$wp_path/wp-admin" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$wp_path/wp-admin" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$wp_path/wp-includes" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$wp_path/wp-includes" -type f -exec chmod 644 {} \; 2>/dev/null || true

    log "SUCCESS" "Permissions and attributes fixed"
}

fix_all_permissions() {
    local wp_path="$1"

    log "INFO" "=========================================="
    log "INFO" "Fixing permissions on entire WordPress installation..."
    log "INFO" "=========================================="

    if ! is_root; then
        log "WARNING" "--fix-permissions requires root privileges, skipping ownership changes"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN" "Would fix permissions on entire WordPress installation"
        return 0
    fi

    # Remove immutable attributes from entire installation
    log "INFO" "Removing immutable attributes..."

    # First, handle the root directory itself (critical for write access)
    if command -v chattr &> /dev/null; then
        chattr -i "$wp_path" 2>/dev/null || true
    fi
    if command -v chflags &> /dev/null; then
        chflags nouchg "$wp_path" 2>/dev/null || true
    fi
    # Ensure root directory is writable
    chmod u+w "$wp_path" 2>/dev/null || true

    # Then handle all contents recursively
    if command -v chattr &> /dev/null; then
        chattr -R -i "$wp_path" 2>/dev/null || true
    fi
    if command -v chflags &> /dev/null; then
        chflags -R nouchg "$wp_path" 2>/dev/null || true
    fi

    # Fix ownership on entire WordPress directory (requires root)
    if is_root; then
        log "INFO" "Fixing ownership to $WP_USER:$WP_USER..."
        chown -R "$WP_USER:$WP_USER" "$wp_path" 2>/dev/null || {
            log "ERROR" "Failed to change ownership."
            return 1
        }
    fi

    # Fix permissions
    log "INFO" "Setting directory permissions to 755..."
    find "$wp_path" -type d -exec chmod 755 {} \; 2>/dev/null || true

    log "INFO" "Setting file permissions to 644..."
    find "$wp_path" -type f -exec chmod 644 {} \; 2>/dev/null || true

    # wp-config.php should be more restrictive
    if [[ -f "$wp_path/wp-config.php" ]]; then
        chmod 640 "$wp_path/wp-config.php" 2>/dev/null || true
        log "INFO" "Set wp-config.php to 640"
    fi

    # .htaccess should be readable
    if [[ -f "$wp_path/.htaccess" ]]; then
        chmod 644 "$wp_path/.htaccess" 2>/dev/null || true
    fi

    # wp-content/uploads needs to be writable
    if [[ -d "$wp_path/wp-content/uploads" ]]; then
        log "INFO" "Ensuring uploads directory is writable..."
        chmod 755 "$wp_path/wp-content/uploads" 2>/dev/null || true
    fi

    # Plugins directory
    if [[ -d "$wp_path/wp-content/plugins" ]]; then
        log "INFO" "Fixing plugin permissions..."
        find "$wp_path/wp-content/plugins" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$wp_path/wp-content/plugins" -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi

    # Themes directory
    if [[ -d "$wp_path/wp-content/themes" ]]; then
        log "INFO" "Fixing theme permissions..."
        find "$wp_path/wp-content/themes" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$wp_path/wp-content/themes" -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi

    # mu-plugins directory
    if [[ -d "$wp_path/wp-content/mu-plugins" ]]; then
        log "INFO" "Fixing mu-plugins permissions..."
        find "$wp_path/wp-content/mu-plugins" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$wp_path/wp-content/mu-plugins" -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi

    log "SUCCESS" "All permissions fixed"
    log "INFO" "  - Directories: 755"
    log "INFO" "  - Files: 644"
    log "INFO" "  - wp-config.php: 640"
    log "INFO" "  - Owner: $WP_USER:$WP_USER"

    return 0
}

scan_and_clean_critical_files() {
    local wp_path="$1"

    log "INFO" "Scanning critical files for malware injections..."

    local infected_files=()

    # Patterns that indicate malware injection
    # These are common obfuscation patterns used by malware
    local malware_patterns=(
        'ob_start();'
        'eval(base64_decode'
        'eval(gzinflate'
        'eval(gzuncompress'
        'eval(str_rot13'
        '\$_[A-Z]+\[[^\]]+\]\('
        'function _0x[0-9a-f]+'
        'urlcuttly\.net'
        'preg_replace.*\/e'
        'assert.*\$'
        'create_function'
        '\x[0-9a-fA-F]{2}'
        'chr\([0-9]+\)\.chr\('
    )

    # Build grep pattern
    local grep_pattern
    grep_pattern=$(printf '%s\|' "${malware_patterns[@]}" | sed 's/\\|$//')

    # Files to check
    local critical_files=(
        "$wp_path/wp-config.php"
        "$wp_path/index.php"
        "$wp_path/wp-settings.php"
        "$wp_path/wp-blog-header.php"
        "$wp_path/wp-load.php"
    )

    # Check each critical file
    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            if grep -qE "$grep_pattern" "$file" 2>/dev/null; then
                infected_files+=("$file")
                log "WARNING" "Potential malware detected in: $file"
            fi
        fi
    done

    # Check wp-content root for suspicious files
    if [[ -d "$wp_path/wp-content" ]]; then
        for file in "$wp_path/wp-content"/*.php; do
            if [[ -f "$file" ]]; then
                local filename
                filename=$(basename "$file")
                # Known legitimate drop-ins
                case "$filename" in
                    db.php|object-cache.php|advanced-cache.php|db-error.php|install.php|maintenance.php|sunrise.php|blog-deleted.php|blog-inactive.php|blog-suspended.php)
                        # Check if legitimate drop-in is infected
                        if grep -qE "$grep_pattern" "$file" 2>/dev/null; then
                            infected_files+=("$file")
                            log "WARNING" "Potential malware detected in drop-in: $file"
                        fi
                        ;;
                    *)
                        # Unknown PHP file in wp-content root - suspicious
                        log "WARNING" "Suspicious file in wp-content root: $filename"
                        infected_files+=("$file")
                        ;;
                esac
            fi
        done
    fi

    # Check mu-plugins
    if [[ -d "$wp_path/wp-content/mu-plugins" ]]; then
        while IFS= read -r -d '' file; do
            if grep -qE "$grep_pattern" "$file" 2>/dev/null; then
                infected_files+=("$file")
                log "WARNING" "Potential malware detected in mu-plugin: $file"
            fi
        done < <(find "$wp_path/wp-content/mu-plugins" -name "*.php" -print0 2>/dev/null)
    fi

    # Report findings
    if [[ ${#infected_files[@]} -gt 0 ]]; then
        log "ERROR" "Found ${#infected_files[@]} potentially infected files!"
        log "INFO" "Please manually review and clean these files:"
        for file in "${infected_files[@]}"; do
            log "INFO" "  - $file"
        done

        # Attempt to clean wp-config.php specifically
        if [[ " ${infected_files[*]} " =~ " $wp_path/wp-config.php " ]]; then
            clean_wp_config "$wp_path"
        fi

        return 1
    else
        log "SUCCESS" "No obvious malware patterns detected in critical files"
        return 0
    fi
}

clean_wp_config() {
    local wp_path="$1"
    local wp_config="$wp_path/wp-config.php"

    if [[ ! -f "$wp_config" ]]; then
        return 1
    fi

    log "INFO" "Attempting to clean wp-config.php..."

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN" "Would attempt to clean wp-config.php"
        return 0
    fi

    # Backup original
    cp "$wp_config" "$wp_config.infected.bak"
    log "INFO" "Backup created: $wp_config.infected.bak"

    # Remove common malware injections
    # Pattern 1: Remove everything before <?php if it exists at the start
    # Pattern 2: Remove ob_start() injections with binary garbage
    # Pattern 3: Remove script tags
    # Pattern 4: Remove base64 eval blocks

    # Create a cleaned version
    local temp_file
    temp_file=$(mktemp)

    # Extract just the PHP content, removing injected code before opening tag
    # and any script/HTML injections
    sed -n '/^<?php/,$p' "$wp_config" | \
        sed '/^.*ob_start();.*$/d' | \
        sed '/<script.*<\/script>/d' | \
        sed '/eval(base64_decode/d' | \
        sed '/eval(gzinflate/d' | \
        sed '/function _0x[0-9a-f]*/,/^}$/d' \
        > "$temp_file"

    # Check if the cleaned file still looks like valid wp-config
    if grep -q "DB_NAME" "$temp_file" && grep -q "DB_PASSWORD" "$temp_file"; then
        # Also make sure it starts with <?php
        if ! head -1 "$temp_file" | grep -q '^<?php'; then
            echo '<?php' | cat - "$temp_file" > "$temp_file.tmp" && mv "$temp_file.tmp" "$temp_file"
        fi

        mv "$temp_file" "$wp_config"
        if is_root; then
            chown "$WP_USER:$WP_USER" "$wp_config"
        fi
        chmod 644 "$wp_config"
        log "SUCCESS" "wp-config.php has been cleaned (backup saved as .infected.bak)"
    else
        log "ERROR" "Cleaned wp-config.php appears invalid, keeping original"
        log "INFO" "Please manually clean: $wp_config"
        rm -f "$temp_file"
        # Restore from backup
        mv "$wp_config.infected.bak" "$wp_config"
        return 1
    fi

    return 0
}

repair_core() {
    local wp_path="$1"

    # Get current WordPress version - handle potentially corrupted version.php
    local wp_version_raw
    wp_version_raw=$(wp_cli core version --path="$wp_path" 2>/dev/null || echo "")

    # Extract clean version number (e.g., "5.8.11" or "6.4.2")
    # This handles cases where malware has corrupted the version.php file
    # The version could be at the start, end, or anywhere in the output
    local wp_version
    wp_version=$(echo "$wp_version_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)

    # If no patch version found, try major.minor format
    if [[ -z "$wp_version" ]]; then
        wp_version=$(echo "$wp_version_raw" | grep -oE '[0-9]+\.[0-9]+' | tail -1 || true)
    fi

    # If we couldn't extract a version, try reading directly from version.php
    if [[ -z "$wp_version" ]]; then
        log "WARNING" "Could not get clean version from WP-CLI, attempting to read version.php directly..."

        if [[ -f "$wp_path/wp-includes/version.php" ]]; then
            wp_version=$(grep -oP "\\\$wp_version\s*=\s*['\"][0-9]+\.[0-9]+(\.[0-9]+)?['\"]" "$wp_path/wp-includes/version.php" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
        fi
    fi

    # If still no version, try the database
    if [[ -z "$wp_version" ]]; then
        log "WARNING" "Could not read version.php, checking database..."
        wp_version=$(wp_cli db query "SELECT option_value FROM $(wp_cli db prefix --path="$wp_path" 2>/dev/null || echo "wp_")options WHERE option_name = 'db_version'" --path="$wp_path" --skip-column-names 2>/dev/null | head -1 || true)

        # Convert db_version to WP version (approximate - may need manual verification)
        if [[ -n "$wp_version" ]]; then
            log "WARNING" "Found db_version: $wp_version - this may not map exactly to a WP release"
            log "ERROR" "Cannot determine exact WordPress version. Please specify manually."
            log "INFO" "You can run: wp core download --version=X.X.X --force --path=$wp_path"
            CORE_FAILED=true
            return 1
        fi
    fi

    if [[ -z "$wp_version" ]]; then
        log "ERROR" "Could not determine WordPress version. Core files may be severely corrupted."
        log "INFO" "Please manually reinstall: wp core download --version=X.X.X --force --path=$wp_path"
        CORE_FAILED=true
        return 1
    fi

    # Validate version format
    if ! [[ "$wp_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log "ERROR" "Invalid version format detected: $wp_version"
        log "INFO" "Please manually reinstall with correct version"
        CORE_FAILED=true
        return 1
    fi

    log "INFO" "Detected WordPress version: $wp_version"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN" "Would delete and reinstall WordPress core version $wp_version"
        return 0
    fi

    # Step 1: Delete rogue files that should not exist
    log "INFO" "Checking for rogue files that should not exist..."
    delete_rogue_core_files "$wp_path"

    # Step 2: Remove immutable attributes and fix permissions on wp-admin and wp-includes
    log "INFO" "Fixing file permissions and attributes..."
    fix_core_permissions "$wp_path"

    # Step 3: Ensure root directory is writable (required for wp core download)
    log "INFO" "Ensuring WordPress root directory is writable..."
    if command -v chattr &> /dev/null; then
        chattr -i "$wp_path" 2>/dev/null || true
    fi
    if command -v chflags &> /dev/null; then
        chflags nouchg "$wp_path" 2>/dev/null || true
    fi
    chmod u+w "$wp_path" 2>/dev/null || true

    log "INFO" "Downloading WordPress core $wp_version..."

    # Force reinstall core (this downloads and overwrites core files)
    if wp_cli core download --version="$wp_version" --force --path="$wp_path"; then
        log "SUCCESS" "WordPress core $wp_version reinstalled successfully"

        # Verify again
        if verify_core_checksum "$wp_path"; then
            return 0
        else
            log "ERROR" "Core still fails checksum after reinstall"
            CORE_FAILED=true
            return 1
        fi
    else
        log "ERROR" "Failed to reinstall WordPress core"
        CORE_FAILED=true
        return 1
    fi
}

verify_plugin_checksums() {
    local wp_path="$1"

    log "INFO" "Verifying plugin checksums..."

    # Get list of all plugins using CSV format (no jq dependency)
    local plugins_raw
    plugins_raw=$(wp_cli plugin list --path="$wp_path" --format=csv --fields=name,status,version 2>/dev/null) || true

    if [[ -z "$plugins_raw" ]]; then
        log "ERROR" "Failed to get plugin list"
        return 1
    fi

    # Parse plugins - skip header line
    local plugin_count
    plugin_count=$(echo "$plugins_raw" | tail -n +2 | wc -l | tr -d ' ')

    if [[ "$plugin_count" == "0" ]]; then
        log "INFO" "No plugins installed"
        return 0
    fi

    log "INFO" "Found $plugin_count plugins to verify"
    local verified_count=0
    local skipped_count=0
    local repaired_count=0
    local failed_count=0

    while IFS=',' read -r plugin_name plugin_status plugin_version; do
        # Skip header
        [[ "$plugin_name" == "name" ]] && continue

        # Skip must-use plugins
        if [[ "$plugin_status" == "must-use" ]]; then
            verbose_log "Plugin '$plugin_name' (v$plugin_version): skipped_must_use"
            continue
        fi

        local verify_output
        local verify_status=0
        verify_output=$(wp_cli plugin verify-checksums "$plugin_name" --path="$wp_path" 2>&1) || verify_status=$?

        if [[ "$verify_output" =~ "Could not retrieve" ]] || [[ "$verify_output" =~ "Couldn't fetch response" ]] || [[ "$verify_output" =~ "not available" ]] || [[ "$verify_output" =~ "not found" ]]; then
            log "WARNING" "Skipping plugin '$plugin_name' (not in WordPress.org repository)"
            append_unique "$plugin_name" SKIPPED_PLUGINS
            verbose_log "Plugin '$plugin_name' (v$plugin_version): skipped_not_wporg"
            skipped_count=$((skipped_count + 1))
        elif [[ $verify_status -eq 0 ]] && [[ "$verify_output" =~ "Success:" ]]; then
            verbose_log "Plugin '$plugin_name' (v$plugin_version): verified"
            verified_count=$((verified_count + 1))
        else
            verbose_log "Plugin '$plugin_name' (v$plugin_version): failed_checksum"

            if repair_plugin "$wp_path" "$plugin_name"; then
                if [[ "$DRY_RUN" == true ]]; then
                    verbose_log "Plugin '$plugin_name' (v$plugin_version): failed_checksum -> dry_run_reinstall_pending"
                else
                    verbose_log "Plugin '$plugin_name' (v$plugin_version): failed_checksum -> repaired"
                fi
                repaired_count=$((repaired_count + 1))
            else
                verbose_log "Plugin '$plugin_name' (v$plugin_version): failed_checksum -> repair_failed"
                failed_count=$((failed_count + 1))
            fi
        fi
    done <<< "$plugins_raw"

    if [[ $failed_count -gt 0 ]]; then
        log "ERROR" "Plugin checksum verification completed with $failed_count unrepaired failure(s)"
        return 1
    fi

    if [[ $repaired_count -gt 0 ]]; then
        log "WARNING" "Plugin checksum verification found issues and repaired $repaired_count plugin(s)"
        return 0
    fi

    log "SUCCESS" "All plugin checksums verified successfully ($verified_count verified, $skipped_count skipped)"

    return 0
}

repair_plugin() {
    local wp_path="$1"
    local plugin_name="$2"

    # Get plugin version
    local plugin_version
    plugin_version=$(wp_cli plugin get "$plugin_name" --path="$wp_path" --field=version 2>/dev/null) || {
        log "ERROR" "Could not get version for plugin '$plugin_name', cannot repair"
        append_unique "$plugin_name" FAILED_PLUGINS
        return 1
    }

    log "WARNING" "Plugin '$plugin_name' (v$plugin_version) failed checksum verification"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN" "Would reinstall plugin '$plugin_name' version $plugin_version"
        return 0
    fi

    log "INFO" "Reinstalling plugin '$plugin_name' version $plugin_version..."

    # Force reinstall the same version
    if wp_cli plugin install "$plugin_name" --version="$plugin_version" --force --path="$wp_path"; then
        log "SUCCESS" "Plugin '$plugin_name' v$plugin_version reinstalled successfully"
        return 0
    else
        log "ERROR" "Failed to reinstall plugin '$plugin_name'"
        append_unique "$plugin_name" FAILED_PLUGINS
        return 1
    fi
}

inventory_themes() {
    local wp_path="$1"

    log "INFO" "Inventorying installed themes..."

    # Get list of all themes using CSV format (no jq dependency)
    local themes_raw
    themes_raw=$(wp_cli theme list --path="$wp_path" --format=csv --fields=name,status,version 2>/dev/null) || true

    if [[ -z "$themes_raw" ]]; then
        log "ERROR" "Failed to get theme list"
        return 1
    fi

    # Parse themes - skip header line
    local theme_count
    theme_count=$(echo "$themes_raw" | tail -n +2 | wc -l | tr -d ' ')

    if [[ "$theme_count" == "0" ]]; then
        log "INFO" "No themes installed"
        return 0
    fi

    log "INFO" "Found $theme_count installed themes"
    log "INFO" "Theme checksum verification is not supported by WP-CLI; themes will be inventoried only"
    THEMES_INVENTORIED="$theme_count"

    while IFS=',' read -r theme_name theme_status theme_version; do
        [[ "$theme_name" == "name" ]] && continue
        verbose_log "Theme '$theme_name' (v$theme_version): checksum_verification_not_supported"
    done <<< "$themes_raw"

    return 0
}

print_summary() {
    echo ""
    log "INFO" "=========================================="
    log "INFO" "           SUMMARY REPORT"
    log "INFO" "=========================================="

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN" "No changes were made (dry-run mode)"
    fi

    if [[ "$CORE_FAILED" == true ]]; then
        log "ERROR" "Core repair: FAILED"
    else
        log "SUCCESS" "Core: OK"
    fi

    if [[ ${#FAILED_PLUGINS[@]} -gt 0 ]]; then
        log "ERROR" "Failed to repair plugins: ${FAILED_PLUGINS[*]}"
    fi

    if [[ ${#SKIPPED_PLUGINS[@]} -gt 0 ]]; then
        log "WARNING" "Skipped plugins (premium/custom): ${SKIPPED_PLUGINS[*]}"
    fi

    log "INFO" "Themes: inventoried only (${THEMES_INVENTORIED} found, checksum verification not supported by WP-CLI)"

    local total_failures=${#FAILED_PLUGINS[@]}
    if [[ "$CORE_FAILED" == true ]]; then
        total_failures=$((total_failures + 1))
    fi

    if [[ $total_failures -eq 0 ]]; then
        log "SUCCESS" "All checksum verifications completed successfully"
    else
        log "ERROR" "Total failures: $total_failures"
    fi

    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "=========================================="

    return $total_failures
}

#===============================================================================
# Main
#===============================================================================

main() {
    local wp_path=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--path)
                wp_path="$2"
                shift 2
                ;;
            -u|--user)
                WP_USER="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force-clean)
                FORCE_CLEAN=true
                shift
                ;;
            --fix-permissions)
                FIX_PERMISSIONS=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Set default user if not specified
    if [[ -z "$WP_USER" ]]; then
        WP_USER="$DEFAULT_WP_USER"
    fi

    # Verify the user exists
    if ! id "$WP_USER" &>/dev/null; then
        log "ERROR" "User '$WP_USER' does not exist on this system"
        log "INFO" "Use -u/--user to specify a valid user (e.g., www-data, apache, nginx)"
        exit 1
    fi

    # Detect or use default WordPress path
    if [[ -z "$wp_path" ]]; then
        wp_path=$(detect_wp_path)
        if [[ -z "$wp_path" ]]; then
            wp_path="$DEFAULT_WP_PATH"
        fi
    fi

    log "INFO" "=========================================="
    log "INFO" "  WP Checksum Verification & Repair"
    log "INFO" "=========================================="
    log "INFO" "WordPress Path: $wp_path"
    log "INFO" "WP User: $WP_USER"
    log "INFO" "Running as: $(id -un)"
    if ! is_root; then
        log "WARNING" "Not running as root - ownership changes will be skipped"
    fi
    log "INFO" "Dry Run: $DRY_RUN"
    log "INFO" "Force Clean: $FORCE_CLEAN"
    log "INFO" "Fix Permissions: $FIX_PERMISSIONS"
    log "INFO" "Log File: $LOG_FILE"
    log "INFO" "=========================================="
    echo ""

    # Pre-flight checks
    check_wp_cli
    check_wp_installation "$wp_path"

    echo ""

    # Fix permissions first if requested
    if [[ "$FIX_PERMISSIONS" == true ]]; then
        fix_all_permissions "$wp_path" || true
        echo ""
    fi

    # Verify and repair core
    if ! verify_core_checksum "$wp_path"; then
        repair_core "$wp_path" || true
    fi

    echo ""

    # Scan and clean critical files (wp-config.php, mu-plugins, etc.) - only if --force-clean
    if [[ "$FORCE_CLEAN" == true ]]; then
        scan_and_clean_critical_files "$wp_path" || true
        echo ""
    fi

    # Verify and repair plugins
    verify_plugin_checksums "$wp_path" || true

    echo ""

    # Themes have no official WP-CLI checksum command: inventory only.
    inventory_themes "$wp_path" || true

    echo ""

    # Print summary — capture exit code without letting set -e kill the script
    local exit_code=0
    print_summary || exit_code=$?

    exit $exit_code
}

# Run main function
main "$@"
