#!/bin/bash
# Pre-push security scan for builder output.
# Scans the branch diff for patterns that indicate prompt injection succeeded.
# Returns non-zero if suspicious patterns found.

set -uo pipefail

BASE="${1:-master}"
DIFF=$(git diff "$BASE"...HEAD 2>/dev/null || git diff HEAD~1 2>/dev/null || exit 0)

if [ -z "$DIFF" ]; then
  exit 0
fi

FINDINGS=()

# Credential/secret exfiltration
if echo "$DIFF" | grep -qiE 'curl\s.*\bhttp|wget\s.*\bhttp|fetch\(|XMLHttpRequest|new\s+WebSocket'; then
  FINDINGS+=("Network request in diff (curl/fetch/WebSocket)")
fi

# Environment variable access
if echo "$DIFF" | grep -qiE 'process\.env\b|import\.meta\.env\b' | grep -vqE 'VITE_'; then
  # Allow VITE_ prefixed env vars (public by design), flag others
  if echo "$DIFF" | grep -iE 'process\.env\b' | grep -qvE 'NODE_ENV|VITE_'; then
    FINDINGS+=("Non-public environment variable access")
  fi
fi

# Eval/exec patterns. Case-sensitive Function check — lowercase `function(` is the
# JS keyword (IIFEs, callbacks), uppercase `Function(` is the dangerous constructor.
# Pre-2026-05-12 the whole alternation was `-i` and a single `function ()` IIFE
# tripped the scan, blocking a clean LIFT-545 PR.
if echo "$DIFF" | grep -qiE '\beval\s*\(|\bexec\s*\(|child_process|spawn\s*\('; then
  FINDINGS+=("Dynamic code execution (eval/exec/spawn)")
elif echo "$DIFF" | grep -qE '\bFunction\s*\('; then
  FINDINGS+=("Dynamic code execution (Function constructor)")
fi

# Obfuscation patterns
if echo "$DIFF" | grep -qiE 'atob\s*\(|btoa\s*\(|String\.fromCharCode|\\x[0-9a-f]{2}'; then
  FINDINGS+=("Obfuscation pattern (base64/charcode)")
fi

# Cryptocurrency/mining
if echo "$DIFF" | grep -qiE 'crypto.*min|coinhive|monero|bitcoin.*wallet'; then
  FINDINGS+=("Cryptocurrency/mining reference")
fi

# Exfiltration via image/beacon
if echo "$DIFF" | grep -qiE 'new\s+Image\(\)\.src|navigator\.sendBeacon'; then
  FINDINGS+=("Data exfiltration pattern (image beacon)")
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  echo "🚨 SECURITY SCAN FAILED — suspicious patterns in diff:"
  for f in "${FINDINGS[@]}"; do
    echo "  ⛔ $f"
  done
  exit 1
fi

exit 0
