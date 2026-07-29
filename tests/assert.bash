# shellcheck shell=bash
# Assertions and test env for tmux-toolkit.
#
# ── Every assertion is a function call ───────────────────────────────
#
# Never a bare [[ ]] and never `! cmd`. bash 3.2 (the system bash on macOS, and
# a tier this suite must pass on) does not trip `set -e` or the ERR trap for
# either of those when they are not the last statement of the test body:
#
#   bash-3.2 -c 'set -e; f(){ [[ 1 == 2 ]]; echo REACHED; }; f'   -> REACHED
#   bash-3.2 -c 'set -e; f(){ ! true; echo REACHED; }; f'         -> REACHED
#
# A failing *function* call does propagate, on 3.2 as on 5.x, so wrapping is
# what makes an assertion load-bearing. This set is vendored from
# tmux-agent-mesh/tests/helpers.bash, where the suite was green across 227 tests
# while one of them asserted a value the code had never written.

TK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TK_LIB="$TK_ROOT/lib"
TK_STUB_DIR="$TK_ROOT/tests/stub"

_afail() { printf 'assertion failed: %s\n' "$*" >&2; return 1; }

assert_ok()     { [[ "$status" -eq 0 ]] || _afail "expected success, got status $status: $output"; }
assert_fail()   { [[ "$status" -ne 0 ]] || _afail "expected failure, got status 0: $output"; }
assert_status() { [[ "$status" -eq "$1" ]] || _afail "expected status $1, got $status: $output"; }

assert_eq()     { [[ "$1" == "$2" ]] || _afail "expected '$2', got '$1'"; }
assert_ne()     { [[ "$1" != "$2" ]] || _afail "expected anything but '$2'"; }
assert_num_eq() { [[ "$1" -eq "$2" ]] || _afail "expected $2, got '$1'"; }
assert_num_gt() { [[ "$1" -gt "$2" ]] || _afail "expected > $2, got '$1'"; }

assert_contains() { [[ "$1" == *"$2"* ]] || _afail "'$1' does not contain '$2'"; }
refute_contains() { [[ "$1" != *"$2"* ]] || _afail "'$1' unexpectedly contains '$2'"; }
# shellcheck disable=SC2053
assert_match()     { [[ "$1" == $2 ]] || _afail "'$1' does not match '$2'"; }
assert_empty()     { [[ -z "$1" ]] || _afail "expected empty, got '$1'"; }
assert_not_empty() { [[ -n "$1" ]] || _afail "expected a value, got empty"; }

assert_file()    { [[ -f "$1" ]] || _afail "no such file: $1"; }
refute_file()    { [[ ! -f "$1" ]] || _afail "file should not exist: $1"; }
assert_dir()     { [[ -d "$1" ]] || _afail "no such directory: $1"; }
refute_dir()     { [[ ! -d "$1" ]] || _afail "directory should not exist: $1"; }
assert_symlink() { [[ -L "$1" ]] || _afail "not a symlink: $1"; }

# `! cmd` has the same bash 3.2 problem as a bare [[ ]].
refute() { if "$@"; then _afail "expected '$*' to fail"; fi; }

# T4 contract tests generate their assertions from a grep over the source. A
# pattern that matches nothing makes the loop body run zero times and the test
# pass vacuously; tmux-agent-mesh shipped exactly that (tests/isolation.bats:80,
# a `^` anchor against indented lines) and it hid three dead options from a
# 318-test suite. Every generated list goes through this first.
assert_list_nonempty() {
    local label="$1"; shift
    [[ "$#" -gt 0 && -n "${1:-}" ]] || _afail "generated list '$label' is empty; the extraction pattern is broken, the test is vacuous"
}

# ── test env ─────────────────────────────────────────────────────────

# tk_setup - isolated dirs, stub tmux first on PATH, library sourced.
tk_setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export TK_DIR="$TEST_TMPDIR/data"
    export TK_STATE="$TEST_TMPDIR/state"
    export TK_STUB_LOG="$TEST_TMPDIR/tmux.log"
    export TK_STUB_FIXTURE="$TEST_TMPDIR/fixture"
    export TK_LOG_FILE="$TEST_TMPDIR/debug.log"
    mkdir -p "$TK_DIR" "$TK_STATE"
    : > "$TK_STUB_LOG"
    : > "$TK_STUB_FIXTURE"

    # Stub first on PATH. TK_TMUX_BIN stays `tmux` so the code under test
    # resolves it exactly as it does in production.
    export PATH="$TK_STUB_DIR:$PATH"
    unset TK_SOCKET TK_TMUX_DISABLED TMUX TMUX_PANE TMUX_TOOLKIT_DEV
    unset TK_LOADED

    # shellcheck source=../lib/toolkit.sh
    source "$TK_LIB/toolkit.sh"
    tk_init toolkit-test "$TK_DIR"
}

tk_teardown() {
    [[ -n "${TEST_TMPDIR:-}" && "$TEST_TMPDIR" == /*/* ]] || return 0
    rm -rf "$TEST_TMPDIR"
}

# ── T2: a real tmux server on a private socket ───────────────────────
#
# For anything whose correctness *is* tmux's behaviour rather than ours.
#
# -f /dev/null is mandatory: without it the developer's own .tmux.conf loads,
# which on this machine means five sibling plugins rewriting status-right and
# registering hooks inside the test server. Both tmux-agent-mesh and
# tmux-worktree learned that the hard way.
#
# The socket name carries the pid and the test number so a parallel run cannot
# collide, and so no test can ever address the developer's live server.
tk_setup_real() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export TK_DIR="$TEST_TMPDIR/data"
    export TK_STATE="$TEST_TMPDIR/state"
    export TK_LOG_FILE="$TEST_TMPDIR/debug.log"
    mkdir -p "$TK_DIR" "$TK_STATE"

    # TMUX_TMPDIR inside the per-test dir, so the socket is removed with it.
    # kill-server ends the server but leaves the socket file behind, which
    # otherwise litters /tmp/tmux-$UID with one file per test. It also makes a
    # socket-name collision with the developer's live server impossible rather
    # than merely unlikely.
    #
    # A unix socket path caps at ~104 bytes on this platform, and `mktemp -d`
    # under a deep TMPDIR plus tmux's own `tmux-$UID/<name>` suffix can exceed
    # it: tmux then fails with "File name too long" on every call, which reads
    # as a broken library rather than a broken path. Fall back to a short dir
    # when that would happen.
    TK_SOCKET="tk-test-${BATS_TEST_NUMBER:-0}"
    local sockdir="$TEST_TMPDIR"
    if [[ ${#sockdir} -gt 60 ]]; then
        sockdir="${TMPDIR:-/tmp}/tk$$"
        sockdir="${sockdir%/}"
        mkdir -p "$sockdir"
        TK_SOCKDIR_TMP="$sockdir"
    fi
    export TMUX_TMPDIR="$sockdir"
    export TK_SOCKET
    unset TK_TMUX_DISABLED TMUX TMUX_PANE TMUX_TOOLKIT_DEV TK_LOADED

    # A second session keeps the server alive if a test kills the first one.
    # Lifted from tmux-worktree's helper, where production code killing
    # "test-session" used to take the whole server down mid-file.
    command tmux -f /dev/null -L "$TK_SOCKET" new-session -d -s tk-main -x 80 -y 24
    command tmux -L "$TK_SOCKET" new-session -d -s tk-keepalive -x 80 -y 24

    # shellcheck source=../lib/toolkit.sh
    source "$TK_LIB/toolkit.sh"
    tk_init toolkit-test "$TK_DIR"
}

tk_teardown_real() {
    if [[ -n "${TK_SOCKET:-}" ]]; then
        command tmux -L "$TK_SOCKET" kill-server 2>/dev/null || true
    fi
    if [[ -n "${TK_SOCKDIR_TMP:-}" && "$TK_SOCKDIR_TMP" == "${TMPDIR:-/tmp}"/tk* ]]; then
        rm -rf "$TK_SOCKDIR_TMP"
        TK_SOCKDIR_TMP=""
    fi
    tk_teardown
}

# tk_skip_no_tmux - integration tiers are skipped, not failed, without tmux.
tk_skip_no_tmux() {
    command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
}

# tk_fixture <glob> <stdout> [exit] - teach the stub one answer.
#
# <stdout> is taken literally: pass real newlines for multi-line output and a
# real backslash for a backslash. The encoding to the stub's on-disk format is
# done here so no test has to think about it.
#
# Two encodings are in play and both bite:
#   * The record separator is \x1f, not a tab. Tab is IFS whitespace, so the
#     stub's `read` collapses runs of tabs and drops leading ones, which shifted
#     the exit code into the stdout field whenever stdout was empty.
#   * The stub emits stdout through `printf %b`, so a record must carry an
#     escaped form. Backslashes are doubled and newlines become \n here, which
#     makes %b reproduce the caller's string exactly.
tk_fixture() {
    local out="${2:-}"
    out="${out//\\/\\\\}"
    out="${out//$'\n'/\\n}"
    printf '%s\037%s\037%s\n' "$1" "$out" "${3:-0}" >> "$TK_STUB_FIXTURE"
}

# tk_calls - every recorded tmux argv.
tk_calls() { cat "$TK_STUB_LOG" 2>/dev/null || true; }

assert_called()  { assert_contains "$(tk_calls)" "$1"; }
refute_called()  { refute_contains "$(tk_calls)" "$1"; }
assert_call_count() {
    local n
    n="$(grep -c -- "$1" "$TK_STUB_LOG" 2>/dev/null || printf 0)"
    assert_num_eq "${n// /}" "$2"
}
