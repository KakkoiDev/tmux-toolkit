# shellcheck shell=bash
# bug-report.sh — automatic bug report generation when a tk_* function fails.
#
# Captures context at the point of failure: environment, debug log tail,
# session/window/pane state, and a stack trace. Writes a markdown report
# so AIs can read and act on it without human explanation.
#
# Reports go to $TK_DIR/bugs/<timestamp>.md.
#
# Sourced from toolkit-ui.sh.  The crash handler trap is registered by
# tk_crash_handler and can be called from any script that wants automatic
# bug reports on `set -e` / ERR triggers.

# ── tunables ─────────────────────────────────────────────────────────

TK_BUG_DIR="${TK_BUG_DIR:-}"

tk_bug_dir() {
    if [[ -n "$TK_BUG_DIR" ]]; then
        printf '%s' "$TK_BUG_DIR"
    else
        printf '%s/bugs' "${TK_DIR:-${TMPDIR:-/tmp}}"
    fi
}

# ── internal helpers ─────────────────────────────────────────────────

# tk_bug_env — capture a minimal environment snapshot.
tk_bug_env() {
    printf '## Environment\n\n'
    printf -- '- **tmux version:** '
    tk_vers 2>/dev/null || printf 'unknown'
    printf '\n'
    printf -- '- **OS:** %s\n' "$(uname -a 2>/dev/null || printf unknown)"
    printf -- '- **bash version:** %s\n' "${BASH_VERSION:-unknown}"
    printf -- '- **toolkit version:** %s\n' "$(tk_lib_version 2>/dev/null || printf unknown)"
    printf -- '- **hostname:** %s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf -- '- **PID:** %s\n' "$$"

    # Session/window/pane state if inside tmux.
    if [[ -n "${TMUX:-}" || -n "${TMUX_PANE:-}" ]]; then
        printf '\n### tmux State\n\n'
        printf '```\n'
        printf 'session: %s\n' "$(tk_tmux display-message -p '#{session_name}' 2>/dev/null || true)"
        printf 'window:  %s\n' "$(tk_tmux display-message -p '#{window_index}' 2>/dev/null || true)"
        printf 'pane:    %s\n' "$(tk_tmux display-message -p '#{pane_index}' 2>/dev/null || true)"
        printf 'pane_id: %s\n' "${TMUX_PANE:-}"
        printf '```\n'
    fi
}

# tk_bug_stack — print a calling function chain (bash call stack).
tk_bug_stack() {
    printf '## Stack Trace\n\n'
    printf '```\n'
    local i
    # ${FUNCNAME[@]} and ${BASH_LINENO[@]} are available since bash 3.0.
    for ((i = 0; i < ${#FUNCNAME[@]}; i++)); do
        # Skip internal frames.
        [[ "${FUNCNAME[$i]}" == "tk_bug_stack" || \
           "${FUNCNAME[$i]}" == "tk_bug_report" || \
           "${FUNCNAME[$i]}" == "tk_crash_handler" ]] && continue
        if [[ "${FUNCNAME[$i]}" == "main" || "${FUNCNAME[$i]}" == "source" ]]; then
            break
        fi
        printf '  %s (line %s)\\n' "${FUNCNAME[$i]}" "${BASH_LINENO[$((i - 1 >= 0 ? i - 1 : 0))]:-?}"
    done
    printf '```\n'
}

# ── public API ───────────────────────────────────────────────────────

# tk_bug_report <fn> <detail> [intention]
#
# Writes a markdown bug report to $TK_DIR/bugs/<timestamp>.md.
# Captures:
#   - Function that failed
#   - What it was trying to do
#   - Environment (tmux version, OS, session/window/pane state)
#   - Last 20 debug log entries
#   - Suggested causes
#   - Stack trace (calling function chain)
tk_bug_report() {
    local fn="${1:-unknown}" detail="${2:-}" intention="${3:-}"
    local dir ts file
    dir="$(tk_bug_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    ts="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown')"
    file="$dir/$ts.md"

    {
        printf '# Bug Report: `%s`\n\n' "$fn"
        printf '**Timestamp:** %s\n\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || printf unknown)"

        printf '## Failure\n\n'
        printf -- '- **Function:** `%s`\n' "$fn"
        printf -- '- **Detail:** %s\n' "${detail:-none}"
        if [[ -n "$intention" ]]; then
            printf -- '- **Intention:** %s\n' "$intention"
        fi
        printf '\n'

        tk_bug_env
        printf '\n'

        # Last 20 debug log entries.
        printf '## Debug Log (last 20 entries)\n\n'
        printf '```json\n'
        tk_debug_tail 20
        printf '```\n\n'

        # Stack trace.
        tk_bug_stack
        printf '\n'

        # Suggested causes.
        printf '## Suggested Causes\n\n'
        printf '1. [TODO: AI analysis]\n'
        printf '2. [TODO: AI analysis]\n'
        printf '\n'

        # Resolution.
        printf '## Resolution\n\n'
        printf '[TODO: document the fix after applying it]\n'
    } >> "$file" 2>/dev/null

    printf '%s\n' "$file"
}

# ── crash handler ────────────────────────────────────────────────────

# tk_crash_handler — trap ERR to auto-generate bug reports on crashes.
#
# Usage:
#   trap tk_crash_handler ERR
#
# When a command fails under `set -e`, this generates a bug report with
# the last failed command and the call stack.
tk_crash_handler() {
    local line="$1" cmd="${2:-}"
    [[ -n "$cmd" ]] || cmd="(unknown)"

    # Determine the function name from the call stack.
    local fn="(toplevel)"
    if [[ ${#FUNCNAME[@]} -ge 2 ]]; then
        fn="${FUNCNAME[0]}"
        # Walk up to find the first tk_* or meaningful frame.
        local i
        for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
            case "${FUNCNAME[$i]}" in
                tk_*)
                    fn="${FUNCNAME[$i]}"
                    break
                    ;;
            esac
        done
    fi

    local report
    report="$(tk_bug_report "$fn" "command '$cmd' failed at line $line" "automatic crash handler")"
    tk_log error "crash: $fn — bug report written to $report"
    printf 'crash: bug report written to %s\n' "$report" >&2
}

# tk_crash_handler_install — install the ERR trap.
#
# Safe to call multiple times: only installs once.
# Returns the previous trap so the caller can chain it.
tk_crash_handler_install() {
    if [[ "${_TK_CRASH_HANDLER_SET:-0}" == "1" ]]; then
        return 0
    fi
    _TK_CRASH_HANDLER_SET=1
    local old_trap
    old_trap="$(trap -p ERR 2>/dev/null || true)"
    trap 'tk_crash_handler "$LINENO" "$BASH_COMMAND"' ERR
    # Save old trap text so tests can verify it was preserved.
    _TK_CRASH_OLD_TRAP="${old_trap}"
    return 0
}

# tk_crash_handler_remove — remove the ERR trap, restoring any previous.
tk_crash_handler_remove() {
    _TK_CRASH_HANDLER_SET=0
    if [[ -n "${_TK_CRASH_OLD_TRAP:-}" ]]; then
        eval "$_TK_CRASH_OLD_TRAP"
    else
        trap - ERR
    fi
    return 0
}
