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

@test "a lock can be taken and released" {
    tk_lock a
    tk_locked a
    tk_unlock a
    refute tk_locked a
}

@test "a second acquire fails while held" {
    tk_lock a
    ( tk_lock a ) && _afail "expected the second acquire to fail" || true
}

@test "acquiring is non-blocking" {
    # Every caller is on a status-render or hook path where waiting is worse
    # than skipping a cycle.
    tk_lock a
    local start end
    start=$(date +%s)
    refute tk_lock a
    end=$(date +%s)
    [[ $(( end - start )) -le 1 ]] || _afail "tk_lock blocked for $(( end - start ))s"
}

@test "different names do not collide" {
    tk_lock a
    tk_lock b
    tk_locked a; tk_locked b
}

@test "the holder pid is recorded" {
    tk_lock a
    assert_file "$(tk_lock_dir a)/pid"
    assert_eq "$(cat "$(tk_lock_dir a)/pid")" "$$"
}

@test "a lock held by a dead pid is stolen immediately" {
    # The one real defect of a mkdir lock: the OS never releases it when the
    # holder dies. The implementation this replaces waited out a flat 120s
    # timeout, so a crashed holder blocked everything for two minutes.
    mkdir -p "$(tk_lock_dir a)"
    printf '999999' > "$(tk_lock_dir a)/pid"
    local start end
    start=$(date +%s)
    tk_lock a 120
    end=$(date +%s)
    [[ $(( end - start )) -le 1 ]] || _afail "stealing took $(( end - start ))s"
    assert_eq "$(cat "$(tk_lock_dir a)/pid")" "$$"
}

@test "a lock held by a live pid is not stolen" {
    mkdir -p "$(tk_lock_dir a)"
    printf '%s' "$$" > "$(tk_lock_dir a)/pid"
    refute tk_lock a 120
}

@test "a pidless lock is stolen once it ages out" {
    mkdir -p "$(tk_lock_dir a)"
    refute tk_lock a 120
    tk_lock a 0
}

@test "tk_locked is false for a lock whose holder is gone" {
    mkdir -p "$(tk_lock_dir a)"
    printf '999999' > "$(tk_lock_dir a)/pid"
    refute tk_locked a
}

@test "tk_unlock on an unheld lock succeeds" {
    tk_unlock never-held
}

@test "tk_with_lock runs the command and releases" {
    tk_with_lock a touch "$TEST_TMPDIR/ran"
    assert_file "$TEST_TMPDIR/ran"
    refute tk_locked a
}

@test "tk_with_lock releases even when the command fails" {
    # The trap is the point: without it a `set -e` death inside the command
    # leaks the lock forever.
    run tk_with_lock a false
    assert_fail
    refute tk_locked a
}

@test "tk_with_lock propagates the command's exit status" {
    run tk_with_lock a bash -c 'exit 7'
    assert_status 7
}

@test "tk_with_lock refuses when the lock is held" {
    tk_lock a
    run tk_with_lock a touch "$TEST_TMPDIR/should-not-exist"
    assert_fail
    refute_file "$TEST_TMPDIR/should-not-exist"
}

@test "the lock lives under the plugin data dir" {
    assert_eq "$(tk_lock_dir mine)" "$TK_DIR/.lock.mine"
}
