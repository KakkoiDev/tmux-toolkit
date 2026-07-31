#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for hook.sh against the recording tmux stub. The real-server behaviour
# (index removal, show-hooks output shape, -ga idempotence) is pinned in
# tests/integration/hook.bats; here the focus is the guard logic and the
# argv the functions emit.

load '../assert'

setup() {
    tk_setup
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() { tk_teardown; }

# ── tk_hook_valid ────────────────────────────────────────────────────

@test "tk_hook_valid accepts a known hook name" {
    tk_fixture 'show-hooks -g pane-exited' ''
    tk_hook_valid pane-exited
}

@test "tk_hook_valid rejects an unknown hook name" {
    # V8: show-hooks -g <name> returns 1 with "invalid option" for a bogus
    # name, and a bare show-hooks omits unset names, so this is the only
    # per-name validation that works.
    tk_fixture 'show-hooks -g bogus-hook' '' 1
    refute tk_hook_valid bogus-hook
}

@test "tk_hook_valid rejects an empty name" {
    refute tk_hook_valid ""
}

# ── tk_hook_add ──────────────────────────────────────────────────────

@test "tk_hook_add appends with -ga when the hook is free" {
    tk_fixture 'show-hooks -g pane-exited' 'pane-exited'
    tk_hook_add pane-exited "run-shell -b '/x/tracker.sh pane-focus #{pane_id}'"
    assert_called 'set-hook -ga pane-exited run-shell -b'
}

@test "tk_hook_add is a no-op when the command is already registered" {
    # The guard is what keeps -ga idempotent: an unconditional append adds
    # one duplicate per reload, and duplicates are invisible until something
    # runs twice.
    tk_fixture 'show-hooks -g pane-exited' 'pane-exited[0] run-shell -b "/x/tracker.sh pane-focus #{pane_id}"'
    tk_hook_add pane-exited "run-shell -b '/x/tracker.sh pane-focus #{pane_id}'"
    refute_called 'set-hook -ga'
}

@test "tk_hook_add matches despite tmux re-quoting the stored command" {
    # tmux renders stored commands double-quoted no matter how they were
    # passed, so the guard compares quote-stripped text. Without that,
    # grepping for `run-shell '/x/a'` against `run-shell "/x/a"` misses and
    # every reload appends a duplicate (the D-5 hazard).
    tk_fixture 'show-hooks -g pane-exited' 'pane-exited[0] run-shell "/x/a.sh"' 
    tk_hook_add pane-exited "run-shell '/x/a.sh'"
    refute_called 'set-hook -ga'
}

@test "tk_hook_add keeps another handler when adding a different command" {
    tk_fixture 'show-hooks -g pane-exited' 'pane-exited[0] run-shell "/x/other.sh"'
    tk_hook_add pane-exited "run-shell -b '/x/tracker.sh pane-focus #{pane_id}'"
    assert_called 'set-hook -ga pane-exited run-shell'
}

@test "tk_hook_add returns non-zero for a bogus hook name" {
    # D-5 gate: an invalid name must not be silently accepted (set-hook would
    # fail under set -e in the middle of a plugin load).
    tk_fixture 'show-hooks -g bogus-hook' '' 1
    run tk_hook_add bogus-hook "run-shell 'x'"
    assert_fail
    refute_called 'set-hook'
}

@test "tk_hook_add returns non-zero for an empty command" {
    run tk_hook_add pane-exited ""
    assert_fail
    refute_called 'set-hook'
}

# ── tk_hook_remove ───────────────────────────────────────────────────

@test "tk_hook_remove removes only the matching index" {
    tk_fixture 'show-hooks -g pane-exited' \
        'pane-exited[0] run-shell "/x/other.sh"
pane-exited[1] run-shell "/x/tracker.sh cleanup"'
    tk_hook_remove pane-exited "/x/tracker.sh"
    assert_called 'set-hook -gu pane-exited[1]'
    refute_called 'set-hook -gu pane-exited[0]'
}

@test "tk_hook_remove removes indices highest-first" {
    # tmux does not renumber survivors, so order is not strictly required,
    # but removing the highest index first is the defensive shape in case a
    # future tmux renumbers on removal.
    tk_fixture 'show-hooks -g pane-exited' \
        'pane-exited[1] run-shell "/x/t.sh a"
pane-exited[3] run-shell "/x/t.sh b"'
    tk_hook_remove pane-exited "/x/t.sh"
    local log
    log="$(tk_calls)"
    local first second
    first="$(printf '%s\n' "$log" | grep 'set-hook -gu' | head -1)"
    second="$(printf '%s\n' "$log" | grep 'set-hook -gu' | tail -1)"
    assert_contains "$first" 'pane-exited[3]'
    assert_contains "$second" 'pane-exited[1]'
}

@test "tk_hook_remove is a no-op when nothing matches the dir" {
    tk_fixture 'show-hooks -g pane-exited' 'pane-exited[0] run-shell "/x/other.sh"'
    tk_hook_remove pane-exited "/y/nothing-here"
    refute_called 'set-hook'
}

@test "tk_hook_remove returns non-zero for a bogus hook name" {
    tk_fixture 'show-hooks -g bogus-hook' '' 1
    run tk_hook_remove bogus-hook "/x"
    assert_fail
    refute_called 'set-hook'
}

@test "tk_hook_remove returns non-zero for an empty script dir" {
    run tk_hook_remove pane-exited ""
    assert_fail
}
