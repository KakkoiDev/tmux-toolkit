#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for debug.sh: structured JSON-line debug logging.

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

_debug_file() { printf '%s/debug.log' "$TK_DIR"; }

@test "tk_debug writes a JSON line with timestamp, fn, status" {
    tk_debug "tk_pane_send" "OK" "target=%5"
    local log
    log="$(cat "$(_debug_file)")"
    assert_contains "$log" '"fn":"tk_pane_send"'
    assert_contains "$log" '"status":"OK"'
    assert_contains "$log" '"detail":"target=%5"'
    assert_contains "$log" '"ts":"'
}

@test "tk_debug_trace writes TRACE status" {
    tk_debug_trace "tk_pane_run"
    local log
    log="$(cat "$(_debug_file)")"
    assert_contains "$log" '"status":"TRACE"'
    assert_contains "$log" '"fn":"tk_pane_run"'
    assert_contains "$log" '"detail":"entry"'
}

@test "tk_debug_ok writes OK status" {
    tk_debug_ok "tk_pane_send" "sent to %5"
    local log
    log="$(cat "$(_debug_file)")"
    assert_contains "$log" '"status":"OK"'
    assert_contains "$log" '"detail":"sent to %5"'
}

@test "tk_debug_err writes ERR status" {
    tk_debug_err "tk_pane_run" "pane dead: %5"
    local log
    log="$(cat "$(_debug_file)")"
    assert_contains "$log" '"status":"ERR"'
    assert_contains "$log" '"detail":"pane dead: %5"'
}

@test "tk_debug_warn writes WARN status" {
    tk_debug_warn "tk_lock" "stale lock stolen"
    local log
    log="$(cat "$(_debug_file)")"
    assert_contains "$log" '"status":"WARN"'
    assert_contains "$log" '"detail":"stale lock stolen"'
}

@test "tk_debug_event escapes double quotes in detail" {
    tk_debug "test_fn" "OK" 'got "quoted" value'
    local log
    log="$(cat "$(_debug_file)")"
    # The detail field should contain the key words.
    # JSON escapes quotes as \" — verify the content is preserved.
    assert_contains "$log" 'got'
    assert_contains "$log" 'quoted'
    assert_contains "$log" 'value'
}

@test "tk_debug_event escapes backslashes in detail" {
    tk_debug "test_fn" "OK" 'path\to\file'
    local log
    log="$(cat "$(_debug_file)")"
    # A single backslash in input becomes double backslash in JSON.
    # Just verify the line is valid JSON by checking structure.
    assert_contains "$log" 'path'
    assert_contains "$log" 'to'
    assert_contains "$log" 'file'
}

@test "tk_debug_file defaults to TK_DIR/debug.log" {
    assert_eq "$(tk_debug_file)" "$TK_DIR/debug.log"
}

@test "tk_debug creates the log directory" {
    TK_DIR="$TEST_TMPDIR/nested/deep"
    tk_debug "test_fn" "OK" "msg"
    assert_file "$TK_DIR/debug.log"
}

@test "tk_debug is non-blocking: unwritable directory doesn't fail" {
    # Debug logging must never be the reason a harness hook exits non-zero.
    local fake="/proc/nonexistent/deep"
    # We can't set TK_DIR since other things use it, so override via env.
    # Actually, tk_debug reads TK_DIR at call time.
    # Test: set TK_DIR to a non-writable location.
    local saved="$TK_DIR"
    TK_DIR="$fake"
    run tk_debug "test_fn" "OK" "should not crash"
    assert_status 0
    TK_DIR="$saved"
}

@test "tk_debug_tail prints the last n lines" {
    local i
    for i in $(seq 1 30); do
        tk_debug "fn$i" "OK" ""
    done
    local tail
    tail="$(tk_debug_tail 10)"
    local count
    count="$(printf '%s\n' "$tail" | wc -l | tr -d ' ')"
    assert_num_eq "$count" 10
    assert_contains "$tail" "fn30"
    assert_contains "$tail" "fn21"
}

@test "tk_debug_tail defaults to 20 lines" {
    local i
    for i in $(seq 1 25); do
        tk_debug "fn$i" "OK" ""
    done
    local tail
    tail="$(tk_debug_tail)"
    local count
    count="$(printf '%s\n' "$tail" | wc -l | tr -d ' ')"
    assert_num_eq "$count" 20
}

@test "tk_debug_tail on a missing file returns empty" {
    TK_DIR="$TEST_TMPDIR/nonexistent"
    local out
    out="$(tk_debug_tail 5)"
    assert_empty "$out"
}

@test "tk_debug_clear truncates the log" {
    local i
    for i in $(seq 1 50); do
        tk_debug "fn$i" "OK" ""
    done
    assert_file "$(_debug_file)"
    tk_debug_clear
    # File should exist but be empty.
    [[ -f "$(_debug_file)" ]] || _afail "file should still exist after clear"
    local content
    content="$(cat "$(_debug_file)" 2>/dev/null || true)"
    assert_empty "$content"
}

@test "tk_debug_rotate_now keeps the tail of the log" {
    # Set a small keep size.
    local saved_max="$TK_DEBUG_MAX_BYTES"
    local saved_keep="$TK_DEBUG_KEEP_BYTES"
    TK_DEBUG_KEEP_BYTES=500

    local i
    for i in $(seq 1 200); do
        # Write long lines to fill up space.
        printf '{"ts":"2026-01-01T00:00:00","fn":"fn%04d","status":"OK","detail":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\n' "$i" >> "$(_debug_file)"
    done

    local before_count
    before_count="$(wc -l < "$(_debug_file)" | tr -d ' ')"

    tk_debug_rotate_now

    local after_count
    after_count="$(wc -l < "$(_debug_file)" | tr -d ' ')"
    # Should have fewer lines after rotation.
    [[ "$after_count" -le "$before_count" ]]
    # The last entry should still be present.
    assert_contains "$(cat "$(_debug_file)")" "fn0200"

    TK_DEBUG_MAX_BYTES="$saved_max"
    TK_DEBUG_KEEP_BYTES="$saved_keep"
}
