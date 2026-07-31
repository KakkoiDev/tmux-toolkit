# Debugging tmux-toolkit

How AIs (and humans) debug toolkit issues.

## Where logs live

| What | Path |
|------|------|
| Debug log | `~/.tmux-toolkit/debug.log` (or `$TK_DIR/debug.log`) |
| Bug reports | `~/.tmux-toolkit/bugs/` (or `$TK_DIR/bugs/`) |

The `TK_DIR` is set by `tk_init <ns> [data_dir]` and defaults to `~/.tmux-<ns>`.

## Debug log format

One JSON line per event, grep-able:

```json
{"ts":"2026-07-31T17:00:00","fn":"tk_pane_send","status":"OK","detail":"target=%5"}
{"ts":"2026-07-31T17:00:01","fn":"tk_pane_run","status":"ERR","detail":"pane dead: %5"}
{"ts":"2026-07-31T17:00:02","fn":"tk_lock","status":"WARN","detail":"stale lock stolen"}
```

### Status values

| Status | Meaning |
|--------|---------|
| `TRACE` | Function entry (from `tk_debug_trace`) |
| `OK`    | Success (from `tk_debug_ok`) |
| `ERR`   | Failure (from `tk_debug_err`) |
| `WARN`  | Warning (from `tk_debug_warn`) |

### Rotation

The log rotates at 1 MB, keeping the most recent ~512 KB.
Rotation is sampled (~1% of writes) to avoid a `wc -c` fork on every call.

No locks are used: appending is atomic at the kernel level for lines
under `PIPE_BUF` (~4 KB), and our log lines are much shorter.

## How to read and act on a bug report

1. **Open the bug report** — it's a markdown file named `YYYYMMDD-HHMMSS.md`
   in `$TK_DIR/bugs/`.

2. **Read the Failure section** — which function failed, what detail was
   captured, and what the function was trying to do.

3. **Check the Environment** — tmux version, OS, bash version, and the
   tmux session/window/pane state at the time of the crash.

4. **Read the Debug Log tail** — the last 20 log entries show what happened
   right before the failure. Look for `ERR` or `WARN` entries immediately
   preceding the crash.

5. **Read the Stack Trace** — the calling function chain shows how the
   code reached the failure point. The topmost `tk_*` function is the one
   that failed.

6. **Check Suggested Causes** — fill in the `[TODO: AI analysis]`
   placeholders with your analysis of what went wrong.

## How to write a fix and verify

1. **Identify the root cause** from the bug report.

2. **Write a failing test** in the appropriate `tests/unit/` bats file
   that reproduces the condition.

3. **Fix the code** in `lib/`.

4. **Run the test suite:**
   ```bash
   make test
   ```

5. **Update the bug report's Resolution section** with the fix.

## Manually triggering bug reports

```bash
# From any script that sources toolkit-ui.sh:
tk_bug_report "function_name" "error detail" "what I was trying to do"

# Install the automatic ERR trap:
tk_crash_handler_install
# Now any failed command under `set -e` generates a bug report.
```

## Examining the debug log

```bash
# Last 50 entries:
tail -50 ~/.tmux-toolkit/debug.log

# All errors:
grep '"status":"ERR"' ~/.tmux-toolkit/debug.log

# Errors and warnings:
grep -E '"status":"(ERR|WARN)"' ~/.tmux-toolkit/debug.log

# Activity for a specific function:
grep '"fn":"tk_pane_send"' ~/.tmux-toolkit/debug.log
```

## Testing with headless sessions

For integration tests that need real tmux but must not touch the user's
session:

```bash
source lib/toolkit-ui.sh
tk_init test-plugin

# Start an isolated session.
socket=$(tk_test_session_start "my-test")

# Run commands.
tk_test_exec "$socket" "echo hello"

# Capture output.
content=$(tk_test_capture "$socket")

# Clean up.
tk_test_session_stop "$socket"
```

The test session uses `tmux -L test-XXXX -f /dev/null` — it never loads
the user's config and doesn't appear on their screen.

## Debugging from Claude Code / Pi

When the agent reports a toolkit failure:

1. **Read `$TK_DIR/debug.log`** for the last ~50 lines.
2. **If there's a bug report**, read it — it contains the precise context.
3. **Check tmux state:** `tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'`
4. **Verify the toolkit version:** `tmux-toolkit version`
5. **Run the doctor:** `tmux-toolkit doctor`
