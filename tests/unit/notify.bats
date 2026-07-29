#!/usr/bin/env bats
# shellcheck shell=bats
load '../assert'
setup() {
    tk_setup
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() { tk_teardown; }

@test "no configured command means nothing runs" {
    tk_notify ns transition a b
}

# The contract: the snippet is a command *prefix*, and the arguments are appended
# to it as argv. So `notify-send` receives them; a snippet does not write "$@"
# itself, or it gets them twice.
@test "the configured snippet runs with its arguments appended" {
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$1.out"\n' > "$BATS_TEST_TMPDIR/rec"
    chmod +x "$BATS_TEST_TMPDIR/rec"
    tk_fixture 'show-option -gqv @ns-on-transition' "$BATS_TEST_TMPDIR/rec $BATS_TEST_TMPDIR/x"
    tk_notify ns transition working blocked
    local waited=0
    while [[ ! -s "$BATS_TEST_TMPDIR/x.out" && "$waited" -lt 30 ]]; do sleep 0.1; waited=$((waited+1)); done
    assert_eq "$(cat "$BATS_TEST_TMPDIR/x.out")" "$(printf '%s\nworking\nblocked' "$BATS_TEST_TMPDIR/x")"
}

@test "an argument containing spaces stays one argument" {
    # The three implementations this replaces use `eval "$cmd" "$@"`, which
    # splices the args into the evaluated string, so a prompt summary with a
    # space arrived as two arguments.
    printf '#!/bin/sh\nshift\nfor a in "$@"; do printf "[%%s]" "$a"; done > "%s"\n' "$BATS_TEST_TMPDIR/sp" > "$BATS_TEST_TMPDIR/rec2"
    chmod +x "$BATS_TEST_TMPDIR/rec2"
    tk_fixture 'show-option -gqv @ns-on-transition' "$BATS_TEST_TMPDIR/rec2 ignored"
    tk_notify ns transition "fix the flaky test" second
    local waited=0
    while [[ ! -s "$BATS_TEST_TMPDIR/sp" && "$waited" -lt 30 ]]; do sleep 0.1; waited=$((waited+1)); done
    assert_eq "$(cat "$BATS_TEST_TMPDIR/sp")" "[fix the flaky test][second]"
}

@test "a failing snippet does not fail the caller" {
    tk_fixture 'show-option -gqv @ns-on-transition' 'exit 7'
    tk_notify ns transition a
}

@test "tk_notify_push does nothing without a topic" {
    tk_notify_push ns "hello"
}

@test "tk_notify_all fires the snippet and returns success" {
    tk_fixture 'show-option -gqv @ns-on-mail' "printf ok > $BATS_TEST_TMPDIR/mail"
    tk_notify_all ns mail "you have mail"
    local waited=0
    while [[ ! -s "$BATS_TEST_TMPDIR/mail" && "$waited" -lt 30 ]]; do sleep 0.1; waited=$((waited+1)); done
    assert_eq "$(cat "$BATS_TEST_TMPDIR/mail")" "ok"
}
