#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2: pane I/O against a real tmux on a private socket.
#
# Everything here asserts tmux's own behaviour, which is exactly why it is
# integration: that `send-keys -l --` really types one literal argument, that
# capture-pane -S -N means "N scrollback lines plus the visible screen", that a
# pane option round-trips as an annotation, that respawn-pane brings a dead
# pane back, and that the poll-loop waits behave against a pane that is really
# producing output.
#
# The fake agent is a python script whose prompt ("> ") flushes immediately;
# python's comm name (Python on macOS, python3 elsewhere) is in the default
# agent list.

load '../assert'

setup() {
    tk_skip_no_tmux
    # Deterministic panes: the developer's own shell rc must not print into
    # them mid-test, and the session's shell is chosen at session creation,
    # so SHELL must be set before tk_setup_real. -f /dev/null already
    # isolates tmux config; this isolates the shell tmux starts.
    export SHELL=/bin/sh
    export ENV=/dev/null
    tk_setup_real
    # shellcheck source=../../lib/toolkit-pane.sh
    source "$TK_LIB/toolkit-pane.sh"
}
teardown() { tk_teardown_real; }

# fake_agent_pane - open a window running a python prompt loop and print its
# session:window.pane target. The prompt is flushed so the composer is readable.
fake_agent_pane() {
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s\n' \
        'import sys, time' \
        'while True:' \
        "    sys.stdout.write('> ')" \
        '    sys.stdout.flush()' \
        '    line = sys.stdin.readline()' \
        '    if not line:' \
        '        break' \
        "    sys.stdout.write('got: ' + line)" \
        '    sys.stdout.flush()' \
        '    time.sleep(1)' \
        "    sys.stdout.write('done: ' + line)" \
        '    sys.stdout.flush()' > "$TEST_TMPDIR/fakeagent.py"
    tk_tmux new-window -t tk-main -n agent "python3 $TEST_TMPDIR/fakeagent.py" >/dev/null 2>&1 || return 1
    local idx
    idx="$(tk_tmux list-windows -t tk-main -F '#{window_index}' | sort -n | tail -1)"
    printf 'tk-main:%s.0' "$idx"
}

# ── send / key ───────────────────────────────────────────────────────

@test "tk_pane_send types literal text; tk_pane_key submits it" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    run tk_pane_send "$target" 'echo pane-send-ok'
    assert_ok
    assert_contains "$output" 'attach -t tk-main'
    # typed, not yet executed: the command text is visible on the input line
    tk_pane_wait "$target" --text 'echo pane-send-ok' --timeout 5 >/dev/null
    tk_pane_key "$target" Enter
    run tk_pane_wait "$target" --text '^pane-send-ok$' --timeout 5
    assert_ok
}

@test "tk_pane_send passes spaces and quotes through untouched" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'echo "sp ace" $HOME'
    run tk_pane_wait "$target" --text '^sp ace ' --timeout 5
    assert_ok
}

# ── run / respawn ────────────────────────────────────────────────────

@test "tk_pane_run executes a command in the pane" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    run tk_pane_run "$target" echo pane-run-ok
    assert_ok
    run tk_pane_wait "$target" --text '^pane-run-ok$' --timeout 5
    assert_ok
}

@test "tk_pane_run refuses a pane whose foreground process is not a shell" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'sleep 30'
    sleep 0.7
    run tk_pane_run "$target" echo nope
    assert_fail
    assert_contains "$output" 'refusing'
    tk_pane_key "$target" C-c
}

@test "tk_pane_run respawns a dead pane's shell before running" {
    tk_tmux set-option -g remain-on-exit on
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" exit
    sleep 0.6
    assert_eq "$(tk_tmux display-message -t "$target" -p '#{pane_dead}')" "1"
    run tk_pane_run "$target" echo after-respawn
    assert_ok
    run tk_pane_wait "$target" --text '^after-respawn$' --timeout 5
    assert_ok
}

@test "tk_pane_proc reports dead for the closed pane and the next run revives it" {
    tk_tmux set-option -g remain-on-exit on
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" exit
    sleep 0.6
    assert_match "$(tk_pane_proc "$target")" 'dead*'
    tk_pane_run "$target" echo revived
    run tk_pane_wait "$target" --text '^revived$' --timeout 5
    assert_ok
    assert_match "$(tk_pane_proc "$target")" 'shell*'
}

# ── read ─────────────────────────────────────────────────────────────

@test "tk_pane_read returns a bounded tail, --full the whole scrollback" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'i=1; while [ $i -le 60 ]; do printf "read-line-%02d\n" $i; i=$((i+1)); done'
    tk_pane_wait "$target" --text '^read-line-60$' --timeout 10 >/dev/null
    local full tail20
    full="$(tk_pane_read "$target" --full)"
    tail20="$(tk_pane_read "$target" --tail 20)"
    assert_contains "$full" 'read-line-01'
    assert_contains "$full" 'read-line-60'
    assert_contains "$tail20" 'read-line-60'
    refute_contains "$tail20" 'read-line-01'
}

@test "tk_pane_read --since resumes after the last line containing the cursor" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'echo pre-line'
    tk_pane_run "$target" 'echo post-line'
    tk_pane_wait "$target" --text '^post-line$' --timeout 5 >/dev/null
    local out
    out="$(tk_pane_read "$target" --since 'echo pre-line')"
    assert_contains "$out" 'post-line'
    refute_contains "$out" 'echo pre-line'
}

# ── guardrails ───────────────────────────────────────────────────────

@test "typing is refused until the pane has been read" {
    local target="tk-main:0.0"
    run tk_pane_send "$target" hi
    assert_fail
    assert_contains "$output" 'read'
    tk_pane_read "$target" >/dev/null
    run tk_pane_send "$target" hi
    assert_ok
}

@test "tk_pane_proc classifies a real interactive shell pane" {
    local target="tk-main:0.0"
    assert_match "$(tk_pane_proc "$target")" 'shell*'
}

# ── metadata ─────────────────────────────────────────────────────────

@test "tk_pane_set/get round-trip through a real pane option" {
    local target="tk-main:0.0"
    tk_pane_set "$target" note 'hello world'
    assert_eq "$(tk_pane_get "$target" note)" 'hello world'
    assert_empty "$(tk_pane_get "$target" never-set)"
}

# ── wait ─────────────────────────────────────────────────────────────

@test "tk_pane_wait --text waits for future output, not just current" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'sleep 1; echo done-now'
    run tk_pane_wait "$target" --text '^done-now$' --timeout 10
    assert_ok
}

@test "tk_pane_wait --text times out on real tmux" {
    local target="tk-main:0.0"
    run tk_pane_wait "$target" --text 'zzz-never' --timeout 1
    assert_fail
    assert_contains "$output" 'timeout'
}

@test "tk_pane_wait --idle returns after streaming output settles" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    tk_pane_run "$target" 'i=1; while [ $i -le 10 ]; do echo tick-$i; sleep 0.5; i=$((i+1)); done'
    run tk_pane_wait "$target" --idle 1 --timeout 15
    assert_ok
    assert_contains "$(tk_pane_read "$target")" 'tick-10'
}

# ── agent layer ──────────────────────────────────────────────────────

@test "tk_agent_prompt types into an agent pane and never submits" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    local target
    target="$(fake_agent_pane)"
    tk_pane_wait "$target" --text '^> $' --timeout 5 >/dev/null

    run tk_agent_prompt "$target" 'task-7'
    assert_ok
    assert_contains "$output" 'attach -t tk-main'
    # typed, not submitted: the text is in the composer, the agent has not
    # seen a line yet
    assert_contains "$(tk_pane_capture "$target" 10)" 'task-7'
    refute_contains "$(tk_pane_capture "$target" 10)" 'got: task-7'
    assert_eq "$(tk_agent_composer "$target")" 'pending'

    # a second prompt refuses rather than clobbering the pending text
    run tk_agent_prompt "$target" 'task-8'
    assert_fail
    assert_contains "$output" 'pending'
}

@test "tk_agent_wait returns when the agent goes idle after work" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    local target
    target="$(fake_agent_pane)"
    tk_pane_wait "$target" --text '^> $' --timeout 5 >/dev/null
    tk_agent_prompt "$target" 'task-9'
    tk_pane_key "$target" Enter
    run tk_agent_wait "$target" --idle 0 --timeout 10
    assert_ok
    assert_contains "$(tk_pane_capture "$target" 20)" 'done: task-9'
}

@test "tk_agent_wait times out while the composer stays pending" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    local target
    target="$(fake_agent_pane)"
    tk_pane_wait "$target" --text '^> $' --timeout 5 >/dev/null
    tk_agent_prompt "$target" 'task-10'
    run tk_agent_wait "$target" --timeout 1
    assert_fail
    assert_contains "$output" 'timeout'
}

@test "tk_agent_prompt refuses a shell pane" {
    local target="tk-main:0.0"
    tk_pane_read "$target" >/dev/null
    run tk_agent_prompt "$target" hi
    assert_fail
    assert_contains "$output" 'refusing'
}

@test "tk_pane_run refuses an agent pane" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    local target
    target="$(fake_agent_pane)"
    tk_pane_wait "$target" --text '^> $' --timeout 5 >/dev/null
    run tk_pane_run "$target" echo nope
    assert_fail
    assert_contains "$output" 'refusing'
}
