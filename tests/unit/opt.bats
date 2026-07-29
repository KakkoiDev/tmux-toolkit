#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

# The exact `show-options -g` rendering, probed on tmux 3.5a:
#   ''        set to empty
#   0         bare
#   "a b c"   double-quoted when it contains a space or #
#   a\\b      backslash doubled, still bare
_bulk() {
    tk_fixture 'show-options -g' "$1"
}

@test "tk_opt returns the value" {
    tk_fixture 'show-option -gqv @ns-key' 'W'
    assert_eq "$(tk_opt @ns-key X)" "W"
}

@test "tk_opt falls back to the default when empty or unset" {
    tk_fixture 'show-option -gqv @ns-key' ''
    assert_eq "$(tk_opt @ns-key fallback)" "fallback"
}

@test "tk_opt with no default yields empty, not the literal string" {
    assert_eq "$(tk_opt @ns-missing)" ""
}

# ── the bug this module exists to avoid ──────────────────────────────

@test "tk_opt_cached returns 0 for an option set to zero" {
    # The plan proposed `#{?@o,#{@o},default}` as a one-round-trip read. On
    # 3.5a that yields the DEFAULT for an option set to "0", because #{?X,,}
    # treats the string "0" as false. Silently defaulting every
    # @ns-debug-log 0 / @ns-completed-delay 0 is why that form is not offered.
    _bulk '@ns-debug-log 0'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-debug-log 7)" "0"
}

@test "tk_opt_cached returns the default for an unset option" {
    _bulk '@ns-other x'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-absent D)" "D"
}

@test "tk_opt_cached treats an explicitly-empty option as the default, like tk_opt" {
    _bulk "@ns-empty ''"
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-empty D)" "D"
}

@test "tk_opt_cached does not let one option name match a longer one" {
    # jaclu's trailing-space match is load-bearing: a plain prefix test makes
    # @ns-empty also match @ns-empty-extra.
    _bulk "@ns-empty ''
@ns-empty-extra TRAP"
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-empty D)" "D"
    assert_eq "$(tk_opt_cached @ns-empty-extra D)" "TRAP"
}

@test "tk_opt_cached asks tmux for a value carrying escapes" {
    # `a\tb` (literal backslash-t) renders as a\\tb, and `a<TAB>b` renders as
    # a\tb. Sequential \\ -> \ then \t -> TAB turns the first into the second,
    # so escaped values must come from the authoritative single-option read.
    _bulk '@ns-path a\\tb'
    tk_fixture 'show-option -gqv @ns-path' 'a\tb'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-path D)" 'a\tb'
    assert_called 'show-option -gqv @ns-path'
}

@test "tk_opt_cached asks tmux for a double-quoted value" {
    _bulk '@ns-msg "a b c"'
    tk_fixture 'show-option -gqv @ns-msg' 'a b c'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-msg D)" "a b c"
}

@test "tk_opt_cached does not fork for a plain value" {
    _bulk '@ns-icon *'
    tk_opt_bulk '@ns-'
    assert_eq "$(tk_opt_cached @ns-icon D)" "*"
    refute_called 'show-option -gqv @ns-icon'
}

@test "tk_opt_bulk costs one fork regardless of how many options are read" {
    _bulk '@ns-a 1
@ns-b 2
@ns-c 3
@ns-d 4'
    tk_opt_bulk '@ns-'
    tk_opt_cached @ns-a >/dev/null
    tk_opt_cached @ns-b >/dev/null
    tk_opt_cached @ns-c >/dev/null
    tk_opt_cached @ns-d >/dev/null
    assert_call_count 'show-options -g' 1
}

@test "tk_opt_names lists every option present" {
    _bulk '@ns-a 1
@ns-b 2'
    tk_opt_bulk '@ns-'
    local names
    names="$(tk_opt_names)"
    assert_contains "$names" "@ns-a"
    assert_contains "$names" "@ns-b"
}

# ── save/load across processes ───────────────────────────────────────

@test "a saved blob is readable without touching tmux" {
    _bulk '@ns-a 1'
    tk_opt_bulk_save '@ns-' "$TK_DIR/opts.cache"
    : > "$TK_STUB_LOG"
    TK_OPTS_BLOB=""
    tk_opt_bulk_load '@ns-' "$TK_DIR/opts.cache"
    assert_eq "$(tk_opt_cached @ns-a D)" "1"
    assert_empty "$(tk_calls)"
}

@test "loading a missing blob fails rather than reporting every option unset" {
    refute tk_opt_bulk_load '@ns-' "$TK_DIR/nope.cache"
}

# ── tk_opt_many ──────────────────────────────────────────────────────

@test "tk_opt_many reads several options in one round trip" {
    local tab
    tab="$(printf '\t')"
    tk_fixture 'display-message -p *' "W${tab}10${tab}q"
    local out
    out="$(tk_opt_many "$tab" @ns-key @ns-items @ns-quit)"
    assert_eq "$out" "W${tab}10${tab}q"
    assert_call_count 'display-message -p' 1
}

@test "tk_opt_many builds a format with no conditionals" {
    tk_fixture 'display-message -p *' 'x'
    tk_opt_many ':' @ns-a @ns-b >/dev/null
    assert_called '#{@ns-a}:#{@ns-b}'
    refute_called '#{?'
}

# ── tk_opt_into ──────────────────────────────────────────────────────

@test "tk_opt_into assigns into the named variable" {
    tk_fixture 'show-option -gqv @ns-key' 'Z'
    tk_opt_into MY_KEY @ns-key D
    assert_eq "$MY_KEY" "Z"
}

@test "tk_opt_into applies the default" {
    tk_opt_into MY_KEY @ns-absent D
    assert_eq "$MY_KEY" "D"
}

@test "tk_opt_into refuses a variable name that is not one" {
    run tk_opt_into 'x; rm -rf /' @ns-key D
    assert_fail
    assert_contains "$output" "invalid variable name"
}

@test "tk_opt_into refuses a name starting with a digit" {
    run tk_opt_into '1bad' @ns-key D
    assert_fail
}

@test "tk_opt_into preserves a value containing a quote" {
    tk_fixture 'show-option -gqv @ns-msg' "it's"
    tk_opt_into MY_MSG @ns-msg D
    assert_eq "$MY_MSG" "it's"
}

# ── writes ───────────────────────────────────────────────────────────

@test "tk_opt_set writes globally" {
    tk_opt_set @ns-key V
    assert_called 'set-option -g @ns-key V'
}

@test "tk_opt_unset uses -gu" {
    tk_opt_unset @ns-key
    assert_called 'set-option -gu @ns-key'
}
