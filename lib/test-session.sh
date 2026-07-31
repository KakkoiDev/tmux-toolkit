# shellcheck shell=bash
# test-session.sh — isolated tmux sessions for automated testing.
#
# Creates a detached tmux session on a private socket (tmux -L test-XXXX),
# completely headless. Menus opened here don't appear on the user's screen.
# The socket and session are cleaned up on shell exit via trap.
#
# Sourced from toolkit-ui.sh so tests that need real tmux can reach it.
#
# Usage:
#   socket=$(tk_test_session_start)
#   tk_test_exec "$socket" "echo hello"
#   tk_test_capture "$socket"   # prints pane content
#   tk_test_session_stop "$socket"

# ── private state ────────────────────────────────────────────────────

# Track sockets for cleanup.
TK_TEST_SOCKETS=""

# ── session lifecycle ────────────────────────────────────────────────

# tk_test_session_start [name] — start a detached test session.
#
# Prints the socket name (test-<timestamp>) on stdout. The session runs
# completely headless with -f /dev/null to avoid loading the developer's
# personal tmux config. The socket path includes the test tmpdir for
# automatic cleanup.
#
# A keepalive session on the same socket prevents the server from exiting
# when the test session is killed.
tk_test_session_start() {
    local name="${1:-test}"
    local socket timestamp
    timestamp="$(date +%s 2>/dev/null || printf '0')"
    socket="test-${timestamp}-$$-$RANDOM"

    # Create the session on a private socket.
    command tmux -f /dev/null -L "$socket" new-session -d -s "$name" -x 80 -y 24 2>/dev/null || {
        printf 'tk_test_session_start: failed to create session on socket %s\n' "$socket" >&2
        return 1
    }

    # A keepalive session keeps the server up if the test kills the main one.
    command tmux -L "$socket" new-session -d -s "tk-keepalive-${timestamp}" -x 80 -y 24 2>/dev/null || true

    # Track for cleanup.
    TK_TEST_SOCKETS="$TK_TEST_SOCKETS $socket"

    printf '%s\n' "$socket"
    return 0
}

# tk_test_session_stop <socket> — kill the server on this socket.
tk_test_session_stop() {
    local socket="${1:-}"
    [[ -n "$socket" ]] && command tmux -L "$socket" kill-server 2>/dev/null || true
    # Remove from tracked list.
    TK_TEST_SOCKETS="${TK_TEST_SOCKETS// $socket / }"
    TK_TEST_SOCKETS="${TK_TEST_SOCKETS// $socket/}"
    TK_TEST_SOCKETS="${TK_TEST_SOCKETS#[ ]}"
    TK_TEST_SOCKETS="${TK_TEST_SOCKETS%[ ]}"
    return 0
}

# tk_test_session_cleanup — kill all tracked test sessions.
# Called automatically via trap; also callable directly.
tk_test_session_cleanup() {
    local s
    for s in $TK_TEST_SOCKETS; do
        [[ -n "$s" ]] || continue
        command tmux -L "$s" kill-server 2>/dev/null || true
    done
    TK_TEST_SOCKETS=""
    return 0
}

# Register cleanup on shell exit.
if [[ -z "${_TK_TEST_TRAP_SET:-}" ]]; then
    _TK_TEST_TRAP_SET=1
    trap tk_test_session_cleanup EXIT
fi

# ── operations on test sessions ──────────────────────────────────────

# tk_test_exec <socket> <cmd> — run a shell command in the test session.
#
# Uses run-shell so the command runs inside tmux's environment.
# Returns tmux's exit status.
tk_test_exec() {
    local socket="${1:?tk_test_exec: socket required}"
    shift
    [[ "$#" -gt 0 ]] || { printf 'tk_test_exec: command required\n' >&2; return 1; }
    command tmux -L "$socket" run-shell "$*" 2>/dev/null
}

# tk_test_send_key <socket> <key> — send a key to the test session's active pane.
#
# Key names follow tmux conventions: Enter, Escape, C-c, etc.
# Text is sent literally via -l.
tk_test_send_key() {
    local socket="${1:?tk_test_send_key: socket required}" key="${2:-}"
    [[ -n "$key" ]] || { printf 'tk_test_send_key: key required\n' >&2; return 1; }
    # If key is a single printable character or looks like a key name, send it.
    # Use -l for literal text so spaces and $ are not interpreted.
    case "$key" in
        Enter|Escape|C-c|C-d|C-z|C-\\|Space|Tab|Up|Down|Left|Right|Home|End|PageUp|PageDown|BSpace|Delete|Insert|F[0-9]|F1[0-9]|KPEnter|KP0|KP1|KP2|KP3|KP4|KP5|KP6|KP7|KP8|KP9|IC|DC)
            command tmux -L "$socket" send-keys "$key" 2>/dev/null || true ;;
        *)
            command tmux -L "$socket" send-keys -l -- "$key" 2>/dev/null || true ;;
    esac
}

# tk_test_capture <socket> [target] — capture pane content.
#
# Captures the visible screen (no scrollback by default, matching the
# headless test convention where nothing scrolls).
tk_test_capture() {
    local socket="${1:?tk_test_capture: socket required}" target="${2:-}"
    local args=(-p -J)
    [[ -n "$target" ]] && args+=(-t "$target")
    command tmux -L "$socket" capture-pane "${args[@]}" 2>/dev/null || true
}

# tk_test_capture_full <socket> [target] — capture with full scrollback.
tk_test_capture_full() {
    local socket="${1:?tk_test_capture_full: socket required}" target="${2:-}"
    local args=(-p -J -S -)
    [[ -n "$target" ]] && args+=(-t "$target")
    command tmux -L "$socket" capture-pane "${args[@]}" 2>/dev/null || true
}

# tk_test_menu <socket> <title> <items...> — open a display-menu.
#
# Items are triples: "label" "key" "command". Pass them as three
# consecutive arguments per item. Separators: empty "" "" "".
#
# Example:
#   tk_test_menu "$sock" "Test" "Run" "r" "run-shell 'echo hi'" "Quit" "q" ""
tk_test_menu() {
    local socket="${1:?tk_test_menu: socket required}" title="${2:-}"
    shift 2
    local args=()
    [[ -n "$title" ]] && args+=(-T "$title")
    for a in "$@"; do args+=("$a"); done
    command tmux -L "$socket" display-menu "${args[@]}" 2>/dev/null || true
}

# tk_test_pane_count <socket> — number of panes in the test session.
tk_test_pane_count() {
    local socket="${1:?tk_test_pane_count: socket required}"
    command tmux -L "$socket" list-panes -a -F '1' 2>/dev/null | wc -l | tr -d ' '
}

# tk_test_session_exists <socket> <name> — true when a session exists.
tk_test_session_exists() {
    local socket="${1:?tk_test_session_exists: socket required}" name="${2:-}"
    [[ -n "$name" ]] || return 1
    command tmux -L "$socket" has-session -t "$name" 2>/dev/null
}
