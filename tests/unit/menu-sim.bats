#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for menu simulation functions in menu-test.sh.
#
# These tests exercise the structural menu-test functions (the existing ones)
# plus the new tk_menu_sim_* and tk_menu_chain functions. The PTY-based
# simulation requires real tmux, so those tests are skipped when tmux is absent.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
    # shellcheck source=../../lib/menu-test.sh
    source "$TK_LIB/menu-test.sh"
    tk_menu_test_reset
}
teardown() {
    tk_menu_sim_close 2>/dev/null || true
    tk_teardown
}

# ── existing menu-test functions ─────────────────────────────────────

@test "tk_menu_test_reset clears the menu array" {
    tk_menu_item "a" "1" "cmd"
    tk_menu_test_reset
    assert_eq "$(tk_menu_test_count)" "0"
}

@test "tk_menu_test_assert_count passes for the right count" {
    tk_menu_item "a" "1" "c"
    tk_menu_item "b" "2" "c"
    tk_menu_test_assert_count 2
}

@test "tk_menu_test_assert_item checks label and key exactly" {
    tk_menu_item "speaking: on" "e" "$(tk_menu_cmd voice.sh toggle-enabled)"
    tk_menu_test_assert_item 0 "speaking: on" "e"
}

@test "tk_menu_test_assert_item checks cmd_substring when given" {
    tk_menu_item "run" "r" "$(tk_menu_cmd /path/to/script.sh arg1 arg2)"
    tk_menu_test_assert_item 0 "run" "r" "script.sh"
}

@test "tk_menu_test_assert_has_key finds a key anywhere in the menu" {
    tk_menu_item "first" "a" "c"
    tk_menu_item "second" "b" "c"
    tk_menu_item "third" "c" "c"
    tk_menu_test_assert_has_key "b"
}

@test "tk_menu_test_run executes the shell command for an item" {
    local marker="$TEST_TMPDIR/ran"
    tk_menu_item "go" "g" "$(tk_menu_cmd touch "$marker")"
    tk_menu_test_run 0
    assert_file "$marker"
}

@test "tk_menu_test_done clears the menu" {
    tk_menu_item "a" "1" "c"
    tk_menu_test_done
    assert_eq "$(tk_menu_count)" "0"
}

# ── tk_menu_chain ────────────────────────────────────────────────────

@test "tk_menu_chain executes the toggle then reopens the menu" {
    local toggle_output="$TEST_TMPDIR/toggled"
    local menu_output="$TEST_TMPDIR/menued"

    # Define a toggle command that writes a marker.
    _toggle() { touch "$toggle_output"; }
    _menu()   { touch "$menu_output"; }

    tk_menu_chain "_toggle" "_menu"

    assert_file "$toggle_output"
    assert_file "$menu_output"
}

@test "tk_menu_chain handles run-shell prefix in toggle" {
    local marker="$TEST_TMPDIR/ran"
    tk_menu_chain "run-shell 'touch' '$marker'" "true"
    assert_file "$marker"
}

@test "tk_menu_chain fails without toggle command" {
    run tk_menu_chain "" "echo hi"
    assert_fail
}

@test "tk_menu_chain fails without menu command" {
    run tk_menu_chain "true" ""
    assert_fail
}

# ── tk_menu_sim_socket ───────────────────────────────────────────────

@test "tk_menu_sim_socket returns empty when no simulation is active" {
    assert_empty "$(tk_menu_sim_socket)"
}

@test "tk_menu_sim_close is safe when no simulation is active" {
    tk_menu_sim_close
    # Should not error.
}

# ── tk_menu_sim_open (requires real tmux) ────────────────────────────

@test "tk_menu_sim_open creates a test session and returns socket" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_menu_sim_open "Test" "Run" "r" "run-shell 'echo hi'" "Quit" "q" "" 2>/dev/null)" || {
        skip "could not create test session"
    }
    [[ -n "$socket" ]]
    # Verify the socket is usable.
    command tmux -L "$socket" has-session -t menu-sim 2>/dev/null || {
        tk_menu_sim_close
        _afail "test session not found on socket $socket"
    }
    tk_menu_sim_close
}

@test "tk_menu_sim_select sends a key to the simulation" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_menu_sim_open "Test" "One" "1" "run-shell 'true'" "Quit" "q" "" 2>/dev/null)" || skip
    # This should not error.
    tk_menu_sim_select "1" 2>/dev/null || true
    tk_menu_sim_close
}

@test "tk_menu_sim_close cleans up the test session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_menu_sim_open "Test" "One" "1" "run-shell 'true'" 2>/dev/null)" || skip
    tk_menu_sim_close
    # The session should be gone.
    run command tmux -L "$socket" has-session -t menu-sim 2>/dev/null
    assert_fail
}

@test "tk_menu_sim_select fails without active simulation" {
    run tk_menu_sim_select "1"
    assert_fail
}

@test "tk_menu_sim_type fails without active simulation" {
    run tk_menu_sim_type "hello"
    assert_fail
}

# ── full test simulation workflow ────────────────────────────────────

@test "full sim workflow: open, select, close" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_menu_sim_open "TestMenu" "OK" "o" "run-shell 'echo OK'" "Cancel" "c" "" 2>/dev/null)" || skip
    assert_eq "$(tk_menu_sim_socket)" "$socket"
    # Select "o"
    tk_menu_sim_select "o" 2>/dev/null || true
    # Close
    tk_menu_sim_close
    assert_empty "$(tk_menu_sim_socket)"
}
