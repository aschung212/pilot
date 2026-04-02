#!/usr/bin/env bats
# Tests for lib/log.sh

load test_helper

# bats test_tags=fast
@test "log: log_info writes correct format" {
  export LOG_COMPONENT="test-component"
  source "$PILOT_DIR/lib/log.sh"
  output=$(log_info "hello world")
  [[ "$output" == *"INFO"* ]]
  [[ "$output" == *"test-component"* ]]
  [[ "$output" == *"hello world"* ]]
}

# bats test_tags=fast
@test "log: log_warn writes WARN level" {
  export LOG_COMPONENT="test-component"
  source "$PILOT_DIR/lib/log.sh"
  output=$(log_warn "something off")
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"something off"* ]]
}

# bats test_tags=fast
@test "log: log_error writes ERROR level" {
  export LOG_COMPONENT="test-component"
  source "$PILOT_DIR/lib/log.sh"
  output=$(log_error "bad thing" 2>/dev/null)
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"bad thing"* ]]
}

# bats test_tags=fast
@test "log: unified log file is created" {
  export LOG_COMPONENT="test-component"
  source "$PILOT_DIR/lib/log.sh"
  log_info "test entry" > /dev/null
  # Check that the unified log file exists
  ls "$OUTPUT_DIR"/pilot-*.log 2>/dev/null
  [ $? -eq 0 ]
}

# bats test_tags=fast
@test "log: log format includes timestamp" {
  export LOG_COMPONENT="test-component"
  source "$PILOT_DIR/lib/log.sh"
  output=$(log_info "timestamped")
  # Should match YYYY-MM-DD HH:MM:SS pattern
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}
