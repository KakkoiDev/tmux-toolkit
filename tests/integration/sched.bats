#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2 for sched.sh against a real tmux on a private socket: the run-shell -d
# timer (V7) firing a command on the server without a sleep child in the
# client's process tree.

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
}
teardown() { tk_teardown_real; }

@test "tk_after runs the command on the server after the delay (3.2+)" {
    tk_vers_ge 3.2 || skip "run-shell -d needs tmux 3.2+"
    local marker="$TEST_TMPDIR/after.marker"
    rm -f "$marker"
    tk_after 1 "touch '$marker'"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        [[ -e "$marker" ]] && break
        sleep 0.1
    done
    assert_file "$marker"
}

@test "tk_after with an empty command schedules nothing" {
    tk_after 1 ""
}
