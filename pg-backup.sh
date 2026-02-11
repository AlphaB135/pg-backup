#!/bin/bash

##############################################################################
# PostgreSQL Auto Backup Script
# Author: αB (https://github.com/AlphaB135)
# Version: 1.0.0
##############################################################################

set -euo pipefail

##############################################################################
# CONFIGURATION
##############################################################################

# Database Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAMES="${DB_NAMES:-}"

# Backup Directory
BACKUP_DIR="${BACKUP_DIR:-./backups}"

# Storage Configuration
STORAGE_TYPE="${STORAGE_TYPE:-local}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PATH="${S3_PATH:-postgres/}"
S3_REGION="${S3_REGION:-us-east-1}"

# GCS Configuration
GCS_BUCKET="${GCS_BUCKET:-}"
GCS_PATH="${GCS_PATH:-postgres/}"

# B2 Configuration
B2_BUCKET="${B2_BUCKET:-}"
B2_PATH="${B2_PATH:-postgres/}"

# Compression
COMPRESS="${COMPRESS:-true}"

# Encryption
ENCRYPT="${ENCRYPT:-false}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"

# Retention
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Notifications
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="${EMAIL_FROM:-}"
SMTP_SERVER="${SMTP_SERVER:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"

# Timestamp
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
LOG_FILE="${BACKUP_DIR}/pg-backup-${TIMESTAMP}.log"

##############################################################################
# FUNCTIONS
##############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $*"
    notify_slack "❌ Backup failed: $*"
    notify_email "Backup failed: $*" "error"
    exit 1
}

check_dependencies() {
    local deps=("psql" "pg_dump")

    if [ "$STORAGE_TYPE" = "s3" ]; then
        deps+=("aws")
    fi

    if [ "$STORAGE_TYPE" = "gcs" ]; then
        deps+=("gsutil")
    fi

    if [ "$STORAGE_TYPE" = "b2" ]; then
        deps+=("b2")
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Required dependency not found: $dep"
        fi
    done
}

create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    log "Backup directory: $BACKUP_DIR"
}

test_connection() {
    log "Testing database connection..."
    if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1" &> /dev/null; then
        log "✓ Database connection successful"
    else
        error "Failed to connect to database"
    fi
}

backup_database() {
    local db_name=$1
    local backup_file="${BACKUP_DIR}/${db_name}-${TIMESTAMP}.sql"

    log "Starting backup for database: $db_name"

    # Create backup
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$db_name" \
        --format=plain \
        --no-owner \
        --no-acl \
        > "$backup_file"

    # Compress if enabled
    if [ "$COMPRESS" = "true" ]; then
        gzip "$backup_file"
        backup_file="${backup_file}.gz"
        log "✓ Backup compressed: ${backup_file}.gz"
    else
        log "✓ Backup created: $backup_file"
    fi

    # Encrypt if enabled
    if [ "$ENCRYPT" = "true" ] && [ -n "$ENCRYPTION_KEY" ]; then
        local encrypted_file="${backup_file}.enc"
        openssl enc -aes-256-cbc -salt -in "$backup_file" -out "$encrypted_file" -k "$ENCRYPTION_KEY"
        rm "$backup_file"
        backup_file="$encrypted_file"
        log "✓ Backup encrypted: $backup_file"
    fi

    echo "$backup_file"
}

upload_to_s3() {
    local local_file=$1
    local db_name=$2
    local s3_path="s3://${S3_BUCKET}/${S3_PATH}${db_name}/$(basename "$local_file")"

    log "Uploading to S3: $s3_path"
    aws s3 cp "$local_file" "$s3_path" --region "$S3_REGION"

    if [ $? -eq 0 ]; then
        log "✓ Upload successful"
        return 0
    else
        error "S3 upload failed"
    fi
}

upload_to_gcs() {
    local local_file=$1
    local db_name=$2
    local gcs_path="gs://${GCS_BUCKET}/${GCS_PATH}${db_name}/$(basename "$local_file")"

    log "Uploading to GCS: $gcs_path"
    gsutil cp "$local_file" "$gcs_path"

    if [ $? -eq 0 ]; then
        log "✓ Upload successful"
        return 0
    else
        error "GCS upload failed"
    fi
}

upload_to_b2() {
    local local_file=$1
    local db_name=$2
    local b2_path="b2://${B2_BUCKET}/${B2_PATH}${db_name}/$(basename "$local_file")"

    log "Uploading to B2: $b2_path"
    b2 upload-file "$B2_BUCKET" "$local_file" "${B2_PATH}${db_name}/$(basename "$local_file")"

    if [ $? -eq 0 ]; then
        log "✓ Upload successful"
        return 0
    else
        error "B2 upload failed"
    fi
}

cleanup_old_backups() {
    log "Cleaning up old backups (older than $RETENTION_DAYS days)..."

    local db_name=$1

    if [ "$STORAGE_TYPE" = "local" ]; then
        find "$BACKUP_DIR" -name "${db_name}-*.sql*" -mtime +$RETENTION_DAYS -delete
        log "✓ Old backups deleted"
    elif [ "$STORAGE_TYPE" = "s3" ]; then
        aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}${db_name}/" --recursive | \
            while read -r line; do
                file_date=$(echo "$line" | awk '{print $1" "$2}')
                file_path=$(echo "$line" | awk '{print $4}')

                file_timestamp=$(date -d "$file_date" +%s 2>/dev/null || echo 0)
                cutoff_timestamp=$(date -d "$RETENTION_DAYS days ago" +%s)

                if [ "$file_timestamp" -lt "$cutoff_timestamp" ] && [ "$file_timestamp" -ne 0 ]; then
                    aws s3 rm "s3://${S3_BUCKET}/${file_path}" &>/dev/null
                    log "Deleted old backup: $file_path"
                fi
            done
    fi
}

notify_slack() {
    if [ -n "$SLACK_WEBHOOK" ]; then
        local message=$1
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"text\": \"$message\"}" &>/dev/null
    fi
}

notify_email() {
    local subject=$1
    local body=$2

    if [ -n "$EMAIL_TO" ] && [ -n "$SMTP_SERVER" ]; then
        local full_subject="PostgreSQL Backup: $subject"

        if [ "$body" = "error" ]; then
            cat "$LOG_FILE" | mail -s "$full_subject" -a "From: $EMAIL_FROM" \
                -S smtp="$SMTP_SERVER:$SMTP_PORT" \
                -S smtp-use-starttls \
                -S smtp-auth=login \
                -S smtp-auth-user="$SMTP_USER" \
                -S smtp-auth-password="$SMTP_PASSWORD" \
                "$EMAIL_TO" &>/dev/null || true
        else
            echo "PostgreSQL backup completed successfully" | mail -s "$full_subject" \
                -a "From: $EMAIL_FROM" \
                -S smtp="$SMTP_SERVER:$SMTP_PORT" \
                -S smtp-use-starttls \
                -S smtp-auth=login \
                -S smtp-auth-user="$SMTP_USER" \
                -S smtp-auth-password="$SMTP_PASSWORD" \
                "$EMAIL_TO" &>/dev/null || true
        fi
    fi
}

##############################################################################
# MAIN
##############################################################################

main() {
    log "========================================="
    log "PostgreSQL Backup Script"
    log "========================================="

    # Check dependencies
    check_dependencies

    # Create backup directory
    create_backup_dir

    # Test connection
    test_connection

    # Split DB_NAMES by comma
    IFS=',' read -ra DATABASES <<< "$DB_NAMES"

    # Backup each database
    for db_name in "${DATABASES[@]}"; do
        db_name=$(echo "$db_name" | xargs) # trim whitespace

        if [ -z "$db_name" ]; then
            continue
        fi

        log "Processing database: $db_name"

        # Create backup
        backup_file=$(backup_database "$db_name")

        # Upload to storage
        case "$STORAGE_TYPE" in
            s3)
                upload_to_s3 "$backup_file" "$db_name"
                ;;
            gcs)
                upload_to_gcs "$backup_file" "$db_name"
                ;;
            b2)
                upload_to_b2 "$backup_file" "$db_name"
                ;;
            local|*)
                log "Keeping backup locally: $backup_file"
                ;;
        esac

        # Cleanup old backups
        cleanup_old_backups "$db_name"
    done

    # Success notification
    log "✓ All backups completed successfully"
    notify_slack "✅ PostgreSQL backup completed successfully"
    notify_email "Backup completed" "success"

    log "========================================="
    log "Backup process finished at: $(date)"
    log "========================================="
}

##############################################################################
# COMMAND LINE INTERFACE
##############################################################################

case "${1:-}" in
    --help)
        echo "PostgreSQL Auto Backup Script"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help          Show this help message"
        echo "  --test          Run connection test only"
        echo "  --list          List available backups"
        echo "  --restore FILE  Restore from backup file"
        echo "  --status        Show backup status"
        echo ""
        echo "Environment Variables:"
        echo "  DB_HOST         Database host (default: localhost)"
        echo "  DB_PORT         Database port (default: 5432)"
        echo "  DB_USER         Database user (default: postgres)"
        echo "  DB_PASSWORD     Database password"
        echo "  DB_NAMES        Comma-separated list of databases"
        echo "  BACKUP_DIR      Backup directory (default: ./backups)"
        echo "  STORAGE_TYPE    Storage type: local, s3, gcs, b2 (default: local)"
        echo "  S3_BUCKET       S3 bucket name"
        echo "  S3_PATH         S3 path prefix (default: postgres/)"
        echo "  S3_REGION       S3 region (default: us-east-1)"
        echo "  COMPRESS        Compress backups (default: true)"
        echo "  ENCRYPT         Encrypt backups (default: false)"
        echo "  ENCRYPTION_KEY  Encryption key"
        echo "  RETENTION_DAYS  Days to keep backups (default: 7)"
        echo "  SLACK_WEBHOOK   Slack webhook URL"
        echo "  EMAIL_TO        Email recipient"
        echo "  EMAIL_FROM      Email sender"
        echo "  SMTP_SERVER     SMTP server"
        echo "  SMTP_PORT       SMTP port (default: 587)"
        echo "  SMTP_USER       SMTP username"
        echo "  SMTP_PASSWORD   SMTP password"
        exit 0
        ;;
    --test)
        check_dependencies
        create_backup_dir
        test_connection
        log "✓ Connection test passed"
        exit 0
        ;;
    --list)
        echo "Available backups:"
        ls -lh "$BACKUP_DIR"/*.sql* 2>/dev/null || echo "No backups found"
        exit 0
        ;;
    --restore)
        if [ -z "${2:-}" ]; then
            error "Please specify backup file to restore"
        fi
        backup_file="${2}"
        if [ ! -f "$backup_file" ]; then
            error "Backup file not found: $backup_file"
        fi
        log "Restoring from: $backup_file"
        read -p "Enter target database name: " db_name
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db_name" < "$backup_file"
        log "✓ Restore completed"
        exit 0
        ;;
    --status)
        echo "Backup Status:"
        echo "Last backup:"
        ls -lt "$BACKUP_DIR"/*.sql* 2>/dev/null | head -1 || echo "No backups found"
        echo ""
        echo "Storage type: $STORAGE_TYPE"
        echo "Retention: $RETENTION_DAYS days"
        exit 0
        ;;
    *)
        # Run backup
        main
        ;;
esac
