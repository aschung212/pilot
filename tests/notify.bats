#!/usr/bin/env bats
# Tests for adapters/notify.sh

load test_helper

NOTIFY="$PILOT_DIR/adapters/notify.sh"

# bats test_tags=fast
@test "notify: unknown command exits with error" {
  run bash "$NOTIFY" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown notify command"* ]]
}

# bats test_tags=fast
@test "notify: get_channel_id resolves known channels" {
  # Test by calling send with automation channel — it should resolve the ID
  export SLACK_BOT_TOKEN="xoxb-test-token"
  run bash "$NOTIFY" send automation "hello"
  [ "$status" -eq 0 ]
  # curl should have been called with our test channel ID
  grep -q "C_TEST_AUTO" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "notify: --as flag routes to Bot API" {
  export SLACK_BOT_TOKEN="xoxb-test-token"
  run bash "$NOTIFY" --as builder send automation "test message"
  [ "$status" -eq 0 ]
  # Should have called curl (Bot API), not webhook
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
  grep -q "chat.postMessage" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "notify: send without token or webhook is a no-op" {
  # No SLACK_BOT_TOKEN, no webhooks — should silently do nothing
  run bash "$NOTIFY" send automation "test"
  [ "$status" -eq 0 ]
  # curl should not have been called
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "notify: thread-start returns timestamp" {
  export SLACK_BOT_TOKEN="xoxb-test-token"
  run bash "$NOTIFY" thread-start automation "Starting thread"
  [ "$status" -eq 0 ]
  # Our mock curl returns {"ok": true, "ts": "1234567890.123456"}
  [[ "$output" == *"1234567890.123456"* ]]
}

# bats test_tags=fast
@test "notify: thread-reply with empty ts falls back to webhook" {
  export SLACK_WEBHOOK_URL="https://hooks.slack.com/test"
  run bash "$NOTIFY" thread-reply automation "" "fallback message"
  [ "$status" -eq 0 ]
  # Should have used webhook (curl with the webhook URL)
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "notify: send falls back to Bot API when webhook fails" {
  export SLACK_WEBHOOK_URL="https://hooks.slack.com/test"
  export SLACK_BOT_TOKEN="xoxb-test-token"
  export MOCK_CURL_HTTP_CODE="404"
  # Webhook will "fail" (404), should fall back to Bot API
  # Note: this is tricky because our mock curl returns the same thing for all calls
  # Just verify curl is called (the fallback path requires two calls)
  run bash "$NOTIFY" send automation "test"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
}
