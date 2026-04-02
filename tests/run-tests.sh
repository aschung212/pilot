#!/bin/bash
# Run the pilot test suite
# Usage:
#   ./tests/run-tests.sh              # run all tests
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
FILES=()
for arg in "$@"; do
  case "$arg" in
    --tap) FORMAT="--formatter tap" ;;
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

echo "🧪 Pilot Test Suite"
echo "━━━━━━━━━━━━━━━━━━━"
echo ""

bats $FORMAT "${FILES[@]}"
