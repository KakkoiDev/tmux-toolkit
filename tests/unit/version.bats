#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

_v() { tk_fixture '-V' "tmux $1"; }

@test "tk_vers reads and strips the tmux -V prefix" {
    _v "3.5a"
    assert_eq "$(tk_vers)" "3.5a"
}

@test "tk_vers survives no tmux at all" {
    tk_fixture '-V' '' 1
    assert_eq "$(tk_vers)" "0.0"
    refute tk_vers_ge 3.0
}

@test "tk_vers_ge compares minor versions numerically, not lexically" {
    # jaclu/tmux-menus' concatenated-digit encoding makes 3.10 -> 310 and
    # 3.9 -> 39 and so reports 3.9 > 3.10. This is the regression test for
    # deliberately not copying that.
    _v "3.10"
    tk_vers_ge 3.9
    assert_num_eq "$TK_VERS_N" 3010
}

@test "tk_vers_ge rejects a requirement above the running version" {
    _v "3.5a"
    refute tk_vers_ge 3.8
    refute tk_vers_ge 4.0
}

@test "tk_vers_ge accepts equal and lower requirements" {
    _v "3.5a"
    tk_vers_ge 3.5
    tk_vers_ge 3.0
    tk_vers_ge 2.9
}

@test "a suffixed version satisfies an unsuffixed requirement" {
    _v "3.5a"
    tk_vers_ge 3.5
}

@test "an unsuffixed version does not satisfy a suffixed requirement" {
    _v "3.5"
    refute tk_vers_ge 3.5a
}

@test "suffix letters order within the same numeric version" {
    _v "3.7b"
    tk_vers_ge 3.7a
    tk_vers_ge 3.7b
    refute tk_vers_ge 3.7c
}

@test "next- builds are treated as their target version" {
    _v "next-3.8"
    tk_vers_ge 3.8
    assert_num_eq "$TK_VERS_N" 3008
}

@test "-rc suffixes are stripped" {
    tk_vers_parse "3.6-rc"
    assert_num_eq "$TK_P_N" 3006
}

@test "a version with no minor component parses as .0" {
    tk_vers_parse "4"
    assert_num_eq "$TK_P_N" 4000
}

@test "unparseable input fails rather than comparing as zero silently" {
    refute tk_vers_parse "not-a-version"
}

@test "tk_vers_ge memoizes both outcomes" {
    _v "3.5a"
    tk_vers_ge 3.0
    refute tk_vers_ge 3.9
    assert_contains "$TK_VERS_OK" "3.0"
    assert_contains "$TK_VERS_NO" "3.9"
}

@test "tk_vers only forks tmux once across many comparisons" {
    _v "3.5a"
    tk_vers_ge 3.0; tk_vers_ge 3.1; tk_vers_ge 3.2; tk_vers >/dev/null
    assert_call_count '^-V$' 1
}

@test "tk_vers_require names the plugin in its error" {
    _v "3.5a"
    run tk_vers_require 3.9 tmux-agent-mesh
    assert_fail
    assert_contains "$output" "tmux-agent-mesh requires tmux 3.9+"
    assert_contains "$output" "found 3.5a"
}
