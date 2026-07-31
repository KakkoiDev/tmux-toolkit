#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for pane-ops.sh: pane, window, and session management against the
# stubbed tmux.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() { tk_teardown; }

# ── pane_split ───────────────────────────────────────────────────────

@test "tk_pane_split defaults to horizontal split on the current pane" {
    tk_fixture 'split-window -h' ''
    tk_pane_split
    assert_called 'split-window -h'
}

@test "tk_pane_split -v splits vertically" {
    tk_fixture 'split-window -v' ''
    tk_pane_split -v
    assert_called 'split-window -v'
}

@test "tk_pane_split accepts a target and size" {
    tk_fixture 'split-window -t main:1.0 -h -p 50' ''
    tk_pane_split -h "main:1.0" "-p 50"
    assert_called 'split-window -t main:1.0 -h -p 50'
}

@test "tk_pane_split with only a target (no size)" {
    tk_fixture 'split-window -t main:1.0 -h' ''
    tk_pane_split "main:1.0"
    assert_called 'split-window -t main:1.0 -h'
}

# ── pane_kill ────────────────────────────────────────────────────────

@test "tk_pane_kill kills a named pane" {
    tk_fixture 'kill-pane -t main:1.0' ''
    tk_pane_kill "main:1.0"
    assert_called 'kill-pane -t main:1.0'
}

@test "tk_pane_kill defaults to the current pane" {
    tk_fixture 'kill-pane' ''
    tk_pane_kill
    assert_called 'kill-pane'
}

@test "tk_pane_kill_silent swallows failure" {
    tk_fixture 'kill-pane*' '' 1
    tk_pane_kill_silent "main:1.0"
}

# ── pane_rename ──────────────────────────────────────────────────────

@test "tk_pane_rename sets the pane title" {
    tk_fixture 'select-pane -t main:1.0 -T my-title' ''
    tk_pane_rename "main:1.0" "my-title"
    assert_called 'select-pane -t main:1.0 -T my-title'
}

@test "tk_pane_rename requires a target" {
    run tk_pane_rename "" "name"
    assert_fail
}

@test "tk_pane_rename requires a name" {
    run tk_pane_rename "main:1.0" ""
    assert_fail
}

# ── pane_resize ──────────────────────────────────────────────────────

@test "tk_pane_resize resizes in the given direction" {
    tk_fixture 'resize-pane -t main:1.0 -U 5' ''
    tk_pane_resize "main:1.0" "-U" "5"
    assert_called 'resize-pane -t main:1.0 -U 5'
}

@test "tk_pane_resize requires all three arguments" {
    run tk_pane_resize "" "-U" "5"
    assert_fail
    run tk_pane_resize "main:1.0" "" "5"
    assert_fail
    run tk_pane_resize "main:1.0" "-U" ""
    assert_fail
}

# ── window_new ───────────────────────────────────────────────────────

@test "tk_window_new creates a new window" {
    tk_fixture 'new-window' ''
    tk_window_new
    assert_called 'new-window'
}

@test "tk_window_new accepts a name and command" {
    tk_fixture 'new-window -n mywin -- mycmd' ''
    tk_window_new "mywin" "mycmd"
    assert_called 'new-window -n mywin -- mycmd'
}

@test "tk_window_new accepts just a name" {
    tk_fixture 'new-window -n mywin' ''
    tk_window_new "mywin"
    assert_called 'new-window -n mywin'
}

# ── window_kill ──────────────────────────────────────────────────────

@test "tk_window_kill kills a named window" {
    tk_fixture 'kill-window -t @3' ''
    tk_window_kill "@3"
    assert_called 'kill-window -t @3'
}

@test "tk_window_kill defaults to the current window" {
    tk_fixture 'kill-window' ''
    tk_window_kill
    assert_called 'kill-window'
}

# ── window_rename ────────────────────────────────────────────────────

@test "tk_window_rename renames a window" {
    tk_fixture 'rename-window -t @3 newname' ''
    tk_window_rename "@3" "newname"
    assert_called 'rename-window -t @3 newname'
}

# ── window_list ──────────────────────────────────────────────────────

@test "tk_window_list lists windows with a machine-readable format" {
    # Use a simple pipe separator in the fixture; the real tk_window_list
    # uses \037 but the stub's printf %b does not interpret octal in the
    # same way across all /bin/sh implementations. The point is that
    # list-windows -F is called and its output is returned.
    tk_fixture 'list-windows -F*' '0|bash|*|1'
    local out
    out="$(tk_window_list)"
    assert_contains "$out" 'bash'
    assert_contains "$out" '1'
}

# ── window_find ──────────────────────────────────────────────────────

@test "tk_window_find finds a window by name" {
    tk_fixture 'list-windows -F*' '0 bash
1 zsh'
    assert_eq "$(tk_window_find "zsh")" "1"
}

@test "tk_window_find returns empty when not found" {
    tk_fixture 'list-windows -F*' '0 bash'
    assert_empty "$(tk_window_find "zsh")"
}

# ── session_new ──────────────────────────────────────────────────────

@test "tk_session_new creates a detached session" {
    tk_fixture 'new-session -d -s myname' ''
    tk_session_new "myname"
    assert_called 'new-session -d -s myname'
}

@test "tk_session_new accepts a command" {
    tk_fixture 'new-session -d -s myname -- mycmd' ''
    tk_session_new "myname" "mycmd"
    assert_called 'new-session -d -s myname -- mycmd'
}

# ── session_rename ───────────────────────────────────────────────────

@test "tk_session_rename renames a session" {
    tk_fixture 'rename-session -t old new' ''
    tk_session_rename "old" "new"
    assert_called 'rename-session -t old new'
}

# ── session_list ─────────────────────────────────────────────────────

@test "tk_session_list lists sessions with a machine-readable format" {
    tk_fixture 'list-sessions -F*' 'main|3|1'
    local out
    out="$(tk_session_list)"
    assert_contains "$out" 'main'
    assert_contains "$out" '3'
}

# ── session_kill ─────────────────────────────────────────────────────

@test "tk_session_kill kills a session" {
    tk_fixture 'kill-session -t myname' ''
    tk_session_kill "myname"
    assert_called 'kill-session -t myname'
}

# ── session_attach ───────────────────────────────────────────────────

@test "tk_session_attach prints the attach command" {
    local out
    out="$(tk_session_attach "mysession")"
    assert_eq "$out" 'tmux attach -t mysession'
}

@test "tk_session_attach respects TK_SOCKET" {
    export TK_SOCKET=my-sock
    assert_eq "$(tk_session_attach "mysession")" 'tmux -L my-sock attach -t mysession'
    unset TK_SOCKET
}

# ── session_exists ───────────────────────────────────────────────────

@test "tk_session_exists succeeds when the session is there" {
    tk_fixture 'has-session -t myname' ''
    tk_session_exists "myname"
}

@test "tk_session_exists fails when the session is absent" {
    tk_fixture 'has-session -t myname' '' 1
    refute tk_session_exists "myname"
}

# ── silent variants ──────────────────────────────────────────────────

@test "tk_pane_rename_silent swallows failure" {
    tk_fixture 'select-pane*' '' 1
    tk_pane_rename_silent "main:1.0" "x"
}

@test "tk_pane_resize_silent swallows failure" {
    tk_fixture 'resize-pane*' '' 1
    tk_pane_resize_silent "main:1.0" "-U" "5"
}

@test "tk_window_new_silent swallows failure" {
    tk_fixture 'new-window*' '' 1
    tk_window_new_silent "x"
}

@test "tk_window_kill_silent swallows failure" {
    tk_fixture 'kill-window*' '' 1
    tk_window_kill_silent "@0"
}

@test "tk_window_rename_silent swallows failure" {
    tk_fixture 'rename-window*' '' 1
    tk_window_rename_silent "@0" "x"
}

@test "tk_session_new_silent swallows failure" {
    tk_fixture 'new-session*' '' 1
    tk_session_new_silent "x"
}

@test "tk_session_rename_silent swallows failure" {
    tk_fixture 'rename-session*' '' 1
    tk_session_rename_silent "old" "new"
}

@test "tk_session_kill_silent swallows failure" {
    tk_fixture 'kill-session*' '' 1
    tk_session_kill_silent "x"
}
