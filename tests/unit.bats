#!/usr/bin/env bats

load test_helper

@test "ls with no jobs shows empty message" {
  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"no jobs configured"* ]]
}

@test "ls lists job names from jobs.d" {
  create_job "home"
  create_job "work"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"home"* ]]
  [[ "$output" == *"work"* ]]
}

@test "config shows resolved repo path" {
  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" config test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repo:"*"$TEST_CONFIG_DIR/repos/test"* ]]
}

@test "run with --dry-run skips retention" {
  create_job "test"
  touch "$MOCK_REPO_MARKER"          # pretend the repo is already initialised

  run "$BACKUP_RESTIC_SCRIPT" run test --dry-run
  [ "$status" -eq 0 ]
  assert_called "restic backup"
  assert_not_called "restic forget"
}

@test "dry-run with uninitialised repo skips gracefully when non-interactive" {
  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" run test --dry-run
  [ "$status" -eq 0 ]
  assert_not_called "restic backup"
  [[ "$output" == *"dry-run skipped"* ]]
}

@test "run applies retention after backup by default" {
  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  assert_called "restic backup"
  assert_called "restic forget"
}

@test "restic exit 3 maps to warning, overall exit 0" {
  create_job "test"
  export MOCK_BACKUP_EXIT="3"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]  # warning doesn't fail the run
  [[ "$output" == *"warning"* ]] || [[ "$output" == *"WARNING"* ]]
}

@test "restic exit 1 maps to failure" {
  create_job "test"
  export MOCK_BACKUP_EXIT="1"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"failed"* ]]
}

@test "job config with invalid name is rejected" {
  # Create a job with invalid characters in filename
  cat > "$TEST_CONFIG_DIR/jobs.d/invalid@name.conf" <<EOF
REPO_NAME="invalid"
PATHS=("$TEST_DIR/data")
EOF
  chmod 0640 "$TEST_CONFIG_DIR/jobs.d/invalid@name.conf"

  run "$BACKUP_RESTIC_SCRIPT" config invalid@name
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid job name"* ]]
}

@test "global config overrides are applied" {
  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_PASSWORD_FILE="$TEST_PASSWORD_FILE"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
DEFAULT_RETENTION=(--keep-yearly 10)
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" config test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retention:"*"--keep-yearly 10"* ]]
}

@test "job config overrides global defaults" {
  create_job "test" 'RETENTION=(--keep-daily 1)'

  run "$BACKUP_RESTIC_SCRIPT" config test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retention:"*"--keep-daily 1"* ]]
}

@test "missing password file causes error" {
  cat > "$TEST_CONFIG_DIR/backup-restic.conf" <<EOF
LOG_DIR="$TEST_LOG_DIR"
DEFAULT_REPO_BASE="$TEST_CONFIG_DIR/repos"
EOF
  chmod 0640 "$TEST_CONFIG_DIR/backup-restic.conf"

  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" config test
  [ "$status" -ne 0 ]
  [[ "$output" == *"password file"* ]]
}

@test "empty PATHS array causes error" {
  cat > "$TEST_CONFIG_DIR/jobs.d/empty.conf" <<EOF
REPO_NAME="empty"
PATHS=()
EOF
  chmod 0640 "$TEST_CONFIG_DIR/jobs.d/empty.conf"

  run "$BACKUP_RESTIC_SCRIPT" config empty
  [ "$status" -ne 0 ]
  [[ "$output" == *"PATHS is empty"* ]]
}

@test "relative repo path triggers warning" {
  create_job "test" 'REPO="relative/path"'

  run "$BACKUP_RESTIC_SCRIPT" config test 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"relative path"* ]]
}

@test "--version prints version" {
  run "$BACKUP_RESTIC_SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-restic"* ]]
}

@test "--help shows usage" {
  run "$BACKUP_RESTIC_SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "unknown command shows error and usage" {
  run "$BACKUP_RESTIC_SCRIPT" invalid-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}
