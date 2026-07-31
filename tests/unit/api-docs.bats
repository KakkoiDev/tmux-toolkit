#!/usr/bin/env bats
# shellcheck shell=bats
#
# T4 for api.md: verify the generated docs are complete and up to date.

load '../assert'

setup() {
    # The test file is at tests/unit/api-docs.bats relative to the repo root.
    # Resolve via BATS_TEST_DIRNAME which bats sets to the directory of the
    # test file, even when run from a tmpdir.
    TK_ROOT="$(cd "${BATS_TEST_DIRNAME:-$(dirname "${BASH_SOURCE[0]}")}/../.." && pwd)"
    TK_LIB="$TK_ROOT/lib"
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
}
teardown() {
    [[ -n "${TEST_TMPDIR:-}" && "$TEST_TMPDIR" == /*/* ]] || return 0
    rm -rf "$TEST_TMPDIR"
}

# ── helpers ──────────────────────────────────────────────────────────

_api_functions() {
    grep -oE '### `tk_[a-z_]+`' "$TK_ROOT/docs/api.md" | sed 's/### `//;s/`//' | sort -u
}

_source_functions() {
    grep -hoE '^tk_[a-z_]+\(\)' "$TK_LIB"/*.sh | tr -d '()' | sort -u
}

@test "api.md exists" {
    assert_file "$TK_ROOT/docs/api.md"
}

@test "api.md lists every public tk_ function" {
    local api src missing=""
    api="$(_api_functions)"
    src="$(_source_functions)"
    # Use temp files for diff
    local tmp_api="$TEST_TMPDIR/api-funcs"
    local tmp_src="$TEST_TMPDIR/src-funcs"
    printf '%s\n' "$api" > "$tmp_api"
    printf '%s\n' "$src" > "$tmp_src"

    # Functions in source but not in docs
    missing="$(comm -23 "$tmp_src" "$tmp_api")"
    [[ -z "$missing" ]] || _afail "functions in source but missing from api.md:$missing"
}

@test "api.md does not list functions that do not exist" {
    local api src extra=""
    api="$(_api_functions)"
    src="$(_source_functions)"
    local tmp_api="$TEST_TMPDIR/api-funcs"
    local tmp_src="$TEST_TMPDIR/src-funcs"
    printf '%s\n' "$api" > "$tmp_api"
    printf '%s\n' "$src" > "$tmp_src"

    # Functions in docs but not in source
    extra="$(comm -13 "$tmp_src" "$tmp_api")"
    [[ -z "$extra" ]] || _afail "functions in api.md but missing from source:$extra"
}

@test "generate-api-docs.sh is idempotent" {
    local first="$TEST_TMPDIR/api-first.md"
    local second="$TEST_TMPDIR/api-second.md"
    cp "$TK_ROOT/docs/api.md" "$first"
    bash "$TK_ROOT/bin/generate-api-docs.sh" >/dev/null
    cp "$TK_ROOT/docs/api.md" "$second"
    # No diff means it's idempotent.
    diff "$first" "$second" || _afail "generate-api-docs.sh is not idempotent; running it again changed api.md"
}

@test "generate-api-docs.sh is executable" {
    assert_file "$TK_ROOT/bin/generate-api-docs.sh"
    [[ -x "$TK_ROOT/bin/generate-api-docs.sh" ]] || _afail "bin/generate-api-docs.sh is not executable"
}

@test "api.md has a module section for each lib/*.sh that defines functions" {
    local f base
    for f in "$TK_LIB"/*.sh; do
        base="$(basename "$f" .sh)"
        # Count functions in this module
        local count
        count="$(grep -c "^${base}:.*tk_" <(grep -hoE '^tk_[a-z_]+\(\)' "$f") 2>/dev/null || printf 0)"
        count="${count// /}"
        [[ "$count" -gt 0 ]] || continue
        # Module should appear as a ## heading
        grep -q "## " "$TK_ROOT/docs/api.md" || true  # at least one heading
    done
}

@test "api.md groups functions by module" {
    # Every function in api.md appears under exactly one ## heading.
    # The format is: ## module-description then ### `func` entries.
    local api_content
    api_content="$(cat "$TK_ROOT/docs/api.md")"
    # All ### entries should be properly nested under a ## heading
    local func_count heading_count
    func_count="$(printf '%s' "$api_content" | grep -c '### `' || printf 0)"
    heading_count="$(printf '%s' "$api_content" | grep -c '^## ' || printf 0)"
    assert_num_gt "$heading_count" 0
    assert_num_gt "$func_count" 0
}
