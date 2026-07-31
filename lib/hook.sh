# shellcheck shell=bash
# hook.sh - tmux hook registration, validation and removal.
#
# Replaces mesh's hand-rolled guard, worktree's `set-hook -ag` and the
# tracker's `_add_focus_hook`, and fixes V5 for free: a bare `set-hook -g`
# REPLACES every handler on that hook, so on every plugin reload it silently
# deletes whatever the other plugins registered. Every add here is `-ga`
# (append) behind an existence guard, so a reload is a no-op instead of a
# clobber.
#
# tmux's floor matters in three places:
#   * An unknown hook name makes set-hook fail (which under `set -e` would
#     abort the rest of the plugin's load), and the only check that works is
#     the per-name `show-hooks -g <name>`: a bare `show-hooks -g` omits names
#     that are unset. Verified on 3.0 and 3.7b (finding V8).
#   * Hooks are array options since 3.0, so each entry has an index and
#     `set-hook -gu '<name>[<i>]'` removes exactly that one. Removal does not
#     renumber the survivors, so the indices read from show-hooks stay valid
#     while earlier ones are deleted.
#   * tmux renders a stored command double-quoted regardless of how it was
#     passed, so the duplicate guard compares quote-stripped text: grepping
#     for `run-shell '/a/b.sh'` against the rendered `run-shell "/a/b.sh"`
#     would miss and append a second copy on every reload.

# tk_hook_valid <name> - true when <name> is a real tmux hook event.
#
# The floor is 3.0 and an unknown name makes set-hook fail, so every add and
# remove validates first. `show-hooks -g <name>` returns 0 for a known name
# and 1 with "invalid option" for an unknown one.
tk_hook_valid() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    tk_tmux show-hooks -g "$name" >/dev/null 2>&1
}

# tk_hook_add <name> <cmd> - append a handler, idempotently.
#
# 1. Validates the name; an unknown hook returns 1 so the caller can decide
#    whether to abort (the tracker prints a warning and keeps loading).
# 2. Skips when a handler with the same command is already registered, so
#    re-sourcing the plugin never accumulates duplicates.
# 3. Appends with -ga, never -g, so other plugins' handlers on the same event
#    survive.
tk_hook_add() {
    local name="${1:-}" cmd="${2:-}"
    [[ -n "$name" && -n "$cmd" ]] || return 1
    tk_hook_valid "$name" || {
        printf '%s: %s is not a valid tmux hook on %s; skipping\n' \
            "${0##*/}" "$name" "$(tk_vers)" >&2
        return 1
    }
    # tmux displays commands double-quoted; strip quotes on both sides so the
    # guard works whether the caller used single or double quotes.
    local listing probe
    listing="$(tk_tmux show-hooks -g "$name" 2>/dev/null | tr -d "'\"" || true)"
    probe="$(printf '%s' "$cmd" | tr -d "'\"")"
    [[ -n "$probe" ]] || return 1
    if printf '%s' "$listing" | grep -qF "$probe"; then
        return 0
    fi
    tk_tmux set-hook -ga "$name" "$cmd" 2>/dev/null || true
}

# tk_hook_remove <name> <script-dir> - remove this plugin's handlers.
#
# Removes every handler on <name> whose command mentions <script-dir>. The
# directory is the discriminator: other plugins' handlers on the same event
# are left alone. Indices come from `show-hooks -g <name>` and are removed
# highest-first, so a removal never invalidates a later index even though
# tmux does not renumber.
#
# Returns 0 when nothing matched (idempotent teardown).
tk_hook_remove() {
    local name="${1:-}" dir="${2:-}"
    [[ -n "$name" && -n "$dir" ]] || return 1
    tk_hook_valid "$name" || return 1
    local idx indices
    indices="$(tk_tmux show-hooks -g "$name" 2>/dev/null \
        | grep -F "$dir" \
        | sed -n 's/^[^[]*\[\([0-9]*\)\].*/\1/p' || true)"
    [[ -n "$indices" ]] || return 0
    # shellcheck disable=SC2086
    for idx in $(printf '%s' "$indices" | sort -rn); do
        tk_tmux set-hook -gu "${name}[${idx}]" 2>/dev/null || true
    done
    return 0
}
