#!/bin/bash
# ===========================================================================
# store-pre.sh — BEFORE_BACKUP hook for the "store" job
# ===========================================================================
# Runs before the backup. Its job here is to make sure the backup storage is
# available (mounted) before restic starts.
#
# SECURITY: backup-restic validates this file before running it. It must be a
# regular file (not a symlink), owned by root, executable, and not writable by
# group/other. See the setup commands in the README note.
#
# Exit status matters:
#   0      -> continue with the backup
#   non-0  -> failed before-hook; what happens next depends on
#             BEFORE_BACKUP_FAILURE (abort = stop, ignore = continue anyway)
#
# Environment provided by backup-restic:
#   BACKUP_RESTIC_JOB       job name ("store")
#   BACKUP_RESTIC_MODE      "BACKUP" or "DRY RUN"
#   BACKUP_RESTIC_DRY_RUN   "1" or "0"
#   BACKUP_RESTIC_PHASE     "before"
#   BACKUP_RESTIC_STATUS    "success" at this point
#   BACKUP_RESTIC_REASON    "" at this point

set -uo pipefail

# --- what to mount ----------------------------------------------------------
MOUNT_POINT="/mnt/backups"

# Pick ONE mount style and comment out the others.

# Local block device (by-label/by-uuid is more stable than /dev/sdX):
DEVICE="/dev/disk/by-label/BACKUPS"
FS_TYPE="ext4"
MOUNT_OPTS="rw,noatime"

# NFS share:
#DEVICE="nas.example.com:/volume1/backups"
#FS_TYPE="nfs"
#MOUNT_OPTS="rw,soft,timeo=30"

# CIFS/SMB share (keep credentials in a root-only 0600 file, never inline):
#DEVICE="//nas.example.com/backups"
#FS_TYPE="cifs"
#MOUNT_OPTS="credentials=/etc/backup-restic/cifs-store.cred,iocharset=utf8"

# --- optional: skip mounting during a dry run --------------------------------
# Uncomment if a dry run should not mount real storage (e.g. to avoid waking a
# NAS). Note: if MOUNT_CHECK is set for this job, the dry run will then fail
# its mount preflight - which is usually the desired behaviour.
#if [ "${BACKUP_RESTIC_DRY_RUN:-0}" = "1" ]; then
#    echo "store-pre: dry run - not mounting $MOUNT_POINT"
#    exit 0
#fi

# Idempotency: if it's already mounted, there's nothing to do.
if mountpoint -q "$MOUNT_POINT"; then
    echo "store-pre: $MOUNT_POINT already mounted"
    exit 0
fi

echo "store-pre: mounting $DEVICE at $MOUNT_POINT"
if ! mount -t "$FS_TYPE" -o "$MOUNT_OPTS" "$DEVICE" "$MOUNT_POINT"; then
    echo "store-pre: FAILED to mount $DEVICE at $MOUNT_POINT" >&2
    exit 1
fi

echo "store-pre: $MOUNT_POINT mounted"
exit 0
