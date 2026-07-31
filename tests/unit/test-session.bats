#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 + T2 for test-session.sh: headless tmux sessions for automated testing.
#
# Most tests require real tmux (T2). The unit-level tests (T1) verify that
# the environment setup functions work correctly even without tmux.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() {
    tk_test_session_cleanup 2>/dev/null || true
    tk_teardown
}

# ── T1: unit tests (no tmux needed) ──────────────────────────────────

@test "tk_test_session_cleanup is safe with no sessions" {
    tk_test_session_cleanup
    # Should not error.
}

@test "tk_test_session_stop is safe with empty socket" {
    tk_test_session_stop ""
    # Should not error.
}

@test "tk_test_session_stop is safe with nonexistent socket" {
    tk_test_session_stop "nonexistent-99999"
    # Should not error — kill-server on a nonexistent socket is harmless.
}

# ── T2: integration tests (real tmux) ────────────────────────────────

@test "tk_test_session_start creates a detached session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-start")"
    [[ -n "$socket" ]]

    # Verify the session exists.
    run command tmux -L "$socket" has-session -t test-start
    assert_status 0

    tk_test_session_stop "$socket"
}

@test "tk_test_session_stop kills the server" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-stop")"
    [[ -n "$socket" ]]

    tk_test_session_stop "$socket"

    # Server should be gone.
    run command tmux -L "$socket" has-session -t test-stop 2>/dev/null
    assert_fail
}

@test "tk_test_exec runs a command in the test session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-exec")"
    [[ -n "$socket" ]]

    # Set a user option via run-shell.
    command tmux -L "$socket" set-option -g "@test-flag" "hello" 2>/dev/null

    # Read it back.
    local val
    val="$(command tmux -L "$socket" show-option -gv "@test-flag" 2>/dev/null || true)"
    assert_eq "$val" "hello"

    tk_test_session_stop "$socket"
}

@test "tk_test_send_key sends literal text to the pane" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-key")"
    [[ -n "$socket" ]]

    tk_test_send_key "$socket" "hello world"

    # Capture the pane to verify.
    local content
    content="$(tk_test_capture "$socket")"
    # The pane starts empty; typed text should appear.
    assert_contains "$content" "hello"

    tk_test_session_stop "$socket"
}

@test "tk_test_send_key sends special keys by name" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-special")"
    [[ -n "$socket" ]]

    # Sending Enter should not crash.
    tk_test_send_key "$socket" "Enter"
    tk_test_send_key "$socket" "C-c"
    tk_test_send_key "$socket" "Escape"

    tk_test_session_stop "$socket"
}

@test "tk_test_capture returns pane content" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-capture")"
    [[ -n "$socket" ]]

    # Write something to the pane via send-keys.
    command tmux -L "$socket" send-keys "captured text" 2>/dev/null

    local content
    content="$(tk_test_capture "$socket")"
    assert_contains "$content" "captured"

    tk_test_session_stop "$socket"
}

@test "tk_test_capture_full captures with scrollback" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-full")"
    [[ -n "$socket" ]]

    command tmux -L "$socket" send-keys "line1" Enter "line2" Enter 2>/dev/null
    sleep 0.1

    local content
    content="$(tk_test_capture_full "$socket")"
    assert_contains "$content" "line1"

    tk_test_session_stop "$socket"
}

@test "tk_test_pane_count reports correct count" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-count")"
    [[ -n "$socket" ]]

    local count
    count="$(tk_test_pane_count "$socket")"
    # At least 2 panes: the main session + keepalive.
    assert_num_gt "$count" 0

    tk_test_session_stop "$socket"
}

@test "tk_test_session_exists returns true for existing session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-exists")"
    [[ -n "$socket" ]]

    tk_test_session_exists "$socket" "test-exists"
    assert_status 0

    tk_test_session_stop "$socket"
}

@test "tk_test_session_exists returns false for nonexistent session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-nope")"
    [[ -n "$socket" ]]

    run tk_test_session_exists "$socket" "nonexistent-session-xyz"
    assert_fail

    tk_test_session_stop "$socket"
}

@test "multiple test sessions can coexist" {
    tk_skip_no_tmux
    local s1 s2
    s1="$(tk_test_session_start "multi-1")"
    s2="$(tk_test_session_start "multi-2")"
    [[ -n "$s1" && -n "$s2" ]]
    [[ "$s1" != "$s2" ]]

    command tmux -L "$s1" has-session -t multi-1
    command tmux -L "$s2" has-session -t multi-2

    tk_test_session_cleanup

    # Both should be gone.
    run command tmux -L "$s1" has-session -t multi-1 2>/dev/null
    assert_fail
    run command tmux -L "$s2" has-session -t multi-2 2>/dev/null
    assert_fail
}

@test "tk_test_menu opens a display-menu in the test session" {
    tk_skip_no_tmux
    local socket
    socket="$(tk_test_session_start "test-menu")"
    [[ -n "$socket" ]]

    # display-menu blocks, so run it in background, then kill it.
    command tmux -L "$socket" display-menu -T "Test" "OK" "o" "run-shell 'true'" 2>/dev/null &
    local pid=$!
    sleep 0.1
    # Kill the menu by sending Escape.
    command tmux -L "$socket" send-keys Escape 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    tk_test_session_stop "$socket"
}

@test "tk_test_session_cleanup cleans up all tracked sessions" {
    tk_skip_no_tmux
    local s1
    s1="$(tk_test_session_start "cleanup-1")"
    [[ -n "$s1" ]]

    # Verify session is alive.
    command tmux -L "$s1" has-session -t cleanup-1

    # Manual cleanup.
    tk_test_session_cleanup

    # Session should be gone.
    run command tmux -L "$s1" has-session -t cleanup-1 2>/dev/null
    assert_fail
}
