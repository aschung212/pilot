#!/bin/bash
# Fixture runner. The counter must READ this file — to learn which tag the fast
# tier filters on — and must never EXECUTE it. The tripwire below is how the
# tests tell those two apart.
touch "$(cd "$(dirname "$0")" && pwd)/suite-was-run"

case "$1" in
  --fast) FILTER="--filter-tags fast" ;;
esac
