# Remaining work

Handoff state for the tmux toolkit extraction. Written to be executable cold,
after a context reset, without re-reading the original plan.

**On a machine that has never seen this project, read `docs/RESUME.md` first.**
It carries the clone layout, the prerequisites, the verification commands with
their expected numbers, and the list of things that are machine-local and so are
not regressions. This file assumes you are already set up.

Authoritative step list: `docs/plan.md` (steps D-0..D-21, findings V1..V16,
corrections C1..C8, open items H.1..H.9, plus a dated status section at the top).
It used to live at `~/.claude/plans/we-have-powerful-tmux-eventual-sky.md`, which
was outside every repo and therefore did not survive a machine change; it is now
committed here.
Agent-surface assessment: `docs/agent-surface-assessment.md`.
Bug state, reproducible on demand: `tests/audit.sh`.
First external consumer's findings: `docs/NG-report-agent-voice.md`.

## Status 2026-07-30 (D-2b done)

**Bugs: 0 open, 13 fixed.** Run `tests/audit.sh`.

Done and pushed since the previous handoff: tmux 3.7b installed (server restart
still pending, human's call); V4 fixed with a four-hook covering set and a
debounce; `dist` pushed plus a `make dist-check` guard in CI; 532 bare `[[ ]]`
assertions converted across three repos; a new `_has_agent_child` bug fixed in
tracker and resumer; and **D-2b: all five plugins now vendor `lib/` at 0.2.0.**

**One step remains from the plan, D-4, and it should not be next.** D-15
(registry-based identity) is what fixes the roster noise, and there is now live
evidence it is needed. See the plan file's order note.

## Ground truth as of 2026-07-30

| Repo | Tests | Published | lib/ vendored |
|---|---|---|---|
| `tmux-toolkit` | 209 (189 unit + 20 integration) | public, 0.2.0, dist pushed | n/a (source) |
| `tmux-agent-mesh` | 327/327 | public | yes, 0.2.0 |
| `tmux-agent-tracker` | 274/274 | public | yes, 0.2.0 |
| `tmux-agent-resumer` | 36/36 | public | yes, 0.2.0 |
| `tmux-worktree` | 494/494 (`make test`, not `bats tests/`) | public, 24 stars | yes, 0.2.0 |
| `tmux-session-order` | 12/12 | public | yes, 0.2.0 |

Every suite green. `shellcheck -S warning` clean in toolkit, mesh, resumer and
session-order. The tracker has **11** pre-existing warnings, down from 14, and now
has CI (drift guard plus both bats tiers, no shellcheck gate until those 11 are
cleared). worktree has 9, unchanged, and its lint job is `|| true`.

Every consumer's CI runs the `lib/.checksum` drift guard, so a `lib/` edited in
place fails the build. `tmux-toolkit consumers` prints the version each one
actually has; `consumers.txt` is only the intended set.

bats runs test bodies under `/bin/bash` 3.2.57 here, so every run above is already
the bash 3.2 tier. **There is no bash 5 on this machine**; that tier exists only in
CI. Also measured: a bare `[[ ]]` and a negated `! cmd` are inert mid-body on 3.2,
but a bare `[ ]` is decisive, because `[[` is a compound command and errexit does
not apply to it inside a function.

**Environment:** tmux **3.7b** is installed and linked; the running server is still
**3.5a** (pid 9420 at time of writing). Upgrading needs a server restart, which
kills every live agent session, so it is the human's call. Rollback is
`ln -sf ../Cellar/tmux/3.5a/bin/tmux /opt/homebrew/bin/tmux`; the 3.5a keg is kept.

## Built in the toolkit

`lib/toolkit.sh` (hot path, for harness hooks): `core tmux version opt log json
sqlite config`.
`lib/toolkit-ui.sh` (interactive/install): the above plus `lock menu notify`.

**Not built:** `target.sh fmt.sh status.sh hook.sh sched.sh identity.sh
harness.sh`. The README names them as unbuilt, and five contract tests in
`tests/unit/contract.bats` fail if it ever claims otherwise.

## Next steps

The authoritative list is the "Left to do" section of `docs/plan.md`. This file
deliberately does not duplicate it, because two copies of a step list is how one
of them goes stale and starts lying.

Short form, in the order to do them:

1. **D-15, registry-based identity.** Promoted ahead of D-4. `mesh.db` currently
   holds three paneless rows; `claude agents --json` says two are dead and one is
   **live**. `cmd_cleanup` skips any row with an empty `tmux_pane`, so the two dead
   ones are reapable by no path at all, and copying tracker's "reap paneless rows
   older than 10 minutes" would delete the live one. Liveness has to come from the
   registry. This is also the step that unblocks the two `_json_val` deferrals
   recorded in tracker and resumer.
2. **D-4, worktree menus emit TSV rendered by `tk_menu_*`.** Rewrites the ten awk
   scripts and deletes `worktree_manager.sh`'s `eval "tmux display-menu ..."`.
   Highest regression risk in the plan; needs the human's six-screen manual
   re-verify, so it wants a fresh context.
3. **D-0.5, the tmux server restart.** Independent of both, and the human's call.
   3.7b is linked; the running server is still 3.5a. Not urgent: the live server
   already picked up the four new mesh cleanup hooks.

## Landmines, all verified on this machine

- `#{?@opt,#{@opt},default}` is **not** an option-with-default. It returns the
  default for an option set to `""` **and** for one set to the string `"0"`,
  because `#{?X,a,b}` is false for both. Would silently default every
  `@ns-debug-log 0`. Use `tk_opt` or `tk_opt_many`.
- `show-options -g` escaping cannot be undone by sequential substitution: the
  value `a\tb` renders as `a\\tb` and a real tab renders as `a\tb`.
  `tk_opt_cached` reforks for any value carrying escapes.
- A **tab is IFS whitespace**, so `IFS=$'\t' read -r a b c` collapses runs of
  tabs and drops leading ones. Any record format with optional fields must use
  `\x1f`. This will bite `identity.tsv`, whose `pane_id`, `target`, `tty` and
  `waiting_for` are all optional.
- `bash -n` passes `V=(a b`, and sourcing that file aborts the caller. A syntax
  error cannot be trapped, so provenance is checked via the cache format marker.
- `mv tmp config` **destroys a symlink**; `cat tmp > config` writes through. Both
  `~/.tmux.conf` and `~/.claude/settings.json` are dotfiles symlinks here. BSD
  `sed -i` refuses a symlink outright and aborts under `set -e`.
- `#{pane_current_command}` for a Claude pane is literally `2.1.220`, because
  claude rewrites argv[0]. Use a `ps -eo ppid,comm` child walk.
- `grep -c` prints its count **and** exits 1 when the count is zero, so
  `$(grep -c ... || printf 0)` yields `"0\n0"`.
- A unix socket path caps at ~104 bytes, and `mktemp -d` under a deep `TMPDIR`
  plus tmux's own `tmux-$UID/<name>` can exceed it. Failure reads as a broken
  library ("File name too long"), not a broken path.
- `read -r x < file` returns non-zero at EOF with no trailing newline **even
  though it assigned x**. Do not treat its status as "no value".
- A comment line starting with `# shellcheck` is parsed as a directive and fails
  with SC1072. Related and also real: a comment of `#`, then spaces, then a bare
  `!` is read as a malformed shebang and fails with SC1115 and SC1128, so a prose
  line like `#   ! true is inert` cannot be written that way.
- `tracker.sh cmd_refresh` runs from `status-right` every status-interval and
  used to ATTACH a world-writable `/tmp` file into the real database. Now
  overridable and ownership-checked. Any future code that reads a shared `/tmp`
  path into production state needs the same guard.
- **`ps -o comm` prints the executable as invoked, not its basename.** A bare PATH
  invocation reports `claude`; an absolute one reports
  `/opt/homebrew/bin/claude`. Any exact-match against a harness name must strip
  the path first. A `comm` can also contain spaces
  (`/Applications/Claude.app/.../Claude Helper (Renderer)` is running right now),
  so it must be read as the rest of the line and never as an awk field.
- **`pane-exited` does not fire on `kill-pane`.** Measured on 3.5a with
  `remain-on-exit` off: a pane whose process exits fires `pane-exited`; `kill-pane`
  fires only `after-kill-pane`; `kill-window` fires only `window-unlinked`;
  `kill-session` fires `session-closed`; `pane-died` never fires at all. Any
  "clean up when a pane goes away" hook needs all four names, and
  `window-layout-changed` is the wrong fifth because it also fires on every split
  and resize.
- `set-hook -gu 'name[N]'` removes one entry of a hook array and tmux does **not**
  renumber the survivors, so indices captured before a removal stay valid.
- **zsh does not word-split an unquoted `$var`.** The Bash tool's shell here is
  zsh, so a probe written as `for n in $names` iterates once with the whole string
  and every `tmux set-hook` in it fails as one bogus option name. Two hook probes
  reported "nothing fires" for this reason before the third was run under `bash`.
  Write throwaway probes with `bash -s <<'SH'`.
- Instrumenting a bare assertion as `if ! [[ A ]] || [[ B ]]` changes the meaning
  of a compound: it parses as `(!A) || B`, not `!(A || B)`, and manufactures
  failures the original line never had. Wrap the whole condition in `{ ...; }`.
- In `[[ $x == *"2*"* ]]` the quoted middle is a **literal** substring even though
  it contains a `*`; only the bare outer stars are wildcards. And the RHS of `=~`
  must be quoted when it becomes a function argument, or the shell strips the
  backslashes and `1!#\[default\]` silently turns `[default]` into a character
  class.
- **A test harness that awk-strips `^source ` lines swallows the vendored
  library.** Both mesh's `source_mesh_functions` and the tracker's
  `source_tracker_functions` strip every `source` line before evaluating the
  script, so `source .../lib/toolkit.sh` vanishes and every `tk_*` call dies with
  127. Source `lib/toolkit.sh` in the test helper itself, and source the real
  library rather than stubbing `tk_sql` and friends: a stub lets `lib/` break with
  every suite still green.
- **`"$TK_TMUX_BIN"` resolves to a shell function.** Measured: bash looks up the
  command word *after* expansion and finds a function before a builtin or PATH, so
  `TK_TMUX_BIN=tmux; "$TK_TMUX_BIN" -V` calls an in-process `tmux() { ... }` stub.
  That is what makes routing existing call sites through `tk_tmux` safe in suites
  that stub tmux as a function rather than as a fake binary.
- **A tmux stub keyed on `$1` breaks the moment a socket flag is prepended.**
  worktree's two version tests matched `-V` at `$1`, and its suite exports
  `TMUX_SOCKET`, so once the call went through `tk_tmux` the argv started with
  `-L`. One test failed and **the other passed for the wrong reason**: no version
  at all reads as too old, so "fails for tmux 2.x" was green while asserting
  nothing. Match the flag anywhere in `$*`.
- **A command-prefix assignment does not persist across a bash function call.**
  Measured on 3.2: `TK_LOG_LEVEL=debug tk_log debug msg` is seen inside the
  function and gone afterwards, even though POSIX permits a shell to keep it. This
  is the way to pass a dynamically-scoped value without shellcheck reporting SC2034
  for a `local` it cannot see being read.
- **`tk_config_load` only round-trips the specs**, so a variable *derived* from
  options must be recomputed after every call, not written into the cache. The
  tracker's `_HAS_HOOKS` is one: leaving it to the cache would mean a cache hit
  setting it to empty and `_fire_transition_hook` reading `${_HAS_HOOKS:-0}` as 0,
  silently stopping every user hook.
- **`tk_json` is jq-first and top-level only, so it is not a drop-in for a
  substring `_json_val`.** The resumer's looked identical but two of its three
  call sites depend on being depth-blind: `_json_val "$line" text` finds
  `.message.content[0].text` because a slice ignores depth, and `.text` is null on
  that record. Swapping it would have made every 429 classify as "unknown".

## Do not do

- Do not require or wait for tmux 3.8. Unreleased, no RC, git-master only. Its
  headline (`set-hook -B` monitor hooks) is content scraping that
  `claude agents --json` already beats with an official API. Gate it behind
  `tk_vers_ge 3.8` if built at all.
- Do not put `send-keys` in `lib/`. Mesh's whole thesis is that it never types
  into a pane, pinned by a grep over its own tree, and it vendors this library. A
  contract test enforces this.
- Do not read `~/.claude/projects/**/*.jsonl`. The vendor documents the format as
  internal and unstable, and `CLAUDE_CONFIG_DIR` relocates it.
- Do not ship a schema-migration ladder before a migration is needed. The
  constraint is byte-identical to every existing database;
  `_ensure_schema` documents the rebuild procedure instead.
- Do not build the agent CLI (`mux`) before step 5. It would parse menu-command
  strings and get rewritten. The `tmux-fleet` skill already documents the
  existing CLIs, which was the actual ask.
