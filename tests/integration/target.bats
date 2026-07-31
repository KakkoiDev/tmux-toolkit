#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2 for target.sh against a real tmux on a private socket: the dead-pane
# echo-back guard (D-6), liveness across windows and sessions, and the
# focus triple.

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
}
teardown() { tk_teardown_real; }

@test "tk_pane_target resolves a live pane to session:window.pane" {
    local target
    target="$(tk_pane_target "%0")"
    assert_match "$target" 'tk-main:[0-9]*\.[0-9]*'
    assert_eq "$target" "$(tk_tmux display-message -t "%0" -p "$TK_TARGET_FMT")"
}

@test "tk_pane_target returns empty for a killed pane, not the echo-back" {
    # D-6 gate, the regression this guard exists for: tmux echoes ":." for a
    # dead pane, and every plugin used to store that phantom as a target.
    local pane target
    pane="$(tk_tmux new-window -d -t tk-main -P -F '#{pane_id}' 'sleep 30')"
    target="$(tk_pane_target "$pane")"
    assert_match "$target" 'tk-main:[0-9]*\.[0-9]*'
    tk_tmux kill-pane -t "$pane"
    sleep 0.3
    assert_empty "$(tk_pane_target "$pane")"
}

@test "tk_pane_alive is true for a live pane and false for a dead one" {
    local pane
    pane="$(tk_tmux new-window -d -P -F '#{pane_id}' 'sleep 30')"
    tk_pane_alive "$pane"
    tk_tmux kill-pane -t "$pane"
    sleep 0.3
    refute tk_pane_alive "$pane"
}

@test "tk_pane_alive sees panes outside the current window" {
    # -a is the whole point: list-panes without it lists only the current
    # window, so the keepalive session's pane (never current here) would read
    # as dead. This fails on the pre-fix code.
    local keep
    keep="$(tk_tmux list-panes -t tk-keepalive -F '#{pane_id}' | head -1)"
    assert_not_empty "$keep"
    tk_pane_alive "$keep"
}

@test "tk_pane_alive is false for an empty pane id" {
    # D-6 gate: grep -qx "" exits 0, so the old shape reported empty as alive.
    refute tk_pane_alive ""
}

@test "tk_panes_alive aggregates across sessions" {
    local keep
    keep="$(tk_tmux list-panes -t tk-keepalive -F '#{pane_id}' | head -1)"
    tk_panes_alive "%0" "$keep"
}

@test "tk_goto actually selects the window and pane" {
    # switch-client is a no-op without an attached client (and must not
    # fail); the select-window/select-pane half is observable headless.
    local pane target
    pane="$(tk_tmux new-window -d -t tk-main -P -F '#{pane_id}' 'sleep 30')"
    target="$(tk_pane_target "$pane")"
    tk_goto "$target"
    assert_eq "$(tk_tmux display-message -t tk-main -p '#{window_index}')" \
        "$(tk_tmux display-message -t "$pane" -p '#{window_index}')"
    assert_eq "$(tk_tmux display-message -t tk-main -p '#{pane_index}')" \
        "$(tk_tmux display-message -t "$pane" -p '#{pane_index}')"
}
