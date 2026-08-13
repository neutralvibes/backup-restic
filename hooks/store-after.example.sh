#!/bin/bash
# ===========================================================================
# store-post.sh — AFTER_BACKUP hook for the "store" job
# ===========================================================================
# Runs after the backup, ALWAYS - even when the backup failed. Use it for
# cleanup that must happen regardless of outcome (unmount, unfreeze, remove
# temp files) and to react to the result.
#
# SECURITY: same requirements as the before hook (root-owned, executable,
# not group/world writable).
#
# Environment provided by backup-restic:
#   BACKUP_RESTIC_JOB       job name ("store")
#   BACKUP_RESTIC_MODE      "BACKUP" or "DRY RUN"
#   BACKUP_RESTIC_DRY_RUN   "1" or "0"
#   BACKUP_RESTIC_PHASE     "after"
#   BACKUP_RESTIC_STATUS    "success" or "failure" (outcome so far)
#   BACKUP_RESTIC_REASON    failure category when status=failure, e.g.
#                           "backup", "before_hook"; empty on success
#
# Exit status matters:
#   0      -> after-hook succeeded
#   non-0  -> marks the after-hook as failed. If the backup already failed the
#             original reason is preserved; if it succeeded, the job is then
#             reported as failed with reason "after_hook".

set -uo pipefail

MOUNT_POINT="/mnt/backups"

status="${BACKUP_RESTIC_STATUS:-success}"
reason="${BACKUP_RESTIC_REASON:-}"

echo "store-post: backup finished with status=$status${reason:+ reason=$reason}"

case "$status" in
    success)
        # e.g. rotate an external drive offline, send a separate alert, etc.
        ;;
    failure)
        # Leave the drive mounted so you can inspect what went wrong.
        echo "store-post: backup failed (${reason:-unknown reason}); keeping $MOUNT_POINT mounted for inspection" >&2
        exit 0
        ;;
esac

# --- cleanup: unmount -------------------------------------------------------
# Reached only on success (the failure case exited above), so a failed run
# leaves the data accessible. Remove the case guard if you always want to
# unmount.
if mountpoint -q "$MOUNT_POINT"; then
    echo "store-post: unmounting $MOUNT_POINT"
    if ! umount "$MOUNT_POINT"; then
        # A busy/failed unmount is usually not worth failing the whole job
        # over, so warn and exit 0. Change to `exit 1` if you want a failed
        # unmount to mark the after-hook (and the job) as failed.
        echo "store-post: WARNING - could not unmount $MOUNT_POINT (busy?)" >&2
        exit 0
    fi
    echo "store-post: $MOUNT_POINT unmounted"
fi

exit 0
