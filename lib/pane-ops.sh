# shellcheck shell=bash
# pane-ops.sh — pane, window, and session management primitives.
#
# Fills the gaps in what an AI agent can do with tmux: split, kill, rename,
# resize panes; create, kill, rename, list windows; create, rename, list,
# kill, and attach sessions. Each function is thin (1-3 tmux commands),
# follows the tk_tmux convention, and returns tmux's exit status.
#
# tk_*_silent variants swallow output and never fail — for use in hook
# contexts where a cosmetic operation must not abort the caller.
#
# Sourced from toolkit-ui.sh so interactive and agent paths both reach it.

# ── pane operations ──────────────────────────────────────────────────

# tk_pane_split [-h|-v] [target] [size]
#
# Split the current (or given) pane. -h horizontal (default), -v vertical.
# size is passed directly to split-window: use "-p 50" for percentage or
# "-l 20" for lines.
tk_pane_split() {
    local direction="-h" target="" size=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|-v) direction="$1"; shift ;;
            -*)    size="$1"; shift ;;
            *)     if [[ -z "$target" ]]; then target="$1"; shift
                   else size="$1"; shift; fi ;;
        esac
    done
    local args=()
    [[ -n "$target" ]] && args+=(-t "$target")
    args+=("$direction")
    [[ -n "$size" ]] && args+=("$size")
    tk_tmux split-window "${args[@]}"
}

# tk_pane_kill [target] — kill a pane.
tk_pane_kill() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        tk_tmux kill-pane -t "$target"
    else
        tk_tmux kill-pane
    fi
}

# tk_pane_kill_silent [target] — kill a pane, never failing.
tk_pane_kill_silent() {
    tk_pane_kill "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_pane_rename <target> <name> — set the pane title (select-pane -T).
tk_pane_rename() {
    local target="${1:?tk_pane_rename: target required}"
    local name="${2:?tk_pane_rename: name required}"
    tk_tmux select-pane -t "$target" -T "$name"
}

# tk_pane_rename_silent <target> <name>
tk_pane_rename_silent() {
    tk_pane_rename "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_pane_resize <target> <-U|-D|-L|-R> <size>
#
# Resize a pane by <size> rows/columns in the given direction.
tk_pane_resize() {
    local target="${1:?tk_pane_resize: target required}"
    local direction="${2:?tk_pane_resize: direction required (-U|-D|-L|-R)}"
    local size="${3:?tk_pane_resize: size required}"
    tk_tmux resize-pane -t "$target" "$direction" "$size"
}

# tk_pane_resize_silent <target> <-U|-D|-L|-R> <size>
tk_pane_resize_silent() {
    tk_pane_resize "$@" >/dev/null 2>&1 || true
    return 0
}

# ── window operations ────────────────────────────────────────────────

# tk_window_new [name] [cmd] — create a new window, optionally named and
# running a command.
tk_window_new() {
    local name="${1:-}" cmd="${2:-}"
    local args=()
    [[ -n "$name" ]] && args+=(-n "$name")
    if [[ -n "$cmd" ]]; then
        tk_tmux new-window "${args[@]}" -- "$cmd"
    else
        tk_tmux new-window "${args[@]}"
    fi
}

# tk_window_new_silent [name] [cmd]
tk_window_new_silent() {
    tk_window_new "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_window_kill [target] — kill a window.
tk_window_kill() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        tk_tmux kill-window -t "$target"
    else
        tk_tmux kill-window
    fi
}

# tk_window_kill_silent [target]
tk_window_kill_silent() {
    tk_window_kill "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_window_rename <target> <name> — rename a window.
tk_window_rename() {
    local target="${1:?tk_window_rename: target required}"
    local name="${2:?tk_window_rename: name required}"
    tk_tmux rename-window -t "$target" "$name"
}

# tk_window_rename_silent <target> <name>
tk_window_rename_silent() {
    tk_window_rename "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_window_list — list windows in the current session, one per line.
#
# Format: <window_index>\x1f<window_name>\x1f<window_flags>\x1f<window_active>
# \x1f (unit separator) is the delimiter because a window name can contain
# any printable character.
tk_window_list() {
    local sep
    sep="$(printf '\037')"
    tk_tmux list-windows -F "#{window_index}${sep}#{window_name}${sep}#{window_flags}${sep}#{window_active}" 2>/dev/null || true
}

# tk_window_find <name> — print the window index for a named window, or
# empty if not found.
tk_window_find() {
    local name="${1:?tk_window_find: window name required}"
    tk_tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null \
        | grep -E " ${name}$" 2>/dev/null \
        | head -1 \
        | cut -d' ' -f1 \
        || true
}

# ── session operations ───────────────────────────────────────────────

# tk_session_new <name> [cmd] — create a detached named session,
# optionally running a command.
tk_session_new() {
    local name="${1:?tk_session_new: session name required}"
    local cmd="${2:-}"
    if [[ -n "$cmd" ]]; then
        tk_tmux new-session -d -s "$name" -- "$cmd"
    else
        tk_tmux new-session -d -s "$name"
    fi
}

# tk_session_new_silent <name> [cmd]
tk_session_new_silent() {
    tk_session_new "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_session_rename <old> <new> — rename a session.
tk_session_rename() {
    local old="${1:?tk_session_rename: old name required}"
    local new="${2:?tk_session_rename: new name required}"
    tk_tmux rename-session -t "$old" "$new"
}

# tk_session_rename_silent <old> <new>
tk_session_rename_silent() {
    tk_session_rename "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_session_list — list all sessions, one per line.
#
# Format: <session_name>\x1f<session_windows>\x1f<session_attached>
tk_session_list() {
    local sep
    sep="$(printf '\037')"
    tk_tmux list-sessions -F "#{session_name}${sep}#{session_windows}${sep}#{session_attached}" 2>/dev/null || true
}

# tk_session_kill <name> — kill a named session.
tk_session_kill() {
    local name="${1:?tk_session_kill: session name required}"
    tk_tmux kill-session -t "$name"
}

# tk_session_kill_silent <name>
tk_session_kill_silent() {
    tk_session_kill "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_session_attach <name> — print the command a human runs to attach.
#
# Respects TK_SOCKET so the printed command connects to the right server.
tk_session_attach() {
    local name="${1:?tk_session_attach: session name required}"
    if [[ -n "${TK_SOCKET:-}" ]]; then
        printf 'tmux -L %s attach -t %s\n' "$TK_SOCKET" "$name"
    else
        printf 'tmux attach -t %s\n' "$name"
    fi
}

# tk_session_exists <name> — true when a session with this name exists.
tk_session_exists() {
    local name="${1:?tk_session_exists: session name required}"
    tk_tmux has-session -t "$name" 2>/dev/null
}
