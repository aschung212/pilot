#!/bin/bash
# Run the pilot test suite
# Usage:
#   ./tests/run-tests.sh              # run all tests
#   ./tests/run-tests.sh --fast       # fast tier only (pre-commit)
#   ./tests/run-tests.sh tracker      # run specific test file
#   ./tests/run-tests.sh --tap        # TAP output for CI

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check bats is installed
if ! command -v bats >/dev/null 2>&1; then
  echo "❌ bats-core not installed. Run: brew install bats-core" >&2
  exit 1
fi

# Parse args
FORMAT=""
FILTER=""
FILES=()
for arg in "$@"; do
  case "$arg" in
    --tap) FORMAT="--formatter tap" ;;
    --fast) FILTER="--filter-tags fast" ;;
    --slow) FILTER="--filter-tags slow" ;;
    *)
      if [ -f "$SCRIPT_DIR/${arg}.bats" ]; then
        FILES+=("$SCRIPT_DIR/${arg}.bats")
      elif [ -f "$arg" ]; then
        FILES+=("$arg")
      else
        echo "Unknown test file: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

# Default: run all .bats files
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=("$SCRIPT_DIR"/*.bats)
fi

if [ -n "$FILTER" ]; then
  echo "🧪 Pilot Test Suite (${FILTER#--filter-tags })"
else
  echo "🧪 Pilot Test Suite"
fi
echo "━━━━━━━━━━━━━━━━━━━"
echo ""

# Use parallel execution if GNU parallel is available
JOBS=""
if command -v parallel >/dev/null 2>&1; then
  JOBS="-j 8"
fi

bats $FORMAT $FILTER $JOBS "${FILES[@]}"
