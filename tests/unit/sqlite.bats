#!/usr/bin/env bats
# shellcheck shell=bats

load '../assert'

setup() {
    tk_setup
    DB="$TEST_TMPDIR/t.db"
}
teardown() { tk_teardown; }

@test "tk_sql_init creates a table with WAL enabled" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    tk_sql_table_exists "$DB" t
    assert_eq "$(tk_sql "$DB" 'PRAGMA journal_mode;')" "wal"
}

@test "tk_sql_init is idempotent" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    tk_sql "$DB" "INSERT INTO t VALUES ('keep');"
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    assert_eq "$(tk_sql "$DB" 'SELECT a FROM t;')" "keep"
}

@test "tk_sql_init refuses DDL containing DROP TABLE" {
    # tmux-agent-tracker runs `DROP TABLE IF EXISTS sessions` from its .tmux
    # loader on every tmux server start, and prefix+r is bound to source-file,
    # so every config reload wiped live agent state. A shared helper must not
    # make that easy to reintroduce.
    run tk_sql_init "$DB" "DROP TABLE IF EXISTS t; CREATE TABLE t (a TEXT);"
    assert_fail
    assert_contains "$output" "refusing DDL containing DROP TABLE"
}

@test "the db is a parameter, so two databases cannot collide" {
    # All three existing implementations close over a bare \$DB. That is why
    # mesh.sh carries a six-line comment about an unprefixed name pointing the
    # tracker at mesh.db and killing its hooks.
    local a="$TEST_TMPDIR/a.db" b="$TEST_TMPDIR/b.db"
    tk_sql_init "$a" "CREATE TABLE IF NOT EXISTS ta (x TEXT);"
    tk_sql_init "$b" "CREATE TABLE IF NOT EXISTS tb (x TEXT);"
    tk_sql_table_exists "$a" ta
    tk_sql_table_exists "$b" tb
    refute tk_sql_table_exists "$a" tb
    refute tk_sql_table_exists "$b" ta
}

@test "tk_sql_esc doubles single quotes" {
    assert_eq "$(tk_sql_esc "it's")" "it''s"
    assert_eq "$(tk_sql_esc "a'b'c")" "a''b''c"
    assert_eq "$(tk_sql_esc "plain")" "plain"
}

@test "an escaped value survives a round trip" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    local val="it's a \"test\"; DROP TABLE t;--"
    tk_sql "$DB" "INSERT INTO t VALUES ('$(tk_sql_esc "$val")');"
    assert_eq "$(tk_sql "$DB" 'SELECT a FROM t;')" "$val"
    tk_sql_table_exists "$DB" t
}

@test "tk_sql_sep uses the requested separator" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT, b TEXT);"
    tk_sql "$DB" "INSERT INTO t VALUES ('x','y');"
    assert_eq "$(tk_sql_sep "$DB" '|' 'SELECT a,b FROM t;')" "x|y"
}

@test "tk_sql_json returns an empty array, not an empty string" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    assert_eq "$(tk_sql_json "$DB" 'SELECT a FROM t;')" "[]"
}

@test "tk_sql_json returns rows as JSON" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    tk_sql "$DB" "INSERT INTO t VALUES ('v');"
    assert_contains "$(tk_sql_json "$DB" 'SELECT a FROM t;')" '"a":"v"'
}

@test "tk_sql_has_column detects a column and its absence" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT, b INTEGER);"
    tk_sql_has_column "$DB" t a
    tk_sql_has_column "$DB" t b
    refute tk_sql_has_column "$DB" t missing
}

@test "tk_sql_table_exists is false for an absent table" {
    tk_sql_init "$DB" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    refute tk_sql_table_exists "$DB" other
}

@test "tk_sql_init creates the parent directory" {
    local nested="$TEST_TMPDIR/a/b/c/t.db"
    tk_sql_init "$nested" "CREATE TABLE IF NOT EXISTS t (a TEXT);"
    assert_file "$nested"
}
