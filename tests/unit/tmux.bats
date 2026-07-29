#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

@test "tk_tmux passes arguments through" {
    tk_tmux display-message -p '#{pane_id}'
    assert_called 'display-message -p #{pane_id}'
}

@test "tk_tmux injects -L when TK_SOCKET is set" {
    # This replaces the `if [ -n "$TMUX_SOCKET" ]` fork that tmux-worktree
    # hand-copied at ten call sites.
    TK_SOCKET="my-sock"
    tk_tmux list-panes
    assert_called '-L my-sock list-panes'
}

@test "tk_tmux omits -L when TK_SOCKET is empty" {
    tk_tmux list-panes
    refute_called '-L'
}

@test "tk_tmux is a no-op returning success when disabled" {
    # tmux-agent-tracker's sandbox mode: no tmux server exists, and every call
    # must succeed silently rather than fail a harness hook.
    TK_TMUX_DISABLED=1
    tk_tmux kill-server
    assert_empty "$(tk_calls)"
}

@test "a disabled tk_tmux yields empty in a command substitution" {
    TK_TMUX_DISABLED=1
    tk_fixture 'display-message*' 'SHOULD-NOT-APPEAR'
    assert_empty "$(tk_tmux display-message -p '#{pid}')"
}

@test "tk_tmux propagates a failing exit status" {
    tk_fixture 'has-session*' '' 1
    refute tk_tmux has-session -t nope
}

@test "tk_tmux_silent swallows failure so a hook cannot die on a cosmetic write" {
    tk_fixture 'set-option*' '' 1
    tk_tmux_silent set-option -gq @ns-status x
}

@test "tk_tmux_ok uses list-sessions, not tmux info" {
    # `tmux info` exits non-zero with "no current client" when a server runs
    # unattached, which made install and doctor report no tmux on a healthy
    # server.
    tk_tmux_ok || true
    assert_called 'list-sessions'
    refute_called 'info'
}

@test "tk_tmux_ok is false when no server answers" {
    tk_fixture 'list-sessions*' '' 1
    refute tk_tmux_ok
}

@test "tk_tmux_ok is false when tmux is disabled" {
    TK_TMUX_DISABLED=1
    refute tk_tmux_ok
}

@test "tk_in_tmux reflects the pane environment, not server reachability" {
    refute tk_in_tmux
    TMUX_PANE="%3"
    tk_in_tmux
}

@test "tk_display never fails" {
    tk_fixture 'display-message*' '' 1
    tk_display "hello"
    assert_called 'display-message hello'
}

@test "tk_server_pid returns the pid" {
    tk_fixture 'display-message -p #{pid}' '12345'
    assert_eq "$(tk_server_pid)" "12345"
}

@test "tk_server_pid is empty rather than failing when no server answers" {
    tk_fixture 'display-message*' '' 1
    assert_empty "$(tk_server_pid)"
}

@test "TK_TMUX_BIN redirects the binary" {
    printf '#!/bin/sh\nprintf ALT\n' > "$TEST_TMPDIR/alt-tmux"
    chmod +x "$TEST_TMPDIR/alt-tmux"
    TK_TMUX_BIN="$TEST_TMPDIR/alt-tmux"
    assert_eq "$(tk_tmux -V)" "ALT"
}
