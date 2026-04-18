#!/bin/bash
set -euo pipefail
LOG="/tmp/claude-hooks.log"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
  OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // ""')
  LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // ""')
else
  SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))")
  FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))")
  OFFSET=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('offset',''))")
  LIMIT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('limit',''))")
fi

[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0
IS_PARTIAL=false
[[ -n "$OFFSET" && "$OFFSET" != "null" ]] && IS_PARTIAL=true
[[ -n "$LIMIT"  && "$LIMIT"  != "null" ]] && IS_PARTIAL=true

# Skip binary and generated files
case "$FILE_PATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.pdf|*.lock|*.min.js|*.min.css|*.map) exit 0 ;;
esac

FNAME=$(basename "$FILE_PATH")
CACHE_DIR="/tmp/claude-read-cache/$SESSION_ID"
mkdir -p "$CACHE_DIR"

# Block large files (>1000 lines) - require offset/limit
if [[ "$IS_PARTIAL" == "false" ]]; then
  LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo "0")
  LINE_COUNT=$(echo "$LINE_COUNT" | tr -d ' ')
  if [[ "$LINE_COUNT" -gt 1000 ]]; then
    echo "This file has ${LINE_COUNT} lines. Use offset/limit to read only the section you need." >&2
    echo "[$(date +%H:%M:%S)] pre-read: blocked large file ${FNAME} (${LINE_COUNT} lines)" >> "$LOG"
    exit 2
  fi
fi

if command -v md5 &>/dev/null; then
  CACHE_KEY=$(echo -n "$FILE_PATH" | md5 -q)
elif command -v md5sum &>/dev/null; then
  CACHE_KEY=$(echo -n "$FILE_PATH" | md5sum | cut -d' ' -f1)
else
  CACHE_KEY=$(echo -n "$FILE_PATH" | sed 's/[^a-zA-Z0-9]/_/g')
fi

CACHE_FILE="$CACHE_DIR/$CACHE_KEY"

# Partial read range cache check
if [[ "$IS_PARTIAL" == "true" ]]; then
  OFFSET_NUM=${OFFSET:-0}
  if [[ -n "$LIMIT" && "$LIMIT" != "null" ]]; then
    LIMIT_NUM=$LIMIT
  else
    LIMIT_NUM=$(wc -l < "$FILE_PATH" | tr -d ' ')
  fi
  [[ "$LIMIT_NUM" -le 0 ]] && exit 0
  START=$((OFFSET_NUM + 1))
  END=$((OFFSET_NUM + LIMIT_NUM))

  SNAPSHOT_FILE="$CACHE_DIR/${CACHE_KEY}.snapshot"
  RANGES_FILE="$CACHE_DIR/${CACHE_KEY}.ranges"

  if [[ -f "$SNAPSHOT_FILE" && -f "$RANGES_FILE" ]]; then
    if diff -q "$SNAPSHOT_FILE" "$FILE_PATH" > /dev/null 2>&1; then
      while read -r rs re; do
        [[ -z "$rs" || -z "$re" ]] && continue
        if [[ "$rs" -le "$START" && "$re" -ge "$END" ]]; then
          echo "Range already read (lines ${START}-${END}): $FILE_PATH"
          echo "No changes since last read. Work with the content you already have."
          echo "To modify: use Edit tool."
          echo "[$(date +%H:%M:%S)] pre-read: partial range cache hit (${FNAME} ${START}-${END})" >> "$LOG"
          exit 2
        fi
      done < "$RANGES_FILE"
    else
      echo "Showing changes since last read: $FILE_PATH"
      echo "---"
      diff --unified=3 "$SNAPSHOT_FILE" "$FILE_PATH" || true
      echo "---"
      echo "Above diff shows changes since your last read. Check the actual read result below."
      rm -f "$RANGES_FILE"
      echo "[$(date +%H:%M:%S)] pre-read: partial read change detected, diff shown (${FNAME})" >> "$LOG"
      exit 0
    fi

  elif [[ -f "$CACHE_FILE" && -f "$RANGES_FILE" ]]; then
    if diff -q "$CACHE_FILE" "$FILE_PATH" > /dev/null 2>&1; then
      while read -r rs re; do
        [[ -z "$rs" || -z "$re" ]] && continue
        if [[ "$rs" -le "$START" && "$re" -ge "$END" ]]; then
          echo "Range already read (lines ${START}-${END}): $FILE_PATH"
          echo "No changes since last read. Work with the content you already have."
          echo "To modify: use Edit tool."
          echo "[$(date +%H:%M:%S)] pre-read: post-full-read partial range hit (${FNAME} ${START}-${END})" >> "$LOG"
          exit 2
        fi
      done < "$RANGES_FILE"
    else
      echo "Showing changes since last read: $FILE_PATH"
      echo "---"
      diff --unified=3 "$CACHE_FILE" "$FILE_PATH" || true
      echo "---"
      echo "Above diff shows changes since your last read. Check the actual read result below."
      cp "$FILE_PATH" "$CACHE_FILE"
      rm -f "$RANGES_FILE"
      echo "[$(date +%H:%M:%S)] pre-read: post-full-read partial change detected, diff shown (${FNAME})" >> "$LOG"
      exit 0
    fi
  fi

  exit 0
fi

# Full read cache check
[[ ! -f "$CACHE_FILE" ]] && exit 0

if diff -q "$CACHE_FILE" "$FILE_PATH" > /dev/null 2>&1; then
  echo "File unchanged (re-read unnecessary): $FILE_PATH"
  echo "No changes since last read. Work with the content you already have."
  echo "To modify: use Edit tool."
  echo "[$(date +%H:%M:%S)] pre-read: cache hit, blocked re-read (${FNAME})" >> "$LOG"
  exit 2
else
  echo "Showing changes since last read: $FILE_PATH"
  echo "---"
  diff --unified=3 "$CACHE_FILE" "$FILE_PATH" || true
  echo "---"
  echo "Above diff shows changes since your last read. Check the actual read result below."
  cp "$FILE_PATH" "$CACHE_FILE"
  echo "[$(date +%H:%M:%S)] pre-read: full read change detected, diff shown (${FNAME})" >> "$LOG"
  exit 0
fi
