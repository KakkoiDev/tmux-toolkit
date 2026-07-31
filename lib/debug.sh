# shellcheck shell=bash
# debug.sh — structured JSON-line debug logging for every tk_* function.
#
# All tk_* functions in ALL modules should call debug helpers at entry, exit,
# and on error. The log lives at $TK_DIR/debug.log, one JSON object per line.
# Rotated at 1 MB.
#
# Format (grep-able, one JSON line per event):
#   {"ts":"2026-07-31T17:00:00","fn":"tk_pane_send","status":"ERR","detail":"pane dead: %5"}
#
# Non-blocking on purpose: append-only, no locks. Never fails the caller.
#
# Sourced from toolkit.sh so every module gets it for free.

# ── tunables ─────────────────────────────────────────────────────────

TK_DEBUG_MAX_BYTES="${TK_DEBUG_MAX_BYTES:-1048576}"  # 1 MB
TK_DEBUG_KEEP_BYTES="${TK_DEBUG_KEEP_BYTES:-524288}" # 512 KB after rotation

# ── log file ─────────────────────────────────────────────────────────

tk_debug_file() {
    printf '%s/debug.log' "${TK_DIR:-${TMPDIR:-/tmp}}"
}

# ── internal helper ──────────────────────────────────────────────────

# tk_debug_event <func_name> <status> [detail]
#
# Appends one JSON line. Status: OK, ERR, WARN, TRACE.
# Rotation is sampled: checked roughly 1 write in 100.
tk_debug_event() {
    local fn="${1:-unknown}" status="${2:-OK}" detail="${3:-}"
    local file ts
    file="$(tk_debug_file)"
    ts="$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
    [[ -n "$ts" ]] || ts="unknown"

    # Build JSON line: manual to avoid jq dependency.
    # Escape backslashes and double quotes in fn and detail.
    local esc_fn="${fn//\\/\\\\}"; esc_fn="${esc_fn//\"/\\\"}"
    local esc_d="${detail//\\/\\\\}"; esc_d="${esc_d//\"/\\\"}"

    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '{"ts":"%s","fn":"%s","status":"%s","detail":"%s"}\n' \
        "$ts" "$esc_fn" "$status" "$esc_d" >> "$file" 2>/dev/null || return 0

    # Sample rotation at ~1% rate.
    if [[ $(( RANDOM % 100 )) -eq 0 ]]; then
        tk_debug_rotate
    fi
    return 0
}

# ── public API ───────────────────────────────────────────────────────

# tk_debug_trace <func_name> — called at function entry.
tk_debug_trace() {
    local fn="${1:-unknown}"
    tk_debug_event "$fn" "TRACE" "entry"
}

# tk_debug_ok <func_name> [detail] — called on success.
tk_debug_ok() {
    local fn="${1:-unknown}"
    tk_debug_event "$fn" "OK" "${2:-}"
}

# tk_debug_err <func_name> <detail> — called on failure.
tk_debug_err() {
    local fn="${1:-unknown}" detail="${2:-}"
    tk_debug_event "$fn" "ERR" "$detail"
}

# tk_debug_warn <func_name> [detail] — called on warning.
tk_debug_warn() {
    local fn="${1:-unknown}"
    tk_debug_event "$fn" "WARN" "${2:-}"
}

# tk_debug <func_name> <status> [detail] — general purpose.
# status: OK, ERR, WARN
tk_debug() {
    local fn="${1:-unknown}" status="${2:-OK}" detail="${3:-}"
    tk_debug_event "$fn" "$status" "$detail"
}

# ── rotation ─────────────────────────────────────────────────────────

# tk_debug_rotate — rotate the debug log if it exceeds 1 MB.
# Keeps the most recent ~512 KB (tail of the file).
tk_debug_rotate() {
    local file size
    file="$(tk_debug_file)"
    [[ -f "$file" ]] || return 0
    size="$(wc -c < "$file" 2>/dev/null || printf 0)"
    size="${size// /}"
    if [[ "${size:-0}" -gt "$TK_DEBUG_MAX_BYTES" ]]; then
        # Keep the tail: count lines to approximate TK_DEBUG_KEEP_BYTES.
        # Use tail on bytes directly rather than line counting for
        # efficiency on large files.
        tail -c "$TK_DEBUG_KEEP_BYTES" "$file" > "$file.tmp" 2>/dev/null \
            && mv -f "$file.tmp" "$file" 2>/dev/null || true
    fi
    return 0
}

# tk_debug_rotate_now — force immediate rotation (for tests).
tk_debug_rotate_now() {
    local file
    file="$(tk_debug_file)"
    [[ -f "$file" ]] || return 0
    tail -c "$TK_DEBUG_KEEP_BYTES" "$file" > "$file.tmp" 2>/dev/null \
        && mv -f "$file.tmp" "$file" 2>/dev/null || true
    return 0
}

# ── tail ─────────────────────────────────────────────────────────────

# tk_debug_tail [n] — print the last n log entries (default 20).
tk_debug_tail() {
    local n="${1:-20}" file
    file="$(tk_debug_file)"
    [[ -f "$file" ]] || return 0
    tail -n "$n" "$file" 2>/dev/null || true
}

# tk_debug_clear — truncate the log (for tests).
tk_debug_clear() {
    local file
    file="$(tk_debug_file)"
    : > "$file" 2>/dev/null || true
}
