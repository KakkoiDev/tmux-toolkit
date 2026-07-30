# Herdr Pane I/O vs tmux-toolkit — Detailed Comparison

## 1. Herdr's Pane I/O Capabilities (Full Reference)

### 1.1 Fundamental Primitives

| Primitive | Herdr command | What it does |
|---|---|---|
| **Send text** | `herdr pane send-text <id> <text>` | Sends literal text to a pane (no trailing newline) |
| **Send keys** | `herdr pane send-keys <id> <key> [key...]` | Sends keystroke names (Enter, Tab, Ctrl+c, etc.) |
| **Run command** | `herdr pane run <id> <command>` | Sends text + Enter atomically |
| **Read output** | `herdr pane read <id> [--source visible\|recent\|recent-unwrapped] [--lines N]` | Reads pane terminal snapshot |
| **Wait for output** | `herdr pane wait-output <id> --match <text> \| --regex <pattern> [--timeout MS]` | Blocks until output matches literal or regex |
| **List panes** | `herdr pane list [--workspace <id>]` | Enumerate panes with IDs |

### 1.2 Source modes for reads

| Mode | Behaviour |
|---|---|
| `visible` | Only what's on screen right now |
| `recent` (default) | Scrollback buffer from the bottom |
| `recent-unwrapped` | Scrollback without line wrapping |
| `detection` | Agent-specific output detection format |

### 1.3 Agent-Aware Layer (built on top of pane I/O)

| Command | Behaviour |
|---|---|
| `herdr agent prompt <target> <text> --wait [--until STATUS]` | Sends prompt, waits for agent to settle into a state (idle/done/blocked) |
| `herdr agent wait <target> [--until STATUS] [--timeout MS]` | Waits for agent to reach a lifecycle state |
| `herdr agent read <target> [--source] [--lines]` | Agent-aware output read |
| `herdr agent start <name> --kind pi\|claude\|codex\|... --pane <id>` | Detects agent readiness in a pane |
| `herdr agent list / get / explain` | Agent registry/metadata |

### 1.4 Key Architectural Properties

- **Atomic `pane run`**: text + Enter are sent as one operation, no race between typing and submitting
- **Blocking `wait-output`**: polls the pane snapshot, supports existing+future output, optional timeout, indefinite wait by default
- **State machine on `agent prompt`**: from non-working state, requires observed state change within 5s (or returns `agent_prompt_stalled`), then waits for idle/done/blocked
- **Socket API**: all commands go over a Unix socket to a persistent server — no forking per operation
- **Agent metadata**: `pane report-agent` / `pane report-metadata` / `pane release-agent` let external tools annotate a pane with agent state

---

## 2. tmux-toolkit Ecosystem — What Exists

tmux-toolkit is a **shared bash library** vendored into five plugins. It does NOT directly do pane I/O. The relevant pieces:

### 2.1 tmux-toolkit (`lib/toolkit.sh` + `lib/toolkit-ui.sh`)

**What it provides:**

| Module | Capabilities |
|---|---|
| `core` | `tk_init`, `tk_die`, `tk_require`, `tk_now`, `tk_mtime`, `tk_age`, `tk_fresh` |
| `tmux` | `tk_tmux`, `tk_tmux_silent`, `tk_tmux_ok`, `tk_in_tmux`, `tk_display` |
| `opt` | `tk_opt`, `tk_opt_many`, `tk_opt_bulk`, `tk_opt_cached`, `tk_opt_set` |
| `version` | `tk_vers`, `tk_vers_ge`, `tk_vers_require` |
| `log` | `tk_log`, `tk_error/warn/info/debug` |
| `json` | `tk_json`, `tk_json_read`, `tk_json_esc`, etc. |
| `sqlite` | `tk_sql`, `tk_sql_init`, `tk_sql_json`, etc. |
| `config` | `tk_config_load`, `tk_config_fresh`, `tk_config_invalidate` |
| `lock` (ui) | `tk_lock`, `tk_unlock` |
| `menu` (ui) | `tk_menu_show` (generates `display-menu` args) |
| `notify` (ui) | `tk_notify` (desktop/os notifications) |

**What is explicitly NOT in tmux-toolkit:**

> `send-keys` and everything around it. tmux-agent-mesh's guarantee is that it never types into a pane, pinned by a grep in its own test suite; it vendors this library, so keystroke injection must not be reachable from here. A contract test enforces it. Typing lives in `tmux-agent-resumer/scripts/keys.sh`.

### 2.2 Plugins that DO pane I/O (outside the toolkit)

The pane I/O operations are scattered across separate plugins. None exist on this Linux machine (Mac-only paths):

| Plugin | I/O operations | Status on this machine |
|---|---|---|
| **tmux-agent-resumer** | `scripts/keys.sh` — `send-keys` wrappers, spill detection, auto-resume | ❌ Not cloned (exists at `/Users/cyril.antoni/...`) |
| **tmux-agent-tracker** | Hook-driven state tracking (reads Claude/Codex/Gemini hooks, writes SQLite) | ✅ Available (TPM plugin) |
| **tmux-agent-mesh** | Multi-agent coordination (explicitly never types into a pane) | ❌ Not cloned |
| **tmux-worktree** | Git worktree management, session naming hooks | ✅ Available |

### 2.3 What tmux itself provides (raw)

| Operation | tmux command | Notes |
|---|---|---|
| Send text | `tmux send-keys -t <target> <text>` | No atomic "text+Enter" — you send two operations |
| Send Enter | `tmux send-keys -t <target> Enter` | |
| Read output | `tmux capture-pane -t <target> -p -S -` | Captures scrollback, no `visible`/`recent` distinction |
| Wait for output | Nothing built-in | Must poll in a loop with `capture-pane` + `grep` |
| List panes | `tmux list-panes -a -F '{format}'` | |
| Run command | `tmux send-keys -t <target> "command" Enter` | No atomicity guarantee |

---

## 3. Head-to-Head: Herdr vs tmux-toolkit Ecosystem

### 3.1 Send + Execute

| Capability | Herdr | tmux-toolkit ecosystem | Gap |
|---|---|---|---|
| Send text | `pane send-text <id> <text>` | `tmux send-keys -t <target> <text>` (raw) | None functionally, but no bash helper in toolkit |
| Send Enter | `pane send-keys <id> Enter` | `tmux send-keys -t <target> Enter` (raw) | None |
| Send text+Enter atomically | `pane run <id> <command>` | No atomic equivalent | **GAP** — must do two `send-keys`, race window exists |
| Send keystroke names | `pane send-keys <id> <key>` | `tmux send-keys -t <target> <key>` (raw) | None |

### 3.2 Read Output

| Capability | Herdr | tmux-toolkit ecosystem | Gap |
|---|---|---|---|
| Read visible screen | `pane read --source visible` | `tmux capture-pane -t <target> -p` | None |
| Read scrollback | `pane read --source recent` | `tmux capture-pane -t <target> -p -S -` | None |
| Read N lines from bottom | `pane read --lines N` | `tmux capture-pane -t <target> -p -S - -E -` but awkward | Minor |
| Read without line wrapping | `--source recent-unwrapped` | Not directly available | **GAP** — would need to post-process |
| Read raw with ANSI | `--format ansi --raw` | `capture-pane -p -e` | None |

### 3.3 Wait for Output (the killer feature)

| Capability | Herdr | tmux-toolkit ecosystem | Gap |
|---|---|---|---|
| Wait for literal match | `wait-output --match <text>` | **Nothing built-in.** Poll loop: `capture-pane` → `grep` → sleep → repeat | **MAJOR GAP** |
| Wait for regex match | `wait-output --regex <pattern>` | Same poll-loop approach | **MAJOR GAP** |
| Timeout | `--timeout MS` | Would need to implement `timeout` wrapper | **MAJOR GAP** |
| Check existing + poll future | Default behaviour | Would need two-phase: capture + grep, then poll loop | **MAJOR GAP** |
| Indefinite wait | Default (no `--timeout`) | No built-in, would loop forever without guard | **MAJOR GAP** |

### 3.4 Agent-Aware Operations

| Capability | Herdr | tmux-toolkit ecosystem | Gap |
|---|---|---|---|
| Know which pane runs an agent | Built-in agent registry | `tmux-agent-tracker` via SQLite + hooks | Implemented differently |
| Send prompt + wait for completion | `agent prompt --wait` | `tmux-agent-resumer` (keys.sh) but no wait-for-output | **GAP** — resumer sends keys but doesn't block on output |
| Wait for agent lifecycle state | `agent wait --until idle\|working\|blocked\|done` | `tmux-agent-tracker` has states but no blocking wait | **GAP** |
| Detect agent started | `agent start --kind pi` — detects readiness | Hook-based: `SessionStart` hook → SQLite write | Different approach |
| Annotate pane metadata | `pane report-agent`, `pane report-metadata` | Not available in toolkit | **GAP** |

### 3.5 Architecture

| Aspect | Herdr | tmux-toolkit ecosystem |
|---|---|---|
| Language | Rust | Bash |
| Runtime | Persistent daemon (server/client) | Per-command fork of `tmux` binary |
| IPC | Unix socket API | tmux's own control mode + options |
| Statefulness | Server holds pane state, output buffers | Stateless — reads tmux options and SQLite on demand |
| Latency profile | Fast (in-process server, socket round-trip) | Slow (fork bash + fork tmux per operation) |
| Wait mechanism | Built-in polling in server | Must be implemented in bash polling loop |

---

## 4. What Would Need to Be Built in tmux-toolkit

Assuming you want to bring tmux-toolkit ecosystem to feature parity with Herdr's pane I/O, here's the work breakdown:

### 4.1 Build: `tk_pane_send` (trivial, ~1 file)

```bash
tk_pane_send <target> <text>       # send-text equivalent
tk_pane_run <target> <command>     # atomic text+Enter (send-keys + Enter in rapid succession)
tk_pane_key <target> <key>         # send-keys wrapper
```

**Notes:**
- `tk_pane_run` can't be truly atomic in tmux (two `send-keys` calls), but can minimize race by sending both in one tmux command
- Must be in a separate module (toolkit explicitly contracts against `send-keys` reachability)

### 4.2 Build: `tk_pane_read` (easy, ~1 file)

```bash
tk_pane_read <target> [--source visible|recent|recent-unwrapped] [--lines N]
```

**Notes:**
- Thin wrapper around `capture-pane` with different flags
- `recent-unwrapped` may need post-processing (strip wraps from tmux output)
- Already partially exists as ad-hoc code in consumer plugins

### 4.3 Build: `tk_pane_wait` (hard, ~2-3 files)

```bash
tk_pane_wait <target> [--match <text>|--regex <pattern>] [--timeout MS] [--lines N]
```

**This is the core gap.** Herdr's `wait-output` is the "killer primitive" that makes agent automation reliable. A tmux-toolkit equivalent needs:

1. **Polling loop** — `capture-pane` → grep/sed for match → sleep → repeat
2. **Efficient capture** — capture only the tail (`-S - -E -`), not full scrollback, to keep forking cheap
3. **Timeout** — `timeout` command or arithmetic in bash
4. **Two-phase matching** — check existing output first (fast path), then poll new output
5. **Backoff** — start at 100ms, increase to 500ms to avoid fork bombing on long waits

**Performance concern:** Each poll = fork bash + fork tmux. A 30-second wait polling every 200ms = 150 forks. Herdr does this in-process with zero forks.

### 4.4 Build: `tk_agent_prompt` (hard, ~2-3 files)

```bash
tk_agent_prompt <target> <text> [--wait] [--timeout MS]
tk_agent_wait <target> [--until state] [--timeout MS]
```

**Notes:**
- Combines `tk_pane_send` + `tk_pane_wait` with agent state awareness
- Requires integration with tmux-agent-tracker's SQLite state database
- The "state stall detection" (5s window from Herdr) is valuable — if agent doesn't change state after prompt, something is wrong
- Timing: 5s stall check, then indefinite wait (or timeout)

### 4.5 Build: `tk_pane_metadata` (medium, ~1 file)

```bash
tk_pane_set_metadata <target> <key=value>...   # annotate pane
tk_pane_get_metadata <target> [key]            # read annotations
```

**Notes:**
- Could piggyback on tmux pane options (`set-option -p @ns-key value`)
- Or use SQLite like agent-tracker does
- Herdr's `report-agent`/`report-metadata` is a pub-sub annotation system — useful but not critical

### 4.6 Architectural Enhancement: Background Watcher (optional, hard ~3-5 files)

To avoid fork-bomb polling, add a lightweight background daemon:

```bash
tk_pane_watch start <target> [--match <pattern>] [--callback <cmd>]
tk_pane_watch stop <target>
```

This would be a background shell process that polls a pane and triggers callbacks. This is what Herdr's server does natively.

**Alternative:** Use tmux's `window-buffers` and `new-session -d` to run a watcher in a detached session. But this is complex and fragile.

---

## 5. Summary Table: Gap Severity

| Capability | Herdr | Current tmux-toolkit | Effort to build | Priority |
|---|---|---|---|---|
| Send text | ✅ `send-text` | ❌ Not in toolkit (raw tmux only) | Trivial (1 file) | High |
| Send text+Enter | ✅ `run` (atomic) | ❌ Not in toolkit, not atomic | Easy (close-enough wrapper) | High |
| Send keys | ✅ `send-keys` | ❌ Not in toolkit (raw tmux only) | Trivial (1 file) | High |
| Read output | ✅ `read` with 3 sources | ❌ Not in toolkit (raw tmux only) | Easy (1 file) | Medium |
| Wait for output | ✅ `wait-output` with timeout | ❌ Nothing, poll-loop DIY | **Hard** (2-3 files) | **Critical** |
| Agent-aware prompt | ✅ `agent prompt --wait` | ❌ Nothing integrated | Hard (3-5 files, needs tracker) | High |
| Agent state wait | ✅ `agent wait --until` | ❌ Nothing blocking | Medium (2-3 files) | Medium |
| Pane metadata | ✅ `report-agent/metadata` | ❌ Nothing | Medium (1 file) | Low |
| Atomic writes | ✅ Single socket IPC | ❌ Multiple forks per op | Architectural | Medium |
| Persistent watcher | ✅ Built-in server | ❌ Nothing | Hard (daemon) | Low |

---

## 6. Recommendation

### Build in this order:

1. **`tk_pane_send`, `tk_pane_run`, `tk_pane_key`** — trivial wrappers, unblocks everything
2. **`tk_pane_read`** — thin capture-pane wrapper with source/line options
3. **`tk_pane_wait`** — the critical piece, poll loop with timeout and two-phase matching
4. **`tk_agent_prompt`** — combines send + wait with tracker integration
5. **`tk_agent_wait`** — agent state waiter on top of tracker SQLite
6. **`tk_pane_metadata`** — annotation system

### Design constraints for toolkit compliance:

- Must live in **a separate module** (not `toolkit.sh` or `toolkit-ui.sh`) — toolkit contracts against send-keys reachability
- Name it `lib/toolkit-pane.sh` or similar, with its own entry point
- Must work on bash 3.2+ (macOS default) — no associative arrays for state tracking
- SQLite for persistent state (consistent with tracker pattern)
- `TK_TMUX_DISABLED=1` must make everything a no-op (testing requirement)

### What remains inherently better in Herdr:

- **True atomic `run`** — tmux can't do this, only approximate
- **In-process polling** — no fork overhead on `wait-output`
- **Agent kind detection** (`agent start --kind pi|claude|codex`) — tmux has no concept of agent types in panes
- **Socket API** — programmatic access without shelling out
