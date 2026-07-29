#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2: real tmux on a private socket.
#
# Everything here asserts tmux's own behaviour, not ours. These started as
# one-off probes while designing lib/opt.sh; they live here so a future tmux
# release cannot change the contract underneath the library without a red test.

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
}
teardown() { tk_teardown_real; }

# ── the truthiness trap that killed tk_opt_fmt ───────────────────────

@test "a format conditional treats a set-empty option as false" {
    tk_tmux set-option -g @ns-x ""
    assert_eq "$(tk_tmux display-message -p '#{?@ns-x,SET,UNSET}')" "UNSET"
}

@test "a format conditional treats the string 0 as false" {
    # This is why `#{?@o,#{@o},default}` is not offered as an option-with-default
    # helper: it silently returns the default for every option a user
    # legitimately sets to zero.
    tk_tmux set-option -g @ns-zero "0"
    assert_eq "$(tk_tmux display-message -p '#{?@ns-zero,SET,UNSET}')" "UNSET"
    assert_eq "$(tk_tmux display-message -p '#{?@ns-zero,#{@ns-zero},DEFAULT}')" "DEFAULT"
}

@test "a format conditional is true for an ordinary value" {
    tk_tmux set-option -g @ns-v "hello"
    assert_eq "$(tk_tmux display-message -p '#{?@ns-v,#{@ns-v},DEFAULT}')" "hello"
}

@test "tk_opt gets zero right where a format conditional does not" {
    tk_tmux set-option -g @ns-zero "0"
    assert_eq "$(tk_opt @ns-zero 7)" "0"
}

# ── show-options rendering contract ──────────────────────────────────

@test "an unset user option is absent from show-options, a set-empty one is not" {
    # This is the only way to distinguish the two, and it is why the bulk read
    # exists alongside the per-option read.
    tk_tmux set-option -g @ns-empty ""
    local out
    out="$(tk_tmux show-options -g | grep '^@ns-' || true)"
    assert_contains "$out" "@ns-empty"
    refute_contains "$out" "@ns-never-set"
}

@test "show-options renders empty as '' and a bare value bare" {
    tk_tmux set-option -g @ns-empty ""
    tk_tmux set-option -g @ns-zero "0"
    local out
    out="$(tk_tmux show-options -g | grep '^@ns-' || true)"
    assert_contains "$out" "@ns-empty ''"
    assert_contains "$out" "@ns-zero 0"
}

@test "show-options double-quotes a value containing a space or a hash" {
    tk_tmux set-option -g @ns-spaces "a b c"
    tk_tmux set-option -g @ns-hash 'x#{y}'
    local out
    out="$(tk_tmux show-options -g | grep '^@ns-' || true)"
    assert_contains "$out" '@ns-spaces "a b c"'
    assert_contains "$out" '@ns-hash "x#{y}"'
}

@test "show-options doubles a backslash, which is why escaped values refork" {
    # value  a\b     renders  a\\b
    # value  a<TAB>b renders  a\tb
    # so `\\`->`\` then `\t`->TAB turns the literal a\tb into a<TAB>b. Undoing
    # this needs a single left-to-right pass; tk_opt_cached asks tmux instead.
    tk_tmux set-option -g @ns-back 'a\tb'
    tk_tmux set-option -g @ns-tab "$(printf 'a\tb')"
    local out
    out="$(tk_tmux show-options -g | grep '^@ns-' || true)"
    assert_contains "$out" '@ns-back a\\tb'
    assert_contains "$out" '@ns-tab a\tb'
}

@test "tk_opt_cached returns the true value for an escaped option" {
    tk_tmux set-option -g @ns-back 'a\tb'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-back D)" 'a\tb'
}

@test "tk_opt_cached returns the true value for a quoted option" {
    tk_tmux set-option -g @ns-msg "it's \"quoted\" and spaced"
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-msg D)" "it's \"quoted\" and spaced"
}

@test "a whole namespace round-trips through the bulk read" {
    tk_tmux set-option -g @ns-a "1"
    tk_tmux set-option -g @ns-b "two words"
    tk_tmux set-option -g @ns-c "0"
    tk_tmux set-option -g @ns-d ""
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-a X)" "1"
    assert_eq "$(tk_opt_cached @ns-b X)" "two words"
    assert_eq "$(tk_opt_cached @ns-c X)" "0"
    assert_eq "$(tk_opt_cached @ns-d X)" "X"
    assert_eq "$(tk_opt_cached @ns-absent X)" "X"
}

@test "one option name does not match a longer one against a real server" {
    tk_tmux set-option -g @ns-key "short"
    tk_tmux set-option -g @ns-key-extra "long"
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-key X)" "short"
    assert_eq "$(tk_opt_cached @ns-key-extra X)" "long"
}

# ── writes ───────────────────────────────────────────────────────────

@test "tk_opt_set then tk_opt round-trips" {
    tk_opt_set @ns-w "written"
    assert_eq "$(tk_opt @ns-w X)" "written"
}

@test "tk_opt_set round-trips a value with quotes and spaces" {
    local v="it's \"a\" value"
    tk_opt_set @ns-w "$v"
    assert_eq "$(tk_opt @ns-w X)" "$v"
}

@test "tk_opt_unset removes the option from show-options" {
    tk_opt_set @ns-w "x"
    tk_opt_unset @ns-w
    refute_contains "$(tk_tmux show-options -g | grep '^@ns-' || true)" "@ns-w"
}

@test "tk_opt_many reads several real options in one call" {
    tk_tmux set-option -g @ns-a "A"
    tk_tmux set-option -g @ns-b "B"
    local tab out
    tab="$(printf '\t')"
    out="$(tk_opt_many "$tab" @ns-a @ns-b)"
    assert_eq "$out" "A${tab}B"
}

@test "tk_opt_many returns an option set to zero as zero" {
    tk_tmux set-option -g @ns-z "0"
    assert_eq "$(tk_opt_many ':' @ns-z)" "0"
}

# ── socket routing ───────────────────────────────────────────────────

@test "TK_SOCKET keeps every call on the private server" {
    # The guard that stops a test suite from writing to the developer's live
    # server, where five plugins and seven agents are running.
    tk_opt_set @ns-isolation "private"
    assert_eq "$(command tmux -L "$TK_SOCKET" show-option -gqv @ns-isolation)" "private"
}

@test "tk_server_pid returns the private server's pid" {
    local pid
    pid="$(tk_server_pid)"
    assert_match "$pid" '[0-9]*'
    assert_num_gt "$pid" 1
}

@test "tk_tmux_ok is true against a live server" {
    tk_tmux_ok
}
