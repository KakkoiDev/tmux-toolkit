#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

@test "tk_init sets the namespace and data dir" {
    tk_init agent-mesh "$TEST_TMPDIR/mesh"
    assert_eq "$TK_NS" "agent-mesh"
    assert_eq "$TK_DIR" "$TEST_TMPDIR/mesh"
}

@test "tk_init defaults the data dir from the namespace" {
    unset TK_DIR
    tk_init agent-mesh
    assert_eq "$TK_DIR" "$HOME/.tmux-agent-mesh"
}

@test "an explicit data dir beats the environment" {
    TK_DIR="$TEST_TMPDIR/from-env"
    tk_init agent-mesh "$TEST_TMPDIR/from-arg"
    assert_eq "$TK_DIR" "$TEST_TMPDIR/from-arg"
}

@test "tk_init requires a namespace" {
    run tk_init
    assert_fail
}

@test "tk_lib_dir and tk_plugin_dir resolve without init" {
    assert_eq "$(tk_lib_dir)" "$TK_LIB"
    assert_eq "$(tk_plugin_dir)" "$TK_ROOT"
}

@test "tk_require names every missing command, not just the first" {
    run tk_require definitely-not-a-command also-not-one
    assert_fail
    assert_contains "$output" "definitely-not-a-command"
    assert_contains "$output" "also-not-one"
}

@test "tk_require passes for commands that exist" {
    tk_require sh printf
}

@test "tk_mtime fails for a missing file rather than printing zero" {
    refute tk_mtime "$TEST_TMPDIR/nope"
}

@test "tk_mtime returns an epoch for a real file" {
    touch "$TEST_TMPDIR/f"
    local m
    m="$(tk_mtime "$TEST_TMPDIR/f")"
    assert_num_gt "$m" 1700000000
}

@test "tk_age reports a missing file as infinitely old" {
    # Callers all want a number here for a staleness test; an error would just
    # be re-handled identically at every call site.
    assert_num_gt "$(tk_age "$TEST_TMPDIR/nope")" 100000000
}

@test "tk_age is near zero for a file just written" {
    touch "$TEST_TMPDIR/f"
    local a
    a="$(tk_age "$TEST_TMPDIR/f")"
    [[ "$a" -ge 0 && "$a" -le 2 ]] || _afail "expected 0..2, got $a"
}

@test "tk_fresh is false for a missing file" {
    refute tk_fresh "$TEST_TMPDIR/nope" 60
}

@test "tk_fresh is true for a new file and false at ttl 0" {
    touch "$TEST_TMPDIR/f"
    tk_fresh "$TEST_TMPDIR/f" 60
    refute tk_fresh "$TEST_TMPDIR/f" 0
}

@test "tk_fmt_time formats an epoch on either platform" {
    assert_match "$(tk_fmt_time 1700000000)" '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'
}

# ── tk_cq ────────────────────────────────────────────────────────────

@test "tk_cq round-trips a value containing single quotes through source" {
    # This is the exact failure the escaping exists for: @<ns>-on-mail is a
    # user shell snippet, and an unescaped quote produced a cache that would
    # not parse, which a bare `source` under `set -euo pipefail` turned into
    # every hook, menu and refresh dying at once.
    local val="echo 'hi there' && x=\"y\""
    printf 'V=%s\n' "$(tk_cq "$val")" > "$TEST_TMPDIR/c"
    bash -n "$TEST_TMPDIR/c"
    # shellcheck disable=SC1090
    source "$TEST_TMPDIR/c"
    assert_eq "$V" "$val"
}

@test "tk_cq round-trips an empty value" {
    printf 'V=%s\n' "$(tk_cq "")" > "$TEST_TMPDIR/c"
    # shellcheck disable=SC1090
    source "$TEST_TMPDIR/c"
    assert_eq "${V-unset}" ""
}

@test "tk_cq round-trips a value with a newline" {
    local val="line1
line2"
    printf 'V=%s\n' "$(tk_cq "$val")" > "$TEST_TMPDIR/c"
    bash -n "$TEST_TMPDIR/c"
    # shellcheck disable=SC1090
    source "$TEST_TMPDIR/c"
    assert_eq "$V" "$val"
}

# ── library version ──────────────────────────────────────────────────

@test "tk_lib_version reads lib/VERSION" {
    assert_match "$(tk_lib_version)" '[0-9]*.[0-9]*.[0-9]*'
}

@test "tk_require_version accepts an equal or lower requirement" {
    tk_require_version "$(tk_lib_version)"
    tk_require_version 0.0.1
}

@test "tk_require_version dies on a newer requirement and says how to fix it" {
    run tk_require_version 999.0.0
    assert_fail
    assert_contains "$output" "make sync"
}
