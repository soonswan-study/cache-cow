#!/bin/bash
set -euo pipefail
LOG="/tmp/claude-hooks.log"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
  OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // ""')
  LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // ""')
  IS_WRITE=$(echo "$INPUT" | jq -r 'if .tool_input.content != null or .tool_input.new_string != null then "true" else "false" end')
else
  SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))")
  FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))")
  OFFSET=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('offset',''))")
  LIMIT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('limit',''))")
  IS_WRITE=$(echo "$INPUT" | python3 -c "
import sys,json; d=json.load(sys.stdin); ti=d.get('tool_input',{})
print('true' if ti.get('content') is not None or ti.get('new_string') is not None else 'false')")
fi

[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0

# Skip binary and generated files
case "$FILE_PATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.pdf|*.lock|*.min.js|*.min.css|*.map) exit 0 ;;
esac

FNAME=$(basename "$FILE_PATH")
CACHE_DIR="/tmp/claude-read-cache/$SESSION_ID"
mkdir -p "$CACHE_DIR"

if command -v md5 &>/dev/null; then
  CACHE_KEY=$(echo -n "$FILE_PATH" | md5 -q)
elif command -v md5sum &>/dev/null; then
  CACHE_KEY=$(echo -n "$FILE_PATH" | md5sum | cut -d' ' -f1)
else
  CACHE_KEY=$(echo -n "$FILE_PATH" | sed 's/[^a-zA-Z0-9]/_/g')
fi

CACHE_FILE="$CACHE_DIR/$CACHE_KEY"

_merge_ranges() {
  local ranges_file="$1"
  local tmp="${ranges_file}.tmp"
  grep -v '^\s*$' "$ranges_file" | sort -n -k1,1 -k2,2 | awk '
    BEGIN { n=0 }
    {
      s=$1; e=$2
      if (n==0) { rs[0]=s; re[0]=e; n=1 }
      else if (s <= re[n-1]+1) { if (e > re[n-1]) re[n-1]=e }
      else { rs[n]=s; re[n]=e; n++ }
    }
    END { for(i=0;i<n;i++) print rs[i], re[i] }
  ' > "$tmp" || { rm -f "$tmp"; return 0; }
  [[ -s "$tmp" ]] && mv "$tmp" "$ranges_file" || rm -f "$tmp"
}

if [[ "$IS_WRITE" == "true" ]]; then
  # On write/edit: update existing cache entry and invalidate ranges
  if [[ -f "$CACHE_FILE" ]]; then
    cp "$FILE_PATH" "$CACHE_FILE"
  fi
  rm -f "$CACHE_DIR/${CACHE_KEY}.snapshot" "$CACHE_DIR/${CACHE_KEY}.ranges"
  echo "[$(date +%H:%M:%S)] post-file-cache: cache updated + ranges invalidated (${FNAME})" >> "$LOG"
else
  RANGES_FILE="$CACHE_DIR/${CACHE_KEY}.ranges"
  SNAPSHOT_FILE="$CACHE_DIR/${CACHE_KEY}.snapshot"

  IS_PARTIAL=false
  [[ -n "$OFFSET" && "$OFFSET" != "null" ]] && IS_PARTIAL=true
  [[ -n "$LIMIT"  && "$LIMIT"  != "null" ]] && IS_PARTIAL=true

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
    cp "$FILE_PATH" "$SNAPSHOT_FILE"
    echo "$START $END" >> "$RANGES_FILE"
    _merge_ranges "$RANGES_FILE"
    echo "[$(date +%H:%M:%S)] post-file-cache: partial range cached+merged (${FNAME} ${START}-${END})" >> "$LOG"
  else
    TOTAL=$(wc -l < "$FILE_PATH" | tr -d ' ')
    cp "$FILE_PATH" "$CACHE_FILE"
    echo "1 $TOTAL" > "$RANGES_FILE"
    rm -f "$SNAPSHOT_FILE"
    echo "[$(date +%H:%M:%S)] post-file-cache: full read cached (${FNAME})" >> "$LOG"
  fi
fi

exit 0
