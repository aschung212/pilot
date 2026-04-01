#!/bin/bash
# Lift Overnight Runner — chains discovery + triage + builder
# Scheduled via launchd at 11 PM nightly.
# 1. Discovery: finds new issues
# 2. Triage: Gemini reviews/enhances issues, adds implementation plans
# 3. Builder: implements top-priority issues until 7 AM
#
# Logs:
#   Discovery: ~/Documents/Claude/outputs/lift-discover-<date>.md
#   Triage:    ~/Documents/Claude/outputs/lift-triage-<date>.md
#   Builder:   ~/Documents/Claude/outputs/lift-enhance-<date>-run<N>.md
#   This script: ~/Documents/Claude/outputs/lift-overnight-<date>.log

set -euo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

SCRIPTS="$HOME/Documents/Scripts"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="$HOME/Documents/Claude/outputs"
LOG="$OUTPUT_DIR/lift-overnight-$DATE.log"
RUNTIME_CSV="$OUTPUT_DIR/lift-runtime.csv"

# Initialize runtime CSV if needed
if [ ! -f "$RUNTIME_CSV" ]; then
  echo "date,pipeline_start,pipeline_end,total_sec,discover_sec,triage_sec,builder_sec" > "$RUNTIME_CSV"
fi

PIPELINE_START=$(date +%s)
PIPELINE_START_FMT=$(date +%H:%M)

echo "=== Lift Overnight Runner — $DATE $PIPELINE_START_FMT ===" | tee "$LOG"

# Step 1: Discovery agent (quick — finds new issues for the builder)
echo "[$(date +%H:%M)] Starting discovery agent..." | tee -a "$LOG"
STAGE_START=$(date +%s)
if bash "$SCRIPTS/lift-discover.sh" >> "$LOG" 2>&1; then
  echo "[$(date +%H:%M)] Discovery complete." | tee -a "$LOG"
else
  echo "[$(date +%H:%M)] Discovery failed (non-fatal, continuing to builder)." | tee -a "$LOG"
fi
DISCOVER_SEC=$(( $(date +%s) - STAGE_START ))

# Step 2: Triage agent (Gemini reviews and enhances issues before builder picks them up)
echo "[$(date +%H:%M)] Starting triage agent..." | tee -a "$LOG"
STAGE_START=$(date +%s)
if bash "$SCRIPTS/lift-triage.sh" >> "$LOG" 2>&1; then
  echo "[$(date +%H:%M)] Triage complete." | tee -a "$LOG"
else
  echo "[$(date +%H:%M)] Triage failed (non-fatal, builder will work with raw issues)." | tee -a "$LOG"
fi
TRIAGE_SEC=$(( $(date +%s) - STAGE_START ))

# Step 3: Overnight builder (runs until 7 AM)
echo "[$(date +%H:%M)] Starting overnight builder (until 07:00)..." | tee -a "$LOG"
STAGE_START=$(date +%s)
if bash "$SCRIPTS/lift-enhance-overnight.sh" >> "$LOG" 2>&1; then
  echo "[$(date +%H:%M)] Builder finished." | tee -a "$LOG"
else
  echo "[$(date +%H:%M)] Builder exited with error." | tee -a "$LOG"
fi
BUILDER_SEC=$(( $(date +%s) - STAGE_START ))

# Step 4: Linear cleanup (archive completed/canceled, deduplicate)
echo "[$(date +%H:%M)] Running Linear cleanup..." | tee -a "$LOG"
if bash "$SCRIPTS/lift-linear-cleanup.sh" >> "$LOG" 2>&1; then
  echo "[$(date +%H:%M)] Cleanup complete." | tee -a "$LOG"
else
  echo "[$(date +%H:%M)] Cleanup failed (non-fatal)." | tee -a "$LOG"
fi

PIPELINE_END=$(date +%s)
TOTAL_SEC=$((PIPELINE_END - PIPELINE_START))
echo "=== Overnight run complete — $(date +%H:%M) (${TOTAL_SEC}s total: discover=${DISCOVER_SEC}s triage=${TRIAGE_SEC}s builder=${BUILDER_SEC}s) ===" | tee -a "$LOG"

# Append runtime to CSV
echo "$DATE,$PIPELINE_START_FMT,$(date +%H:%M),$TOTAL_SEC,$DISCOVER_SEC,$TRIAGE_SEC,$BUILDER_SEC" >> "$RUNTIME_CSV"
