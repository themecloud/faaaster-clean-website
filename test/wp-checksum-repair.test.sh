#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../wp-checksum-repair.sh
source "$REPO_DIR/wp-checksum-repair.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

LOG_FILE="$TEST_DIR/clean.log"
WP_USER=$(id -un)
VERBOSE=true

wp_cli() {
    if [[ "$1" == "plugin" && "$2" == "list" ]]; then
        printf '%s\n' \
            'name,status,version' \
            'db.php,dropin,' \
            'akismet,active,5.3'
        return 0
    fi

    if [[ "$1" == "plugin" && "$2" == "verify-checksums" && "$3" == "db.php" ]]; then
        touch "$TEST_DIR/dropin-checksum-called"
        return 99
    fi

    if [[ "$1" == "plugin" && "$2" == "verify-checksums" && "$3" == "akismet" ]]; then
        echo 'Success: Verified 1 of 1 files.'
        return 0
    fi

    echo "Unexpected wp_cli invocation: $*" >&2
    return 98
}

OUTPUT=$(verify_plugin_checksums "/fake-wordpress" 2>&1)

if [[ -e "$TEST_DIR/dropin-checksum-called" ]]; then
    echo "db.php was incorrectly passed to plugin checksum verification" >&2
    exit 1
fi

grep -Fq "Drop-in 'db.php': skipped_checksum_not_applicable" <<< "$OUTPUT"
grep -Fq "All plugin checksums verified successfully (1 verified, 0 skipped)" <<< "$OUTPUT"

echo "PASS: drop-ins are excluded from plugin checksum verification"
