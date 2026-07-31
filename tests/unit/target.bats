#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

# ── TK_TARGET_FMT ────────────────────────────────────────────────────

@test "TK_TARGET_FMT is the canonical pane target format" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    assert_contains "$TK_TARGET_FMT" "session_name"
    assert_contains "$TK_TARGET_FMT" "window_index"
    assert_contains "$TK_TARGET_FMT" "pane_index"
}

# ── tk_pane_target ───────────────────────────────────────────────────

@test "tk_pane_target resolves a live pane id to a target string" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'display-message -t %4 -p *' 'mysession:2.1'
    assert_eq "$(tk_pane_target "%4")" "mysession:2.1"
}

@test "tk_pane_target returns empty when tmux echoes back the dead-pane sentinel" {
    # The echo-back guard: tmux returns ":." for a dead pane.
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'display-message -t %9 -p *' ':.0'
    assert_empty "$(tk_pane_target "%9")"
}

@test "tk_pane_target returns empty for an empty input" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    assert_empty "$(tk_pane_target "")"
}

@test "tk_pane_target returns empty when tmux fails" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'display-message -t %99 -p *' '' 1
    assert_empty "$(tk_pane_target "%99")"
}

# ── tk_target_split ──────────────────────────────────────────────────

@test "tk_target_split decomposes a standard target" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    local result
    result="$(tk_target_split "main:2.1")"
    assert_eq "$(printf '%s\n' "$result" | head -1)" "main"
    assert_eq "$(printf '%s\n' "$result" | head -2 | tail -1)" "2"
    assert_eq "$(printf '%s\n' "$result" | tail -1)" "1"
}

@test "tk_target_split handles a target with an @ window" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    local result
    result="$(tk_target_split "dev:@42.3")"
    assert_eq "$(printf '%s\n' "$result" | head -1)" "dev"
    assert_eq "$(printf '%s\n' "$result" | head -2 | tail -1)" "@42"
    assert_eq "$(printf '%s\n' "$result" | tail -1)" "3"
}

@test "tk_target_split handles empty input gracefully" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    assert_empty "$(tk_target_split "")"
}

# ── tk_goto ──────────────────────────────────────────────────────────

@test "tk_goto issues the three-command focus sequence" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_goto "main:2.1" || true
    assert_called 'switch-client -t main:2.1'
    assert_called 'select-window -t main:2.1'
    assert_called 'select-pane -t main:2.1'
}

@test "tk_goto does not fail when switch-client fails (unattached)" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'switch-client*' '' 1
    tk_goto "main:2.1"
}

@test "tk_goto returns 1 for an empty target" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    refute tk_goto ""
}

# ── tk_goto_pane ─────────────────────────────────────────────────────

@test "tk_goto_pane resolves a pane id and focuses it" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'display-message -t %4 -p *' 'mysession:2.1'
    tk_goto_pane "%4" || true
    assert_called 'switch-client -t mysession:2.1'
}

@test "tk_goto_pane returns 1 when the pane is dead" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture 'display-message -t %9 -p *' ':.0'
    refute tk_goto_pane "%9"
}

# ── tk_pane_alive ────────────────────────────────────────────────────

@test "tk_pane_alive is true for a live pane" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture '-V' 'tmux 3.7b'
    tk_fixture 'list-panes -a -f *' '1'
    tk_pane_alive "%4"
}

@test "tk_pane_alive is false for a dead pane" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture '-V' 'tmux 3.7b'
    tk_fixture 'list-panes -a -f *' ''
    refute tk_pane_alive "%99"
}

@test "tk_pane_alive falls back to the grep shape below tmux 3.2" {
    # -f for list-panes arrived in 3.2; on the 3.0/3.1 floor the check uses
    # the list-panes -a -F | grep -qx shape this module replaces.
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture '-V' 'tmux 3.0a'
    tk_fixture 'list-panes -a -F *' '%0
%4'
    tk_pane_alive "%4"
    tk_fixture '-V' 'tmux 3.0a'
    tk_fixture 'list-panes -a -F *' '%0'
    refute tk_pane_alive "%99"
}

@test "tk_pane_alive is false for an empty pane id (unlike grep -qx '')" {
    # This is the bug: grep -qx "" exits 0, so every stored-target check
    # that parses `list-panes | grep -qx` reports empty as alive.
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    refute tk_pane_alive ""
}

# ── tk_panes_alive ───────────────────────────────────────────────────

@test "tk_panes_alive is true when every pane is alive" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture '-V' 'tmux 3.7b'
    tk_fixture 'list-panes -a -f *' '1'
    tk_panes_alive "%1" "%4"
}

@test "tk_panes_alive fails on the first dead pane" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_fixture '-V' 'tmux 3.7b'
    # First call returns 1 (alive), second returns empty (dead)
    tk_fixture 'list-panes -a -f #{==:#{pane_id},%1}*' '1'
    tk_fixture 'list-panes -a -f #{==:#{pane_id},%99}*' ''
    refute tk_panes_alive "%1" "%99"
}

@test "tk_panes_alive is true with no arguments" {
    # shellcheck source=../../lib/target.sh
    source "$TK_LIB/target.sh"
    tk_panes_alive
}
