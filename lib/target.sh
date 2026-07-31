# shellcheck shell=bash
# target.sh - pane targets, liveness checks, and focus primitives.
#
# Three patterns that appear across every plugin:
#   1. The literal target format string `#{session_name}:#{window_index}.#{pane_index}`,
#      duplicated six times and already drifted once.
#   2. The `${t%%:*}` / `${t%.*}` parse for extracting session from a target,
#      hand-rolled in three places with three different quoting styles.
#   3. The `switch-client` / `select-window` / `select-pane` triple for focus,
#      copied four times with one copy missing `switch-client`.
#   4. `list-panes -a -F '#{pane_id}' | grep -qx` for liveness, which returns
#      the live pane id on stdout when the pane exists, and nothing when not,
#      but `grep -qx ""` exits 0 so an empty stored target always looks alive.
#
# This module also carries the dead-pane echo-back guard: tmux displays a blank
# target (":.0") when the stored target is dead, and without the guard every
# plugin stores that phantom. The echo-back guard is lifted from
# tmux-agent-mesh's cmd_dispatch, where it lived unreachable by the other four
# plugins.

# The canonical tmux pane target format. Six copies in the wild; one here.
TK_TARGET_FMT='#{session_name}:#{window_index}.#{pane_index}'

# ── target construction ──────────────────────────────────────────────

# tk_pane_target <pane_id> - the display-able <session>:<window>.<pane> target
# for a %N pane id. Guards against tmux's dead-pane echo-back: when the pane id
# is stale, tmux returns the literal string ":." followed by the default index,
# so the result is ":.\n%0" or similar. Every consumer's stored-target lookup
# must run through here.
tk_pane_target() {
    local pane_id="${1:-}"
    [[ -n "$pane_id" ]] || { printf '\n'; return 0; }
    local target
    target="$(tk_tmux display-message -t "$pane_id" -p "$TK_TARGET_FMT" 2>/dev/null || true)"
    # The echo-back guard: ":." signals a dead pane. Return empty.
    case "$target" in
        :.*) printf '\n'; return 0 ;;
        *)   printf '%s\n' "$target" ;;
    esac
}

# tk_target_split <target> - split a <session>:<window>.<pane> into its three
# components. Outputs session, window, and pane index on three lines. The window
# index includes the @ if present. For a target like "main:2.1", prints:
#   main
#   2
#   1
tk_target_split() {
    local t="${1:-}"
    [[ -n "$t" ]] || return 0
    # session: everything before the colon
    local sess="${t%%:*}"
    # pane: everything after the last dot
    local pane="${t##*.}"
    # window: everything after colon and before the last dot
    local rest="${t#*:}"
    local win="${rest%.*}"
    printf '%s\n' "$sess" "$win" "$pane"
}

# ── focus ────────────────────────────────────────────────────────────

# tk_goto <target> - focus a pane by target. The three-command sequence that
# four plugins hand-copied with one copy missing switch-client.
tk_goto() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 1
    tk_tmux switch-client -t "$target" 2>/dev/null || true
    tk_tmux select-window -t "$target" 2>/dev/null || true
    tk_tmux select-pane -t "$target" 2>/dev/null || true
}

# tk_goto_pane <pane_id> - focus a pane by its %N id.
tk_goto_pane() {
    local target
    target="$(tk_pane_target "${1:-}")"
    [[ -n "$target" ]] || return 1
    tk_goto "$target"
}

# ── liveness ─────────────────────────────────────────────────────────

# tk_pane_alive <pane_id> - true when the pane id references a current pane.
# Does NOT echo back to stdout, unlike `list-panes -f ... | grep -qx`.
# The empty-string case is explicitly false: grep -qx "" exits 0, so every
# plugin's stored-target check would report a missing pane as alive.
tk_pane_alive() {
    local pane_id="${1:-}"
    [[ -n "$pane_id" ]] || return 1
    tk_tmux list-panes -f "#{==:#{pane_id},$pane_id}" -F '1' 2>/dev/null | grep -q 1
}

# tk_panes_alive <pane_id>... - true when every named pane id is alive.
# Fails on the first dead one, no aggregation: the next layer always wants the
# dead one, not "there is a dead one somewhere".
tk_panes_alive() {
    local pid
    for pid in "$@"; do
        tk_pane_alive "$pid" || return 1
    done
}
