#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2 for hook.sh against a real tmux on a private socket. Everything here is
# tmux's own hook behaviour: per-name validation (V8), append-with-guard
# idempotence (V5), and index-aware removal.

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
}
teardown() { tk_teardown_real; }

@test "tk_hook_valid accepts a real hook and rejects a bogus one" {
    tk_hook_valid pane-exited
    refute tk_hook_valid bogus-hook
}

@test "tk_hook_add registers once and a second call adds no duplicate" {
    # D-5 gate: re-sourcing a plugin calls add again; the existence guard
    # must make that a no-op, not an accumulation.
    tk_hook_add pane-exited "run-shell 'echo tk-hook-focus'"
    tk_hook_add pane-exited "run-shell 'echo tk-hook-focus'"
    local n
    n="$(tk_tmux show-hooks -g pane-exited | grep -c 'echo tk-hook-focus' || true)"
    assert_eq "$n" "1"
}

@test "tk_hook_add leaves a decoy handler on the same event alone" {
    # The D-5 verify: a plugin adding its handler must not clobber another
    # plugin's (or the user's) handler on the same event.
    tk_tmux set-hook -ga pane-exited "run-shell 'echo decoy'"
    tk_hook_add pane-exited "run-shell 'echo tk-hook-focus'"
    local listing
    listing="$(tk_tmux show-hooks -g pane-exited)"
    assert_contains "$listing" 'echo decoy'
    assert_contains "$listing" 'echo tk-hook-focus'
}

@test "tk_hook_add returns non-zero for a bogus hook name" {
    run tk_hook_add bogus-hook "run-shell 'echo x'"
    assert_fail
}

@test "tk_hook_add still works after the command's quoting differs" {
    # tmux re-renders the stored command double-quoted; the quote-stripped
    # guard must recognise a re-install that used single quotes.
    tk_hook_add pane-exited "run-shell '/x/tk-hook focus'"
    tk_hook_add pane-exited "run-shell \"/x/tk-hook focus\""
    local n
    n="$(tk_tmux show-hooks -g pane-exited | grep -c '/x/tk-hook focus' || true)"
    assert_eq "$n" "1"
}

@test "tk_hook_remove removes only the matching script dir" {
    tk_tmux set-hook -ga pane-exited "run-shell '/x/mine.sh cleanup'"
    tk_tmux set-hook -ga pane-exited "run-shell '/y/theirs.sh cleanup'"
    tk_hook_remove pane-exited "/x/mine.sh"
    local listing
    listing="$(tk_tmux show-hooks -g pane-exited)"
    refute_contains "$listing" '/x/mine.sh'
    assert_contains "$listing" '/y/theirs.sh'
}

@test "tk_hook_remove is idempotent and survives a full add/remove cycle" {
    # The D-5 migration shape: remove the stale handler, then add the fresh
    # one, and the result holds exactly one of ours.
    tk_hook_remove pane-exited "/x/mine.sh"
    tk_hook_add pane-exited "run-shell '/x/mine.sh cleanup'"
    tk_hook_remove pane-exited "/x/mine.sh"
    tk_hook_add pane-exited "run-shell '/x/mine.sh cleanup'"
    local n
    n="$(tk_tmux show-hooks -g pane-exited | grep -c '/x/mine.sh' || true)"
    assert_eq "$n" "1"
}
