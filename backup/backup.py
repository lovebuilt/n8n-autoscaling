import os
import sys
import time
import shutil
import tarfile
import logging
import subprocess
import smtplib
from datetime import datetime, timezone, timedelta
from email.mime.text import MIMEText
from pathlib import Path
from dotenv import load_dotenv
from croniter import croniter
import redis

load_dotenv()

# --- Logging Setup ---
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# --- Configuration from Environment Variables ---
POSTGRES_HOST = os.getenv('POSTGRES_HOST', 'postgres')
POSTGRES_DB = os.getenv('POSTGRES_DB', 'n8n')
POSTGRES_USER = os.getenv('POSTGRES_USER', 'postgres')
POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', '')

REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', '6379'))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD', '')

BACKUP_SCHEDULE = os.getenv('BACKUP_SCHEDULE', '0 2 * * *')
BACKUP_RETENTION_DAYS = int(os.getenv('BACKUP_RETENTION_DAYS', '30'))
BACKUP_ENCRYPTION_KEY = os.getenv('BACKUP_ENCRYPTION_KEY', '')
BACKUP_RCLONE_DESTINATIONS = os.getenv('BACKUP_RCLONE_DESTINATIONS', '')
BACKUP_RUN_ON_START = os.getenv('BACKUP_RUN_ON_START', 'false').lower() == 'true'
BACKUP_DELETE_LOCAL_AFTER_UPLOAD = os.getenv('BACKUP_DELETE_LOCAL_AFTER_UPLOAD', 'false').lower() == 'true'
BACKUP_WEBHOOK_URL = os.getenv('BACKUP_WEBHOOK_URL', '')

SMTP_HOST = os.getenv('SMTP_HOST', '')
SMTP_PORT = int(os.getenv('SMTP_PORT', '587'))
SMTP_USER = os.getenv('SMTP_USER', '')
SMTP_PASSWORD = os.getenv('SMTP_PASSWORD', '')
SMTP_TO = os.getenv('SMTP_TO', '')

BACKUP_DIR = Path('/backups')
N8N_MAIN_DATA = Path('/data/n8n_main')
N8N_WEBHOOK_DATA = Path('/data/n8n_webhook')
REDIS_DATA = Path('/data/redis')
SUBPROCESS_TIMEOUT = 600  # 10 minutes for large backups


def run_pg_dump(output_path):
    """Runs pg_dump and saves a compressed custom-format dump."""
    logging.info(f"Starting PostgreSQL backup of database '{POSTGRES_DB}' on host '{POSTGRES_HOST}'...")
    env = os.environ.copy()
    env['PGPASSWORD'] = POSTGRES_PASSWORD

    cmd = [
        'pg_dump',
        '-h', POSTGRES_HOST,
        '-U', POSTGRES_USER,
        '-d', POSTGRES_DB,
        '-Fc',  # Custom format (compressed, supports pg_restore)
        '-f', str(output_path)
    ]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
    if result.returncode != 0:
        raise RuntimeError(f"pg_dump failed (exit {result.returncode}): {result.stderr.strip()}")

    size_mb = output_path.stat().st_size / (1024 * 1024)
    logging.info(f"PostgreSQL backup complete: {output_path.name} ({size_mb:.1f} MB)")


def run_redis_backup(output_path):
    """Triggers a Redis BGSAVE and copies the resulting RDB dump."""
    logging.info("Starting Redis backup...")
    try:
        r = redis.Redis(
            host=REDIS_HOST, port=REDIS_PORT,
            password=REDIS_PASSWORD or None, decode_responses=True
        )
        r.ping()

        # Record the last save time before triggering a new one
        last_save = r.lastsave()

        # Trigger background save
        r.bgsave()
        logging.info("Redis BGSAVE triggered, waiting for completion...")

        # Poll until save completes (up to 5 minutes)
        timeout = 300
        start = time.time()
        while time.time() - start < timeout:
            current_save = r.lastsave()
            if current_save > last_save:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Redis BGSAVE timed out after 5 minutes")

        # Copy the dump.rdb from the mounted volume
        rdb_path = REDIS_DATA / 'dump.rdb'
        if rdb_path.exists():
            import gzip
            with open(rdb_path, 'rb') as f_in:
                with gzip.open(str(output_path), 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            size_mb = output_path.stat().st_size / (1024 * 1024)
            logging.info(f"Redis backup complete: {output_path.name} ({size_mb:.1f} MB)")
        else:
            logging.warning("Redis dump.rdb not found at mounted volume, skipping Redis backup")

    except redis.exceptions.ConnectionError as e:
        logging.warning(f"Could not connect to Redis for backup (non-fatal): {e}")
    except Exception as e:
        logging.warning(f"Redis backup failed (non-fatal): {e}")


def tar_volume_data(output_path, data_paths):
    """Creates a compressed tar archive of n8n volume data."""
    logging.info("Archiving n8n volume data...")
    with tarfile.open(output_path, 'w:gz') as tar:
        for data_path in data_paths:
            if data_path.exists() and any(data_path.iterdir()):
                tar.add(str(data_path), arcname=data_path.name)
                logging.info(f"  Added {data_path.name}")
            else:
                logging.debug(f"  Skipping {data_path.name} (empty or missing)")

    size_mb = output_path.stat().st_size / (1024 * 1024)
    logging.info(f"Volume archive complete: {output_path.name} ({size_mb:.1f} MB)")


def create_final_archive(timestamp, pg_dump_path, volumes_path, redis_dump_path=None):
    """Bundles the pg_dump, volume archive, and optional Redis dump into a single archive."""
    archive_name = f"n8n-backup-{timestamp}.tar.gz"
    archive_path = BACKUP_DIR / archive_name

    with tarfile.open(archive_path, 'w:gz') as tar:
        tar.add(str(pg_dump_path), arcname=pg_dump_path.name)
        tar.add(str(volumes_path), arcname=volumes_path.name)
        if redis_dump_path and redis_dump_path.exists():
            tar.add(str(redis_dump_path), arcname=redis_dump_path.name)

    size_mb = archive_path.stat().st_size / (1024 * 1024)
    logging.info(f"Final archive: {archive_name} ({size_mb:.1f} MB)")
    return archive_path


def encrypt_archive(archive_path):
    """Encrypts the archive with GPG symmetric encryption."""
    if not BACKUP_ENCRYPTION_KEY:
        return archive_path

    logging.info("Encrypting backup archive...")
    encrypted_path = archive_path.with_suffix(archive_path.suffix + '.gpg')
    cmd = [
        'gpg', '--batch', '--yes', '--symmetric',
        '--cipher-algo', 'AES256',
        '--passphrase-fd', '0',
        '--output', str(encrypted_path),
        str(archive_path)
    ]

    result = subprocess.run(
        cmd, input=BACKUP_ENCRYPTION_KEY,
        capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT
    )
    if result.returncode != 0:
        raise RuntimeError(f"GPG encryption failed: {result.stderr.strip()}")

    # Remove unencrypted archive
    archive_path.unlink()
    size_mb = encrypted_path.stat().st_size / (1024 * 1024)
    logging.info(f"Encrypted archive: {encrypted_path.name} ({size_mb:.1f} MB)")
    return encrypted_path


def upload_to_destinations(file_path):
    """Uploads the backup file to all configured rclone destinations."""
    if not BACKUP_RCLONE_DESTINATIONS:
        logging.warning("No BACKUP_RCLONE_DESTINATIONS configured. Backup saved locally only.")
        return

    destinations = [d.strip() for d in BACKUP_RCLONE_DESTINATIONS.split(',') if d.strip()]
    if not destinations:
        logging.warning("No valid rclone destinations found. Backup saved locally only.")
        return

    for dest in destinations:
        dest_path = f"{dest}/{file_path.name}"
        logging.info(f"Uploading to {dest_path}...")
        cmd = [
            'rclone', 'copyto',
            str(file_path), dest_path,
            '--config', '/config/rclone/rclone.conf',
            '--progress'
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
        if result.returncode != 0:
            raise RuntimeError(f"rclone upload to '{dest}' failed: {result.stderr.strip()}")
        logging.info(f"Upload to {dest} complete.")


def cleanup_old_backups():
    """Removes local backups older than BACKUP_RETENTION_DAYS."""
    if BACKUP_RETENTION_DAYS <= 0:
        return

    cutoff = datetime.now(timezone.utc) - timedelta(days=BACKUP_RETENTION_DAYS)
    removed = 0

    for f in BACKUP_DIR.glob('n8n-backup-*'):
        if f.is_file() and datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc) < cutoff:
            f.unlink()
            removed += 1
            logging.debug(f"Removed old backup: {f.name}")

    if removed:
        logging.info(f"Cleaned up {removed} old local backup(s).")


def cleanup_remote_backups():
    """Removes remote backups older than BACKUP_RETENTION_DAYS using rclone delete."""
    if not BACKUP_RCLONE_DESTINATIONS or BACKUP_RETENTION_DAYS <= 0:
        return

    destinations = [d.strip() for d in BACKUP_RCLONE_DESTINATIONS.split(',') if d.strip()]
    for dest in destinations:
        logging.info(f"Cleaning up old backups on {dest}...")
        cmd = [
            'rclone', 'delete',
            dest,
            '--config', '/config/rclone/rclone.conf',
            '--min-age', f"{BACKUP_RETENTION_DAYS}d",
            '--include', 'n8n-backup-*'
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
        if result.returncode != 0:
            logging.warning(f"Remote cleanup on '{dest}' failed: {result.stderr.strip()}")
        else:
            logging.info(f"Remote cleanup on {dest} complete.")


def send_notification(subject, body, is_error=False):
    """Sends a notification via email and/or webhook."""
    if SMTP_HOST and SMTP_TO:
        try:
            msg = MIMEText(body)
            msg['Subject'] = subject
            msg['From'] = SMTP_USER or f"n8n-backup@{POSTGRES_HOST}"
            msg['To'] = SMTP_TO

            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as server:
                server.starttls()
                if SMTP_USER and SMTP_PASSWORD:
                    server.login(SMTP_USER, SMTP_PASSWORD)
                server.send_message(msg)
            logging.info("Email notification sent.")
        except Exception as e:
            logging.error(f"Failed to send email notification: {e}")

    if BACKUP_WEBHOOK_URL:
        try:
            import json
            import urllib.request
            payload = json.dumps({
                'event': 'backup_error' if is_error else 'backup_success',
                'subject': subject,
                'body': body,
                'timestamp': datetime.now(timezone.utc).isoformat()
            }).encode('utf-8')
            req = urllib.request.Request(
                BACKUP_WEBHOOK_URL,
                data=payload,
                headers={'Content-Type': 'application/json'}
            )
            urllib.request.urlopen(req, timeout=30)
            logging.info("Webhook notification sent.")
        except Exception as e:
            logging.error(f"Failed to send webhook notification: {e}")


def run_backup():
    """Executes a single backup cycle."""
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    work_dir = BACKUP_DIR / f"work-{timestamp}"
    work_dir.mkdir(parents=True, exist_ok=True)

    try:
        # Step 1: PostgreSQL dump
        pg_dump_path = work_dir / 'database.dump'
        run_pg_dump(pg_dump_path)

        # Step 2: Redis backup
        redis_dump_path = work_dir / 'redis.rdb.gz'
        run_redis_backup(redis_dump_path)

        # Step 3: Archive n8n volume data
        volumes_path = work_dir / 'volumes.tar.gz'
        tar_volume_data(volumes_path, [N8N_MAIN_DATA, N8N_WEBHOOK_DATA])

        # Step 4: Create final archive
        archive_path = create_final_archive(timestamp, pg_dump_path, volumes_path, redis_dump_path)

        # Step 5: Encrypt if configured
        final_path = encrypt_archive(archive_path)

        # Step 6: Upload to remote destinations
        upload_to_destinations(final_path)

        size_mb = final_path.stat().st_size / (1024 * 1024)

        # Step 7: Delete local copy after successful upload if configured
        if BACKUP_DELETE_LOCAL_AFTER_UPLOAD and BACKUP_RCLONE_DESTINATIONS:
            final_path.unlink()
            logging.info("Local backup deleted after successful remote upload.")

        # Step 8: Cleanup old backups
        cleanup_old_backups()
        cleanup_remote_backups()
        send_notification(
            f"n8n Backup Successful - {timestamp}",
            f"Backup completed successfully.\n\nFile: {final_path.name}\nSize: {size_mb:.1f} MB\nEncrypted: {'Yes' if BACKUP_ENCRYPTION_KEY else 'No'}\nDestinations: {BACKUP_RCLONE_DESTINATIONS or 'local only'}"
        )
        logging.info(f"Backup cycle complete: {final_path.name}")

    except Exception as e:
        logging.error(f"Backup failed: {e}")
        send_notification(
            f"n8n Backup FAILED - {timestamp}",
            f"Backup failed with error:\n\n{e}",
            is_error=True
        )
        raise
    finally:
        # Clean up working directory
        if work_dir.exists():
            shutil.rmtree(work_dir)


def main():
    logging.info("n8n Backup Service starting...")
    logging.info(f"  Schedule: {BACKUP_SCHEDULE}")
    logging.info(f"  Retention: {BACKUP_RETENTION_DAYS} days")
    logging.info(f"  Encryption: {'enabled' if BACKUP_ENCRYPTION_KEY else 'disabled'}")
    logging.info(f"  Destinations: {BACKUP_RCLONE_DESTINATIONS or 'local only'}")
    logging.info(f"  Run on start: {BACKUP_RUN_ON_START}")

    # Validate cron expression
    if not croniter.is_valid(BACKUP_SCHEDULE):
        logging.error(f"Invalid BACKUP_SCHEDULE cron expression: '{BACKUP_SCHEDULE}'")
        sys.exit(1)

    # Run immediately on start if configured
    if BACKUP_RUN_ON_START:
        logging.info("Running initial backup on start...")
        try:
            run_backup()
        except Exception:
            logging.error("Initial backup failed, but continuing to schedule future backups.")

    # Schedule loop
    cron = croniter(BACKUP_SCHEDULE, datetime.now(timezone.utc))
    while True:
        next_run = cron.get_next(datetime)
        wait_seconds = (next_run - datetime.now(timezone.utc)).total_seconds()

        if wait_seconds > 0:
            logging.info(f"Next backup scheduled at {next_run.strftime('%Y-%m-%d %H:%M:%S UTC')} (in {wait_seconds/3600:.1f}h)")
            time.sleep(max(wait_seconds, 0))

        try:
            run_backup()
        except Exception:
            logging.error("Backup failed. Will retry at next scheduled time.")


if __name__ == "__main__":
    main()
