#!/bin/bash
# Shared logging library — source this in all pipeline scripts.
#
# Provides:
#   log_info  "message"   → INFO level
#   log_warn  "message"   → WARN level
#   log_error "message"   → ERROR level (also sends Slack alert)
#   log_rotate            → archives logs older than 14 days
#
# Writes to:
#   1. Component log (the script's own $RUN_LOG or stdout)
#   2. Unified daily log ($OUTPUT_DIR/pilot-YYYY-MM-DD.log)
#
# Format: YYYY-MM-DD HH:MM:SS | LEVEL | COMPONENT | message
#
# Usage in scripts:
#   source "$SCRIPT_DIR/../lib/log.sh"
#   LOG_COMPONENT="builder"   # set before calling log functions
#   log_info "Starting iteration $RUN"

# Resolve paths
_LOG_REAL="$(readlink "$0" 2>/dev/null || echo "$0")"
_LOG_SCRIPT_DIR="$(cd "$(dirname "$_LOG_REAL")" && pwd)"
_LOG_PROJECT_DIR="$(cd "$_LOG_SCRIPT_DIR/.." && pwd)"

# Source project.env if not already loaded
[ -z "${OUTPUT_DIR:-}" ] && [ -f "$_LOG_PROJECT_DIR/project.env" ] && source "$_LOG_PROJECT_DIR/project.env"

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
LOG_COMPONENT="${LOG_COMPONENT:-unknown}"

_UNIFIED_LOG="$OUTPUT_DIR/pilot-$(date +%Y-%m-%d).log"

# Core log function
_log() {
  local level="$1" msg="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local line="$timestamp | $level | $LOG_COMPONENT | $msg"

  # Write to unified log
  echo "$line" >> "$_UNIFIED_LOG" 2>/dev/null

  # Write to stdout (component log captures this via tee/redirect)
  echo "$line"
}

log_info() {
  _log "INFO" "$1"
}

log_warn() {
  _log "WARN" "$1"
}

log_error() {
  _log "ERROR" "$1"

  # Alert to Slack on errors
  local notify="$_LOG_PROJECT_DIR/adapters/notify.sh"
  if [ -x "$notify" ]; then
    bash "$notify" send automation "🚨 *ERROR in $LOG_COMPONENT*: $1" 2>/dev/null &
  fi
}

# Rotate logs older than 14 days into archive/
log_rotate() {
  local archive_dir="$OUTPUT_DIR/archive"
  mkdir -p "$archive_dir"
  local count=0

  # Archive old unified logs
  find "$OUTPUT_DIR" -maxdepth 1 -name "pilot-*.log" -mtime +14 -exec mv {} "$archive_dir/" \; 2>/dev/null
  # Archive old component logs
  find "$OUTPUT_DIR" -maxdepth 1 -name "lift-*.log" -mtime +14 -exec mv {} "$archive_dir/" \; 2>/dev/null
  find "$OUTPUT_DIR" -maxdepth 1 -name "lift-*.md" -mtime +14 -exec mv {} "$archive_dir/" \; 2>/dev/null
  find "$OUTPUT_DIR" -maxdepth 1 -name "lift-*-output.json" -mtime +14 -exec mv {} "$archive_dir/" \; 2>/dev/null

  count=$(find "$archive_dir" -type f -newer "$archive_dir" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] && log_info "Rotated $count files to archive/"

  # Delete archives older than 60 days
  find "$archive_dir" -type f -mtime +60 -delete 2>/dev/null
}
