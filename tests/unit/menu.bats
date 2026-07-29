#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup() {
    tk_setup
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
    tk_menu_reset
    export TK_MENU_DRYRUN=1
}
teardown() { tk_teardown; }

@test "a menu is title plus label/key/command triples" {
    tk_menu_title "Agents"
    tk_menu_item "one" "1" "run-shell 'x'"
    local out
    out="$(tk_menu_show)"
    assert_eq "$out" "$(printf -- '-T\nAgents\none\n1\nrun-shell '"'"'x'"'"'')"
}

@test "tk_menu_count counts rows, not arguments" {
    tk_menu_item a 1 c
    tk_menu_item b 2 c
    assert_eq "$(tk_menu_count)" "2"
}

@test "a separator is three empty fields" {
    tk_menu_item a 1 c
    tk_menu_sep
    assert_eq "$(tk_menu_count)" "2"
    assert_eq "$(tk_menu_show | wc -l | tr -d ' ')" "6"
}

@test "a hash in a label is stripped" {
    # tmux expands # in a label as a format, so a branch named fix#12 would
    # render as something else or error outright.
    tk_menu_item "fix#12" "1" "c"
    refute_contains "$(tk_menu_show)" "#"
}

@test "tk_menu_text makes an inert row" {
    tk_menu_text "no agents"
    assert_eq "$(tk_menu_show)" "$(printf 'no agents\n\n')"
}

@test "tk_menu_reset clears title and rows" {
    tk_menu_title T; tk_menu_item a 1 c
    tk_menu_reset
    assert_eq "$(tk_menu_count)" "0"
    assert_empty "$(tk_menu_show)"
}

# ── quoting, the reason this module exists ───────────────────────────

@test "tk_menu_cmd single-quotes every argument" {
    assert_eq "$(tk_menu_cmd /bin/x switch main)" "run-shell '/bin/x' 'switch' 'main'"
}

@test "tk_menu_cmd survives a path with a space" {
    assert_eq "$(tk_menu_cmd "/my dir/x" arg)" "run-shell '/my dir/x' 'arg'"
}

@test "tk_menu_cmd survives an apostrophe" {
    # A branch called fix/don't-crash. POSIX '\'' is the only portable escape.
    assert_eq "$(tk_menu_cmd /bin/x "fix/don't")" "run-shell '/bin/x' 'fix/don'\\''t'"
}

@test "a command quoted by tk_menu_cmd is what sh actually runs" {
    # The end-to-end check: the emitted string, parsed by sh, must yield the
    # original argv. This is what six layers of hand-written backslashes in
    # tmux-worktree's awk-generated menus kept getting wrong.
    local script="$TEST_TMPDIR/echo args"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' > "$script"
    chmod +x "$script"
    local cmd
    cmd="$(tk_menu_cmd "$script" "fix/don't" "two words" 'a$b' 'c;d')"
    local got
    got="$(eval "${cmd#run-shell }")"
    assert_eq "$got" "[fix/don't][two words][a\$b][c;d]"
}

@test "tk_menu_cmd does not expand a dollar sign" {
    assert_contains "$(tk_menu_cmd /bin/x 'a$HOME')" 'a$HOME'
}

@test "a semicolon in an argument cannot end the tmux command" {
    assert_eq "$(tk_menu_cmd /bin/x 'a;kill-server')" "run-shell '/bin/x' 'a;kill-server'"
}

# ── pagination ───────────────────────────────────────────────────────

@test "tk_menu_page computes pages and offset" {
    tk_menu_page 25 10 2
    assert_eq "$TK_PAGES" "3"; assert_eq "$TK_PAGE" "2"; assert_eq "$TK_OFFSET" "10"
}

@test "tk_menu_page clamps a page above the last one" {
    tk_menu_page 5 10 99
    assert_eq "$TK_PAGES" "1"; assert_eq "$TK_PAGE" "1"; assert_eq "$TK_OFFSET" "0"
}

@test "tk_menu_page clamps zero and negative pages" {
    tk_menu_page 25 10 0
    assert_eq "$TK_PAGE" "1"
    tk_menu_page 25 10 -3
    assert_eq "$TK_PAGE" "1"
}

@test "tk_menu_page treats a non-numeric page as the first" {
    tk_menu_page 25 10 "; rm -rf /"
    assert_eq "$TK_PAGE" "1"
}

@test "tk_menu_page reports one page when there is nothing to show" {
    tk_menu_page 0 10 1
    assert_eq "$TK_PAGES" "1"; assert_eq "$TK_OFFSET" "0"
}

@test "tk_menu_page survives a zero page size" {
    tk_menu_page 10 0 1
    assert_eq "$TK_PAGES" "10"
}

@test "an exact multiple does not produce a trailing empty page" {
    tk_menu_page 20 10 1
    assert_eq "$TK_PAGES" "2"
}

# ── the real call ────────────────────────────────────────────────────

@test "without the dry run it calls display-menu once" {
    unset TK_MENU_DRYRUN
    tk_menu_title T; tk_menu_item a 1 c
    tk_menu_show
    assert_called 'display-menu -T T a 1 c'
    assert_call_count 'display-menu' 1
}

@test "extra flags are passed through before the rows" {
    unset TK_MENU_DRYRUN
    tk_menu_title T; tk_menu_item a 1 c
    tk_menu_show -x C -y C
    assert_called 'display-menu -T T -x C -y C a 1 c'
}
