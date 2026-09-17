#!/usr/bin/env bash

# Minimal, deliberately conservative backup/restore helper for Orialis.
#
# backup:  backup <database-file> <uploads-directory> <backup-directory>
# restore: restore <backup-directory> <target-directory>
#
# Restore never overwrites an existing target directory.  This is intentional:
# the caller must choose a new, empty location before moving it into service.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage:
  $SCRIPT_NAME backup  <database-file> <uploads-directory> <backup-directory>
  $SCRIPT_NAME restore <backup-directory> <target-directory>

The restore target must not already exist. No files are overwritten.
EOF
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

existing_dir() {
    local path="$1"
    [[ -d "$path" ]] || fail "directory does not exist: $path"
    (cd -P "$path" && pwd -P)
}

existing_file() {
    local path="$1"
    [[ -f "$path" ]] || fail "file does not exist: $path"
    local parent
    parent="$(cd -P "$(dirname "$path")" && pwd -P)"
    printf '%s/%s\n' "$parent" "$(basename "$path")"
}

new_path() {
    local path="$1"
    local parent
    [[ -n "$path" ]] || fail 'path must not be empty'
    [[ ! -e "$path" ]] || fail "refusing to use an existing path: $path"
    parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P)" \
        || fail "parent directory does not exist: $(dirname "$path")"
    printf '%s/%s\n' "$parent" "$(basename "$path")"
}

sqlite_quote() {
    local value="$1"
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

sqlite_backup() {
    local database="$1"
    local destination="$2"
    local quoted_destination
    quoted_destination="$(sqlite_quote "$destination")"
    sqlite3 "$database" ".backup $quoted_destination"
}

verify_database() {
    local database="$1"
    local result
    result="$(sqlite3 "$database" 'PRAGMA integrity_check;')" \
        || fail "SQLite integrity check could not run: $database"
    [[ "$result" == 'ok' ]] || fail "SQLite integrity check failed for $database: $result"
    printf 'Verified: SQLite integrity_check=ok (%s)\n' "$database"
}

verify_uploads() {
    local expected="$1"
    local actual="$2"
    diff -qr "$expected" "$actual" >/dev/null \
        || fail "uploads verification failed: $expected and $actual differ"
    printf 'Verified: uploads match (%s)\n' "$actual"
}

backup() {
    [[ "$#" -eq 3 ]] || usage
    require_command sqlite3
    require_command diff

    local database uploads backup_dir temp_dir
    database="$(existing_file "$1")"
    uploads="$(existing_dir "$2")"
    backup_dir="$(new_path "$3")"

    [[ "$backup_dir" != "$database" ]] || fail 'backup directory cannot be the database file'
    [[ "$backup_dir" != "$uploads"/* ]] || fail 'backup directory cannot be inside uploads'

    temp_dir="$(mktemp -d "$(dirname "$backup_dir")/.${SCRIPT_NAME}.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT
    mkdir "$temp_dir/uploads"

    sqlite_backup "$database" "$temp_dir/database.sqlite3"
    cp -R -p "$uploads"/. "$temp_dir/uploads"/
    verify_database "$temp_dir/database.sqlite3"
    verify_uploads "$uploads" "$temp_dir/uploads"

    printf 'format-version=1\n' >"$temp_dir/backup.info"
    mv "$temp_dir" "$backup_dir"
    trap - EXIT
    printf 'Backup created: %s\n' "$backup_dir"
}

restore() {
    [[ "$#" -eq 2 ]] || usage
    require_command sqlite3
    require_command diff

    local backup_dir target_dir temp_dir
    backup_dir="$(existing_dir "$1")"
    target_dir="$(new_path "$2")"

    [[ "$backup_dir" != "$target_dir" ]] || fail 'backup directory and target directory must differ'
    [[ "$target_dir" != "$backup_dir"/* ]] || fail 'target directory cannot be inside backup directory'
    [[ -f "$backup_dir/database.sqlite3" ]] \
        || fail "backup is missing database.sqlite3: $backup_dir"
    [[ -d "$backup_dir/uploads" ]] \
        || fail "backup is missing uploads directory: $backup_dir"

    temp_dir="$(mktemp -d "$(dirname "$target_dir")/.${SCRIPT_NAME}.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT
    mkdir "$temp_dir/uploads"
    cp -p "$backup_dir/database.sqlite3" "$temp_dir/database.sqlite3"
    cp -R -p "$backup_dir/uploads"/. "$temp_dir/uploads"/

    verify_database "$temp_dir/database.sqlite3"
    verify_uploads "$backup_dir/uploads" "$temp_dir/uploads"
    mv "$temp_dir" "$target_dir"
    trap - EXIT
    printf 'Restore prepared: %s\n' "$target_dir"
    printf 'Verification passed; no existing path was overwritten.\n'
}

[[ "$#" -ge 1 ]] || usage
case "$1" in
    backup)
        shift
        backup "$@"
        ;;
    restore)
        shift
        restore "$@"
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac
