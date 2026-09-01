#!/usr/bin/env bats
# Tests for adapters/ai-research.sh (Gemini REST API — Flash + grounding)

load test_helper

AI_RESEARCH="$PILOT_DIR/adapters/ai-research.sh"

# bats test_tags=fast
@test "ai-research: unknown command exits with error" {
  run bash "$AI_RESEARCH" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown ai-research command"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: prompt calls the Gemini API via curl" {
  run bash "$AI_RESEARCH" prompt "Search for Vue best practices"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
  grep -q "generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: prompt respects --model override" {
  run bash "$AI_RESEARCH" prompt "test" --model gemini-3.5-flash
  [ "$status" -eq 0 ]
  grep -q "models/gemini-3.5-flash:generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: default model is gemini-2.5-flash" {
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  grep -q "models/gemini-2.5-flash:generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: prompt with --output writes to file" {
  local out_file="$TEST_TMPDIR/research.txt"
  run bash "$AI_RESEARCH" prompt "test" --output "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  [ -s "$out_file" ]
}

# bats test_tags=fast
@test "ai-research: missing GEMINI_API_KEY fails loud (exit 3)" {
  export GEMINI_API_KEY=""
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 3 ]
  [[ "$output" == *"GEMINI_API_KEY not set"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: empty prompt fails loud (exit 2)" {
  run bash "$AI_RESEARCH" prompt ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty prompt"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: HTTP error from the API fails loud (non-zero)" {
  export MOCK_CURL_OUTPUT='{"error":{"code":429,"message":"RESOURCE_EXHAUSTED"}}'
  export MOCK_CURL_HTTP_CODE="429"
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: empty API result fails loud (non-zero)" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":""}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "ai-research: parses candidate text on success" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"finding one"}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]] || return 1
}

# ── Backend routing (added 2026-08-30) ───────────────────────────────────────

# bats test_tags=fast
@test "ai-research: default backend is gemini — triage must not silently move to Claude" {
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
  [ ! -f "$TEST_TMPDIR/mock_calls/claude" ]
}

# bats test_tags=fast
@test "ai-research: unknown backend fails loud instead of falling through to gemini" {
  run bash "$AI_RESEARCH" prompt "test" --backend bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown backend"* ]] || return 1
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "ai-research: --backend claude calls the claude CLI, never curl" {
  MOCK_CLAUDE_OUTPUT='{"result": "findings here", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/claude" ]
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "ai-research: grounded claude backend allows web tools and blocks Task fan-out" {
  # Task is disallowed deliberately: unbounded subagent fan-out is what made the
  # Opus arm of the 2026-08-30 bake-off take 1187s instead of 137s.
  MOCK_CLAUDE_OUTPUT='{"result": "findings", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude
  [ "$status" -eq 0 ]
  grep -q -- "--allowedTools WebSearch,WebFetch" "$TEST_TMPDIR/mock_calls/claude"
  grep -q -- "Task" "$TEST_TMPDIR/mock_calls/claude"
}

# bats test_tags=fast
@test "ai-research: --no-grounding on the claude backend removes web access" {
  MOCK_CLAUDE_OUTPUT='{"result": "reasoned answer", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude --no-grounding
  [ "$status" -eq 0 ]
  run grep -o -- "--allowedTools [^ ]*" "$TEST_TMPDIR/mock_calls/claude"
  [[ "$output" != *"WebSearch"* ]] || return 1
  grep -q -- "--disallowedTools WebSearch,WebFetch" "$TEST_TMPDIR/mock_calls/claude"
}

# bats test_tags=fast
@test "ai-research: claude backend uses AI_RESEARCH_CLAUDE_MODEL, not AI_RESEARCH_MODEL" {
  AI_RESEARCH_CLAUDE_MODEL="claude-sonnet-5" \
  MOCK_CLAUDE_OUTPUT='{"result": "x", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude
  [ "$status" -eq 0 ]
  grep -q -- "--model claude-sonnet-5" "$TEST_TMPDIR/mock_calls/claude"
}

# bats test_tags=fast
@test "ai-research: claude backend fails loud when the CLI reports is_error" {
  MOCK_CLAUDE_OUTPUT='{"result": "", "is_error": true, "subtype": "error_max_turns"}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude request failed"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: claude backend survives the Bun AVX preamble before the JSON" {
  # `claude --output-format json` is not valid JSON at line 1 on this host — Bun
  # prints a CPU warning first. This broke every pre-pick on 2026-05-19.
  MOCK_CLAUDE_OUTPUT='warn: CPU lacks AVX support, strange crashes may occur.
{"result": "real findings", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"real findings"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: claude backend writes --output to file" {
  local out_file="$TEST_TMPDIR/claude-research.md"
  MOCK_CLAUDE_OUTPUT='{"result": "cited findings", "is_error": false}' \
    run bash "$AI_RESEARCH" prompt "test" --backend claude --output "$out_file"
  [ "$status" -eq 0 ]
  [ -s "$out_file" ]
  grep -q "cited findings" "$out_file"
}

# ── Grounding citations ──────────────────────────────────────────────────────
# The API never cites inside the answer text; the sources it actually read live
# in candidates[0].groundingMetadata.groundingChunks[].web. Discarding them is
# why research arrived uncited after the REST migration.

GROUNDED_BODY='{"candidates":[{"content":{"parts":[{"text":"finding one"}]},"groundingMetadata":{"groundingChunks":[{"web":{"title":"strong.app","uri":"https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC1"}},{"web":{"title":"barbend.com","uri":"https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC2"}}],"webSearchQueries":["fitness apps 2026"]}}]}'

# bats test_tags=fast
@test "ai-research: grounded call appends a Sources section with domain and uri" {
  export MOCK_CURL_OUTPUT="$GROUNDED_BODY"
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]] || return 1
  [[ "$output" == *"Sources (2"* ]] || return 1
  [[ "$output" == *"1. strong.app — https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC1"* ]] || return 1
  [[ "$output" == *"2. barbend.com — https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC2"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: Sources dedupes repeated domains" {
  # A real grounded call returns ~16 chunks, most of them repeats of a few
  # domains. Cite each domain once.
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"txt"}]},"groundingMetadata":{"groundingChunks":[{"web":{"title":"apple.com","uri":"https://x/1"}},{"web":{"title":"apple.com","uri":"https://x/2"}},{"web":{"title":"Apple.com","uri":"https://x/3"}},{"web":{"title":"hevyapp.com","uri":"https://x/4"}}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sources (2"* ]] || return 1
  [ "$(echo "$output" | grep -ci 'apple\.com' | tr -d ' \n')" -eq 1 ]
  [[ "$output" == *"hevyapp.com"* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: --no-grounding output carries no Sources section" {
  # Triage parses this output for VERDICT; it asked for no web, so cite nothing.
  export MOCK_CURL_OUTPUT="$GROUNDED_BODY"
  run bash "$AI_RESEARCH" prompt "test" --no-grounding
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]] || return 1
  [[ "$output" != *"Sources ("* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: response without groundingMetadata still returns the answer" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"finding one"}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]] || return 1
  [[ "$output" != *"Sources ("* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: malformed groundingMetadata does not cost us the answer" {
  # Citations are a bonus. A shape we did not expect must degrade to the plain
  # answer, never to an empty result (which the caller treats as FAIL LOUD).
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"finding one"}]},"groundingMetadata":{"groundingChunks":"not-a-list"}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]] || return 1
  [[ "$output" != *"Sources ("* ]] || return 1
}

# bats test_tags=fast
@test "ai-research: non-web grounding chunks are skipped, titleless ones kept" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"txt"}]},"groundingMetadata":{"groundingChunks":[{"retrievedContext":{"title":"internal"}},{"web":{"uri":"https://x/9"}},{"web":{"title":"strong.app","uri":"https://x/1"}}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sources (2"* ]] || return 1
  [[ "$output" != *"internal"* ]] || return 1
  [[ "$output" == *"(untitled source) — https://x/9"* ]] || return 1
  [[ "$output" == *"strong.app"* ]] || return 1
}
