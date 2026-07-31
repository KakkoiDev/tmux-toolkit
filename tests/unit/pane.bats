#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1: pane I/O against the stubbed tmux (and a stubbed ps for the liveness
# classification, which is the one thing the tmux stub cannot fake: a comm
# child-walk is a ps query, not a tmux format).

load '../assert'

setup() {
    tk_setup
    export TK_PS_FIXTURE="$TEST_TMPDIR/ps-fixture"
    : > "$TK_PS_FIXTURE"
    # shellcheck source=../../lib/toolkit-pane.sh
    source "$TK_LIB/toolkit-pane.sh"
}
teardown() { tk_teardown; }

# ps_fixture <lines> - teach the ps stub one process tree.
ps_fixture() { printf '%s\n' "$1" >> "$TK_PS_FIXTURE"; }

# A live shell pane: read marker set, pane alive, shell process, no children.
shell_pane() {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash'
}

# ── tk_pane_send ─────────────────────────────────────────────────────

@test "tk_pane_send types literal text as one argument through -l --" {
    shell_pane
    run tk_pane_send "main:1.0" 'echo "hello world"'
    assert_ok
    assert_called 'send-keys -t main:1.0 -l -- echo "hello world"'
    refute_called 'send-keys -t main:1.0 Enter'
}

@test "tk_pane_send prints the human's attach command" {
    shell_pane
    run tk_pane_send "main:1.0" hi
    assert_ok
    assert_contains "$output" 'tk-pane: wrote to main:1.0'
    assert_contains "$output" 'tmux attach -t main'
}

@test "the attach command carries the private socket when TK_SOCKET is set" {
    export TK_SOCKET=tk-test
    tk_fixture '-L tk-test show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture '-L tk-test display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash'
    run tk_pane_send "main:1.0" hi
    assert_ok
    assert_contains "$output" 'tmux -L tk-test attach -t main'
    unset TK_SOCKET
}

@test "tk_pane_send refuses the agent's own pane" {
    export TMUX_PANE=%0
    tk_fixture 'display-message -t main:1.0 -p #{pane_id}*' '%0'
    run tk_pane_send "main:1.0" boom
    assert_fail
    assert_contains "$output" 'own pane'
    refute_called 'send-keys'
    unset TMUX_PANE
}

@test "tk_pane_send refuses a pane that was not read first" {
    # @pane-read unset: show-options fails, tk_pane_get yields empty.
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read' '' 1
    run tk_pane_send "main:1.0" hi
    assert_fail
    assert_contains "$output" 'read'
    refute_called 'send-keys'
}

@test "tk_pane_send refuses a pane running something other than a shell or agent" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash
43 42 vim'
    run tk_pane_send "main:1.0" hi
    assert_fail
    assert_contains "$output" 'refusing'
    refute_called 'send-keys'
}

@test "tk_pane_send refuses a dead pane" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    run tk_pane_send "main:1.0" hi
    assert_fail
    assert_contains "$output" 'dead'
}

@test "tk_pane_send types into an agent pane (the resumer's path)" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 claude'
    run tk_pane_send "main:1.0" 'resume'
    assert_ok
    assert_called 'send-keys -t main:1.0 -l -- resume'
}

@test "tk_pane_send requires a target and text" {
    shell_pane
    run tk_pane_send ""
    assert_fail
    run tk_pane_send "main:1.0" ""
    assert_fail
}

# ── tk_pane_run ──────────────────────────────────────────────────────

@test "tk_pane_run sends the command and Enter to a shell pane" {
    shell_pane
    run tk_pane_run "main:1.0" echo 'hello world'
    assert_ok
    assert_called 'send-keys -t main:1.0 -l -- echo hello world'
    assert_called 'send-keys -t main:1.0 Enter'
    assert_contains "$output" 'tmux attach -t main'
}

@test "tk_pane_run respawns a dead pane's shell before sending" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    run tk_pane_run "main:1.0" echo respawned
    assert_ok
    assert_called 'respawn-pane -t main:1.0'
    assert_called 'send-keys -t main:1.0 -l -- echo respawned'
}

@test "tk_pane_run refuses an agent pane (a command would go to the agent)" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 claude'
    run tk_pane_run "main:1.0" ls
    assert_fail
    refute_called 'send-keys'
    refute_called 'respawn-pane'
}

@test "tk_pane_run requires a command" {
    shell_pane
    run tk_pane_run "main:1.0"
    assert_fail
}

# ── tk_pane_key ──────────────────────────────────────────────────────

@test "tk_pane_key sends one named key" {
    shell_pane
    run tk_pane_key "main:1.0" C-c
    assert_ok
    assert_called 'send-keys -t main:1.0 C-c'
    assert_contains "$output" 'tmux attach -t main'
}

@test "tk_pane_key works on any live process (the rescue path)" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash
43 42 vim'
    run tk_pane_key "main:1.0" C-c
    assert_ok
    assert_called 'send-keys -t main:1.0 C-c'
}

@test "tk_pane_key refuses a dead pane" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    run tk_pane_key "main:1.0" C-c
    assert_fail
    assert_contains "$output" 'dead'
}

# ── tk_pane_read ─────────────────────────────────────────────────────

@test "tk_pane_read returns the default 200-line tail and marks the pane read" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'line1
line2
line3'
    run tk_pane_read "main:1.0"
    assert_ok
    assert_contains "$output" 'line2'
    assert_called 'capture-pane -t main:1.0 -p -J -S -200'
    assert_called 'set-option -p -t main:1.0 @pane-read 1'
}

@test "tk_pane_read honors --tail" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -50*' 'tail50'
    run tk_pane_read "main:1.0" --tail 50
    assert_ok
    assert_contains "$output" 'tail50'
    assert_called 'capture-pane -t main:1.0 -p -J -S -50'
}

@test "tk_pane_read --full captures the whole scrollback" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -*' 'everything'
    run tk_pane_read "main:1.0" --full
    assert_ok
    assert_contains "$output" 'everything'
    assert_called 'capture-pane -t main:1.0 -p -J -S -'
}

@test "tk_pane_read --since resumes after the last line containing the cursor" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'one
two
three
two
four'
    run tk_pane_read "main:1.0" --since 'two'
    assert_ok
    assert_eq "$output" 'four'
}

@test "tk_pane_read --since prints everything when the cursor is not found" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'one
two'
    run tk_pane_read "main:1.0" --since 'zzz'
    assert_ok
    assert_contains "$output" 'one'
}

@test "tk_pane_read fails on a vanished pane and does not mark it read" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' '' 1
    run tk_pane_read "main:1.0"
    assert_fail
    refute_called 'set-option -p -t main:1.0 @pane-read'
}

@test "tk_pane_read requires a target" {
    run tk_pane_read ""
    assert_fail
}

# ── tk_pane_wait ─────────────────────────────────────────────────────

@test "tk_pane_wait --text returns immediately when the text is already there" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'build complete'
    run tk_pane_wait "main:1.0" --text 'complete' --timeout 2
    assert_ok
    assert_contains "$output" 'build complete'
}

@test "tk_pane_wait --text matches a regex, not just a literal" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'task-7 done'
    run tk_pane_wait "main:1.0" --text 'task-[0-9]+ done' --timeout 2
    assert_ok
}

@test "tk_pane_wait --text times out" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'nothing here'
    run tk_pane_wait "main:1.0" --text 'never-appears' --timeout 1
    assert_fail
    assert_contains "$output" 'timeout'
}

@test "tk_pane_wait --idle returns when the pane stops changing" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' 'static'
    run tk_pane_wait "main:1.0" --idle 0 --timeout 2
    assert_ok
}

@test "tk_pane_wait needs --text or --idle" {
    run tk_pane_wait "main:1.0"
    assert_fail
    assert_contains "$output" '--text'
}

@test "tk_pane_wait rejects a non-numeric timeout" {
    run tk_pane_wait "main:1.0" --text x --timeout soon
    assert_fail
}

@test "tk_pane_wait fails fast when the pane vanishes" {
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' '' 1
    run tk_pane_wait "main:1.0" --text anything --timeout 5
    assert_fail
    assert_contains "$output" 'vanished'
}

# ── tk_pane_metadata ─────────────────────────────────────────────────

@test "tk_pane_set writes a @pane-<key> option" {
    run tk_pane_set "main:1.0" note 'hello world'
    assert_ok
    assert_called 'set-option -p -t main:1.0 @pane-note hello world'
}

@test "tk_pane_get reads a @pane-<key> option" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-note' 'hello world'
    assert_eq "$(tk_pane_get "main:1.0" note)" 'hello world'
}

@test "tk_pane_get returns empty for an unset key" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-note' '' 1
    assert_empty "$(tk_pane_get "main:1.0" note)"
}

@test "tk_pane_set/get require a key" {
    run tk_pane_set "main:1.0" "" v
    assert_fail
    run tk_pane_get "main:1.0" ""
    assert_fail
}

# ── tk_pane_proc classification ──────────────────────────────────────

@test "tk_pane_proc reports dead for a gone pane" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    assert_eq "$(tk_pane_proc "main:1.0")" 'dead'
}

@test "tk_pane_proc reports dead when the pid is not in ps" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '99'
    ps_fixture '42 1 bash'
    assert_eq "$(tk_pane_proc "main:1.0")" 'dead'
}

@test "tk_pane_proc classifies an idle shell" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash'
    assert_match "$(tk_pane_proc "main:1.0")" 'shell*'
}

@test "tk_pane_proc sees an agent child of a shell (claude typed at a prompt)" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash
43 42 claude'
    assert_match "$(tk_pane_proc "main:1.0")" 'agent*'
}

@test "tk_pane_proc classifies a pane launched directly as an agent" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 claude'
    assert_match "$(tk_pane_proc "main:1.0")" 'agent*'
}

@test "tk_pane_proc classifies a foreground editor as other" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash
43 42 vim'
    assert_match "$(tk_pane_proc "main:1.0")" 'other*'
}

@test "tk_pane_proc basenames a full-path comm (macOS framework binaries)" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 /opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python'
    assert_match "$(tk_pane_proc "main:1.0")" 'agent*'
}

@test "tk_pane_proc strips the login-shell dash" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 -sh'
    assert_match "$(tk_pane_proc "main:1.0")" 'shell*'
}

@test "tk_pane_proc strips macOS's parenthesized shim names" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 (Python)'
    assert_match "$(tk_pane_proc "main:1.0")" 'agent*'
}

# ── tk_agent_composer ────────────────────────────────────────────────

agent_pane() {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 claude'
}

@test "tk_agent_composer reports empty for a bare prompt" {
    agent_pane
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' 'some output above
> '
    assert_eq "$(tk_agent_composer "main:1.0")" 'empty'
}

@test "tk_agent_composer reports pending for text after the prompt" {
    agent_pane
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' '> hello there'
    assert_eq "$(tk_agent_composer "main:1.0")" 'pending'
}

@test "tk_agent_composer reports unknown for non-prompt content" {
    agent_pane
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' 'Working on it...'
    assert_eq "$(tk_agent_composer "main:1.0")" 'unknown'
}

@test "tk_agent_composer reports unknown when the pane is not an agent" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash'
    assert_eq "$(tk_agent_composer "main:1.0")" 'unknown'
}

@test "tk_agent_composer reports dead for a dead pane" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    assert_eq "$(tk_agent_composer "main:1.0")" 'dead'
}

# ── tk_agent_prompt ──────────────────────────────────────────────────

@test "tk_agent_prompt types a prompt into an empty composer and never submits" {
    agent_pane
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' '> '
    run tk_agent_prompt "main:1.0" 'hello agent'
    assert_ok
    assert_called 'send-keys -t main:1.0 -l -- hello agent'
    refute_called 'send-keys -t main:1.0 Enter'
    assert_contains "$output" 'tmux attach -t main'
}

@test "tk_agent_prompt refuses when the composer is pending" {
    agent_pane
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' '> already typed'
    run tk_agent_prompt "main:1.0" 'more'
    assert_fail
    assert_contains "$output" 'pending'
    refute_called 'send-keys -t main:1.0 -l -- more'
}

@test "tk_agent_prompt refuses a shell pane" {
    tk_fixture 'show-options -p -t main:1.0 -v @pane-read*' '1'
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '42'
    ps_fixture '42 1 bash'
    run tk_agent_prompt "main:1.0" hi
    assert_fail
    assert_contains "$output" 'refusing'
    refute_called 'send-keys'
}

@test "tk_agent_prompt requires text" {
    agent_pane
    run tk_agent_prompt "main:1.0" ""
    assert_fail
}

# ── tk_agent_wait ────────────────────────────────────────────────────

@test "tk_agent_wait returns when the agent is back at a bare prompt" {
    agent_pane
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' '> '
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -200*' '> '
    run tk_agent_wait "main:1.0" --idle 0 --timeout 2
    assert_ok
}

@test "tk_agent_wait times out while the agent stays busy" {
    agent_pane
    tk_fixture 'capture-pane -t main:1.0 -p -J -S -5*' 'Working on it...'
    run tk_agent_wait "main:1.0" --timeout 1
    assert_fail
    assert_contains "$output" 'timeout'
}

@test "tk_agent_wait fails fast when the agent pane dies" {
    tk_fixture 'display-message -t main:1.0 -p #{pane_pid}*' '' 1
    run tk_agent_wait "main:1.0" --timeout 10
    assert_fail
    assert_contains "$output" 'died'
}
