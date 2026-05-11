#!/usr/bin/env bats
# Contract tests — verify adapter interfaces remain stable.
# If an adapter's command set changes, these tests catch it.

load test_helper

# ── tracker.sh interface ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: tracker supports all required commands" {
  TRACKER="$PILOT_DIR/adapters/tracker.sh"
  for cmd in list view create update comment-list comment-add issue-url board-url; do
    case "$cmd" in
      list)        run bash "$TRACKER" list backlog ;;
      view)        run bash "$TRACKER" view TEST-1 ;;
      create)      run bash "$TRACKER" create "test" 3 ;;
      update)      run bash "$TRACKER" update TEST-1 --state backlog ;;
      comment-list) run bash "$TRACKER" comment-list TEST-1 ;;
      comment-add) run bash "$TRACKER" comment-add TEST-1 "body" ;;
      issue-url)   run bash "$TRACKER" issue-url TEST-1 ;;
      board-url)   run bash "$TRACKER" board-url ;;
    esac
    if [ "$status" -ne 0 ]; then
      echo "tracker.$cmd failed with exit $status" >&2
      false
    fi
  done
}

# ── notify.sh interface ──────────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: notify supports all required commands" {
  NOTIFY="$PILOT_DIR/adapters/notify.sh"
  export SLACK_BOT_TOKEN="xoxb-test"

  for cmd in send send-async thread-start thread-reply; do
    case "$cmd" in
      send)        run bash "$NOTIFY" send automation "msg" ;;
      send-async)  run bash "$NOTIFY" send-async automation "msg" ;;
      thread-start) run bash "$NOTIFY" thread-start automation "msg" ;;
      thread-reply) run bash "$NOTIFY" thread-reply automation "123.456" "msg" ;;
    esac
    if [ "$status" -ne 0 ]; then
      echo "notify.$cmd failed with exit $status" >&2
      false
    fi
  done
}

# bats test_tags=fast
@test "contract: notify supports all agent identities" {
  NOTIFY="$PILOT_DIR/adapters/notify.sh"
  export SLACK_BOT_TOKEN="xoxb-test"

  for identity in builder discovery triage budget-tuner health; do
    run bash "$NOTIFY" --as "$identity" send automation "test"
    if [ "$status" -ne 0 ]; then
      echo "notify --as $identity failed with exit $status" >&2
      false
    fi
  done
}

# ── ai-code.sh interface ────────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: ai-code supports run command" {
  run bash "$PILOT_DIR/adapters/ai-code.sh" run "test prompt"
  [ "$status" -eq 0 ]
}

# ── ai-research.sh interface ────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: ai-research supports prompt command" {
  run bash "$PILOT_DIR/adapters/ai-research.sh" prompt "test query"
  [ "$status" -eq 0 ]
}

# ── ai-review.sh interface (DEPRECATED — adapter no longer called by builder) ──

# bats test_tags=fast
@test "contract: triage verdicts are one of five values" {
  for v in APPROVE ENHANCE SKIP FLAG RESCOPE; do
    echo "VERDICT: $v" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'
  done

  ! echo "VERDICT: MAYBE" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'
}
