# Shared test helper — sourced by all .bats files
# Sets up mock environment so tests never hit real external services.

# Paths — resolve dynamically so tests work on CI runners too
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PILOT_DIR="$(cd "$_HELPER_DIR/.." && pwd)"
export TEST_DIR="$PILOT_DIR/tests"
export MOCK_DIR="$TEST_DIR/mocks"
export FIXTURES_DIR="$TEST_DIR/fixtures"

# Create a temp directory for each test run
setup() {
  export TEST_TMPDIR=$(mktemp -d)

  # Mock environment — no real API calls
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"

  # Fake project.env values
  export PROJECT_NAME="TestProject"
  export PROJECT_DESC="A test application"
  export TECH_STACK="Test Framework + TypeScript"
  export REPO_PATH="$TEST_TMPDIR/repo"
  export GITHUB_REPO="test/repo"
  export DEFAULT_BRANCH="main"
  export LINEAR_TEAM="TEST"
  export LINEAR_PROJECT="TestProject"
  export LINEAR_ORG="testorg"
  export ISSUE_PREFIX="TEST"
  export TRACKER_ADAPTER="linear"
  export SLACK_CHANNEL_AUTOMATION="C_TEST_AUTO"
  export SLACK_CHANNEL_REVIEW="C_TEST_REVIEW"
  export SLACK_CHANNEL_CHANGELOG="C_TEST_LOG"
  # PILOT_DIR already set at top of file via dynamic resolution

  # ── Test hermeticity ──────────────────────────────────────────────────
  # bats inherits the parent shell's environment, and ~/.zshenv exports real
  # Slack webhooks and API tokens. _PILOT_TEST_MODE only stops scripts from
  # *re-sourcing* project.env / ~/.zshenv — it does NOT clear values already
  # inherited from the interactive shell. So scrub every secret the pipeline
  # might read, otherwise the "absent token/webhook" branches are never
  # exercised and a test could post to a real channel.
  for _leaked in ${!SLACK_WEBHOOK_@}; do unset "$_leaked"; done
  unset LINEAR_API_KEY LINEAR_API_TOKEN 2>/dev/null || true
  # The four below are read via ${VAR:-} in scripts; export them empty so the
  # behavior is identical whether or not the parent shell had them set.
  export SLACK_BOT_TOKEN=""
  export SLACK_WEBHOOK_URL=""
  export SLACK_WEBHOOK_DAILY_REVIEW=""
  export SLACK_WEBHOOK_CHANGELOG=""

  # AI model config
  export AI_CODE_MODEL="opus"
  export AI_RESEARCH_MODEL="gemini-2.5-flash"
  # Deterministic fake Gemini API key. ai-research.sh now authenticates to the
  # Gemini REST API with this (the OAuth CLI tier was retired 2026-06-18), so a
  # fixed value keeps tests hermetic — overrides any real key leaked from the
  # parent shell and lets CI run without one. curl is mocked, so it never leaves.
  export GEMINI_API_KEY="test-gemini-key"

  # Put mocks first on PATH so they intercept external commands
  export PATH="$MOCK_DIR:$PATH"

  # Create a fake repo
  mkdir -p "$REPO_PATH"

  # Suppress project.env sourcing in scripts (we set vars directly)
  export _PILOT_TEST_MODE=1
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Helper: create a mock command that outputs a fixed string
# Usage: create_mock "gemini" "REVIEW_VERDICT:MERGE"
create_mock() {
  local cmd="$1" output="$2" exit_code="${3:-0}"
  cat > "$TEST_TMPDIR/bin/$cmd" <<EOF
#!/bin/bash
echo "$output"
exit $exit_code
EOF
  chmod +x "$TEST_TMPDIR/bin/$cmd"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

# Helper: create a mock that logs its arguments to a file
# Usage: create_logging_mock "linear" "some output"
#        then check: cat "$TEST_TMPDIR/mock_calls/linear"
create_logging_mock() {
  local cmd="$1" output="${2:-}" exit_code="${3:-0}"
  mkdir -p "$TEST_TMPDIR/mock_calls"
  cat > "$TEST_TMPDIR/bin/$cmd" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$TEST_TMPDIR/mock_calls/$cmd"
echo "$output"
exit $exit_code
SCRIPT
  chmod +x "$TEST_TMPDIR/bin/$cmd"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}
