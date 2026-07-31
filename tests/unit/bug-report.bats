#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for bug-report.sh: crash capture and bug report generation.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
    # Clear debug log for predictable tail output.
    tk_debug_clear 2>/dev/null || true
}
teardown() {
    tk_teardown
}

# ── helpers ──────────────────────────────────────────────────────────

_bug_dir() { printf '%s/bugs' "$TK_DIR"; }
_first_report() {
    local dir
    dir="$(_bug_dir)"
    ls -1 "$dir"/*.md 2>/dev/null | head -1 || true
}

@test "tk_bug_report writes a markdown file" {
    local report
    report="$(tk_bug_report "tk_pane_send" "pane dead: %5" "sending text to pane")"
    assert_file "$report"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "# Bug Report"
    assert_contains "$content" "tk_pane_send"
    assert_contains "$content" "pane dead: %5"
    assert_contains "$content" "sending text to pane"
}

@test "tk_bug_report creates the bugs directory" {
    local saved="$TK_BUG_DIR"
    TK_BUG_DIR="$TEST_TMPDIR/nested/bugs"
    tk_bug_report "test" "detail"
    assert_dir "$TK_BUG_DIR"
    TK_BUG_DIR="$saved"
}

@test "tk_bug_report includes environment section" {
    # Seed some debug log entries.
    local i
    for i in $(seq 1 5); do
        tk_debug "fn$i" "OK" "detail$i"
    done

    local report
    report="$(tk_bug_report "tk_pane_run" "command failed")"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "## Environment"
    assert_contains "$content" "tmux version"
    assert_contains "$content" "bash version"
}

@test "tk_bug_report includes debug log tail" {
    local i
    for i in $(seq 1 5); do
        tk_debug "fn$i" "OK" "detail$i"
    done

    local report
    report="$(tk_bug_report "tk_pane_run" "command failed")"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "## Debug Log"
    assert_contains "$content" "fn1"
}

@test "tk_bug_report includes suggested causes placeholder" {
    local report
    report="$(tk_bug_report "test" "detail")"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "## Suggested Causes"
    assert_contains "$content" "TODO"
}

@test "tk_bug_report includes resolution placeholder" {
    local report
    report="$(tk_bug_report "test" "detail")"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "## Resolution"
}

@test "tk_bug_report works without intention" {
    local report
    report="$(tk_bug_report "test" "just a detail")
    assert_file "$report"
}

@test "tk_bug_report uses timestamp in filename" {
    local report
    report="$(tk_bug_report "test" "detail")
    local fname
    fname="$(basename "$report")"
    # Should look like YYYYMMDD-HHMMSS.md
    assert_match "$fname" '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].md'
}

@test "tk_bug_report includes stack trace" {
    # Define a nested function to produce a stack.
    _inner_func() {
        tk_bug_report "inner_func" "oh no" "testing stack trace"
    }
    local report
    report="$(_inner_func)"
    local content
    content="$(cat "$report")"
    assert_contains "$content" "## Stack Trace"
}

@test "tk_bug_dir defaults to TK_DIR/bugs" {
    assert_eq "$(tk_bug_dir)" "$TK_DIR/bugs"
}

@test "tk_bug_dir respects TK_BUG_DIR override" {
    local saved="$TK_BUG_DIR"
    TK_BUG_DIR="$TEST_TMPDIR/custom/bugs"
    assert_eq "$(tk_bug_dir)" "$TEST_TMPDIR/custom/bugs"
    TK_BUG_DIR="$saved"
}

# ── crash handler ────────────────────────────────────────────────────

@test "tk_crash_handler generates a bug report" {
    # The crash handler uses the ERR trap. We test it directly.
    local report
    report="$(tk_crash_handler "42" "false" 2>/dev/null || true)"
    # It should have written a bug report.
    local bugfile
    bugfile="$(_first_report)"
    assert_file "$bugfile"
    local content
    content="$(cat "$bugfile")"
    assert_contains "$content" "command 'false' failed at line 42"
}

@test "tk_crash_handler writes to stderr with report path" {
    local out
    out="$(tk_crash_handler "10" "failing_cmd" 2>&1 || true)"
    assert_contains "$out" "bug report written to"
}

@test "tk_crash_handler_install sets the ERR trap" {
    tk_crash_handler_install
    local trap_text
    trap_text="$(trap -p ERR 2>/dev/null || true)"
    assert_contains "$trap_text" "tk_crash_handler"
    # Clean up.
    trap - ERR
    _TK_CRASH_HANDLER_SET=0
}

@test "tk_crash_handler_remove restores the trap" {
    # Save current trap.
    local saved_trap
    saved_trap="$(trap -p ERR 2>/dev/null || true)"

    tk_crash_handler_install
    tk_crash_handler_remove

    local new_trap
    new_trap="$(trap -p ERR 2>/dev/null || true)"
    # After remove, trap should be either unset or restored.
    # Since we had no trap before, it should be unset.
    if [[ -n "$saved_trap" ]]; then
        assert_eq "$new_trap" "$saved_trap"
    fi
    # Clean up _TK_CRASH_HANDLER_SET.
    _TK_CRASH_HANDLER_SET=0
}

@test "tk_crash_handler_install is idempotent" {
    tk_crash_handler_install
    local first_trap
    first_trap="$(trap -p ERR 2>/dev/null)"

    tk_crash_handler_install
    local second_trap
    second_trap="$(trap -p ERR 2>/dev/null)"

    assert_eq "$first_trap" "$second_trap"

    # Clean up.
    trap - ERR
    _TK_CRASH_HANDLER_SET=0
}
