#!/bin/bash
# Shared utility functions for the Architect agent.
# Sourced by scripts/architect.sh. Tested directly by tests/architect.bats.
#
# These functions use shell variables set by the calling script (architect.sh).
# They're extracted here for testability — each can be called with mock state.

# ── AXES ─────────────────────────────────────────────────────────────────────
# 8 architectural axes. The select_axis function rotates through them.
# 2026-08-21 (GA-readiness shift): "test-architecture" retired — the suite is
# already extensive and GA mode adds tests only as regression proof inside bug
# fixes. Replaced by "error-resilience", which hunts the failure paths users
# actually hit. Historical test-architecture rows in the history CSV are
# harmless; select_axis simply no longer counts them.
ARCHITECT_AXES=(
  "store-coherence"
  "composable-quality"
  "component-boundaries"
  "type-safety"
  "error-resilience"
  "pwa-offline"
  "theme-invariants"
  "supabase-rls"
)

# ── select_axis ───────────────────────────────────────────────────────────────
# Selects the architectural axis for this run using round-robin from history CSV.
# If $AXIS_OVERRIDE is set, uses that instead.
#
# Args:   $1 = history CSV path
# Output: prints axis name to stdout
select_axis() {
  local history_csv="$1"

  # Override takes priority
  if [ -n "${AXIS_OVERRIDE:-}" ]; then
    echo "$AXIS_OVERRIDE"
    return 0
  fi

  local num_axes=${#ARCHITECT_AXES[@]}

  # If history CSV doesn't exist or has no data rows, start from 0
  if [ ! -f "$history_csv" ]; then
    echo "${ARCHITECT_AXES[0]}"
    return 0
  fi

  # Count how many times each axis has been run
  # The axis with the fewest runs goes next (ties: pick earliest in list)
  local min_runs=999999
  local chosen_idx=0

  for i in "${!ARCHITECT_AXES[@]}"; do
    local axis="${ARCHITECT_AXES[$i]}"
    local run_count
    run_count=$(grep -c ",$axis," "$history_csv" 2>/dev/null || echo "0")
    run_count=$(echo "$run_count" | tr -d ' \n')
    if [ "$run_count" -lt "$min_runs" ]; then
      min_runs="$run_count"
      chosen_idx="$i"
    fi
  done

  echo "${ARCHITECT_AXES[$chosen_idx]}"
}

# ── axis_display_name ─────────────────────────────────────────────────────────
# Returns a human-readable name for an axis slug.
axis_display_name() {
  case "$1" in
    store-coherence)      echo "Store / State-Management Coherence" ;;
    composable-quality)   echo "Composable Abstraction Quality" ;;
    component-boundaries) echo "Component Layer Boundaries" ;;
    type-safety)          echo "Type-Safety Gaps" ;;
    error-resilience)     echo "Error-Path Resilience" ;;
    pwa-offline)          echo "PWA / Offline Path" ;;
    theme-invariants)     echo "Theme System Invariants" ;;
    supabase-rls)         echo "Supabase RLS / Data-Shape Drift" ;;
    *)                    echo "$1" ;;
  esac
}

# ── axis_is_valid ─────────────────────────────────────────────────────────────
# Returns 0 if the given axis slug is in ARCHITECT_AXES, 1 otherwise.
axis_is_valid() {
  local target="$1"
  for a in "${ARCHITECT_AXES[@]}"; do
    [ "$a" = "$target" ] && return 0
  done
  return 1
}

# ── parse_architect_json ──────────────────────────────────────────────────────
# Extract key fields from Claude's JSON output file for the Architect.
# Output: prints "findings_count,top_finding_summary" to stdout.
parse_architect_json() {
  local json_file="$1"
  python3 -c "
import json, sys

try:
    with open('$json_file') as f:
        data = json.load(f)
    result = data.get('result', '') or ''

    # Try to locate the JSON block inside the result text
    import re
    m = re.search(r'\{.*\}', result, re.DOTALL)
    if m:
        inner = json.loads(m.group(0))
        findings = inner.get('findings', [])
        count = len(findings)
        top = findings[0].get('title', 'N/A') if findings else 'N/A'
    else:
        # Fall back to counting FINDING_TITLE lines as a heuristic
        count = len(re.findall(r'\"title\"', result))
        top = 'see report'
    print(f'{count},{top}')
except Exception as e:
    print(f'0,parse error: {e}')
" 2>/dev/null
}

# ── parse_usage_architect ─────────────────────────────────────────────────────
# Same as builder's parse_usage — extracts token counts from JSON.
parse_usage_architect() {
  local json_file="$1"
  python3 -c "
import json
try:
    with open('$json_file') as f:
        data = json.load(f)
    usage = data.get('usage', {})
    inp = usage.get('input_tokens', 0)
    out = usage.get('output_tokens', 0)
    cr  = usage.get('cache_read_input_tokens', 0)
    cc  = usage.get('cache_creation_input_tokens', 0)
    print(f'{inp},{out},{cr},{cc}')
except:
    print('0,0,0,0')
" 2>/dev/null
}

# ── build_axis_prompt ─────────────────────────────────────────────────────────
# Returns the axis-specific investigation instructions for the Architect prompt.
# Output: prints a multi-line string to stdout.
build_axis_prompt() {
  local axis="$1"
  local repo="$2"

  case "$axis" in
    store-coherence)
      cat <<AXIS
## Axis: Store / State-Management Coherence

Investigate the Pinia stores under \`$repo/src/stores/\`. For each store:

1. **Persistence patterns** — does it use \`useLocalStorage\`/\`localStorage\` directly, Pinia plugin, or nothing? Are patterns consistent across stores?
2. **Error handling** — does every async action have try/catch with a typed error state? Are loading/error states exposed uniformly?
3. **Hydration / SSR safety** — any \`window\`/\`document\` access at module scope that would break SSR or Vitest?
4. **Inter-store coupling** — stores importing other stores directly (creates circular dep risk)?
5. **Action side-effects** — actions that modify state outside their own store?

Scan: \`$repo/src/stores/**\`, \`$repo/src/composables/**\` (for store usage patterns).
AXIS
      ;;
    composable-quality)
      cat <<AXIS
## Axis: Composable Abstraction Quality

Investigate \`$repo/src/composables/\`:

1. **Duplication** — are there repeated patterns in components that should be extracted into a composable?
2. **Return shape consistency** — do composables return \`{ data, error, loading }\` consistently, or is it ad-hoc?
3. **Lifecycle discipline** — composables that set up event listeners: do they all call \`onUnmounted\` to clean up?
4. **Missing abstractions** — look for 3+ components doing the same data-fetch or DOM manipulation without a shared composable.
5. **Over-engineering** — single-use composables that would be cleaner as inline component logic.

Scan: \`$repo/src/composables/**\`, \`$repo/src/components/**\` (for inline patterns that should be composables).
AXIS
      ;;
    component-boundaries)
      cat <<AXIS
## Axis: Component Layer Boundaries

Investigate whether the codebase respects a clean View → Component → Composable → Store layering:

1. **View vs Component** — do views (route-level components) contain business logic, or do they delegate to dumb components?
2. **Direct store access in leaf components** — leaf/presentational components that call \`useStore()\` directly instead of receiving props?
3. **Composable calls in templates** — composables called inline in templates instead of in \`setup()\`?
4. **Cross-cutting concerns** — analytics, error reporting, logging scattered across components instead of in a single composable?
5. **Component file size** — components over 300 lines that should be split?

Scan: \`$repo/src/components/**\`, \`$repo/src/App.vue\`, route-level views if any.
AXIS
      ;;
    type-safety)
      cat <<AXIS
## Axis: Type-Safety Gaps

Hunt for runtime type hazards in \`$repo/src/\`:

1. **\`any\` / \`unknown\` casts** — grep for \`: any\`, \`as any\`, \`as unknown\`. Each one is a type escape hatch.
2. **Missing return types** — exported functions without explicit return type annotations.
3. **Untyped event payloads** — \`emit('event', payload)\` where payload type isn't declared in \`defineEmits\`.
4. **Supabase query results** — are DB query results typed via generated types, or cast to \`any\`?
5. **Props without runtime validation** — props that use \`type: String\` without \`validator\`, where invalid values cause silent failures.

Scan: all \`.ts\` and \`.vue\` files under \`$repo/src/\`.
AXIS
      ;;
    error-resilience)
      cat <<AXIS
## Axis: Error-Path Resilience

Investigate what happens when things FAIL — the paths users hit when the network drops, a write races, or Supabase errors:

1. **Unhandled rejections** — async actions (store actions, composables, event handlers) without try/catch or \`.catch\`. Each is a silent-failure or white-screen risk.
2. **User-visible failure UX** — when a save/sync/load fails, does the user see an error state with a retry path, or does the UI pretend it worked? Silent data loss is the worst GA bug class.
3. **Global error capture** — is there an app-level \`onErrorCaptured\` / \`window.onerror\` / unhandledrejection handler, or do errors vanish into the console?
4. **Partial-write consistency** — multi-step writes (e.g. workout + sets) that can fail halfway and leave stores/DB inconsistent, with no rollback or reconciliation.
5. **Retry and recovery** — are transient failures retried (with backoff), and does recovering (back online, re-auth) resume cleanly without a manual refresh?

Scan: \`$repo/src/stores/**\`, \`$repo/src/composables/**\`, \`$repo/src/main.ts\`, \`$repo/src/App.vue\`, \`$repo/src/lib/**\`.
AXIS
      ;;
    pwa-offline)
      cat <<AXIS
## Axis: PWA / Offline Path

Investigate the service worker and offline-first behavior:

1. **Service worker lifecycle** — does the SW handle \`install\`, \`activate\`, and \`fetch\` correctly? Is \`skipWaiting\` called?
2. **Cache strategies** — which routes use cache-first vs network-first vs stale-while-revalidate? Are Supabase API calls cached?
3. **Navigation fallback** — is there a proper offline fallback page, or does navigation to an uncached route throw a network error?
4. **Install prompt timing** — when is \`beforeinstallprompt\` captured? Is it deferred until after first meaningful interaction?
5. **Background sync** — does the app queue writes when offline and replay on reconnect, or silently lose data?

Scan: \`$repo/public/sw.js\` or \`$repo/src/sw.ts\`, \`$repo/vite.config.*\`, \`$repo/src/main.ts\`.
AXIS
      ;;
    theme-invariants)
      cat <<AXIS
## Axis: Theme System Invariants

Investigate the CSS theme/design-token system:

1. **Hardcoded colors** — grep for hex codes (\`#[0-9a-f]{3,6}\`) and \`rgb(\`) outside of CSS variable definitions.
2. **Missing CSS variables** — colors or spacing values that should use \`var(--token)\` but don't.
3. **Contrast gaps** — text/background color combinations that might fail WCAG AA (4.5:1 for normal text) in any theme.
4. **Theme switching completeness** — are all component styles reactive to the theme class, or do some styles only work in one theme?
5. **Safe-area and viewport tokens** — are \`env(safe-area-inset-*)\` and \`100dvh\` used consistently for mobile PWA layout?

Scan: \`$repo/src/index.css\`, \`$repo/src/assets/**\`, \`$repo/src/components/**\` for inline styles.
AXIS
      ;;
    supabase-rls)
      cat <<AXIS
## Axis: Supabase RLS / Data-Shape Drift

Investigate the Supabase integration for security and data consistency:

1. **RLS assumptions** — does client code assume RLS is always on, or are there queries that would expose data if RLS were misconfigured?
2. **Schema drift** — are TypeScript types for DB rows kept in sync with actual table shapes? Look for cast-to-any workarounds.
3. **Auth token handling** — is the session token refreshed on expiry, or can silent 401s occur mid-session?
4. **Realtime subscriptions** — if used, are channels properly unsubscribed on component unmount?
5. **Client-side data validation** — is data from Supabase validated before use, or trusted blindly (XSS/injection via DB content)?

Scan: \`$repo/src/lib/**\`, \`$repo/src/stores/**\`, \`$repo/supabase/**\` if present, \`$repo/src/**\` for \`supabase\` imports.
AXIS
      ;;
    *)
      echo "Unknown axis: $axis" >&2
      return 1
      ;;
  esac
}

# ── build_architect_prompt ────────────────────────────────────────────────────
# Assembles the full prompt for a Claude Architect run.
# Args:   $1 = axis, $2 = repo path, $3 = project name
# Output: prints the prompt text to stdout
build_architect_prompt() {
  local axis="$1"
  local repo="$2"
  local project="$3"
  local display_name
  display_name=$(axis_display_name "$axis")

  cat <<PROMPT
You are the $project Codebase Architect — a deep-read critic that hunts for architectural drift, structural debt, and missing abstractions. You do NOT write or modify code. You analyze and report.

## Your mandate this run: $display_name

$(build_axis_prompt "$axis" "$repo")

## Output format

You MUST respond with a valid JSON block (and nothing else outside it). The JSON must have this exact shape:

\`\`\`json
{
  "axis": "$axis",
  "axis_display": "$display_name",
  "summary": "2-4 sentence plain English summary of what you found",
  "files_scanned": 0,
  "findings": [
    {
      "title": "Short imperative title (under 80 chars)",
      "motivation": "Why this matters architecturally. 2-4 sentences as a single string. NOT an array.",
      "files": ["src/stores/workout.ts", "src/composables/useWorkout.ts"],
      "proposed_approach": ["3-6 concrete steps as JSON array of strings", "each item is one short imperative sentence", "this field MUST be an array, never a string with bullets"],
      "priority": 2,
      "sequencing_notes": "Single string — not an array. Should be done before/after X because..."
    }
  ]
}
\`\`\`

## Rules

- Return **3-7 findings** — quality over quantity. If you find fewer real issues, return fewer.
- **GA-readiness lens:** $project is feature-complete and stabilizing for a general-availability release. Prefer findings that manifest as user-visible bugs, data loss, performance problems, or broken failure paths. Deprioritize purely structural refactors (naming, file organization, abstraction taste) — report those only at priority 4, or not at all.
- Priority: 1=architectural risk (data loss / security), 2=high structural debt, 3=medium improvement, 4=low polish.
- Each finding must reference at least one real file path you actually read.
- Do NOT report trivial issues: unused imports, typos, style nits — those belong to the Discovery agent.
- Focus on SYSTEM-LEVEL patterns: things that affect multiple components, cause future brittleness, or create hidden coupling.
- If a pattern is fine and there are no findings for a sub-area, say so in the summary — don't invent issues.
- Count the actual number of files you read and set \`files_scanned\` accurately.
PROMPT
}
