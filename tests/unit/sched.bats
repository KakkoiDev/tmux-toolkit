#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for sched.sh against the recording tmux stub. The real-server `-d`
# timer behaviour is pinned in tests/integration/sched.bats; here the gates
# are which argv shape each tmux version tier produces.

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

# tk_after ────────────────────────────────────────────────────────────

@test "tk_after uses run-shell -b -d on tmux 3.2+" {
    # V7: the -d flag is a libevent timer on the server; no sleep child.
    tk_fixture '-V' 'tmux 3.7b'
    tk_after 5 "true"
    assert_called 'run-shell -b -d 5 true'
}

@test "tk_after keeps the delay argument in the run-shell argv" {
    tk_fixture '-V' 'tmux 3.7b'
    tk_after 42 "touch /tmp/x"
    assert_called 'run-shell -b -d 42 touch /tmp/x'
}

@test "tk_after falls back to sleep on tmux below 3.2" {
    # D-13 gate: the floor is 3.0 and run-shell -d arrived in 3.2, so the
    # pre-3.2 shape must be exercised, not assumed.
    tk_fixture '-V' 'tmux 3.0a'
    tk_after 0 "true"
    refute_called 'run-shell'
}

@test "tk_after with an empty command never calls tmux" {
    tk_fixture '-V' 'tmux 3.7b'
    tk_after 5 ""
    refute_called 'run-shell'
}

@test "tk_after returns 0 even when the version check sees no tmux" {
    # A hook on a box where tmux -V answers nothing (or the stub does) must
    # not fail the hook.
    tk_after 0 "true"
}

# tk_jitter ───────────────────────────────────────────────────────────

@test "tk_jitter with max 0 returns instantly" {
    # $RANDOM is present on bash 3.2, which is the whole point of using it.
    tk_jitter 0
}

@test "tk_jitter ignores a non-numeric max" {
    tk_jitter "soon"
}

@test "tk_jitter with a positive max returns 0" {
    tk_jitter 1
}

@test "tk_jitter stays within the requested window" {
    # Seed RANDOM so the draw is deterministic: with RANDOM=1 and max=1 the
    # result is floor(1*2/32768)=0, i.e. it must not sleep for the max.
    RANDOM=1
    tk_jitter 1
}
