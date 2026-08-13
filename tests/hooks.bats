#!/usr/bin/env bats

load test_helper

@test "before-hook runs before backup" {
  create_job "test" 'BEFORE_BACKUP="$CONFIG_DIR/hooks/before.sh"'
  create_hook "before.sh" "echo 'before-hook-executed' >> \$BACKUP_RESTIC_HOOK_LOG"

  export BACKUP_RESTIC_HOOK_LOG="$TEST_DIR/hook-order.log"
  run "$BACKUP_RESTIC_SCRIPT" run test

  [ "$status" -eq 0 ]
  [ -f "$BACKUP_RESTIC_HOOK_LOG" ]
  grep -q "before-hook-executed" "$BACKUP_RESTIC_HOOK_LOG"

  # Verify before-hook ran before restic backup
  local before_line backup_line
  before_line=$(grep -n "before-hook-executed" "$BACKUP_RESTIC_HOOK_LOG" | cut -d: -f1)
  backup_line=$(grep -n "restic backup" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
  [ "$before_line" -lt "$backup_line" ] 2>/dev/null || {
    echo "before-hook should run before restic backup" >&2
    return 1
  }
}

@test "after-hook runs even on failure" {
  create_job "test" 'AFTER_BACKUP="$CONFIG_DIR/hooks/after.sh"'
  create_hook "after.sh" "echo 'after-hook-executed' >> \$BACKUP_RESTIC_HOOK_LOG"
  export MOCK_BACKUP_EXIT="1"

  export BACKUP_RESTIC_HOOK_LOG="$TEST_DIR/hook-fail.log"
  run "$BACKUP_RESTIC_SCRIPT" run test

  [ "$status" -ne 0 ]
  [ -f "$BACKUP_RESTIC_HOOK_LOG" ]
  grep -q "after-hook-executed" "$BACKUP_RESTIC_HOOK_LOG"
}

@test "BEFORE_BACKUP_FAILURE=abort stops job on hook failure" {
  create_job "test" '
BEFORE_BACKUP="$CONFIG_DIR/hooks/fail.sh"
BEFORE_BACKUP_FAILURE="abort"
'
  create_hook "fail.sh" "exit 1"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -ne 0 ]
  assert_not_called "restic backup"
}

@test "BEFORE_BACKUP_FAILURE=ignore continues on hook failure" {
  create_job "test" '
BEFORE_BACKUP="$CONFIG_DIR/hooks/fail.sh"
BEFORE_BACKUP_FAILURE="ignore"
'
  create_hook "fail.sh" "exit 1"

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  assert_called "restic backup"
}

@test "hook receives correct environment variables" {
  create_job "test" 'BEFORE_BACKUP="$CONFIG_DIR/hooks/env.sh"'
  create_hook "env.sh" "
echo \"JOB=\$BACKUP_RESTIC_JOB\" >> \$BACKUP_RESTIC_HOOK_LOG
echo \"PHASE=\$BACKUP_RESTIC_PHASE\" >> \$BACKUP_RESTIC_HOOK_LOG
echo \"MODE=\$BACKUP_RESTIC_MODE\" >> \$BACKUP_RESTIC_HOOK_LOG
"

  export BACKUP_RESTIC_HOOK_LOG="$TEST_DIR/hook-env.log"
  run "$BACKUP_RESTIC_SCRIPT" run test

  [ "$status" -eq 0 ]
  [ -f "$BACKUP_RESTIC_HOOK_LOG" ]
  grep -q "JOB=test" "$BACKUP_RESTIC_HOOK_LOG"
  grep -q "PHASE=before" "$BACKUP_RESTIC_HOOK_LOG"
  grep -q "MODE=BACKUP" "$BACKUP_RESTIC_HOOK_LOG"
}

@test "after-hook receives status and reason" {
  create_job "test" 'AFTER_BACKUP="$CONFIG_DIR/hooks/after-env.sh"'
  create_hook "after-env.sh" "
echo \"STATUS=\$BACKUP_RESTIC_STATUS\" >> \$BACKUP_RESTIC_HOOK_LOG
echo \"REASON=\$BACKUP_RESTIC_REASON\" >> \$BACKUP_RESTIC_HOOK_LOG
"
  export MOCK_BACKUP_EXIT="1"

  export BACKUP_RESTIC_HOOK_LOG="$TEST_DIR/hook-after-env.log"
  run "$BACKUP_RESTIC_SCRIPT" run test

  [ -f "$BACKUP_RESTIC_HOOK_LOG" ]
  grep -q "STATUS=failure" "$BACKUP_RESTIC_HOOK_LOG"
  grep -q "REASON=backup" "$BACKUP_RESTIC_HOOK_LOG"
}

@test "FORGET_WHEN=before runs retention before backup" {
  create_job "test" 'FORGET_WHEN="before"'

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]

  # Verify forget ran before backup
  local forget_line backup_line
  forget_line=$(grep -n "restic forget" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
  backup_line=$(grep -n "restic backup" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
  [ "$forget_line" -lt "$backup_line" ] 2>/dev/null || {
    echo "forget should run before backup when FORGET_WHEN=before" >&2
    return 1
  }
}

@test "FORGET_AUTO_PRUNE=true adds --prune to forget" {
  create_job "test" 'FORGET_AUTO_PRUNE="true"'

  run "$BACKUP_RESTIC_SCRIPT" run test
  [ "$status" -eq 0 ]
  assert_called "restic forget.*--prune"
}
