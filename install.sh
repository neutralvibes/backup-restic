#!/bin/env bash
#
# install.sh - installer for backup-restic
#
# Distribution is git-clone only:
#
#   git clone --depth 1 <repo-url> backup-restic
#   cd backup-restic
#   ./install.sh          # as root: system install | as user: user install
#
# Mode is auto-detected from EUID:
#
#   root  -> /opt/backup-restic
#            symlink:   /usr/local/bin/backup-restic
#            completion:/etc/bash_completion.d/backup-restic
#            logrotate: /etc/logrotate.d/backup-restic
#
#   user  -> ~/.config/backup-restic
#            symlink:   ~/.local/bin/backup-restic
#            completion:$XDG_DATA_HOME/bash-completion/completions/backup-restic
#
# Safety model:
#   * Strictly non-interactive - safe to automate.
#   * Idempotent - re-running is the upgrade path.
#   * The main `backup-restic` script is ALWAYS overwritten (upgrade).
#   * Files whose names contain ".example" are templates: ALWAYS overwritten.
#   * Real user config (backup-restic.conf, jobs.d/*.conf, hooks without
#     ".example" in their name) is NEVER overwritten.
#   * Permissions are set explicitly (0755 dirs/script, 0640 config/examples)
#     so every installed file passes backup-restic's validate_trusted_file:
#     not group/world-writable, correct owner, no world-writable parent dirs.
#
set -euo pipefail

info() { echo "  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Resolve this script's real directory, even through a symlink.
SRC_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

[ -n "${BASH_VERSINFO:-}" ] || die "install.sh must be run with bash"
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    die "bash >= 4.4 required (found $BASH_VERSION)"
fi

[ -f "$SRC_DIR/backup-restic" ] ||
    die "backup-restic not found next to install.sh - run this from the cloned repository"

SRC_VERSION="$(sed -n 's/^VERSION="\(.*\)".*$/\1/p' "$SRC_DIR/backup-restic" | head -n1)"
SRC_VERSION="${SRC_VERSION:-unknown}"

command -v restic >/dev/null ||
    echo "NOTE: restic not found on PATH. backup-restic needs it at runtime (>= 0.15.0)." >&2
command -v flock >/dev/null ||
    echo "NOTE: flock not found. backup-restic needs it for 'run' (package: util-linux)." >&2

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------

if (( EUID == 0 )); then
    MODE="system"
    INSTALL_DIR="/opt/backup-restic"
    BIN_LINK="/usr/local/bin/backup-restic"
else
    MODE="user"
    INSTALL_DIR="${HOME}/.config/backup-restic"
    BIN_LINK="${HOME}/.local/bin/backup-restic"
fi

[ "$SRC_DIR" != "$INSTALL_DIR" ] ||
    die "source and destination are the same directory - run install.sh from a clone, not from the installed location"

echo "Installing backup-restic $SRC_VERSION ($MODE mode)"
echo "  source:       $SRC_DIR"
echo "  destination:  $INSTALL_DIR"
echo "  symlink:      $BIN_LINK"
echo

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
# 0755 satisfies validate_trusted_file's parent-directory walk (no
# group/world-writable dirs), while staying traversable by all users.

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/jobs.d" "$INSTALL_DIR/hooks" ||
    die "cannot create $INSTALL_DIR - check that $(id -un) may write to $(dirname "$INSTALL_DIR")"
chmod 0755 "$INSTALL_DIR" "$INSTALL_DIR/jobs.d" "$INSTALL_DIR/hooks"

# ---------------------------------------------------------------------------
# Main script - always overwritten; this is the upgrade path
# ---------------------------------------------------------------------------

cp -f "$SRC_DIR/backup-restic" "$INSTALL_DIR/backup-restic" ||
    die "cannot install main script to $INSTALL_DIR"
chmod 0755 "$INSTALL_DIR/backup-restic"
info "installed $INSTALL_DIR/backup-restic"


SCRIPT_LEVEL_FILES=(
    "backup-restic.conf"
    "backup-restic.conf.example"
    )

install_script_level_files() {
    local filename
    for filename in "${SCRIPT_LEVEL_FILES[@]}"; do
        if [ -f "$SRC_DIR/${filename}" ]; then
            cp -f "$SRC_DIR/${filename}" "$INSTALL_DIR" ||
                die "cannot install ${filename}"
            chmod 0640 "$INSTALL_DIR/${filename}"
            info "installed $INSTALL_DIR/$filename"
        fi
    done
}

# ---------------------------------------------------------------------------
# Templates (.example files)
# ---------------------------------------------------------------------------
# Copies every file from a source directory into the matching destination:
#   *.example*  -> always overwritten (templates ship with the tool)
#   anything else -> only if the destination doesn't already have it
#                    (that would be user-managed config; never clobber it)

install_dir_contents() {
    local src_dir="$1" dest_dir="$2"
    local f base
    [ -d "$src_dir" ] || return 0
    for f in "$src_dir"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        if [[ "$base" == *.example* ]]; then
            cp -f "$f" "$dest_dir/$base" || die "cannot install $dest_dir/$base"
            chmod 0640 "$dest_dir/$base"
            info "installed $dest_dir/$base"
        elif [ -e "$dest_dir/$base" ]; then
            info "preserved $dest_dir/$base (user file - not overwritten)"
        else
            cp -f "$f" "$dest_dir/$base" || die "cannot install $dest_dir/$base"
            chmod 0640 "$dest_dir/$base"
            info "installed $dest_dir/$base"
        fi
    done
}

install_script_level_files

install_dir_contents "$SRC_DIR/jobs.d" "$INSTALL_DIR/jobs.d"
install_dir_contents "$SRC_DIR/hooks"  "$INSTALL_DIR/hooks"

# ---------------------------------------------------------------------------
# Symlink into PATH
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$BIN_LINK")"
ln -sfn "$INSTALL_DIR/backup-restic" "$BIN_LINK" ||
    die "cannot create symlink $BIN_LINK"
info "symlinked $BIN_LINK -> $INSTALL_DIR/backup-restic"

# ---------------------------------------------------------------------------
# Completion + logrotate
# ---------------------------------------------------------------------------
# Delegate to the freshly installed script so the snippets have a single
# source of truth. Both are best-effort: failure here doesn't undo the install.

"$INSTALL_DIR/backup-restic" --completion install ||
    echo "WARNING: bash completion install failed (continuing)" >&2

if (( EUID == 0 )); then
    # Root logs go to /var/log/backup-restic, so rotation is worth installing.
    "$INSTALL_DIR/backup-restic" --logrotate install ||
        echo "WARNING: logrotate install failed (continuing)" >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$MODE" = "user" ]; then
    case ":$PATH:" in
        *":$(dirname "$BIN_LINK"):"*) ;;
        *)
            echo
            echo "NOTE: $(dirname "$BIN_LINK") is not in your PATH. Add it, e.g.:"
            echo "      export PATH=\"$(dirname "$BIN_LINK"):\$PATH\""
            ;;
    esac
fi

echo
echo "Done. Next steps:"
if [ ! -f "$INSTALL_DIR/backup-restic.conf" ]; then
    echo "  1. cp $INSTALL_DIR/backup-restic.conf.example $INSTALL_DIR/backup-restic.conf"
    echo "     then edit it (at minimum set DEFAULT_PASSWORD_FILE and DEFAULT_REPO_BASE)."
else
    echo "  1. Existing backup-restic.conf kept as-is."
fi
echo "  2. Create your repo password file, owned by $(id -un), mode 0600 (umask 077)."
echo "  3. Create a job, e.g.:"
echo "       cp $INSTALL_DIR/jobs.d/home.conf.example $INSTALL_DIR/jobs.d/home.conf"
echo "     and edit it (hooks from $INSTALL_DIR/hooks/ need chmod +x after review)."
echo "  4. Test: backup-restic ls   |   backup-restic config home   |   backup-restic run home --dry-run"
