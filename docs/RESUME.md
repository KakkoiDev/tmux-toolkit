# RESUME

Read this first, on any machine, in any fresh context. It is the entry point for
continuing the tmux-toolkit extraction: six repos, one shared `lib/`, a numbered
plan, and a bug audit that reproduces the state on demand.

Nothing here needs the machine it was written on. Everything that *does* depend on
that machine is listed under "What does not travel", so you can tell a real
regression from a missing local prerequisite.

## 1. What this project is

Five home-grown tmux plugins each re-implemented the same tmux plumbing. An
inventory found 26 duplicated capabilities, several byte-identical, several
drifted so the copy held the bugfix and the original held the bug.
`tmux-toolkit` is the extracted shared library; the other five vendor it at
`lib/` via `git subtree` from the toolkit's `dist` branch.

Full reasoning, the numbered step list D-0..D-21, the verified findings V1..V16
and the corrections C1..C8 are in **`docs/plan.md`**. That file is authoritative
for *what to do*. This file is authoritative for *how to get running*.

## 2. Clone layout

The default layout is `$HOME/Code/<repo>`. `consumers.txt` and
`tests/audit.sh` both assume it; the audit takes `CODE_ROOT` as an override, and
`consumers.txt` is one line per path so it can be edited.

All six are public. Use HTTPS: two of them have SSH remotes on the original
machine, which needs a key you may not have.

```sh
mkdir -p ~/Code && cd ~/Code
for r in tmux-toolkit tmux-agent-mesh tmux-agent-tracker \
         tmux-agent-resumer tmux-worktree tmux-session-order; do
    git clone "https://github.com/KakkoiDev/$r.git"
done
```

Default branches differ and this bites scripted checkouts:

| Repo | Default branch | Notes |
|---|---|---|
| `tmux-toolkit` | `main` | plus a `dist` branch, see below |
| `tmux-agent-mesh` | `master` | |
| `tmux-agent-tracker` | `master` | |
| `tmux-agent-resumer` | `master` | |
| `tmux-worktree` | `master` | 24 stars, so the published tmux floor stays 3.0 |
| `tmux-session-order` | `main` | |

### The `dist` branch needs a local ref

`dist` is a `git subtree split` of `lib/`, so its root *is* the library. A fresh
`git clone` puts it in `refs/remotes/origin/dist` and creates no local branch, and
`make dist-check` then fails with `no dist branch; run make release`. **Do not run
`make release`** to fix that: it would re-split and could move `dist`. Create the
local ref instead.

```sh
cd ~/Code/tmux-toolkit
git branch dist origin/dist
make dist-check          # should print: dist = <sha> (0.2.0), matches lib/ and origin
```

Never subtree from `main`: `subtree add --prefix=lib <toolkit> main` puts the repo
*root* at `lib/`, giving `lib/lib/core.sh` plus a copy of the tests and Makefile.
Never `subtree split --rejoin`, which writes a merge commit back onto `main` and
duplicates every release commit there. See correction C5 in `docs/plan.md`.

## 3. Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| `bash` | everything | **macOS `/bin/bash` 3.2 is a supported tier.** No bash-5-only syntax: no associative arrays, no `mapfile`, no namerefs. |
| `tmux` >= 3.0 | integration tests, all five plugins | published floor is 3.0; target is 3.7b |
| `bats` | every suite | `brew install bats-core` / `apt install bats` |
| `sqlite3` | tracker, resumer, mesh | |
| `jq` | mesh runtime, all three installers | resumer's runtime is deliberately jq-free, see below |
| `shellcheck` | lint | `-S warning` |
| `expect` | worktree `make test-e2e` only | the only tier that can assert a *rendered* menu |
| `git` >= 2.30 | worktree health checks | `git worktree repair` was added in 2.30 |

`python3` is used by four heredocs in `tmux-agent-resumer` and nothing else.

## 4. Verify you are at a known-good state

Run all of it before changing anything. These are the exact numbers as of
2026-07-30; a mismatch means either a real regression or a missing prerequisite
above, and the distinction matters.

```sh
cd ~/Code/tmux-toolkit      && make test        # expect 209 ok, 0 not ok
cd ~/Code/tmux-agent-mesh   && bats tests/      # expect 327
cd ~/Code/tmux-agent-tracker && bats tests/     # expect 274
cd ~/Code/tmux-agent-resumer && bats tests/     # expect 36
cd ~/Code/tmux-worktree     && make test        # expect 494  <- NOT `bats tests/`
cd ~/Code/tmux-session-order && bats tests/     # expect 12
```

**worktree needs `make test`, not `bats tests/`.** bats does not recurse into
subdirectories and its tests live in `tests/unit/` and `tests/integration/`.
`bats tests/` there prints exactly `1..0` and **exits 0**, so it looks like a
clean run and reports nothing. Verified in a fresh clone.

Every number above was verified in throwaway clones, not just in the original
working copies, so a mismatch on your machine is about your machine.

Then the two whole-project gates:

```sh
cd ~/Code/tmux-toolkit
./tests/audit.sh            # expect: 0 open, 13 fixed  (exits non-zero if any are open)
make dist-check             # expect: matches lib/ and origin
make sync-check             # expect: lib/ matches tmux-toolkit 0.2.0
./bin/tmux-toolkit consumers  # expect: 0.2.0 for all five
```

`tests/audit.sh` greps **code, not prose**, against a comment-stripped view of
each file. An earlier version matched the comment explaining a fix and reported
the fixed bug as open. `CODE_ROOT=<dir>` points it at a different checkout, which
is how each probe was proven decisive against the pre-fix trees.

## 5. Where you are

**Done:** D-0, D-0.5 (install half), D-1, D-2, **D-2b**, D-8, D-11, D-13 (partial),
D-19, and the bug fixes V4/V4b, V5, V6, V11, V12, V13, V14, V15, C6, NG-1, NG-2,
NG-3. Audit: **0 open, 13 fixed.** All five plugins vendor `lib/` at 0.2.0.

**Next, in this order.** The order deliberately disagrees with the D-number
sequence in `docs/plan.md`; the reason is in that file's order note.

1. **D-15, registry-based identity.** Spec in section C of `docs/plan.md`.
   Blocked on three human decisions, H.1/H.3/H.5 in that file's section H, and
   **H.1 is the one that matters**: the badge count goes from 4 to 7, so somebody
   has to say whether `kind:"background"` and subagent-spawned sessions are
   badge-worthy. Building against a guess risks rewriting the filtering and its
   tests. Recommended split: `lib/identity.sh` plus its tests first, with no
   consumer changes and nothing user-visible, then wire the consumers.
2. **D-4, worktree menus emit TSV rendered by `tk_menu_*`.** 627 lines of awk
   across 10 files, 4 `eval` sites, and 17 integration test files touch menus.
   Highest regression risk in the plan, and the gate is a **human** opening all
   six screens. Do it in a fresh context.
3. **Tracker's 11 `shellcheck -S warning` findings**, then add the gate to its CI
   in the same change. Ten of the eleven are glob `case` patterns inside
   `_map_codex_event`.

**Deferred with a reason, not forgotten:** NG-4 wants `tk_lock_steal`/`--preempt`
for newest-wins barge-in; wait until a second consumer proves it wants that shape.

### Re-measure the mesh roster finding

The finding that promoted D-15 was `mesh.db` rows with an empty `tmux_pane` that
no path can reap. Those ids are per-machine and change on every tmux server
restart, so re-measure rather than trusting any recorded value:

```sh
# mesh rows with no pane. Exclude 'human': it is paneless by design and
# cmd_cleanup skips it explicitly via $sid == $HUMAN_ID.
sqlite3 ~/.tmux-agent-mesh/mesh.db \
  "SELECT session_id FROM agents
   WHERE COALESCE(tmux_pane,'')='' AND session_id != 'human';"

# the registry, which is the only authority on liveness
claude agents --json | jq -r '.[] | "\(.sessionId) \(.status)"'
```

Three cases, and the third is why the obvious fix is wrong:

1. **In mesh, not in the registry** -> dead, and **unreapable by any path today**,
   because `cmd_cleanup` skips every row with an empty pane
   (`[[ -z "$pane" ]] && continue`).
2. **In both** -> a *live* paneless agent. Measured on 2026-07-30. This is why
   copying tracker's "reap paneless rows older than 10 minutes" would delete a
   working agent.
3. **In the registry, not in mesh** -> also measured, twice: two live sessions the
   mesh roster had never heard of. This is the other half of finding V1 (registry
   7 vs hooks 4), and it means D-15 has to reconcile in **both** directions, not
   just prune.

On the original machine at the time of writing, case 1 held for two rows and case
3 for two sessions.

## 6. What does not travel

Do not read any of these as a regression on a new machine.

- **tmux 3.7b.** Installed via Homebrew on the original machine, with a relocated
  bottle (`install_name_tool -change` plus an ad-hoc `codesign`). A new machine
  has whatever tmux it has. Everything here works on 3.0+; nothing requires 3.7b.
- **The pending server restart (D-0.5, second half).** On the original machine
  3.7b is linked but the running server is still 3.5a. Irrelevant elsewhere.
- **Live databases.** `~/.tmux-agent-tracker/tracker.db`,
  `~/.tmux-agent-resumer/resumer.db`, `~/.tmux-agent-mesh/mesh.db` and every
  `config_cache` are local state. A first run recreates them.
- **Old-format config caches.** Any `config_cache` written before D-2b lacks the
  `# tk-config v1 <ns>` marker. That is handled: the loader rejects an unmarked
  cache and rebuilds it. Nothing to migrate.
- **`~/.claude/plans/` and the agent task list.** Both were harness-local. The
  plan is now `docs/plan.md` in this repo; the task list is section 5 above.
- **`~/.tmux.conf`.** The plugins are loaded with `run-shell` from the original
  machine's config. `install.sh` in each repo does that wiring. Note that
  `~/.tmux.conf` and `~/.claude/settings.json` are **symlinks into a dotfiles
  repo** there, which is why every installer writes with `cat "$tmp" > "$target"`
  and never `mv` (findings V6 and C6).
- **Push state.** As of 2026-07-30 three repos were pushed and three were local
  only. If `git log` shows work you cannot find on GitHub, that is why. Verify
  with `git ls-remote origin <branch>` per repo rather than trusting
  `origin/<branch>`, which can be a stale local ref.

## 7. Rules that are load-bearing

Violating any of these has already broken something once.

- **Never edit `lib/` inside a consumer.** Every consumer's CI recomputes
  `lib/.checksum` and fails on drift. Fix the toolkit, `make release`, then
  `make fanout`. Editing in place is how 26 duplicates accumulated.
- **`make fanout` pulls from `$(CURDIR)`**, the local toolkit checkout, so the
  toolkit must be cloned and its `dist` ref must exist first (section 2).
- **Never put `send-keys` in `lib/`.** mesh's entire thesis is that it never types
  into a pane, pinned by a grep over its own tree, and it vendors this library. A
  contract test enforces it.
- **Never read `~/.claude/projects/**/*.jsonl`.** The vendor documents the format
  as internal and unstable, and `CLAUDE_CONFIG_DIR` relocates it.
- **Do not require tmux 3.8.** Unreleased, git-master only, and its headline
  feature is content scraping that `claude agents --json` already beats with an
  official API. Gate anything that needs it behind `tk_vers_ge 3.8`.
- **Every bug fix needs a test that fails on the pre-fix code**, and check *which*
  of your new tests actually fail there. Two of the three NG-3 tests do; the third
  passes on both on purpose, so an over-correction cannot pass either. Claiming
  all three fail would have been wrong, and was corrected before commit.
- **A green test is not a passing test.** Three separate times a test here was
  green while asserting nothing: a generative loop that iterated zero times
  (V12), 532 bare `[[ ]]` assertions inert under bash 3.2 errexit, and a tmux
  stub keyed on `$1` that stopped answering once a `-L` flag was prepended, which
  made "fails for tmux 2.x" pass because *no version at all* reads as too old.

## 8. Traps, all measured on real hardware

The full list is `docs/remaining-work.md`, under "Landmines". The ones most likely
to cost you an hour:

- **A test harness that awk-strips `^source ` lines swallows the vendored
  library.** Both mesh's `source_mesh_functions` and the tracker's
  `source_tracker_functions` do this, so `source .../lib/toolkit.sh` vanishes and
  every `tk_*` call dies with 127. Source `lib/toolkit.sh` in the test helper
  itself, and source the *real* library: a stubbed `tk_sql` lets `lib/` break with
  every suite green.
- **`"$TK_TMUX_BIN"` resolves to a shell function.** bash looks up the command
  word after expansion and finds a function before PATH, so existing in-process
  `tmux() { ... }` stubs keep working through `tk_tmux`. That is what makes
  routing call sites through the choke point safe.
- **zsh does not word-split an unquoted `$var`.** Two hook probes reported
  "nothing fires" for this reason. Write throwaway probes as `bash -s <<'SH'`.
- **`#{?@opt,#{@opt},default}` is not an option-with-default.** It returns the
  default for an option set to `""` *and* for one set to the string `"0"`. Use
  `tk_opt`. This is correction C1 and it would have silently defaulted every
  `@ns-debug-log 0`.
- **`tk_json` is jq-first and top-level only, so it is not a drop-in for a
  substring `_json_val`.** The resumer's depends on being depth-blind: a slice
  finds `.message.content[0].text` and `.text` is null on that record. Swapping it
  would classify every 429 as "unknown". Recorded at the call site in both
  tracker and resumer; both belong to D-15.
- **A unix socket path caps at ~104 bytes**, and `mktemp -d` under a deep
  `TMPDIR` plus tmux's own `tmux-$UID/<name>` can exceed it. It reads as a broken
  library ("File name too long"), not a broken path.
- **`pane-exited` does not fire on `kill-pane`.** The covering set is
  `pane-exited after-kill-pane window-unlinked session-closed`. Correction C8.

## 9. Document map

| File | What it is for |
|---|---|
| `docs/RESUME.md` | this file: bootstrap, verification, current position |
| `docs/plan.md` | authoritative step list D-0..D-21, findings V1..V16, corrections C1..C8, open items H.1..H.9 |
| `docs/remaining-work.md` | cold-read handoff: ground-truth table, the full landmine list, "do not do" |
| `docs/agent-surface-assessment.md` | what an agent-facing CLI would need |
| `docs/NG-report-agent-voice.md` | the first external consumer's findings NG-1..NG-5 |
| `tests/audit.sh` | bug state, reproducible, greps code not prose |
| `consumers.txt` | intended consumer list; `tmux-toolkit consumers` reports reality |

There is deliberately **no second copy of the step list**. Two copies of a step
list is how one of them goes stale and starts lying, which already happened once
in this project.
