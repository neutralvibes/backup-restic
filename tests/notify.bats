#!/usr/bin/env bats

load test_helper

@test "NOTIFY_ON=failure skips notification on success" {
  create_job "test"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="failure"
WEBHOOK_URL="https://example.com/hook"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_CURL_LOG" ] || ! grep -q "curl" "$MOCK_CURL_LOG"
}

@test "NOTIFY_ON=failure sends notification on failure" {
  create_job "test"
  export MOCK_BACKUP_EXIT="1"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="failure"
WEBHOOK_URL="https://example.com/hook"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ -f "$MOCK_CURL_LOG" ]
  grep -q "https://example.com/hook" "$MOCK_CURL_LOG"
}

@test "NOTIFY_ON=success sends notification on success" {
  create_job "test"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="success"
WEBHOOK_URL="https://example.com/hook"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  [ -f "$MOCK_CURL_LOG" ]
  grep -q "https://example.com/hook" "$MOCK_CURL_LOG"
}

@test "notification credentials loaded lazily" {
  create_job "test"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="success"
NOTIFY_CREDENTIALS_FILE="$TEST_CONFIG_DIR/notify-creds"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  cat > "$TEST_CONFIG_DIR/notify-creds" <<EOF
WEBHOOK_URL="https://creds.example.com/hook"
EOF
  chmod 0600 "$TEST_CONFIG_DIR/notify-creds"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  [ -f "$MOCK_CURL_LOG" ]
  grep -q "https://creds.example.com/hook" "$MOCK_CURL_LOG"
}

@test "unreadable credentials file skips notification" {
  create_job "test"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="failure"
NOTIFY_CREDENTIALS_FILE="$TEST_CONFIG_DIR/bad-creds"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  # Create credentials with bad permissions
  cat > "$TEST_CONFIG_DIR/bad-creds" <<EOF
WEBHOOK_URL="https://bad.example.com/hook"
EOF
  chmod 0666 "$TEST_CONFIG_DIR/bad-creds"

  export MOCK_BACKUP_EXIT="1"
  run "$BACKUP_RESTIC_SCRIPT" run test

  # Notification should be skipped
  [ ! -f "$MOCK_CURL_LOG" ] || ! grep -q "curl" "$MOCK_CURL_LOG"
  [[ "$output" == *"notification skipped"* ]] || [[ "$output" == *"credentials"* ]]
}

@test "webhook payload contains job and status" {
  create_job "test"
  export MOCK_BACKUP_EXIT="1"

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="webhook"
NOTIFY_ON="failure"
WEBHOOK_URL="https://example.com/hook"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ -f "$MOCK_CURL_LOG" ]
  grep -q '"job":"test"' "$MOCK_CURL_LOG"
  grep -q '"status":"failure"' "$MOCK_CURL_LOG"
}

@test "job override takes precedence over global" {
  create_job "test" '
NOTIFY_METHOD_OVERRIDE="webhook"
NOTIFY_ON_OVERRIDE="success"
'

  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
NOTIFY_METHOD="none"
WEBHOOK_URL="https://override.example.com/hook"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  [ -f "$MOCK_CURL_LOG" ]
  grep -q "https://override.example.com/hook" "$MOCK_CURL_LOG"
}
