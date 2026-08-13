#!/usr/bin/env bats
# test_helper.bash - shared setup for all bats tests
#
# Every test gets:
# - A fresh CONFIG_DIR with a global conf and password file
# - A fresh LOG_DIR
# - Mock `restic` and `curl` on PATH (record invocations, script exits)
# - BACKUP_RESTIC_CONFIG_DIR exported so backup-restic uses the test dir
#
# Tests never touch a real install, never hit the network, and run identically
# in the devcontainer (vscode user) and in CI (root or user).

setup() {
  # Create isolated directories for this test
  TEST_DIR="$(mktemp -d)"
  TEST_CONFIG_DIR="$TEST_DIR/config"
  TEST_LOG_DIR="$TEST_DIR/logs"
  TEST_BIN_DIR="$TEST_DIR/bin"
  TEST_HOOKS_DIR="$TEST_DIR/hooks"

  mkdir -p "$TEST_CONFIG_DIR/jobs.d" "$TEST_CONFIG_DIR/hooks" \
           "$TEST_LOG_DIR" "$TEST_BIN_DIR" "$TEST_HOOKS_DIR"

  # Create a valid password file (owned by current user, 0600)
  TEST_PASSWORD_FILE="$TEST_CONFIG_DIR/restic-password"
  echo "test-password-$(date +%s%N)" > "$TEST_PASSWORD_FILE"
  chmod 0600 "$TEST_PASSWORD_FILE"

  # Create a minimal global config
  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
DEFAULT_RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
NOTIFY_METHOD="none"
MIN_RESTIC_VERSION="0.15.0"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  # Create the repos base dir
  mkdir -p "$TEST_CONFIG_DIR/repos"

  # Tell backup-restic to use our test config dir
  export BACKUP_RESTIC_CONFIG_DIR="$TEST_CONFIG_DIR"
  export PATH="$TEST_BIN_DIR:$PATH"

  # Export test paths for use in assertions
  export TEST_DIR TEST_CONFIG_DIR TEST_LOG_DIR TEST_BIN_DIR TEST_HOOKS_DIR TEST_PASSWORD_FILE

  # Install mock restic (records calls, scripts exit codes)
  install_mock_restic

  # Install mock curl (for notification tests)
  install_mock_curl

  # Locate the backup-restic script (assumes tests/ is at repo root)
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export BACKUP_RESTIC_SCRIPT="$SCRIPT_DIR/backup-restic"

  # Never let a test block on terminal input: when bats is run from an
  # interactive terminal it passes that TTY through as stdin, which would
  # trigger backup-restic's dry-run temp-repo prompt. Point stdin at
  # /dev/null so every test takes the non-interactive code path.
  exec </dev/null
}

teardown() {
  # Clean up the test directory
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
}

# Install a mock restic that records invocations and can script exits
install_mock_restic() {
  cat > "$TEST_BIN_DIR/restic" <<'EOF'
#!/bin/bash
# Mock restic - records calls and can simulate failures

MOCK_CALL_LOG="${MOCK_CALL_LOG:?MOCK_CALL_LOG must be set}"
echo "restic $*" >> "$MOCK_CALL_LOG"

case "$1" in
  version)
    echo "restic ${MOCK_RESTIC_VERSION:-0.16.0} compiled with go1.21.0 on linux/amd64"
    ;;
  snapshots)
    # Simulate "repo not initialised" if marker doesn't exist
    [ -e "${MOCK_REPO_MARKER:-/dev/null/nonexistent}" ] && exit 0
    exit 1
    ;;
  init)
    touch "${MOCK_REPO_MARKER:?MOCK_REPO_MARKER must be set}"
    ;;
  backup)
    exit "${MOCK_BACKUP_EXIT:-0}"
    ;;
  forget)
    exit "${MOCK_FORGET_EXIT:-0}"
    ;;
  prune)
    exit "${MOCK_PRUNE_EXIT:-0}"
    ;;
  check)
    exit "${MOCK_CHECK_EXIT:-0}"
    ;;
  restore)
    exit "${MOCK_RESTORE_EXIT:-0}"
    ;;
  ls)
    exit "${MOCK_LS_EXIT:-0}"
    ;;
  unlock)
    exit 0
    ;;
  *)
    echo "mock restic: unknown command $1" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$TEST_BIN_DIR/restic"

  export MOCK_CALL_LOG="$TEST_CONFIG_DIR/restic-calls.log"
  export MOCK_REPO_MARKER="$TEST_CONFIG_DIR/.repo-inited"
  export MOCK_RESTIC_VERSION="0.16.0"
  export MOCK_BACKUP_EXIT="0"
  export MOCK_FORGET_EXIT="0"
  export MOCK_PRUNE_EXIT="0"
  export MOCK_CHECK_EXIT="0"
  export MOCK_RESTORE_EXIT="0"
  export MOCK_LS_EXIT="0"
}

# Install a mock curl for notification tests
install_mock_curl() {
  cat > "$TEST_BIN_DIR/curl" <<'EOF'
#!/bin/bash
# Mock curl - records calls and can simulate failures

MOCK_CURL_LOG="${MOCK_CURL_LOG:?MOCK_CURL_LOG must be set}"
echo "curl $*" >> "$MOCK_CURL_LOG"

# Parse args to extract URL and method
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) shift; METHOD="$1" ;;
    --data-binary) shift; PAYLOAD="$1" ;;
    -H) shift ;;
    --max-time) shift ;;
    *)
      if [[ "$1" =~ ^https?:// ]]; then
        URL="$1"
      fi
      ;;
  esac
  shift
done

echo "url=$URL" >> "$MOCK_CURL_LOG"
echo "method=${METHOD:-GET}" >> "$MOCK_CURL_LOG"
[ -n "$PAYLOAD" ] && echo "payload=$PAYLOAD" >> "$MOCK_CURL_LOG"

exit "${MOCK_CURL_EXIT:-0}"
EOF
  chmod +x "$TEST_BIN_DIR/curl"

  export MOCK_CURL_LOG="$TEST_CONFIG_DIR/curl-calls.log"
  export MOCK_CURL_EXIT="0"
}

# Helper: create a valid job config
create_job() {
  local name="$1"
  shift
  local job_conf="$TEST_CONFIG_DIR/jobs.d/${name}.conf"

  cat > "$job_conf" <<EOF
REPO_NAME="$name"
PATHS=("$TEST_DIR/data")
$*
EOF
  chmod 0640 "$job_conf"

  # Create dummy data directory
  mkdir -p "$TEST_DIR/data"
  echo "test data" > "$TEST_DIR/data/file.txt"
}

# Helper: create an executable hook
create_hook() {
  local name="$1"
  local body="$2"
  local hook="$TEST_CONFIG_DIR/hooks/${name}"

  cat > "$hook" <<EOF
#!/bin/bash
$body
EOF
  chmod 0750 "$hook"
}

# Helper: assert that a command was called with specific args
assert_called() {
  local pattern="$1"
  [ -f "$MOCK_CALL_LOG" ] || { echo "mock call log not found" >&2; return 1; }
  grep -q "$pattern" "$MOCK_CALL_LOG" || {
    echo "expected to find '$pattern' in restic calls:" >&2
    cat "$MOCK_CALL_LOG" >&2
    return 1
  }
}

# Helper: assert that a command was NOT called with specific args
assert_not_called() {
  local pattern="$1"
  [ -f "$MOCK_CALL_LOG" ] || return 0
  ! grep -q "$pattern" "$MOCK_CALL_LOG" || {
    echo "expected NOT to find '$pattern' in restic calls, but found:" >&2
    grep "$pattern" "$MOCK_CALL_LOG" >&2
    return 1
  }
}

# Helper: count how many times a command was called
count_calls() {
  local pattern="$1"
  [ -f "$MOCK_CALL_LOG" ] || { echo "0"; return; }
  grep -c "$pattern" "$MOCK_CALL_LOG" 2>/dev/null || echo "0"
}

# Helper: skip test if not running as root
skip_if_not_root() {
  (( EUID == 0 )) || skip "requires root"
}

# Helper: create a file with specific permissions and ownership (for security tests)
create_file_with_perms() {
  local file="$1"
  local mode="$2"
  local owner="$3"
  local content="$4"

  echo "$content" > "$file"
  chmod "$mode" "$file"
  [ -n "$owner" ] && chown "$owner" "$file" 2>/dev/null || true
}
