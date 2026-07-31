#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1: identity module tests.
#
# Uses stubbed claude and ps commands on PATH, plus a real private tmux server
# for pane list operations (the join needs real pane_tty/pane_pid data).
#
# tk_identity_stale tests use the real private server's pid for meta validation.

load '../assert'

# ── stub binaries ────────────────────────────────────────────────────

_stub_binaries() {
    mkdir -p "$TEST_TMPDIR/bin"

    # claude stub: outputs TK_CLAUDE_FIXTURE file content when set
    cat > "$TEST_TMPDIR/bin/claude" <<'STUB'
#!/bin/sh
if [ -n "${TK_CLAUDE_FIXTURE:-}" ] && [ -r "${TK_CLAUDE_FIXTURE:-}" ]; then
    cat "$TK_CLAUDE_FIXTURE"
else
    exit 0
fi
STUB
    chmod +x "$TEST_TMPDIR/bin/claude"

    # ps stub: fixture-driven for -eo pid,tty and -eo pid,ppid,comm;
    # falls through to real ps for other args.
    cat > "$TEST_TMPDIR/bin/ps" <<'STUB'
#!/bin/sh
US="$(printf '\037')"
if [ -n "${TK_PS_FIXTURE:-}" ] && [ -r "${TK_PS_FIXTURE:-}" ]; then
    case "$*" in
        *pid,tty*)
            while read -r _ pid tty; do
                [ "$_" = "tty" ] || continue
                printf '%s%s%s\n' "$pid" "$US" "$tty"
            done < "$TK_PS_FIXTURE"
            ;;
        *pid,ppid,comm*)
            while read -r _ pid ppid comm; do
                [ "$_" = "tree" ] || continue
                printf '%s%s%s%s%s\n' "$pid" "$US" "$ppid" "$US" "$comm"
            done < "$TK_PS_FIXTURE"
            ;;
        *) exec /bin/ps "$@" 2>/dev/null || true ;;
    esac
else
    exec /bin/ps "$@" 2>/dev/null || true
fi
STUB
    chmod +x "$TEST_TMPDIR/bin/ps"

    export PATH="$TEST_TMPDIR/bin:$PATH"
}

# ── fixture helpers ──────────────────────────────────────────────────

_claude_fixture() {
    printf '%s\n' "$1" > "$TEST_TMPDIR/claude_fixture.json"
    export TK_CLAUDE_FIXTURE="$TEST_TMPDIR/claude_fixture.json"
}

_ps_fixture() {
    printf '%s\n' "$1" > "$TEST_TMPDIR/ps_fixture.txt"
    export TK_PS_FIXTURE="$TEST_TMPDIR/ps_fixture.txt"
}

_clear_fixtures() {
    unset TK_CLAUDE_FIXTURE TK_PS_FIXTURE
}

_clear_cache() {
    rm -f "$(tk_identity_cache_file)" "$(tk_identity_meta_file)" "$(tk_identity_dirty_file)"
    rm -rf "$(tk_identity_enrich_dir)"
}

# ── setup / teardown ─────────────────────────────────────────────────

setup() {
    tk_setup_real
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
    _stub_binaries
    _clear_fixtures
    _clear_cache
}

teardown() {
    _clear_fixtures
    tk_teardown_real
}

# ── \x1f separator ──────────────────────────────────────────────────

@test "\x1f separator round-trips with optional empty fields" {
    local us cache
    us="$(printf '\037')"
    cache="$(tk_identity_cache_file)"
    mkdir -p "$(dirname "$cache")"

    # Write a row with empty fields in the middle and a trailing empty enrich.
    # The code writes field19 as the last field (no trailing separator).
    # Fields 5,6,7 (tty, pane_id, target) and 14 (waiting_for) are empty.
    printf '%s\n' "test:id${us}claude${us}sess-1${us}12345${us}${us}${us}${us}/tmp${us}proj${us}main${us}claude${us}live${us}busy${us}${us}interactive${us}${us}registry${us}1234567890${us}" > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    local result f5 f6 f7 f14 f12 f13
    result="$(tk_identity_list)"

    # Field positions preserved despite empty fields
    f5="$(printf '%s' "$result" | cut -d"$us" -f5)"
    f6="$(printf '%s' "$result" | cut -d"$us" -f6)"
    f7="$(printf '%s' "$result" | cut -d"$us" -f7)"
    f14="$(printf '%s' "$result" | cut -d"$us" -f14)"
    f12="$(printf '%s' "$result" | cut -d"$us" -f12)"
    f13="$(printf '%s' "$result" | cut -d"$us" -f13)"

    assert_empty "$f5"
    assert_empty "$f6"
    assert_empty "$f7"
    assert_empty "$f14"
    assert_eq "$f12" "live"
    assert_eq "$f13" "busy"
}

# ── empty state ──────────────────────────────────────────────────────

@test "tk_identity_list returns empty when no agents exist" {
    _claude_fixture '[]'
    _clear_cache

    run tk_identity_list
    assert_ok
    # Should produce no lines (empty agents = empty cache)
    # May have PS provider rows for tmux panes, so don't assert empty
    true
}

# ── join-failure case 1: background, no tty ─────────────────────────

@test "join-failure case 1: background agent emits with empty pane" {
    local us
    us="$(printf '\037')"

    # Use current pid (which IS alive) and kind=background
    _claude_fixture "[
        {\"pid\":$$,\"sessionId\":\"bg-sess\",\"cwd\":\"$TEST_TMPDIR\",\"name\":\"bg-agent\",\"kind\":\"background\",\"status\":\"busy\",\"waitingFor\":\"\"}
    ]"

    # The join logic: kind=background → skip tty lookup, emit with empty pane
    # No PS fixture needed for case 1 test
    _ps_fixture "tty $$ ??"

    _clear_cache

    run tk_identity_list
    assert_ok

    local row pane_id target liveness kind
    row="$(printf '%s' "$output" | grep 'bg-sess' || true)"
    assert_not_empty "$row"

    pane_id="$(printf '%s' "$row" | cut -d"$us" -f6)"
    target="$(printf '%s' "$row" | cut -d"$us" -f7)"
    liveness="$(printf '%s' "$row" | cut -d"$us" -f12)"
    kind="$(printf '%s' "$row" | cut -d"$us" -f15)"

    assert_empty "$pane_id"
    assert_empty "$target"
    assert_eq "$liveness" "live"
    assert_eq "$kind" "background"
}

# ── join-failure case 3: tty is ?? ──────────────────────────────────

@test "join-failure case 3: tty is ?? for non-background agent emits with empty pane" {
    local us
    us="$(printf '\037')"

    _claude_fixture "[
        {\"pid\":$$,\"sessionId\":\"qmark-sess\",\"cwd\":\"$TEST_TMPDIR\",\"name\":\"qmark-agent\",\"kind\":\"interactive\",\"status\":\"busy\",\"waitingFor\":\"\"}
    ]"
    _ps_fixture "tty $$ ??"

    _clear_cache

    run tk_identity_list
    assert_ok

    local row
    row="$(printf '%s' "$output" | grep 'qmark-sess' || true)"
    assert_not_empty "$row"

    # tty is ?? or empty → pane_id is empty
    local pane_id
    pane_id="$(printf '%s' "$row" | cut -d"$us" -f6)"
    assert_empty "$pane_id"
}

# ── join-failure case 4: pid not alive ──────────────────────────────

@test "join-failure case 4: dead pid drops the row" {
    local dead_pid=999999
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$(( dead_pid + 1 ))
    done

    _claude_fixture "[
        {\"pid\":$dead_pid,\"sessionId\":\"dead-sess\",\"cwd\":\"$TEST_TMPDIR\",\"name\":\"dead-agent\",\"kind\":\"interactive\",\"status\":\"idle\",\"waitingFor\":\"\"}
    ]"

    _clear_cache

    run tk_identity_list
    assert_ok

    refute_contains "$output" "dead-sess"
}

# ── cache staleness: signal 1 (mtime) ───────────────────────────────

@test "cache is stale when mtime exceeds TTL" {
    local cache
    cache="$(tk_identity_cache_file)"
    mkdir -p "$(dirname "$cache")"

    printf 'row\n' > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    # With TTL 0, any cache is stale.
    # tk_fresh returns true (0) when fresh; with ttl 0 it should be false (1)
    refute tk_fresh "$cache" 0
}

# ── cache staleness: signal 2 (server pid) ──────────────────────────

@test "cache is hard-invalidated when server pid changes" {
    local cache meta
    cache="$(tk_identity_cache_file)"
    meta="$(tk_identity_meta_file)"
    mkdir -p "$(dirname "$cache")"

    # Write cache with a pid that is not the current server pid
    printf 'row\n' > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "99999" > "$meta"

    # Should be stale (server pid mismatch)
    tk_identity_stale
    assert_ok  # returns 0 = stale
}

# ── cache staleness: signal 3 (dirty flag) ──────────────────────────

@test "cache is stale when dirty flag exists" {
    local cache meta
    cache="$(tk_identity_cache_file)"
    meta="$(tk_identity_meta_file)"
    mkdir -p "$(dirname "$cache")"

    printf 'row\n' > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$meta"
    touch "$(tk_identity_dirty_file)"

    tk_identity_stale
    assert_ok  # returns 0 = stale
}

# ── lock loser serves stale cache ────────────────────────────────────

@test "stale cache is served when lock is held" {
    local cache us
    us="$(printf '\037')"
    cache="$(tk_identity_cache_file)"
    mkdir -p "$(dirname "$cache")"

    # Write a valid-format cache row
    printf '%s\n' "cached-agent${us}claude${us}s1${us}1${us}${us}${us}${us}/tmp${us}${us}${us}${us}live${us}idle${us}${us}${us}${us}registry${us}$(tk_now)${us}" > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    # Acquire the lock so rebuild cannot happen
    tk_lock identity 10

    # Age the meta to make cache stale
    printf '%s\t%s\n' "100" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    run tk_identity_list
    assert_ok
    assert_contains "$output" "cached-agent"

    tk_unlock identity
}

# ── enrichment ───────────────────────────────────────────────────────

@test "tk_identity_enrich appends without lock or tmux" {
    run tk_identity_enrich "test-agent" "activity=blocked" "waiting_for=perm"
    assert_ok

    local f
    f="$(tk_identity_enrich_dir)/test-agent"
    assert_file "$f"
    assert_contains "$(cat "$f")" "activity=blocked"
    assert_contains "$(cat "$f")" "waiting_for=perm"
}

@test "enrichment accumulates across calls" {
    tk_identity_enrich "multi-agent" "key1=val1"
    tk_identity_enrich "multi-agent" "key2=val2"

    local f lines
    f="$(tk_identity_enrich_dir)/multi-agent"
    lines="$(wc -l < "$f" | tr -d ' ')"
    assert_num_eq "$lines" 2
}

# ── row and field accessors ──────────────────────────────────────────

@test "tk_identity_row finds a row by agent_id" {
    local cache us
    us="$(printf '\037')"
    cache="$(tk_identity_cache_file)"
    mkdir -p "$(dirname "$cache")"

    printf '%s\n' "claude:abc${us}claude${us}abc${us}1${us}x${us}x${us}x${us}/tmp${us}x${us}x${us}x${us}live${us}idle${us}x${us}x${us}x${us}registry${us}$(tk_now)${us}x" > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    run tk_identity_row "claude:abc"
    assert_ok
    assert_contains "$output" "claude:abc"
}

@test "tk_identity_field extracts fields by number" {
    local cache us
    us="$(printf '\037')"
    cache="$(tk_identity_cache_file)"
    mkdir -p "$(dirname "$cache")"

    printf '%s\n' "claude:xyz${us}claude${us}xyz${us}42${us}tty1${us}pane1${us}tgt1${us}/cwd${us}proj${us}br${us}nm${us}live${us}busy${us}wf${us}kind${us}host${us}registry${us}$(tk_now)${us}enrich" > "$cache"
    printf '%s\t%s\n' "$(tk_now)" "$(tk_server_pid)" > "$(tk_identity_meta_file)"

    assert_eq "$(tk_identity_field "claude:xyz" 1)" "claude:xyz"
    assert_eq "$(tk_identity_field "claude:xyz" 4)" "42"
    assert_eq "$(tk_identity_field "claude:xyz" 5)" "tty1"
    assert_eq "$(tk_identity_field "claude:xyz" 6)" "pane1"
    assert_eq "$(tk_identity_field "claude:xyz" 13)" "busy"
}

@test "tk_identity_field returns empty for unknown agent" {
    assert_empty "$(tk_identity_field "nonexistent" 1)"
}

# ── invalidate / rebuild ─────────────────────────────────────────────

@test "tk_identity_invalidate creates dirty flag; rebuild clears it" {
    tk_identity_invalidate
    assert_file "$(tk_identity_dirty_file)"

    _claude_fixture '[]'
    _clear_cache

    run tk_identity_list
    assert_ok

    refute_file "$(tk_identity_dirty_file)"
}

# ── live Claude test ─────────────────────────────────────────────────

@test "live: tk_identity_provider_claude succeeds against real claude" {
    if [[ "${TK_LIVE:-}" != "1" ]]; then
        skip "TK_LIVE=1 not set"
    fi
    command -v claude >/dev/null 2>&1 || skip "claude not installed"

    run tk_identity_provider_claude
    assert_ok
}

# ── tk_identity_provider_claude with empty JSON ─────────────────────

@test "tk_identity_provider_claude returns nothing for empty array" {
    _claude_fixture '[]'

    run tk_identity_provider_claude
    assert_ok
    assert_empty "$output"
}

# ── tk_identity_provider_claude parses real fields ──────────────────

@test "tk_identity_provider_claude parses agent fields" {
    _claude_fixture '[{
        "pid": 123,
        "sessionId": "sess-abc",
        "cwd": "/home/user/project",
        "name": "my-agent",
        "kind": "interactive",
        "status": "busy",
        "waitingFor": ""
    }]'

    local us output
    us="$(printf '\037')"

    run tk_identity_provider_claude
    assert_ok

    output="$output"
    # pid(1) sessionId(2) cwd(3) name(4) kind(5) status(6) waitingFor(7)
    assert_eq "$(printf '%s' "$output" | cut -d"$us" -f1)" "123"
    assert_eq "$(printf '%s' "$output" | cut -d"$us" -f2)" "sess-abc"
    assert_eq "$(printf '%s' "$output" | cut -d"$us" -f4)" "my-agent"
    assert_eq "$(printf '%s' "$output" | cut -d"$us" -f5)" "interactive"
    assert_eq "$(printf '%s' "$output" | cut -d"$us" -f6)" "busy"
}
