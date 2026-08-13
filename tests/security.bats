#!/usr/bin/env bats

load test_helper

@test "symlink config file is rejected" {
  # Create a symlink to a valid config
  ln -s "$TEST_CONFIG_DIR/backup-restic.conf" "$TEST_CONFIG_DIR/backup-restic.conf.link"

  # Point the script at the symlink
  cat > "$TEST_CONFIG_DIR/jobs.d/test.conf" <<EOF
REPO_NAME="test"
PATHS=("$TEST_DIR/data")
EOF
  chmod 0640 "$TEST_CONFIG_DIR/jobs.d/test.conf"

  # Temporarily rename and use symlink
  mv "$TEST_CONFIG_DIR/backup-restic.conf" "$TEST_CONFIG_DIR/real.conf"
  ln -s "$TEST_CONFIG_DIR/real.conf" "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be a symlink"* ]]
}

@test "group-writable config is rejected" {
  chmod 0660 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
}

@test "world-writable config is rejected" {
  chmod 0646 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
}

@test "world-writable parent directory is rejected" {
  # Create a world-writable parent
  chmod 0777 "$TEST_CONFIG_DIR"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"group/world writable without sticky-bit"* ]]
}

@test "world-writable directory with sticky bit is accepted" {
  chmod 1777 "$TEST_CONFIG_DIR"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -eq 0 ]
}

@test "non-executable hook is rejected" {
  create_job "test" 'BEFORE_BACKUP="$CONFIG_DIR/hooks/test-hook.sh"'

  # Create a non-executable hook
  cat > "$TEST_CONFIG_DIR/hooks/test-hook.sh" <<EOF
#!/bin/bash
exit 0
EOF
  chmod 0640 "$TEST_CONFIG_DIR/hooks/test-hook.sh"  # not executable

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
}

@test "hook owned by wrong user is rejected when running as root" {
  skip_if_not_root

  create_job "test" 'BEFORE_BACKUP="$CONFIG_DIR/hooks/test-hook.sh"'
  create_hook "test-hook.sh" "exit 0"

  # Change owner to non-root
  chown 1000:1000 "$TEST_CONFIG_DIR/hooks/test-hook.sh"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by"*"root may only use root-owned"* ]]
}

@test "password file writable by group is rejected" {
  chmod 0664 "$TEST_PASSWORD_FILE"

  create_job "test"

  run "$BACKUP_RESTIC_SCRIPT" config test
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
}

@test "unreadable config is rejected" {
  (( EUID == 0 )) && skip "root can read anything; unreadable is unreachable as root"

  chmod 000 "$TEST_CONFIG_DIR/backup-restic.conf"

  run "$BACKUP_RESTIC_SCRIPT" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"not readable"* ]]
}


