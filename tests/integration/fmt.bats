#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2 for fmt.sh against a real tmux on a private socket: the display-message
# round trips, #{q:} quoting, and the #{C/r:} server-side pane search (3.1+).

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
}
teardown() { tk_teardown_real; }

@test "tk_fmt round-trips a real pane field" {
    local want got
    want="$(tk_tmux display-message -t "%0" -p '#{pane_id}')"
    got="$(tk_fmt "%0" "#{pane_id}")"
    assert_eq "$got" "$want"
}

@test "tk_fmt_fields reads several fields in one round trip" {
    local sep want got
    sep="$(printf '\x1f')"
    want="$(tk_tmux display-message -t "%0" -p "#{pane_id}${sep}#{session_name}")"
    got="$(tk_fmt_fields "%0" $'\x1f' pane_id session_name)"
    assert_eq "$got" "$want"
}

@test "tk_q produces a sh-safe quoting that eval round-trips" {
    # The D-18 shape: values at generated-command boundaries (repo paths,
    # branch names) containing a space, a quote and a dollar must survive
    # both tmux's parse and the shell's.
    local v="it's a \$value with spaces"
    local quoted result
    quoted="$(tk_q "$v")"
    result="$(eval "printf '%s' $quoted")"
    assert_eq "$result" "$v"
}

@test "tk_q quotes an empty string to a valid empty token" {
    assert_eq "$(tk_q "")" "''"
}

@test "tk_pane_search finds pane content server-side (3.1+)" {
    tk_vers_ge 3.1 || skip "pane search needs tmux 3.1+"
    local pane
    pane="$(tk_tmux new-window -d -P -F '#{pane_id}' "printf 'unique-marker-98765'; sleep 30")"
    sleep 0.5
    tk_pane_search "$pane" 'unique-marker-98765'
    refute tk_pane_search "$pane" 'nonexistent-zzz-marker'
}
