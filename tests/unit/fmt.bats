#!/usr/bin/env bats
# shellcheck shell=bats
#
# Unit tests for fmt.sh - format helpers, #{q:} quoting, and pane search.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/fmt.sh
    source "$TK_LIB/fmt.sh"
}
teardown() { tk_teardown; }

# ── tk_fmt ───────────────────────────────────────────────────────────

@test "tk_fmt returns a value from a real option" {
    tk_fixture "display-message -t %0 -p #{pane_id}" "999"
    local r
    r="$(tk_fmt "%0" "#{pane_id}")"
    assert_eq "$r" "999"
}

@test "tk_fmt returns empty for an empty target" {
    local r
    r="$(tk_fmt "" "#{pane_id}")"
    assert_empty "$r"
}

@test "tk_fmt returns empty for an empty format" {
    local r
    r="$(tk_fmt "%0" "")"
    assert_empty "$r"
}

@test "tk_fmt passes through multi-word format strings" {
    tk_fixture "display-message -t %0 -p #{session_name}:#{window_index}.#{pane_index}" "main:2.1"
    local r
    r="$(tk_fmt "%0" "#{session_name}:#{window_index}.#{pane_index}")"
    assert_eq "$r" "main:2.1"
}

# ── tk_fmt_fields ────────────────────────────────────────────────────

@test "tk_fmt_fields returns one field" {
    tk_fixture "display-message -t %0 -p #{pane_id}" "42"
    local r
    r="$(tk_fmt_fields "%0" $'\x1f' pane_id)"
    assert_eq "$r" "42"
}

@test "tk_fmt_fields returns two fields separated by a custom delimiter" {
    tk_fixture "display-message -t %0 -p #{pane_id}::#{pane_tty}" "42::/dev/ttys001"
    local r
    r="$(tk_fmt_fields "%0" "::" pane_id pane_tty)"
    assert_eq "$r" "42::/dev/ttys001"
}

@test "tk_fmt_fields preserves an empty trailing field" {
    # Use a safe separator (colon) that won't collide with the stub record format.
    tk_fixture "display-message -t %0 -p #{pane_id}:#{pane_tty}" "42:"
    local r
    r="$(tk_fmt_fields "%0" ":" pane_id pane_tty)"
    # The second field (pane_tty) is empty, so the output is "42:" with nothing after the colon.
    assert_eq "$r" "42:"
}

@test "tk_fmt_fields returns empty for an empty target" {
    local r
    r="$(tk_fmt_fields "" ":" pane_id pane_tty)"
    assert_empty "$r"
}

@test "tk_fmt_fields returns empty with no fields" {
    local r
    r="$(tk_fmt_fields "%0" ":")"
    assert_empty "$r"
}

@test "tk_fmt_fields costs one fork for N fields" {
    tk_fixture "*display-message*" ""
    tk_fmt_fields "%0" "|" pane_id pane_tty pane_current_command session_name >/dev/null
    assert_call_count "display-message" 1
}

# ── tk_q ─────────────────────────────────────────────────────────────

@test "tk_q quotes a plain string with single quotes" {
    tk_fixture "set-option -g @tk_q_*" ""
    local r
    r="$(tk_q "hello")"
    assert_eq "$r" "'hello'"
}

@test "tk_q quotes a string containing a space" {
    tk_fixture "set-option -g @tk_q_*" ""
    local r
    r="$(tk_q "hello world")"
    assert_contains "$r" "hello world"
}

@test "tk_q quotes a string containing a single quote" {
    tk_fixture "set-option -g @tk_q_*" ""
    local r
    r="$(tk_q "it's")"
    # Should produce something shell-safe. The exact form depends on whether
    # tmux or the bash fallback handles it.
    # Verify it round-trips through eval.
    local eval_result
    eval_result="$(eval "printf '%s' $r")"
    assert_eq "$eval_result" "it's"
}

@test "tk_q quotes an empty string" {
    local r
    r="$(tk_q "")"
    # Must be a valid empty shell token. Two single quotes '' or similar.
    assert_eq "$r" "''"
}

@test "tk_q result round-trips through shell evaluation" {
    # When the fixture returns a specific result for set-option + display-message.
    # tk_q first calls set-option, then display-message to get #{q:}.
    # We need two fixtures: one for the set, one for display-message.
    tk_fixture "set-option -g @tk_q_*" ""
    tk_fixture "display-message -p #*@tk_q_*" "'hello world'"
    local r
    r="$(tk_q "hello world")"
    local eval_result
    eval_result="$(eval "printf '%s' $r")"
    assert_eq "$eval_result" "hello world"
}

@test "tk_q result round-trips a value containing a dollar sign" {
    tk_fixture "set-option -g @tk_q_*" ""
    tk_fixture "display-message -p #*@tk_q_*" "'\$HOME'"
    local r
    r="$(tk_q '$HOME')"
    # It must not expand $HOME when eval'd.
    local eval_result
    eval_result="$(eval "printf '%s' $r")"
    assert_eq "$eval_result" '$HOME'
}

@test "tk_q falls back to bash quoting when set-option fails" {
    tk_fixture "set-option -g *" "" 1
    local r
    r="$(tk_q "hello world")"
    local eval_result
    eval_result="$(eval "printf '%s' $r")"
    assert_eq "$eval_result" "hello world"
}

@test "tk_q falls back to bash quoting when display-message returns empty" {
    tk_fixture "set-option -g @tk_q_*" ""
    tk_fixture "display-message -p #*@tk_q_*" "" 0
    local r
    r="$(tk_q "hello world")"
    local eval_result
    eval_result="$(eval "printf '%s' $r")"
    assert_eq "$eval_result" "hello world"
}

# ── tk_pane_search ───────────────────────────────────────────────────

@test "tk_pane_search returns true when the pattern is found" {
    tk_fixture "display-message -t %0 -p #{C/r:needle}" "1"
    tk_pane_search "%0" "needle"
    assert_ok
}

@test "tk_pane_search returns false when the pattern is not found" {
    tk_fixture "display-message -t %0 -p #{C/r:needle}" "0"
    run tk_pane_search "%0" "needle"
    assert_fail
}

@test "tk_pane_search returns false for an empty target" {
    run tk_pane_search "" "needle"
    assert_fail
}

@test "tk_pane_search returns false for an empty pattern" {
    run tk_pane_search "%0" ""
    assert_fail
}

@test "tk_pane_search escapes nothing in a simple literal" {
    tk_fixture "display-message -t %0 -p #{C/r:hello}" "1"
    tk_pane_search "%0" "hello"
    assert_ok
}
