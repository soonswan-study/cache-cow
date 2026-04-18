# Hook Documentation

Detailed explanation of each hook: what problem it solves, how it works, and what the result looks like.

---

## Table of Contents

1. [session-start.sh](#1-session-startsh) - Session cache initialization
2. [pre-read.sh](#2-pre-readsh) - Read cache / large file blocking
3. [post-file-cache.sh](#3-post-file-cachesh) - File content caching
4. [pre-bash.sh](#4-pre-bashsh) - Test output filtering / log limiting
5. [pre-bash.helper.filter.sh](#5-pre-bashhelperfiltersh) - Test runner output parser
6. [post-compact.sh](#6-post-compactsh) - Post-compaction cache cleanup

---

## 1. session-start.sh

**Event:** `SessionStart`

### Problem

When a new Claude Code session starts, stale cache data from previous sessions may remain in `/tmp`. Over time, these accumulate and waste disk space. Additionally, Claude Code often re-queries git status and project structure at the start of every session, even though this information is already injected into the conversation context.

### Solution

This hook runs automatically when a new session begins:

1. **Clears the read cache** for the current session ID (if any leftover from a crashed session)
2. **Purges old caches** older than 7 days across all sessions
3. **Injects a reminder** telling Claude not to re-query session-injected state

```bash
# Cache cleanup
rm -rf "/tmp/claude-read-cache/$SESSION_ID"

# Purge stale caches (>7 days)
find "$CACHE_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
find /tmp/claude-hook-cache -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

### Result

```
[SessionStart] Read cache cleared (12 entries removed)

[Reminder] Do not re-query git status or project structure injected at session start.
```

Log output:
```
[14:30:01] session-start: done
```

---

## 2. pre-read.sh

**Event:** `PreToolUse` (matcher: `Read`)

### Problem

Claude Code frequently re-reads the same file multiple times in a single session:

- Before editing: reads the file to understand context
- After editing: reads it again to verify changes
- During review: reads it once more to check the result
- When referencing: reads it to answer questions about the code

A typical file gets read **3-5 times per session**. Each read consumes tokens proportional to the file size. For a 500-line file read 4 times, that's 2000 lines of tokens wasted on identical content.

Additionally, when Claude reads a very large file (1000+ lines), it consumes a massive amount of tokens even though it usually only needs a small section.

### Solution

This hook intercepts every `Read` tool call and applies four layers of protection:

#### Layer 1: Large File Blocking (full reads only)

Files exceeding 1000 lines are blocked for **full reads**. Claude must specify `offset` and `limit` to read only the section it needs. Partial reads with `offset`/`limit` bypass this check regardless of file size.

```bash
if [[ "$IS_PARTIAL" == "false" ]]; then
  LINE_COUNT=$(wc -l < "$FILE_PATH")
  if [[ "$LINE_COUNT" -gt 1000 ]]; then
    echo "This file has ${LINE_COUNT} lines. Use offset/limit to read only the section you need."
    exit 2  # Block the read
  fi
fi
```

#### Layer 2: Partial Read Range Cache

When `offset` or `limit` is specified, the hook checks if the requested line range has already been read and the file hasn't changed since. If the range is covered, the read is blocked.

Read ranges are stored as a merged union in `{cache_key}.ranges`. For example, after reading lines 1-50 and then 51-100, the ranges file contains `1 100` (merged). A subsequent request for lines 20-70 is detected as already covered.

```bash
# If requested range [START, END] is covered by an existing range:
if [[ "$rs" -le "$START" && "$re" -ge "$END" ]]; then
  echo "Range already read (lines ${START}-${END}): $FILE_PATH"
  exit 2  # Block the read
fi
```

#### Layer 3: Cache Hit (Unchanged File, full reads)

If the file has been fully read before and hasn't changed since, the read is blocked entirely.

```bash
if diff -q "$CACHE_FILE" "$FILE_PATH" > /dev/null 2>&1; then
  echo "File unchanged (re-read unnecessary): $FILE_PATH"
  exit 2  # Block the read
fi
```

#### Layer 4: Diff-Only Return (Changed File)

If the file has been read before but has changed (e.g., after an edit), only the diff is returned instead of the full file content. The read is then allowed so Claude gets the current content.

```bash
diff --unified=3 "$CACHE_FILE" "$FILE_PATH"
cp "$FILE_PATH" "$CACHE_FILE"  # Update cache
exit 0  # Allow the read (post-file-cache will update ranges)
```

### Result

**Case 1: Large file blocked (full read)**
```
This file has 2847 lines. Use offset/limit to read only the section you need.
```

**Case 2: Partial range already read**
```
Range already read (lines 1-50): /project/src/auth/service.ts
No changes since last read. Work with the content you already have.
```

**Case 3: Cache hit (full read, file unchanged)**
```
File unchanged (re-read unnecessary): /project/src/auth/service.ts
No changes since last read. Work with the content you already have.
```

**Case 4: File changed since last read**
```
Showing only changes since last read: /project/src/auth/service.ts
---
@@ -45,7 +45,7 @@
   async validateToken(token: string) {
-    return this.jwtService.verify(token);
+    return this.jwtService.verifyAsync(token);
   }
---
Above diff shows changes since your last read.
```

Log output:
```
[14:31:15] pre-read: blocked large file service.ts (2847 lines)
[14:31:20] pre-read: partial range cache hit (service.ts 1-50)
[14:31:22] pre-read: cache hit, blocked re-read (service.ts)
[14:32:01] pre-read: change detected, returning diff (service.ts)
```

---

## 3. post-file-cache.sh

**Event:** `PostToolUse` (matcher: `Read|Edit|Write`)

### Problem

The `pre-read.sh` hook needs a cached copy of each file to compare against. Without a caching mechanism, it has nothing to diff with. Additionally, when Claude edits or writes a file, the cache must be updated to stay in sync; otherwise, the next read would show a false diff.

### Solution

This hook runs after every `Read`, `Edit`, or `Write` tool call:

#### On Full Read

Saves the file to the session cache and records the full range (`1 N`) in `.ranges`. Deletes any `.snapshot` left from prior partial reads (since the full cache is now authoritative).

```bash
cp "$FILE_PATH" "$CACHE_FILE"
echo "1 $TOTAL" > "$RANGES_FILE"
rm -f "$SNAPSHOT_FILE"
```

#### On Partial Read (offset/limit specified)

Saves a snapshot of the file (diff baseline) and appends the read range to `.ranges`. Ranges are then merged so `[1-50] + [51-100]` becomes `[1-100]`.

```bash
cp "$FILE_PATH" "$SNAPSHOT_FILE"
echo "$START $END" >> "$RANGES_FILE"
_merge_ranges "$RANGES_FILE"  # sort + awk union merge
```

#### On Edit/Write

Updates the full cache (if it exists) and **deletes** `.snapshot` and `.ranges` so the next partial read is treated as fresh.

```bash
if [[ -f "$CACHE_FILE" ]]; then cp "$FILE_PATH" "$CACHE_FILE"; fi
rm -f "$CACHE_DIR/${CACHE_KEY}.snapshot" "$CACHE_DIR/${CACHE_KEY}.ranges"
```

#### Cache Structure

Each file path is hashed (md5) to create a flat cache directory:

```
/tmp/claude-read-cache/{session_id}/
  {md5}           ← full read snapshot (pre-read diff base)
  {md5}.snapshot  ← partial read snapshot (diff base)
  {md5}.ranges    ← merged read ranges: "1 50\n80 120" (sorted, non-overlapping)
```

### Result

The hook is silent to Claude (no stdout output). It only writes to the log:

```
[14:31:10] post-file-cache: full read cached (service.ts)
[14:31:18] post-file-cache: partial range cached+merged (service.ts 1-50)
[14:32:05] post-file-cache: cache updated + ranges invalidated (service.ts)
```

---

## 4. pre-bash.sh

**Event:** `PreToolUse` (matcher: `Bash`)

### Problem

**Test runners** produce verbose output. A typical `pytest` run with 100+ tests generates hundreds of lines, but Claude only needs:
- How many tests were collected
- Which tests failed (with tracebacks)
- The final summary

The rest (dots, passes, percentages, warnings) is noise that wastes tokens.

**Log commands** like `cat app.log` or `docker logs` can dump thousands of lines when only the recent entries matter.

### Solution

#### Test Runner Detection

The hook pattern-matches against common test commands:

```bash
# Matches: pytest, python -m pytest, manage.py test, npm test, npx jest, yarn test, vitest
if echo "$COMMAND" | grep -qE '(pytest|python -m pytest|manage\.py test|npm test|npx jest|yarn test|vitest)'; then
```

When detected, it rewrites the command to pipe output through the `pre-bash.helper.filter.sh` awk filter:

```bash
# Original:  pytest tests/ -v
# Rewritten: pytest tests/ -v 2>&1 | ~/.claude/hooks/pre-bash.helper.filter.sh
```

The rewrite is returned as a `hookSpecificOutput` JSON that Claude Code's hook system understands:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": { "command": "pytest tests/ -v 2>&1 | /path/to/filter.sh" },
    "additionalContext": "Test output filtered (showing only: start, results, failures, errors)"
  }
}
```

#### Log Command Detection

Commands that read log files without any truncation (no `head`, `tail`, `grep`, etc.) are automatically piped through `tail -100`:

```bash
# Original:  cat /var/log/app.log
# Rewritten: cat /var/log/app.log | tail -100

# Original:  docker logs my-container
# Rewritten: docker logs my-container | tail -100
```

#### Passthrough

All other commands (e.g., `ls`, `git status`, `npm install`) pass through unchanged with `exit 0`.

### Result

**Test command (before):** 200+ lines of pytest output
**Test command (after):** ~8-15 lines (session start, failures, summary)

```
======================== test session starts ========================
collected 142 items
...
_______ FAILURES _______
___ test_payment_refund ___
assert result.status == "refunded"
AssertionError: assert "pending" == "refunded"
======================== 1 failed, 141 passed ========================
```

**Log command (before):** Entire log file (could be thousands of lines)
**Log command (after):** Last 100 lines only

Log output:
```
[14:33:10] pre-bash: test output filter applied
[14:34:22] pre-bash: log output limited to tail -100
```

---

## 5. pre-bash.helper.filter.sh

**Event:** None (helper script called by `pre-bash.sh`)

### Problem

Test runner output from different frameworks (pytest, jest, Django test, vitest) follows different formats. A single filter needs to handle all of them while extracting only the essential information.

### Solution

An `awk` script that uses a state machine (`pm` variable) to track which section of the output it's in:

| State | Meaning | Action |
|---|---|---|
| `pm=0` | Normal (skip lines) | Only print known important patterns |
| `pm=1` | Test session header | Print until `collected N items`, then skip |
| `pm=2` | Failures / short summary | Print everything |
| `pm=3` | Errors section | Print everything |
| `pm=4` | Jest failure detail (`●`) | Print until blank line |

#### Patterns Always Printed (regardless of state)

| Pattern | Framework |
|---|---|
| `PASSED`, `FAILED`, `ERROR` | pytest |
| `Ran N tests`, `OK`, `FAILED (` | Django test |
| `Creating/Destroying test database` | Django test |
| `System check identified` | Django check |
| `Tests:`, `Test Suites:`, `PASS`, `FAIL` | Jest |
| `Traceback`, `Error:`, `assert` | All |

### Result

**pytest input (142 tests, 1 failure):**
```
======================== test session starts ========================
platform darwin -- Python 3.11.5
collected 142 items
...
_______ FAILURES _______
___ test_payment_refund ___
    def test_payment_refund():
        result = process_refund(order_id=123)
>       assert result.status == "refunded"
E       AssertionError: assert "pending" == "refunded"
======================== short test summary info ========================
FAILED tests/test_payment.py::test_payment_refund
======================== 1 failed, 141 passed in 8.23s ========================
```

**jest input (45 tests, 1 failure):**
```
Test Suites: 1 failed, 12 passed, 13 total
Tests:       1 failed, 44 passed, 45 total
● CartService > should calculate discount
  expect(received).toBe(expected)
  Expected: 0.15
  Received: 0.1
```

---

## 6. post-compact.sh

**Event:** `PostCompact`

### Problem

When Claude Code's context window fills up, it triggers **compaction**: the conversation is summarized to free up space. After compaction, Claude loses the detailed content of files it previously read. However, the read cache still contains old snapshots, which means:

- `pre-read.sh` would incorrectly say "File unchanged" for files Claude no longer remembers
- Cached diffs would reference content Claude no longer has in context

The cache must be invalidated after compaction so Claude can re-read files fresh.

### Solution

This hook clears both cache directories for the current session:

```bash
# Clear read cache (file snapshots)
rm -rf "/tmp/claude-read-cache/$SESSION_ID"

# Clear hook cache (project context)
rm -rf "/tmp/claude-hook-cache/$SESSION_ID"
```

### Result

```
[PostCompact] Read cache cleared (24 entries removed). Re-read files as needed.
[PostCompact] Hook cache cleared.
```

After this, all subsequent `Read` calls pass through normally (first-read behavior), and the cache rebuilds naturally as Claude reads files again.

Log output:
```
[15:10:33] post-compact: read cache cleared (24 entries)
[15:10:33] post-compact: hook cache cleared
```

---

## Hook Lifecycle

A typical session flows through the hooks in this order:

```
Session Start
  │
  ├─ session-start.sh          Clear old cache, inject reminder
  │
  ├─ Read file.ts
  │   ├─ pre-read.sh           First read → pass through
  │   └─ post-file-cache.sh    Cache file snapshot
  │
  ├─ Read file.ts (again)
  │   └─ pre-read.sh           Cache hit → "File unchanged" (blocked)
  │
  ├─ Edit file.ts
  │   └─ post-file-cache.sh    Update cache with new content
  │
  ├─ Read file.ts (after edit)
  │   └─ pre-read.sh           Changed → return diff only
  │
  ├─ Bash: pytest tests/
  │   └─ pre-bash.sh           Rewrite with output filter
  │
  ├─ [Context compaction occurs]
  │   └─ post-compact.sh       Clear all caches
  │
  ├─ Read file.ts (after compaction)
  │   ├─ pre-read.sh           No cache → pass through (fresh read)
  │   └─ post-file-cache.sh    Re-cache file
  │
  └─ Session End
```
