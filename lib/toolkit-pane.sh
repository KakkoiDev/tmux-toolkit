# shellcheck shell=bash
# toolkit-pane.sh - pane I/O layer: send, run, read, wait, agent-aware typing.
#
# Fills the gap documented in docs/herdr-pane-io-assessment.md: herdr ships
# send/run/read/wait as first-class primitives; this library shipped none of
# them, so every consumer hand-rolled `send-keys` + `capture-pane` + poll
# loops. This module is the agent-facing complement to the human-facing menu
# system: where display-menu serves the human, the tk_pane_* functions serve an
# agent through its Bash tool.
#
# It lives in its own file on purpose. toolkit.sh is the hot set every consumer
# vendors and every hook sources; tmux-agent-mesh's whole thesis is that it
# never types into a pane, and the contract test "send-keys appears only in
# toolkit-pane.sh" pins that boundary. This module is opt-in: only toolkit-ui.sh
# sources it, and a plugin that never calls a pane function never reaches a
# send-keys.
#
# ── guardrails, in evidence order (docs/agent-surface-assessment.md §5) ──
#   1. Never write to your own pane. An agent typing into its own pane feeds
#      its own stdin. Resolved via TMUX_PANE vs #{pane_id}, not by string
#      comparison on the target (which is a session:window.pane label).
#   2. Read before write. Every typing function fails until the pane has been
#      read with tk_pane_read (or acknowledged with tk_pane_set <t> read 1),
#      which records @pane-read on the pane. Blind typing into a pane the agent
#      has never looked at is how output lands in the wrong place.
#   3. Liveness classification before sending, via a `ps -eo ppid,comm` child
#      walk - NOT #{pane_current_command}, which claude rewrites to its version
#      string (plan V3; that format value is literally "2.1.220" for a claude
#      pane here). Typing is refused unless the pane's process tree is a known
#      shell or agent. Foreground detection is a child walk because tmux panes
#      launched with a command run that command as pane_pid (or a shell that
#      spawned it), so the shell itself is never the whole story.
#   4. Bounded reads by default: a 200-line tail with -J for wrapped lines, not
#      a full scrollback dump into the agent's context.
#   5. This module never spawns panes. tk_pane_run's shell launch is a
#      respawn-pane, which reuses the existing pane; the pane count is
#      invariant here. A configurable cap on spawned panes belongs to the
#      future creation API (plan H.10), where spawning is even possible.
#   6. Every function that types prints the human's attach command, so the
#      human can always find the pane an agent is writing to (mitsuhiko's
#      tmux skill convention).
#
# Firstmate's delivery discipline is a deliberate boundary here: prompt/send
# type once and never submit. The retry-Enter-until-composer-clears loop that
# turns a typed prompt into a delivered one is a separate verb for the resumer,
# not a primitive.

# ── tunables ─────────────────────────────────────────────────────────

TK_PANE_READ_LINES="${TK_PANE_READ_LINES:-200}"
TK_PANE_WAIT_TIMEOUT="${TK_PANE_WAIT_TIMEOUT:-30}"
# comm names (after basename and a leading -) that classify a pane's process
# tree as a shell or an agent. macOS reports a framework binary's full exec
# path, hence the basename; TK_PANE_AGENT_NAMES is overridable because harness
# names change faster than this list does.
TK_PANE_AGENT_NAMES="${TK_PANE_AGENT_NAMES:-claude claude-code codex gemini pi aider cursor Python python3}"
TK_PANE_SHELL_NAMES="${TK_PANE_SHELL_NAMES:-bash zsh sh dash fish ksh mksh tcsh}"

# ── failure ──────────────────────────────────────────────────────────

# tk_pane_refuse <msg> - a guardrail refusal: stderr, status 1. Deliberately
# not tk_die: a guard that exits the whole script turns one bad pane target
# into a dead agent loop.
tk_pane_refuse() {
    printf 'tk-pane: %s\n' "$*" >&2
    return 1
}

# ── annotations ──────────────────────────────────────────────────────

# tk_pane_set <target> <key> <value> - annotate a pane as a tmux pane option
# named @pane-<key>. The read-before-write guard uses @pane-read; agents can
# store their own notes with any other key.
tk_pane_set() {
    local target="${1:-}" key="${2:-}" value="${3:-}"
    [[ -n "$target" && -n "$key" ]] || { tk_pane_refuse "tk_pane_set: target and key required"; return 1; }
    tk_tmux set-option -p -t "$target" "@pane-$key" "$value" 2>/dev/null || true
}

# tk_pane_get <target> <key> - read an annotation. Unset returns empty, like
# tk_opt: an unset pane option makes show-options fail, which is swallowed.
tk_pane_get() {
    local target="${1:-}" key="${2:-}"
    [[ -n "$target" && -n "$key" ]] || { tk_pane_refuse "tk_pane_get: target and key required"; return 1; }
    tk_tmux show-options -p -t "$target" -v "@pane-$key" 2>/dev/null || true
}

# tk_pane_was_read <target> - true when @pane-read has been set on the pane.
tk_pane_was_read() {
    [[ -n "$(tk_pane_get "$1" read)" ]]
}

# ── capture ──────────────────────────────────────────────────────────

# tk_pane_capture <target> [lines] - capture-pane -p -J against a target.
# With lines: the last <lines> of scrollback plus the visible screen
# (-S -<lines>); without: the whole scrollback (-S -). Returns tmux's status,
# so a caller can distinguish an empty pane from a vanished one.
tk_pane_capture() {
    local target="${1:-}" lines="${2:-}"
    [[ -n "$target" ]] || return 1
    if [[ -n "$lines" ]]; then
        tk_tmux capture-pane -t "$target" -p -J -S "-$lines" 2>/dev/null
    else
        tk_tmux capture-pane -t "$target" -p -J -S - 2>/dev/null
    fi
}

# ── liveness classification ──────────────────────────────────────────

# tk_pane_classify <comm> - shell|agent|other for one comm name. Agent wins
# over shell so TK_PANE_AGENT_NAMES can override a name that is also a shell.
tk_pane_classify() {
    local comm="${1:-}" name
    comm="${comm#-}"
    comm="${comm##*/}"
    # macOS shows a shim's process name parenthesized: ps comm for /usr/bin/python3
    # is literally "(Python)".
    comm="${comm#(}"
    comm="${comm%)}"
    # Intentional word-split on the name lists.
    # shellcheck disable=SC2086
    for name in $TK_PANE_AGENT_NAMES; do
        [[ "$comm" == "$name" ]] && { printf 'agent\n'; return 0; }
    done
    # shellcheck disable=SC2086
    for name in $TK_PANE_SHELL_NAMES; do
        [[ "$comm" == "$name" ]] && { printf 'shell\n'; return 0; }
    done
    printf 'other\n'
}

# tk_pane_proc <target> - liveness classification of what is actually running
# in the pane, printed as "<state> [comm]" (state: dead|shell|agent|other).
#
# The walk: comm(pane_pid) first - a pane launched directly as an agent is the
# agent. Otherwise classify the direct children of pane_pid and take the first
# non-other: a shell at a prompt has none (shell), a shell running claude has
# claude (agent), a pane running a foreground editor has vim (other). A pane
# with no useful child and an unknown own comm is other. No ps output for the
# pid means the process died between the display-message and the ps call.
tk_pane_proc() {
    local target="${1:-}" pid pcomm="" children="" line cpid cppid ccomm
    [[ -n "$target" ]] || { printf 'dead\n'; return 0; }
    pid="$(tk_tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) printf 'dead\n'; return 0 ;; esac
    while IFS=' ' read -r cpid cppid ccomm; do
        [[ -n "$cpid" ]] || continue
        [[ "$cpid" == "$pid" ]] && pcomm="$ccomm"
        [[ "$cppid" == "$pid" ]] && children="$children $ccomm"
    done <<< "$(ps -eo pid=,ppid=,comm= 2>/dev/null || true)"
    [[ -n "$pcomm" ]] || { printf 'dead\n'; return 0; }

    local state child
    state="$(tk_pane_classify "$pcomm")"
    if [[ "$state" != "agent" ]]; then
        local saw_child=0
        # Intentional word-split on the child list.
        # shellcheck disable=SC2086
        for child in $children; do
            saw_child=1
            state="$(tk_pane_classify "$child")"
            [[ "$state" != "other" ]] && break
        done
        [[ "$saw_child" -eq 0 ]] && state="$(tk_pane_classify "$pcomm")"
    fi
    printf '%s %s\n' "$state" "${pcomm##*/}"
}

# ── write guard (guardrails 1-3) ─────────────────────────────────────

# tk_pane_write_guard <target> <mode> - the checks every typing function runs
# before a single keystroke. Modes: any (key: any live process), send (shell or
# agent), run (shell; a dead pane is allowed, tk_pane_run respawns it),
# agent (agent only).
tk_pane_write_guard() {
    local target="${1:-}" mode="${2:-}"
    [[ -n "$target" ]] || { tk_pane_refuse "target pane required"; return 1; }

    if [[ -n "${TMUX_PANE:-}" ]]; then
        local own
        own="$(tk_tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null || true)"
        if [[ -n "$own" && "$own" == "$TMUX_PANE" ]]; then
            tk_pane_refuse "refusing to type into own pane ($TMUX_PANE); that would feed your own stdin"
            return 1
        fi
    fi

    tk_pane_was_read "$target" || {
        tk_pane_refuse "refusing to type into $target before reading it; run tk_pane_read '$target' first (or acknowledge with tk_pane_set '$target' read 1)"
        return 1
    }

    local state
    state="$(tk_pane_proc "$target")"
    case "$state" in
        dead*)  [[ "$mode" == "run" ]] && return 0
                tk_pane_refuse "pane $target is dead; nothing to type into (tk_pane_run can respawn it)"
                return 1 ;;
        agent*) [[ "$mode" == "any" || "$mode" == "send" || "$mode" == "agent" ]] && return 0 ;;
        shell*) [[ "$mode" == "any" || "$mode" == "send" || "$mode" == "run" ]] && return 0 ;;
        other*) [[ "$mode" == "any" ]] && return 0 ;;
    esac
    tk_pane_refuse "pane $target is '$state'; refusing to type into it"
    return 1
}

# ── the human's door (guardrail 6) ───────────────────────────────────

# tk_pane_session_of <target> - the session name for an attach command, without
# a tmux fork for the common session:window.pane form.
tk_pane_session_of() {
    local target="${1:-}" sess=""
    case "$target" in
        %*) sess="$(tk_tmux display-message -t "$target" -p '#{session_name}' 2>/dev/null || true)" ;;
        *:*) sess="${target%%:*}" ;;
        *) sess="$target" ;;
    esac
    printf '%s' "$sess"
}

# tk_pane_human_attach <target> - print how a human attaches to the pane the
# agent just wrote to. Printed after every function that types.
tk_pane_human_attach() {
    local target="${1:-}" sess
    sess="$(tk_pane_session_of "$target")"
    if [[ -n "$TK_SOCKET" ]]; then
        printf 'tk-pane: wrote to %s; human attach: tmux -L %s attach -t %s\n' "$target" "$TK_SOCKET" "$sess"
    else
        printf 'tk-pane: wrote to %s; human attach: tmux attach -t %s\n' "$target" "$sess"
    fi
}

# ── send / run / key ─────────────────────────────────────────────────

# tk_pane_send <target> <text> - type literal text into a pane, no Enter.
# Text is ONE argument and quoting is handled once, here: agents forget
# `send-keys -l --`, and the result of that is tmux interpreting $ and spaces
# as key names.
tk_pane_send() {
    local target="${1:-}" text="${2:-}"
    [[ -n "$target" ]] || { tk_pane_refuse "tk_pane_send: target required"; return 1; }
    [[ -n "$text" ]] || { tk_pane_refuse "tk_pane_send: text required"; return 1; }
    tk_pane_write_guard "$target" send || return 1
    tk_tmux send-keys -t "$target" -l -- "$text" 2>/dev/null || {
        tk_pane_refuse "send-keys failed on $target"
        return 1
    }
    tk_pane_human_attach "$target"
}

# tk_pane_run <target> <command...> - type a command and Enter into a shell
# pane. If the pane's shell is dead, a fresh shell is launched first
# (respawn-pane): typing a command into a dead pane loses the output, and a
# pane whose only process IS the command dies when the command errors. A shell
# survives both.
tk_pane_run() {
    local target="${1:-}"
    [[ -n "$target" ]] || { tk_pane_refuse "tk_pane_run: target required"; return 1; }
    shift
    [[ "$#" -gt 0 ]] || { tk_pane_refuse "tk_pane_run: command required"; return 1; }
    local command="$*"
    tk_pane_write_guard "$target" run || return 1

    local state
    state="$(tk_pane_proc "$target")"
    case "$state" in
        dead*)
            tk_tmux respawn-pane -t "$target" 2>/dev/null || {
                tk_pane_refuse "cannot respawn dead pane $target"
                return 1
            }
            ;;
    esac
    tk_tmux send-keys -t "$target" -l -- "$command" 2>/dev/null || {
        tk_pane_refuse "send-keys failed on $target"
        return 1
    }
    tk_tmux send-keys -t "$target" Enter 2>/dev/null || true
    tk_pane_human_attach "$target"
}

# tk_pane_key <target> <key> - one keystroke by name: Enter, C-c, C-d,
# Escape, ... Refuses only a dead pane: C-c is the rescue path, so keystrokes
# must work on any live process.
tk_pane_key() {
    local target="${1:-}" key="${2:-}"
    [[ -n "$target" ]] || { tk_pane_refuse "tk_pane_key: target required"; return 1; }
    [[ -n "$key" ]] || { tk_pane_refuse "tk_pane_key: key required (Enter, C-c, Escape, ...)"; return 1; }
    tk_pane_write_guard "$target" any || return 1
    tk_tmux send-keys -t "$target" "$key" 2>/dev/null || {
        tk_pane_refuse "send-keys failed on $target"
        return 1
    }
    tk_pane_human_attach "$target"
}

# ── read ─────────────────────────────────────────────────────────────

# tk_pane_read <target> [--tail <n>] [--since <cursor>] [--full]
#
# capture-pane wrapper. Default: the last TK_PANE_READ_LINES (200) lines of
# scrollback plus the visible screen, -J for wrapped lines. --full is the whole
# scrollback. --since <cursor> prints only the lines after the last line that
# contains <cursor> (a content cursor: pass the last line you consumed); if the
# cursor is not found, everything is printed, because dropping output on a
# mismatch is worse than repeating it.
#
# A successful read records @pane-read, which is what unlocks the typing
# functions (guardrail 2).
tk_pane_read() {
    local target="" tail="$TK_PANE_READ_LINES" since="" full=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --tail)  tail="${2:?tk_pane_read: --tail needs a line count}"; shift 2 ;;
            --since) since="${2:?tk_pane_read: --since needs a cursor}"; shift 2 ;;
            --full)  full=1; shift ;;
            *) if [[ -z "$target" ]]; then target="$1"; shift
               else tk_pane_refuse "tk_pane_read: unknown argument '$1'"; return 1; fi ;;
        esac
    done
    [[ -n "$target" ]] || { tk_pane_refuse "tk_pane_read: target required"; return 1; }

    local out
    if [[ "$full" -eq 1 ]]; then
        out="$(tk_pane_capture "$target")" || { tk_pane_refuse "cannot capture $target; pane missing?"; return 1; }
    else
        out="$(tk_pane_capture "$target" "$tail")" || { tk_pane_refuse "cannot capture $target; pane missing?"; return 1; }
    fi

    tk_pane_set "$target" read 1

    if [[ -n "$since" ]]; then
        local -a lines=()
        local line="" i last=-1
        while IFS= read -r line; do
            lines+=("$line")
        done <<< "$out"
        for ((i = 0; i < ${#lines[@]}; i++)); do
            [[ "${lines[$i]}" == *"$since"* ]] && last="$i"
        done
        for ((i = last + 1; i < ${#lines[@]}; i++)); do
            printf '%s\n' "${lines[$i]}"
        done
    else
        printf '%s\n' "$out"
    fi
}

# ── wait ─────────────────────────────────────────────────────────────

# tk_pane_wait <target> [--idle <secs>] [--text <regex>] [--timeout <secs>]
#
# The gap herdr's wait-output fills and this library had no answer for: a poll
# loop over capture-pane instead of a hand-rolled one in every consumer.
# --text matches with grep -E against the recent tail (two-phase: the current
# capture is checked first, so already-present output returns immediately) and
# prints the matching capture. --idle returns when the tail is unchanged across
# an <idle>-second gap. Either or both may be given. --timeout defaults to
# TK_PANE_WAIT_TIMEOUT (30s); the poll interval backs off 0.1 -> 0.2 -> 0.5s to
# keep fork pressure down on long waits.
tk_pane_wait() {
    local target="" idle="" text="" timeout="$TK_PANE_WAIT_TIMEOUT"
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --idle)    idle="${2:?tk_pane_wait: --idle needs seconds}"; shift 2 ;;
            --text)    text="${2:?tk_pane_wait: --text needs a regex}"; shift 2 ;;
            --timeout) timeout="${2:?tk_pane_wait: --timeout needs seconds}"; shift 2 ;;
            *) if [[ -z "$target" ]]; then target="$1"; shift
               else tk_pane_refuse "tk_pane_wait: unknown argument '$1'"; return 1; fi ;;
        esac
    done
    [[ -n "$target" ]] || { tk_pane_refuse "tk_pane_wait: target required"; return 1; }
    [[ -n "$idle" || -n "$text" ]] || { tk_pane_refuse "tk_pane_wait: need --text <regex> or --idle <secs>"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ ]] || { tk_pane_refuse "tk_pane_wait: timeout must be seconds, got '$timeout'"; return 1; }
    if [[ -n "$idle" ]]; then
        [[ "$idle" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { tk_pane_refuse "tk_pane_wait: idle must be seconds, got '$idle'"; return 1; }
    fi

    local start deadline now out out2 interval="0.1"
    start="$(tk_now)"
    deadline=$(( start + timeout ))
    while :; do
        out="$(tk_pane_capture "$target" "$TK_PANE_READ_LINES")" || {
            tk_pane_refuse "tk_pane_wait: pane $target vanished while waiting"
            return 1
        }
        if [[ -n "$text" ]] && printf '%s' "$out" | grep -Eq -- "$text"; then
            tk_pane_set "$target" read 1
            printf '%s\n' "$out"
            return 0
        fi
        if [[ -n "$idle" ]]; then
            sleep "$idle"
            out2="$(tk_pane_capture "$target" "$TK_PANE_READ_LINES")" || {
                tk_pane_refuse "tk_pane_wait: pane $target vanished while waiting"
                return 1
            }
            if [[ "$out" == "$out2" ]]; then
                tk_pane_set "$target" read 1
                return 0
            fi
        else
            sleep "$interval"
            case "$interval" in
                0.1) interval="0.2" ;;
                0.2) interval="0.5" ;;
            esac
        fi
        now="$(tk_now)"
        if [[ "$now" -ge "$deadline" ]]; then
            tk_pane_refuse "tk_pane_wait: timeout after ${timeout}s on $target (wanted${text:+ text '$text'}${idle:+ idle ${idle}s})"
            return 1
        fi
    done
}

# ── agent-aware layer ────────────────────────────────────────────────

# tk_agent_composer <target> - the firstmate composer verdict, read from the
# pane: empty|pending|unknown|dead. empty means the last line is a bare prompt
# (safe to type into); pending means text is already in the composer (typing
# more would clobber it); unknown is everything else, including a user who
# dropped to a shell in that pane. Reading the pane, not the harness, is the
# point: this must work for any agent with a prompt line.
tk_agent_composer() {
    local target="${1:-}" state
    [[ -n "$target" ]] || { printf 'unknown\n'; return 0; }
    state="$(tk_pane_proc "$target")"
    case "$state" in
        dead*)  printf 'dead\n'; return 0 ;;
        agent*) ;;
        *)      printf 'unknown\n'; return 0 ;;
    esac

    local out line last=""
    out="$(tk_pane_capture "$target" 5)" || { printf 'unknown\n'; return 0; }
    # Default IFS read trims the prompt's trailing spaces; empty rows are
    # skipped, so `last` is the last non-blank line of the recent tail.
    while read -r line; do
        [[ -n "$line" ]] && last="$line"
    done <<< "$out"
    case "$last" in
        '>'|'❯'|'»'|'$'|'#'|'%') printf 'empty\n' ;;
        '>'*|'❯'*|'»'*|'$'*|'#'*|'%'*) printf 'pending\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# tk_agent_prompt <target> <text> - type a prompt into an agent pane and stop.
# Checks liveness (the pane must actually run an agent), reads the composer
# state, and types only when the composer is proven empty. Never submits: no
# Enter, ever. A pending composer is refused rather than clobbered - firstmate's
# "failure over retry" rule - and the retry-Enter loop is a separate verb.
tk_agent_prompt() {
    local target="${1:-}" text="${2:-}" composer
    [[ -n "$target" ]] || { tk_pane_refuse "tk_agent_prompt: target required"; return 1; }
    [[ -n "$text" ]] || { tk_pane_refuse "tk_agent_prompt: prompt text required"; return 1; }
    tk_pane_write_guard "$target" agent || return 1

    composer="$(tk_agent_composer "$target")"
    case "$composer" in
        empty) ;;
        pending) tk_pane_refuse "agent composer has unsubmitted text (pending); refusing to type over it"; return 1 ;;
        *) tk_pane_refuse "agent composer is $composer; refusing to type"; return 1 ;;
    esac

    tk_tmux send-keys -t "$target" -l -- "$text" 2>/dev/null || {
        tk_pane_refuse "send-keys failed on $target"
        return 1
    }
    tk_pane_human_attach "$target"
}

# tk_agent_wait <target> [--idle <secs>] [--timeout <secs>] - wait for the
# agent to go idle: composer back at a bare prompt, and the tail unchanged
# across an <idle>-second gap (the second condition catches a spinner that the
# prompt check cannot see). A dead pane fails immediately rather than polling
# out the timeout.
tk_agent_wait() {
    local target="" idle="1" timeout="$TK_PANE_WAIT_TIMEOUT"
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --idle)    idle="${2:?tk_agent_wait: --idle needs seconds}"; shift 2 ;;
            --timeout) timeout="${2:?tk_agent_wait: --timeout needs seconds}"; shift 2 ;;
            *) if [[ -z "$target" ]]; then target="$1"; shift
               else tk_pane_refuse "tk_agent_wait: unknown argument '$1'"; return 1; fi ;;
        esac
    done
    [[ -n "$target" ]] || { tk_pane_refuse "tk_agent_wait: target required"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ ]] || { tk_pane_refuse "tk_agent_wait: timeout must be seconds, got '$timeout'"; return 1; }
    [[ "$idle" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { tk_pane_refuse "tk_agent_wait: idle must be seconds, got '$idle'"; return 1; }

    local start deadline now composer out out2 interval="0.2"
    start="$(tk_now)"
    deadline=$(( start + timeout ))
    while :; do
        composer="$(tk_agent_composer "$target")"
        case "$composer" in
            dead) tk_pane_refuse "tk_agent_wait: agent pane $target died while waiting"; return 1 ;;
        esac
        if [[ "$composer" == "empty" ]]; then
            out="$(tk_pane_capture "$target" "$TK_PANE_READ_LINES")" || true
            sleep "$idle"
            composer="$(tk_agent_composer "$target")"
            out2="$(tk_pane_capture "$target" "$TK_PANE_READ_LINES")" || true
            if [[ "$composer" == "empty" && "$out" == "$out2" ]]; then
                return 0
            fi
        else
            sleep "$interval"
        fi
        now="$(tk_now)"
        if [[ "$now" -ge "$deadline" ]]; then
            tk_pane_refuse "tk_agent_wait: timeout after ${timeout}s waiting for $target to go idle"
            return 1
        fi
    done
}
