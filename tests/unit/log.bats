#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

@test "warn and error are written by default" {
    tk_warn "a warning"
    tk_error "an error"
    assert_contains "$(cat "$TK_LOG_FILE")" "a warning"
    assert_contains "$(cat "$TK_LOG_FILE")" "an error"
}

@test "info and debug are suppressed by default" {
    tk_info "chatter"
    tk_log debug "detail"
    refute_file "$TK_LOG_FILE"
}

@test "DEBUG_LOG=1 turns on debug, matching the existing plugins" {
    DEBUG_LOG=1
    tk_log debug "detail"
    assert_contains "$(cat "$TK_LOG_FILE")" "detail"
}

@test "DEBUG_LOG=0 leaves debug off" {
    DEBUG_LOG=0
    tk_log debug "detail"
    refute_file "$TK_LOG_FILE"
}

@test "TK_LOG_LEVEL overrides DEBUG_LOG" {
    DEBUG_LOG=1
    TK_LOG_LEVEL=error
    tk_warn "should not appear"
    tk_error "should appear"
    local out
    out="$(cat "$TK_LOG_FILE")"
    refute_contains "$out" "should not appear"
    assert_contains "$out" "should appear"
}

@test "each line carries a timestamp and its level" {
    tk_warn "msg"
    assert_match "$(cat "$TK_LOG_FILE")" '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] *'
    assert_contains "$(cat "$TK_LOG_FILE")" "[warn]"
}

@test "logging does not fork wc on every write" {
    # The implementations this replaces run `wc -l` for every single line, i.e.
    # a fork per log call on a path that fires ~12x per turn. Trimming here is
    # sampled instead, so 50 writes must not mean 50 stat/wc passes.
    local i
    for i in $(seq 1 50); do tk_warn "line $i"; done
    assert_num_eq "$(wc -l < "$TK_LOG_FILE" | tr -d ' ')" 50
}

@test "tk_log_trim bounds the file" {
    TK_LOG_MAX=20
    TK_LOG_KEEP=10
    local i
    for i in $(seq 1 40); do printf 'line %s\n' "$i" >> "$TK_LOG_FILE"; done
    tk_log_trim
    assert_num_eq "$(wc -l < "$TK_LOG_FILE" | tr -d ' ')" 10
    # Trimming keeps the tail, so the newest line must survive.
    assert_contains "$(cat "$TK_LOG_FILE")" "line 40"
    refute_contains "$(cat "$TK_LOG_FILE")" "line 1 "
}

@test "tk_log_trim leaves a file under the limit alone" {
    TK_LOG_MAX=100
    printf 'only\n' >> "$TK_LOG_FILE"
    tk_log_trim
    assert_num_eq "$(wc -l < "$TK_LOG_FILE" | tr -d ' ')" 1
}

@test "tk_log_trim is a no-op with no log file" {
    tk_log_trim
    refute_file "$TK_LOG_FILE"
}

@test "an unwritable log directory does not fail the caller" {
    # Logging is diagnostic. It must never be the reason a harness hook exits
    # non-zero.
    TK_LOG_FILE="/proc/nonexistent/deep/debug.log"
    tk_warn "msg"
}

@test "the log file defaults into the data dir" {
    TK_LOG_FILE=""
    assert_eq "$(tk_log_file)" "$TK_DIR/debug.log"
}

@test "tk_log creates the log directory" {
    TK_LOG_FILE="$TEST_TMPDIR/nested/deep/debug.log"
    tk_warn "msg"
    assert_file "$TK_LOG_FILE"
}
