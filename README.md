# backup-restic

A **job-based wrapper around [restic](https://restic.net/)** that turns per-repository
backup chores into declarative, self-contained jobs — with security validation,
hooks, notifications, retention/prune control, and logging built in.

> **Status:** please test restores before trusting it with data you
> can't afford to lose.

---

## Why?

`restic` is excellent, but running it by hand means remembering a repository path,
a password file, tags, retention flags, and the right sequence of commands for
*every* repository. `backup-restic` collapses all of that into named jobs:

```bash
backup-restic run pve        # back up using the "pve" job definition
backup-restic run --all      # back up everything
backup-restic restore pve a1b2c3d4 --target /tmp/restore-test
```

Each job is a single config file describing **what** to back up, **where** it goes,
**how long** to keep it, and **what to do** before/after. The wrapper handles the rest — safely.

> **Note:** `restic` must be installed on your system to use this wrapper.

### Highlights

- **Job-based config** — one file per backup set (`jobs.d/<job>.conf`) plus a shared
  global config, with a clear precedence chain.
- **Security-first** — configs, hooks, and credentials are validated before use
  (ownership, permissions, symlink and writable-ancestor checks).
- **Hooks** — run scripts before/after a backup (mount drives, dump databases,
  freeze filesystems), with the outcome passed in via environment variables.
- **Retention & prune control** — decide whether `run` prunes automatically, or keep
  pruning explicit and run it on your own schedule.
- **Notifications** — Pushover or generic webhook on success/failure, with the
  failure reason included in the message.
- **Safe dry-run** — `--dry-run` never touches your real repo, and offers a
  throwaway temp repo if the target isn't initialised yet.
- **Logging & locking** — per-job logs, a global lock to prevent concurrent runs,
  and a `-q` quiet mode for cron.
- **Restic version check** — refuses to run against a restic that's too old.

---

## Table of contents

- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Command reference](#command-reference)
- [Retention & pruning](#retention--pruning)
- [Hooks](#hooks)
- [Notifications](#notifications)
- [Dry-run](#dry-run)
- [Security model](#security-model)
- [Logging](#logging)
- [Scheduling with cron](#scheduling-with-cron)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Dependency            | Notes                                     |
|-----------------------|-------------------------------------------|
| `bash` >= 4.4         | Uses arrays and modern expansions         |
| `restic` >= 0.15.0    | Checked at startup (`MIN_RESTIC_VERSION`) |
| GNU coreutils         | `stat`, `date`, `sort`, `mktemp`          |
| `curl`                | Only if notifications are enabled         |
| `flock`, `mountpoint` | Standard on Linux (`util-linux`)          |

Targets Linux. It is not intended to be POSIX-portable or to run on macOS/BSD.

---

## How it works

- A **job** is a config file at `jobs.d/<job>.conf`. The filename is the job name.
- Each job's snapshots are tagged with the job name, so one repository can hold
  many jobs, or each job can have its own repository.
- `backup-restic` resolves the job's repo + password, then drives `restic backup`,
  `restic forget`, and (optionally) `restic prune` for you.
- Config lives **alongside the script**. Symlinks are followed, so you can keep
  everything in `/opt/backup-restic/` and symlink the binary into your `PATH`.

---

## Installation

`backup-restic` is installed directly from its source repository using the included
`install.sh` script. The installer automatically detects your privileges: running it
as `root` performs a system-wide installation, while running it as a standard user
performs a local, user-scoped installation.

**Installer guarantees:**
* **Non-interactive:** Safe to use in automated scripts and CI/CD pipelines.
* **Idempotent:** Re-running the installer is the official upgrade path.
* **Config-safe:** Your active configurations (`backup-restic.conf`, `jobs.d/*.conf`,
  and custom hooks) are **never** overwritten. Only the core script and `.example`
  templates are updated.

### System-wide install (as root)

Installs the wrapper for all users on the system. Ideal for servers and workstations
where backups run via `root` cron jobs.

```bash
sudo git clone --depth 1 https://<repo-url>/backup-restic.git /usr/local/src/backup-restic
cd /usr/local/src/backup-restic
sudo ./install.sh
```

**System file locations:**

| Component                   | Location                               |
|-----------------------------|----------------------------------------|
| Core script, configs, hooks | `/opt/backup-restic/`                  |
| Executable symlink          | `/usr/local/bin/backup-restic`         |
| Bash completion             | `/etc/bash_completion.d/backup-restic` |
| Logrotate policy            | `/etc/logrotate.d/backup-restic`       |
| Runtime logs                | `/var/log/backup-restic/`              |

### User-scoped install (as standard user)

Installs the wrapper entirely within your home directory. Ideal for backing up
personal files without requiring `sudo` privileges.

```bash
git clone --depth 1 https://<repo-url>/backup-restic.git ~/src/backup-restic
cd ~/src/backup-restic
./install.sh
```

*Note: Ensure `~/.local/bin` is in your `$PATH`. The installer will print a reminder
if it is missing.*

**User file locations:**

| Component                   | Location                                                   |
|-----------------------------|------------------------------------------------------------|
| Core script, configs, hooks | `~/.config/backup-restic/`                                 |
| Executable symlink          | `~/.local/bin/backup-restic`                               |
| Bash completion             | `~/.local/share/bash-completion/completions/backup-restic` |
| Runtime logs                | `~/.local/state/backup-restic/`                            |

### Upgrading

To upgrade to the latest version, simply pull the latest changes and re-run the
installer. Your configurations will be preserved.

```bash
cd /path/to/cloned/backup-restic
sudo git pull      # or `git pull` for user installs
sudo ./install.sh  # or `./install.sh`
```

### Verify and Next Steps

Verify the installation by checking the version:

```bash
backup-restic --version
```

> **Note on Bash Completion:** The installer configures tab completion automatically.
> Open a new terminal session or run `source ~/.bashrc` (or equivalent) to enable it.

Once verified, proceed to the [Quick start](#quick-start) guide to configure your
first backup job.

---

## Quick start

A minimal, working setup in five steps. *(Assumes a system-wide installation).*

**1. Create a password file** (one line, root-only):

```bash
sudo mkdir -p /etc/backup-restic
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/backup-restic/restic-password'
```

**2. Write the global config** at `/opt/backup-restic/backup-restic.conf`:

```bash
DEFAULT_PASSWORD_FILE="/etc/backup-restic/restic-password"
DEFAULT_REPO_BASE="/mnt/backups/restic"
```

**3. Create a job** at `/opt/backup-restic/jobs.d/home.conf`:

```bash
REPO_NAME="home"                 # repo resolves to /mnt/backups/restic/home
PATHS=("/home" "/etc")
EXCLUDES=("*.cache" ".cache/")
```

**4. Initialise and run:**

```bash
sudo backup-restic init home
sudo backup-restic run home
```

**5. Inspect:**

```bash
sudo backup-restic ls home            # snapshots
sudo backup-restic config home        # fully resolved config
```

---

## Configuration

Two layers: a **global** config shared by all jobs, and one **job** config per job.
Both are plain bash files that are *sourced*, so they must pass the
[security checks](#security-model).

### Global config

Lives at `backup-restic.conf` next to the script. Sets defaults for every job.

| Variable                        | Default                                           | Description                                                            |
|---------------------------------|---------------------------------------------------|------------------------------------------------------------------------|
| `DEFAULT_PASSWORD_FILE`         | *(empty)*                                         | Fallback restic password file for jobs that don't set `PASSWORD_FILE`. |
| `DEFAULT_REPO_BASE`             | *(empty)*                                         | Base directory for repos resolved via `REPO_NAME`.                     |
| `DEFAULT_REPO_NAME`             | *(empty)*                                         | Shared repo name used when a job sets neither `REPO` nor `REPO_NAME`.  |
| `DEFAULT_RETENTION`             | `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` | Default retention flags passed to `restic forget`.                     |
| `LOG_DIR`                       | `/var/log/backup-restic`                          | Directory for per-job log files.                                       |
| `DEFAULT_FORGET_WHEN`           | `after`                                           | When retention runs during `run` (`after` \| `before`).                |
| `DEFAULT_FORGET_AUTO_PRUNE`     | `false`                                           | Whether retention during `run` also prunes.                            |
| `DEFAULT_BEFORE_BACKUP_FAILURE` | `abort`                                           | What to do when a before-hook fails (`abort` \| `ignore`).             |
| `NOTIFY_METHOD`                 | `none`                                            | Notification method (`none` \| `pushover` \| `webhook`).               |
| `NOTIFY_ON`                     | `failure`                                         | When to notify (`failure` \| `success` \| `both`).                     |
| `NOTIFY_CREDENTIALS_FILE`       | *(empty)*                                         | File holding notification secrets, loaded lazily.                      |
| `MIN_RESTIC_VERSION`            | `0.15.0`                                          | Minimum acceptable restic version.                                     |

`PUSHOVER_TOKEN`, `PUSHOVER_USER`, and `WEBHOOK_URL` may also be set here, but
prefer [`NOTIFY_CREDENTIALS_FILE`](#notifications) for secrets.

### Job config

Lives at `jobs.d/<job>.conf`. Job names may contain `A-Z a-z 0-9 . _ -`.

| Variable                 | Required | Description                                                                 |
|--------------------------|:--------:|-----------------------------------------------------------------------------|
| `REPO`                   | *        | Full repo location — a local path or restic URL (`sftp:`, `s3:`, `rest:`).  |
| `REPO_NAME`              | *        | Repo name; resolves to `$DEFAULT_REPO_BASE/$REPO_NAME`. Use **or** `REPO`.  |
| `PASSWORD_FILE`          | no       | Restic password file for this job (falls back to `DEFAULT_PASSWORD_FILE`).  |
| `PATHS`                  | **yes**  | Array of paths to back up. Must be non-empty.                               |
| `EXCLUDES`               | no       | Array of restic `--exclude` patterns.                                       |
| `RETENTION`              | no       | Retention flags for this job (falls back to `DEFAULT_RETENTION`).           |
| `FORGET_WHEN`            | no       | `after` \| `before` — when retention runs during `run`.                     |
| `FORGET_AUTO_PRUNE`      | no       | `true` \| `false` — whether retention during `run` prunes.                  |
| `MOUNT_CHECK`            | no       | Mountpoint that must be mounted before the backup proceeds.                 |
| `BEFORE_BACKUP`          | no       | Executable run before the backup.                                           |
| `BEFORE_BACKUP_FAILURE`  | no       | `abort` \| `ignore` — what to do if the before-hook fails.                  |
| `AFTER_BACKUP`           | no       | Executable run after the backup (runs even on failure).                     |
| `NOTIFY_METHOD_OVERRIDE` | no       | Override the global `NOTIFY_METHOD` for this job.                           |
| `NOTIFY_ON_OVERRIDE`     | no       | Override the global `NOTIFY_ON` for this job.                               |

\* A repo is required, but it can come from `REPO`, `REPO_NAME`, or the global
`DEFAULT_REPO_NAME`.

**Repo resolution notes:**

- If `REPO` is set it wins; otherwise `REPO_NAME` (or `DEFAULT_REPO_NAME`) is
  combined with `DEFAULT_REPO_BASE`.
- A bare **relative** local path (no leading `/`, no URL scheme) is anchored to the
  config directory rather than your current working directory — and a loud warning
  is printed. Prefer absolute paths.

### Precedence

```text
built-in default  ->  backup-restic.conf  ->  jobs.d/<job>.conf
```

Every `DEFAULT_*` global can be overridden per job, and job-scoped variables are
reset between jobs so a `run --all` never leaks one job's settings into another.

---

## Command reference

| Command                              | Description                                                   |
|--------------------------------------|---------------------------------------------------------------|
| `ls`                                 | List configured jobs                                          |
| `ls JOB`                             | List snapshots for a job                                      |
| `ls JOB SNAPSHOT`                    | List files in a snapshot                                      |
| `config JOB`                         | Show a job's fully resolved config                            |
| `edit JOB`                           | Open a job's config in `$EDITOR` (default `nano`)             |
| `run JOB\|--all [restic args]`       | Backup + retention. Supports `-q/--quiet`, `--dry-run`.       |
| `forget JOB [restic args]`           | Apply retention policy only (no prune unless `--prune` given) |
| `prune JOB [restic args]`            | Prune the repo to reclaim space (expensive)                   |
| `check JOB [restic args]`            | Check repo integrity (`--read-data` supported)                |
| `unlock JOB [restic args]`           | Remove stale locks                                            |
| `init JOB [restic args]`             | Initialise a job's repo                                       |
| `restore JOB SNAPSHOT [restic args]` | Restore a snapshot; requires `--target DIR`                   |
| `--completion [print\|install]`      | Bash completion (default: `print`)                            |
| `--logrotate [print\|install]`       | Logrotate config (default: `print`)                           |
| `--version` / `--help`               | Meta                                                          |

Any extra arguments after the job name are passed straight through to the
underlying `restic` command, so you can use the full power of restic when you need it.

---

## Retention & pruning

Pruning reclaims disk space but can be **slow and expensive**, so it is kept
separate from forgetting by default:

| Command      | Forgets old snapshots? | Prunes (reclaims space)?         |
|--------------|:----------------------:|:--------------------------------:|
| `run JOB`    | Yes                    | Only if `FORGET_AUTO_PRUNE=true` |
| `forget JOB` | Yes                    | No (add `--prune` to force)      |
| `prune JOB`  | —                      | Yes, always                      |

**Recommended workflow:** leave `FORGET_AUTO_PRUNE=false` so daily runs stay fast,
and reclaim space on a schedule you control:

```bash
backup-restic prune home      # e.g. weekly, via cron
```

> **Behaviour note:** with `FORGET_AUTO_PRUNE=false`, `run` drops old snapshots
> from the index but does **not** free space until you `prune`. Repos will grow in
> the meantime — this is intentional.

---

## Hooks

Hooks let you run a script immediately before or after a backup. The common use for
`BEFORE_BACKUP` is **mounting a drive or network share** — the before-hook runs
*before* the `MOUNT_CHECK`, so it can perform the mount that the check then verifies.

```bash
MOUNT_CHECK="/mnt/backups"
BEFORE_BACKUP="$CONFIG_DIR/hooks/store-before.sh"
BEFORE_BACKUP_FAILURE="abort"        # abort | ignore
AFTER_BACKUP="$CONFIG_DIR/hooks/store-after.sh"
```

- Hooks are validated against the [security model](#security-model) before execution.
- They run as a **single executable** (no arguments are passed).
- Their stdout/stderr is captured into the job's log.
- `BEFORE_BACKUP_FAILURE=abort` stops the job if the hook fails; `ignore` logs a
  warning and continues.
- `AFTER_BACKUP` always runs, even when the backup failed, so it's the right place
  for cleanup (unmount, unfreeze, remove temp files).

### Hook environment

| Variable                | Description                                                                            |
|-------------------------|----------------------------------------------------------------------------------------|
| `BACKUP_RESTIC_JOB`     | Job name                                                                               |
| `BACKUP_RESTIC_MODE`    | `BACKUP` or `DRY RUN`                                                                  |
| `BACKUP_RESTIC_DRY_RUN` | `1` on a dry run, else `0`                                                             |
| `BACKUP_RESTIC_PHASE`   | `before` or `after`                                                                    |
| `BACKUP_RESTIC_STATUS`  | `success` or `failure` (in the after-hook, the outcome so far)                         |
| `BACKUP_RESTIC_REASON`  | Failure category (`backup`, `before_hook`, `after_hook`), empty on success             |

---

## Notifications

```bash
NOTIFY_METHOD="pushover"            # none | pushover | webhook
NOTIFY_ON="failure"                 # failure | success | both
NOTIFY_CREDENTIALS_FILE="/etc/backup-restic/notify-credentials"
```

- `pushover` requires `PUSHOVER_TOKEN` and `PUSHOVER_USER`.
- `webhook` POSTs a JSON payload (`job`, `status`, `reason`, `message`) to `WEBHOOK_URL`.
- Per-job behaviour is overridden with `NOTIFY_METHOD_OVERRIDE` / `NOTIFY_ON_OVERRIDE`.

**Credentials are loaded lazily** — `NOTIFY_CREDENTIALS_FILE` is only sourced at the
moment a notification is actually sent, so secrets don't sit in the environment for
the whole backup run. The file is bash-sourced and must pass the security checks:

```bash
# /etc/backup-restic/notify-credentials  (root:root, 0600)
PUSHOVER_TOKEN="abc123..."
PUSHOVER_USER="xyz789..."
# WEBHOOK_URL="https://hooks.example.com/..."
```

Failure notifications include the reason and detail, e.g.:

```text
Job home: failure | reason: backup | detail: restic backup exited 1 (elapsed: 00:02:14)
```

---

## Dry-run

```bash
backup-restic run home --dry-run
```

- Backs up to restic in dry-run mode, skips retention, and never writes snapshots.
- Hooks and preflight checks still run, so you can validate the whole pipeline.
- **Uninitialised repo:** if the target repo doesn't exist yet and you're on an
  interactive terminal, you'll be offered a **temporary throwaway repo** to run the
  dry-run against (removed afterwards; your real repo is untouched). Declining it
  skips the dry-run gracefully. Non-interactive runs skip automatically.

---

## Security model

Configs, hooks, and credentials are **trusted input** — they are sourced or
executed — so `backup-restic` validates them before use and refuses anything risky.

Every trusted file must be:

- a **regular file** (not a symlink),
- **owned by root** when running as root (root must never consume user-owned
  config/hooks — that would let an unprivileged user control code run as root);
  a non-root user may use files they own or root-owned files,
- **not writable** by group or others,
- **readable** by the current user,
- located in directories that are **not group/world writable** unless protected by
  the sticky bit.

Hooks additionally must be **executable**.

### Recommended permissions

```bash
chown root:root /opt/backup-restic/backup-restic.conf /opt/backup-restic/jobs.d/*.conf
chmod 0640      /opt/backup-restic/backup-restic.conf /opt/backup-restic/jobs.d/*.conf

chown root:root /etc/backup-restic/restic-password
chmod 0600      /etc/backup-restic/restic-password
```

> **Known limitation:** there is an inherent check-then-use gap between validation
> and execution. The writable-ancestor check is specifically there to mitigate it —
> if nobody else can write the containing directories, the file can't be swapped.

---

## Logging

- Each job writes to `$LOG_DIR/<job>.log`; `run --all` also writes `$LOG_DIR/all.log`.
- `run -q/--quiet` logs to file only (not stdout) — ideal for cron.
- A `flock`-based lock prevents two `backup-restic` processes from running at once.

Generate a ready-to-use logrotate config:

```bash
backup-restic --logrotate print        # view
sudo backup-restic --logrotate install # install to /etc/logrotate.d/backup-restic
```

---

## Scheduling with cron

```cron
# Nightly: back up everything, quietly (log to file only)
0 2 * * *   root  /usr/local/bin/backup-restic run --all --quiet

# Weekly: reclaim space (expensive, so kept separate)
0 4 * * 0   root  /usr/local/bin/backup-restic prune home
```

`backup-restic` exits non-zero when a job fails, so standard cron `MAILTO` handling
will surface problems.

---

## Examples

### Global config — `backup-restic.conf`

```bash
DEFAULT_PASSWORD_FILE="/etc/backup-restic/restic-password"
DEFAULT_REPO_BASE="/mnt/backups/restic"
DEFAULT_RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
DEFAULT_FORGET_AUTO_PRUNE="false"
NOTIFY_METHOD="pushover"
NOTIFY_ON="failure"
NOTIFY_CREDENTIALS_FILE="/etc/backup-restic/notify-credentials"
```

### Job with a mount hook — `jobs.d/store.conf`

```bash
REPO_NAME="store"
PATHS=("/srv/data" "/etc")
EXCLUDES=("*.tmp" "*.cache")

MOUNT_CHECK="/mnt/backups"
BEFORE_BACKUP="$CONFIG_DIR/hooks/store-before.sh"
BEFORE_BACKUP_FAILURE="abort"
AFTER_BACKUP="$CONFIG_DIR/hooks/store-after.sh"
```

### Remote repo over SFTP — `jobs.d/offsite.conf`

```bash
REPO="sftp:backup@offsite.example.com:/backups/offsite"
PASSWORD_FILE="/etc/backup-restic/offsite-password"
PATHS=("/var/lib/myapp")
```

---

## Troubleshooting

| Symptom                                           | Likely cause / fix                                                                  |
|---------------------------------------------------|-------------------------------------------------------------------------------------|
| `ERROR: ... is writable by group or other users`  | Tighten permissions: `chown root:root` + `chmod 0640` (configs) / `0600` (secrets). |
| `ERROR: another backup-restic process is running` | A run is in progress, or a stale lock remains after a crash.                        |
| `ERROR: restic X is too old`                      | Upgrade restic to >= `0.15.0`.                                                      |
| `password file ... not readable`                  | Wrong ownership/permissions, or a parent dir blocks access. Run with `sudo`.        |
| Repo grows but nothing is pruned                  | `FORGET_AUTO_PRUNE=false` — run `backup-restic prune JOB` to reclaim space.         |
| Dry-run fails on mount check                      | The before-hook didn't mount, or `MOUNT_CHECK` is wrong.                            |
| Notification skipped                              | Check `NOTIFY_ON`, `NOTIFY_METHOD`, and that the credentials file is valid.         |

**Always test your restores.** A backup you've never restored is a hope, not a backup:

```bash
backup-restic ls home
backup-restic restore home <snapshot-id> --target /tmp/restore-test
```
