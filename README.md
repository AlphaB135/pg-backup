# @alphaseed/pg-backup

Automated PostgreSQL backup script with compression, encryption, and multi-cloud storage support.

## Installation

```bash
npm install -g @alphaseed/pg-backup
```

## Quick Start

```bash
# Set environment variables
export DB_HOST="localhost"
export DB_PORT="5432"
export DB_USER="postgres"
export DB_PASSWORD="your-password"
export DB_NAMES="mydb1,mydb2"

# Run backup
pg-backup
```

## Features

- **Automated Backups** - Cron-ready for scheduled backups
- **Compression** - Gzip compression to save storage space
- **Encryption** - AES-256 encryption for sensitive data
- **Cloud Storage** - Support for S3, GCS, and Backblaze B2
- **Retention Policy** - Automatic cleanup of old backups
- **Notifications** - Slack and email notifications
- **Multiple Databases** - Backup multiple databases in one run

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | localhost | Database host |
| `DB_PORT` | 5432 | Database port |
| `DB_USER` | postgres | Database user |
| `DB_PASSWORD` | - | Database password |
| `DB_NAMES` | - | Comma-separated database names |
| `BACKUP_DIR` | ./backups | Backup directory |
| `STORAGE_TYPE` | local | Storage type: local, s3, gcs, b2 |
| `COMPRESS` | true | Compress backups with gzip |
| `ENCRYPT` | false | Encrypt backups |
| `ENCRYPTION_KEY` | - | Encryption key |
| `RETENTION_DAYS` | 7 | Days to keep backups |

### S3 Storage

```bash
export STORAGE_TYPE="s3"
export S3_BUCKET="my-backups"
export S3_PATH="postgres/"
export S3_REGION="us-east-1"
```

### Google Cloud Storage

```bash
export STORAGE_TYPE="gcs"
export GCS_BUCKET="my-backups"
export GCS_PATH="postgres/"
```

### Backblaze B2

```bash
export STORAGE_TYPE="b2"
export B2_BUCKET="my-backups"
export B2_PATH="postgres/"
```

## Commands

```bash
# Run backup
pg-backup

# Test connection
pg-backup --test

# List available backups
pg-backup --list

# Restore from backup
pg-backup --restore /path/to/backup.sql.gz

# Show backup status
pg-backup --status

# Show help
pg-backup --help
```

## Cron Setup

### Daily Backup at 2 AM

```bash
# Edit crontab
crontab -e

# Add this line
0 2 * * * pg-backup
```

## License

MIT

## Author

αB - [GitHub](https://github.com/AlphaB135)
