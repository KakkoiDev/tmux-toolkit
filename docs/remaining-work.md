# Remaining work

Handoff state for the tmux toolkit extraction. Written to be executable cold,
after a context reset, without re-reading the original plan.

Original plan and the authoritative step list: `~/.claude/plans/we-have-powerful-tmux-eventual-sky.md`
(steps D-0..D-21, corrections C1..C8, plus a dated status section at the top).
Agent-surface assessment: `docs/agent-surface-assessment.md`.
Bug state, reproducible on demand: `tests/audit.sh`.
First external consumer's findings: `docs/NG-report-agent-voice.md`.

## Status 2026-07-30

**Bugs: 0 open, 10 fixed.** Run `tests/audit.sh`.

Done and pushed since the previous handoff: tmux 3.7b installed (server restart
still pending, human's call); V4 fixed with a four-hook covering set and a
debounce; `dist` pushed plus a `make dist-check` guard in CI; 532 bare `[[ ]]`
assertions converted across three repos; and a new `_has_agent_child` bug fixed
in tracker and resumer.

**Only two steps remain, both large refactors: D-2b and D-4.** Both are specified
in full in the plan file's "Left to do" section; that is the live copy, not this
file.

## Ground truth as of 2026-07-30

| Repo | Tests | Published | lib/ vendored |
|---|---|---|---|
| `tmux-toolkit` | 209 (189 unit + 20 integration) | public, 0.2.0, dist pushed | n/a (source) |
| `tmux-agent-mesh` | 327/327 | public | **yes, 0.1.0 - needs re-pull** |
| `tmux-agent-tracker` | 268/268 | public | no |
| `tmux-agent-resumer` | 33/33 | public | no |
| `tmux-worktree` | 493/493 (`make test`, not `bats tests/`) | public, 24 stars | no |
| `tmux-session-order` | 12/12 | public | no |

Every suite green. `shellcheck -S warning` clean in toolkit, mesh, resumer,
session-order, worktree. The tracker has 15 pre-existing warnings and no CI.

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

**Two left: D-2b and D-4.** Both are specified in full, with per-plugin notes and
the traps found vendoring mesh, in the "Left to do" section of
`~/.claude/plans/we-have-powerful-tmux-eventual-sky.md`. That is the live copy;
this file deliberately does not duplicate it, because two copies of a step list is
how one of them goes stale and starts lying.

Short form: D-2b vendors `lib/` into tracker, resumer, worktree and session-order
(`subtree add --prefix=lib ~/Code/tmux-toolkit dist --squash`, never `main`, never
`--rejoin`), re-pulls mesh off 0.1.0, and folds in NG-3. D-4 rewrites worktree's
ten awk scripts to emit TSV and renders them with `tk_menu_*`; it is the highest
regression risk in the plan and goes last.

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
