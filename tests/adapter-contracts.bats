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

  for identity in builder discovery triage review-tuner budget-tuner health; do
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

# ── ai-review.sh interface ──────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: ai-review supports all layer commands" {
  REVIEW="$PILOT_DIR/adapters/ai-review.sh"
  DIFF="$TEST_TMPDIR/test.diff"
  echo "diff --git a/test.ts b/test.ts" > "$DIFF"

  export MOCK_GEMINI_OUTPUT="REVIEW_CLEAN
REVIEW_VERDICT:MERGE"

  for layer in layer1 layer2 layer3; do
    OUTPUT="$TEST_TMPDIR/review-${layer}.txt"
    run bash "$REVIEW" "$layer" "$DIFF" "$OUTPUT"
    if [ "$status" -ne 0 ]; then
      echo "ai-review.$layer failed with exit $status" >&2
      false
    fi
    # Every layer must produce a verdict
    if ! grep -q "REVIEW_VERDICT:" "$OUTPUT" 2>/dev/null; then
      echo "ai-review.$layer produced no verdict" >&2
      false
    fi
  done
}

# ── Output format contracts ──────────────────────────────────────────────────

# bats test_tags=fast
@test "contract: review output follows REVIEW_FIX format" {
  # Valid format: REVIEW_FIX:<severity>:<file>:<description>
  valid="REVIEW_FIX:critical:src/App.vue:Missing null check"
  echo "$valid" | grep -qE '^REVIEW_FIX:(critical|high|medium|low):[^:]+:.+$'

  # Invalid: missing severity
  invalid="REVIEW_FIX::src/App.vue:Missing null check"
  ! echo "$invalid" | grep -qE '^REVIEW_FIX:(critical|high|medium|low):[^:]+:.+$'
}

# bats test_tags=fast
@test "contract: review verdicts are one of three values" {
  for v in MERGE REVIEW DO_NOT_MERGE; do
    echo "REVIEW_VERDICT:$v" | grep -qE '^REVIEW_VERDICT:(MERGE|REVIEW|DO_NOT_MERGE)$'
  done

  # Invalid verdict rejected
  ! echo "REVIEW_VERDICT:MAYBE" | grep -qE '^REVIEW_VERDICT:(MERGE|REVIEW|DO_NOT_MERGE)$'
}

# bats test_tags=fast
@test "contract: triage verdicts are one of five values" {
  for v in APPROVE ENHANCE SKIP FLAG RESCOPE; do
    echo "VERDICT: $v" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'
  done

  ! echo "VERDICT: MAYBE" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'
}
