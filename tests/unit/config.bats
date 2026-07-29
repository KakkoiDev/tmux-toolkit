#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

SPECS='KEYBINDING:@ns-keybinding:g ENABLED:@ns-enabled:on MAX_HOPS:@ns-max-hops:4'

_bulk() { tk_fixture 'show-options -g' "$1"; }

@test "tk_config_load assigns defaults when nothing is set" {
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_eq "$KEYBINDING" "g"
    assert_eq "$ENABLED" "on"
    assert_eq "$MAX_HOPS" "4"
}

@test "tk_config_load prefers set options over defaults" {
    _bulk '@ns-keybinding W
@ns-enabled off'
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_eq "$KEYBINDING" "W"
    assert_eq "$ENABLED" "off"
    assert_eq "$MAX_HOPS" "4"
}

@test "a whole namespace costs one fork" {
    _bulk '@ns-keybinding W'
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_call_count 'show-options -g' 1
    refute_called 'show-option -gqv'
}

@test "the cache is written and reused without touching tmux" {
    _bulk '@ns-keybinding W'
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_file "$TK_DIR/config_cache"
    : > "$TK_STUB_LOG"
    KEYBINDING=""
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_eq "$KEYBINDING" "W"
    assert_empty "$(tk_calls)"
}

@test "a stale cache is not used" {
    # tmux-agent-tracker's _load_config_fast sources the cache unconditionally,
    # so `tmux set -g @agent-tracker-color-idle red` never took effect until the
    # file happened to age out. This is the resumer's corrected behaviour.
    _bulk '@ns-keybinding OLD'
    # shellcheck disable=SC2086
    tk_config_load ns 60 $SPECS
    assert_eq "$KEYBINDING" "OLD"

    : > "$TK_STUB_FIXTURE"
    _bulk '@ns-keybinding NEW'
    # shellcheck disable=SC2086
    tk_config_load ns 0 $SPECS
    assert_eq "$KEYBINDING" "NEW"
}

@test "a truncated cache is rebuilt, not sourced" {
    # A bare `source` of a broken cache under `set -euo pipefail` aborts the
    # caller, which takes down every hook, menu and refresh at once, including
    # the one meant to diagnose it. Truncation mid-value is the realistic
    # corruption and leaves an unterminated quote, which bash -n does catch.
    printf '%s ns\nKEYBINDING=%s\n' "$TK_CONFIG_MARKER" "'unterminated" > "$TK_DIR/config_cache"
    _bulk '@ns-keybinding REBUILT'
    # shellcheck disable=SC2086
    tk_config_load ns 3600 $SPECS
    assert_eq "$KEYBINDING" "REBUILT"
}

@test "a cache with no format marker is rebuilt" {
    # This is the guard that matters across a lib/ version bump: bash -n is
    # weaker than it looks. Verified on bash 5.3 and 3.2, an unterminated array
    # assignment passes it --
    #     printf 'V=(a b\n' > f; bash -n f; echo $?   -> 0
    # -- and sourcing that same file aborts the caller. A syntax error cannot be
    # trapped, so provenance is checked instead of trusted.
    printf 'KEYBINDING=(a b\n' > "$TK_DIR/config_cache"
    _bulk '@ns-keybinding REBUILT'
    # shellcheck disable=SC2086
    tk_config_load ns 3600 $SPECS
    assert_eq "$KEYBINDING" "REBUILT"
}

@test "a cache written for another namespace is rebuilt" {
    printf '%s other\nKEYBINDING=%s\n' "$TK_CONFIG_MARKER" "'WRONG'" > "$TK_DIR/config_cache"
    _bulk '@ns-keybinding RIGHT'
    # shellcheck disable=SC2086
    tk_config_load ns 3600 $SPECS
    assert_eq "$KEYBINDING" "RIGHT"
}

@test "a value containing quotes survives the cache round trip" {
    _bulk '@ns-on-mail "notify-send '"'"'got mail'"'"'"'
    tk_fixture 'show-option -gqv @ns-on-mail' "notify-send 'got mail'"
    tk_config_load ns 60 'HOOK_ON_MAIL:@ns-on-mail:'
    assert_eq "$HOOK_ON_MAIL" "notify-send 'got mail'"

    bash -n "$TK_DIR/config_cache"
    HOOK_ON_MAIL=""
    tk_config_load ns 3600 'HOOK_ON_MAIL:@ns-on-mail:'
    assert_eq "$HOOK_ON_MAIL" "notify-send 'got mail'"
}

@test "a default may contain colons" {
    tk_config_load ns 60 'FMT:@ns-fmt:#{session_name}:#{window_index}.#{pane_index}'
    assert_eq "$FMT" '#{session_name}:#{window_index}.#{pane_index}'
}

@test "an option set to zero is not replaced by its default" {
    _bulk '@ns-debug-log 0'
    tk_config_load ns 60 'DEBUG_LOG:@ns-debug-log:1'
    assert_eq "$DEBUG_LOG" "0"
}

@test "an empty default yields an empty variable" {
    tk_config_load ns 60 'HOOK_ON_MAIL:@ns-on-mail:'
    assert_eq "${HOOK_ON_MAIL-unset}" ""
}

@test "tk_config_invalidate forces the next load to re-read" {
    _bulk '@ns-keybinding A'
    tk_config_load ns 3600 'KEYBINDING:@ns-keybinding:g'
    tk_config_invalidate
    refute_file "$TK_DIR/config_cache"
    : > "$TK_STUB_FIXTURE"
    _bulk '@ns-keybinding B'
    tk_config_load ns 3600 'KEYBINDING:@ns-keybinding:g'
    assert_eq "$KEYBINDING" "B"
}

@test "tk_config_fresh reflects cache age" {
    refute tk_config_fresh 60
    tk_config_load ns 60 'KEYBINDING:@ns-keybinding:g'
    tk_config_fresh 60
    refute tk_config_fresh 0
}

@test "no data dir means options load but nothing is created" {
    # A harness hook on a machine where the plugin is not installed must be
    # inert, not a directory-creating side effect.
    TK_DIR="$TEST_TMPDIR/not-installed"
    _bulk '@ns-keybinding W'
    tk_config_load ns 60 'KEYBINDING:@ns-keybinding:g'
    assert_eq "$KEYBINDING" "W"
    refute_dir "$TK_DIR"
    refute_file "$TK_DIR/config_cache"
}

@test "tk_config_prefix builds the option namespace" {
    assert_eq "$(tk_config_prefix agent-mesh)" "@agent-mesh-"
}
