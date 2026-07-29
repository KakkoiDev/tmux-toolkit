#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

PAYLOAD='{"session_id":"abc-123","cwd":"/tmp/x","stop_hook_active":true,"model":{"id":"opus"},"n":7}'
FLAT='{"session_id":"abc-123","model":"sonnet"}'
PRETTY='{
  "session_id": "pretty-1",
  "cwd": "/tmp/y"
}'

@test "tk_json reads a top-level string" {
    assert_eq "$(tk_json "$PAYLOAD" session_id)" "abc-123"
    assert_eq "$(tk_json "$PAYLOAD" cwd)" "/tmp/x"
}

@test "tk_json returns empty for a missing key" {
    assert_empty "$(tk_json "$PAYLOAD" nope)"
}

@test "tk_json handles a pretty-printed payload" {
    # The string-slice implementations in tracker and resumer match only
    # "key":"value" with no whitespace, so they silently returned nothing for
    # any harness that pretty-prints or puts a space after the colon.
    assert_eq "$(tk_json "$PRETTY" session_id)" "pretty-1"
}

@test "tk_json_bool detects a true boolean" {
    tk_json_bool "$PAYLOAD" stop_hook_active
}

@test "tk_json_bool is false for a missing or non-true key" {
    refute tk_json_bool "$PAYLOAD" nope
    refute tk_json_bool '{"x":false}' x
}

@test "tk_json_bool tolerates whitespace around the colon" {
    tk_json_bool '{"x" : true}' x
}

@test "tk_json_str_or_obj accepts an object shape" {
    # Harnesses disagree: "model":"opus" in some payloads, "model":{"id":...}
    # in others. .model.id on a string is a jq error, not null, so the type has
    # to be tested before it is indexed.
    assert_eq "$(tk_json_str_or_obj "$PAYLOAD" model)" "opus"
}

@test "tk_json_str_or_obj accepts a bare string shape" {
    assert_eq "$(tk_json_str_or_obj "$FLAT" model)" "sonnet"
}

@test "tk_json_str_or_obj is empty for a missing key" {
    assert_empty "$(tk_json_str_or_obj '{}' model)"
}

@test "tk_json_path reads a nested value" {
    local p='{"rate_limits":{"five_hour":{"used_percentage":42}}}'
    assert_eq "$(tk_json_path "$p" rate_limits.five_hour.used_percentage)" "42"
}

@test "tk_json_path is empty for a path that does not exist" {
    assert_empty "$(tk_json_path '{"a":{"b":1}}' a.z.q)"
}

@test "tk_json_path does not error when an intermediate is a scalar" {
    assert_empty "$(tk_json_path '{"a":1}' a.b.c)"
}

@test "tk_json_esc escapes quotes and backslashes" {
    assert_eq "$(tk_json_esc 'say "hi"')" 'say \"hi\"'
    assert_eq "$(tk_json_esc 'a\b')" 'a\\b'
}

@test "an escaped string rebuilds into valid JSON" {
    local raw='he said "it'"'"'s" \ done'
    local json
    json="{\"k\":\"$(tk_json_esc "$raw")\"}"
    assert_eq "$(tk_json "$json" k)" "$raw"
}

@test "tk_json_read takes the whole payload, not just the first line" {
    # `read -r` would drop every field after line one for a pretty-printing
    # harness.
    local got
    got="$(printf '%s' "$PRETTY" | tk_json_read)"
    assert_eq "$(tk_json "$got" cwd)" "/tmp/y"
}

@test "tk_need_jq passes when jq is installed" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    tk_need_jq
}

# ── degraded, no-jq path ─────────────────────────────────────────────

@test "the no-jq fallback still reads a flat payload and logs that it degraded" {
    # The fallback exists so SessionEnd can still deregister on a box without
    # jq. It is lossy, so it must be attributable rather than silent.
    local bin="$TEST_TMPDIR/nojq" c p
    mkdir -p "$bin"
    for c in bash sh env printf date grep sed tail wc mv mkdir dirname cat sqlite3 tmux uname; do
        p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$bin/$c"
    done
    refute test -x "$bin/jq"
    run env PATH="$bin" TK_LOG_FILE="$TEST_TMPDIR/nojq.log" TK_LOG_LEVEL=warn \
        bash -c "unset TK_LOADED; source '$TK_LIB/toolkit.sh'; tk_init t '$TK_DIR'; tk_json '$FLAT' session_id"
    assert_ok
    assert_eq "$output" "abc-123"
    assert_contains "$(cat "$TEST_TMPDIR/nojq.log" 2>/dev/null || true)" "degraded"
}
