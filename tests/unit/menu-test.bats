#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for menu-test.sh: structural menu assertions against TK_MENU_ARGS.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
    # shellcheck source=../../lib/menu-test.sh
    source "$TK_LIB/menu-test.sh"
    tk_menu_test_reset
}
teardown() { tk_teardown; }

# ── reset ────────────────────────────────────────────────────────────

@test "tk_menu_test_reset clears the menu array" {
    tk_menu_item "a" "1" "cmd"
    tk_menu_test_reset
    assert_eq "$(tk_menu_test_count)" "0"
}

# ── add / add_sep ────────────────────────────────────────────────────

@test "tk_menu_test_add wraps tk_menu_item" {
    tk_menu_test_add "label" "k" "run-shell 'x'"
    assert_eq "$(tk_menu_test_count)" "1"
    tk_menu_test_assert_item 0 "label" "k"
}

@test "tk_menu_test_add_sep stages a separator" {
    tk_menu_test_add "a" "1" "c"
    tk_menu_test_add_sep
    assert_eq "$(tk_menu_test_count)" "2"
    # Separator has empty label and key
    tk_menu_test_assert_item 1 "" ""
}

# ── assert_count ─────────────────────────────────────────────────────

@test "tk_menu_test_assert_count passes for the right count" {
    tk_menu_item "a" "1" "c"
    tk_menu_item "b" "2" "c"
    tk_menu_test_assert_count 2
}

@test "tk_menu_test_assert_count fails for a wrong count" {
    tk_menu_item "a" "1" "c"
    run tk_menu_test_assert_count 99
    assert_fail
}

# ── assert_item ──────────────────────────────────────────────────────

@test "tk_menu_test_assert_item checks label and key exactly" {
    tk_menu_item "speaking: on" "e" "$(tk_menu_cmd voice.sh toggle-enabled)"
    tk_menu_test_assert_item 0 "speaking: on" "e"
}

@test "tk_menu_test_assert_item checks cmd_substring when given" {
    tk_menu_item "run" "r" "$(tk_menu_cmd /path/to/script.sh arg1 arg2)"
    tk_menu_test_assert_item 0 "run" "r" "script.sh"
}

@test "tk_menu_test_assert_item fails on a label mismatch" {
    tk_menu_item "apple" "a" "c"
    run tk_menu_test_assert_item 0 "orange" "a"
    assert_fail
}

@test "tk_menu_test_assert_item fails on a key mismatch" {
    tk_menu_item "apple" "a" "c"
    run tk_menu_test_assert_item 0 "apple" "z"
    assert_fail
}

# ── assert_has_key ───────────────────────────────────────────────────

@test "tk_menu_test_assert_has_key finds a key anywhere in the menu" {
    tk_menu_item "first" "a" "c"
    tk_menu_item "second" "b" "c"
    tk_menu_item "third" "c" "c"
    tk_menu_test_assert_has_key "b"
}

@test "tk_menu_test_assert_has_key fails when no item has the key" {
    tk_menu_item "first" "a" "c"
    run tk_menu_test_assert_has_key "z"
    assert_fail
}

# ── run ──────────────────────────────────────────────────────────────

@test "tk_menu_test_run executes the shell command for an item" {
    local marker="$TEST_TMPDIR/ran"
    tk_menu_item "go" "g" "$(tk_menu_cmd touch "$marker")"
    tk_menu_test_run 0
    assert_file "$marker"
}

@test "tk_menu_test_run executes multi-word commands" {
    local out="$TEST_TMPDIR/out"
    tk_menu_item "echo" "e" "$(tk_menu_cmd bash -c 'printf hello > "$1"' _ "$out")"
    tk_menu_test_run 0
    assert_eq "$(cat "$out")" "hello"
}

@test "tk_menu_test_run fails when the item has no run-shell command" {
    tk_menu_item "inert" "i" ""
    run tk_menu_test_run 0
    assert_fail
}

# ── done ─────────────────────────────────────────────────────────────

@test "tk_menu_test_done clears the menu" {
    tk_menu_item "a" "1" "c"
    tk_menu_item "b" "2" "c"
    tk_menu_test_done
    assert_eq "$(tk_menu_count)" "0"
}

# ── integration with real menu-building (the use case from the brief) ─

@test "full workflow: build a menu, assert structure, run an item" {
    tk_menu_test_reset

    tk_menu_item "speaking: on" "e" "$(tk_menu_cmd voice.sh toggle-enabled)"
    tk_menu_item "voice: Daniel" "v" "$(tk_menu_cmd voice.sh cycle-voice)"

    tk_menu_test_assert_count 2
    tk_menu_test_assert_item 0 "speaking: on" "e"
    tk_menu_test_assert_has_key "v"

    # Execute item 0 — the toggle. Since voice.sh doesn't exist, use a
    # real command that writes a marker.
    local marker="$TEST_TMPDIR/toggled"
    tk_menu_test_reset
    tk_menu_item "toggle" "t" "$(tk_menu_cmd touch "$marker")"
    tk_menu_test_run 0
    assert_file "$marker"

    tk_menu_test_done
    assert_eq "$(tk_menu_count)" "0"
}
