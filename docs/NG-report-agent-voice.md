# NG report: findings from the first external consumer

Filed by the agent building `~/Code/tmux-agent-voice`, the first plugin written
against `toolkit-ui.sh` rather than refactored onto it. Nothing here was fixed by
me: I do not have the context for the toolkit and another agent is mid-flight.

Verdict up front: **the 0.2.0 library is good work.** `lock.sh`, `menu.sh` and
`notify.sh` are correct, the rationale comments are worth more than the code, all
27 functions I reached for exist and behave as documented, 209 tests pass, 0 fail,
shellcheck is clean, and `sync-check` agrees with `lib/`. The findings below are
about release plumbing and one inherited tracker bug, not about the modules.

---

## NG-1. `dist` was stale, so the documented install silently vendors 0.1.0

**Severity: blocking.** This is the one that cost real time.

`README.md:16-27` tells a consumer to install with:

```sh
git subtree add --prefix=lib https://github.com/KakkoiDev/tmux-toolkit.git dist --squash
```

At the time I ran it, `dist` was still the 0.1.0 split. `git ls-tree -r --name-only dist`
returned eleven files: no `toolkit-ui.sh`, no `lock.sh`, no `menu.sh`, no `notify.sh`.
`git show dist:VERSION` said `0.1.0`.

The failure mode is the bad kind. Nothing errors. You get a `lib/` that passes
`sync-check` against its own stale `.checksum`, and the first symptom is
`tk_lock: command not found` from inside a hook, hours later.

I ran `make dist` to unblock myself. That rewrote only the local `dist` branch
ref, no source files, no push. Disclosing it because I was told afterwards not to
touch the toolkit; revert with `make dist` from any commit if you want it
elsewhere.

**Suggested fix, for you to judge:** make a stale `dist` impossible to commit
past rather than remembering to run a target. Either fold the check into
`sync-check` (compare `git show dist:VERSION` and the `dist` tree hash against
`lib/`), or add a `make release` that is the only sanctioned way to bump
`lib/VERSION` and which does `checksum` + `dist` together. `fanout: checksum dist`
already has the dependency right; the gap is that nothing warns when `lib/` is
committed without it.

## NG-2. `consumers.txt` claims five consumers; four have no `lib/` at all

```
tmux-agent-tracker       no lib/
tmux-agent-resumer       no lib/
tmux-agent-mesh          0.1.0
tmux-worktree            no lib/
tmux-session-order       no lib/
```

So `make fanout` cannot be walking this list successfully today, and the "26
duplicated capabilities" are still duplicated in four repos. `docs/remaining-work.md`
step 4 (D-2b) does say this is outstanding, so this is a completeness note rather
than a surprise. Flagging it because `consumers.txt` reads as a description of
reality and is currently a description of intent, and because `make fanout`
stopping on the first red suite means one un-vendored repo blocks the rest.

Also relevant to NG-1: mesh is pinned at 0.1.0, so it will not pick up
`toolkit-ui.sh` until it is re-pulled.

## NG-3. tracker's `_load_config_fast` sources its cache with no age check

**Not a toolkit bug, but it blocks any consumer that configures tracker.**

`config.sh`'s header already names this ("tmux-agent-tracker's `_load_config_fast`
(scripts/tracker.sh:618) sources the cache unconditionally"). It is still live at
the current line numbers:

```bash
# tracker.sh:696-701
local _cc="$TRACKER_DIR/config_cache"
if [[ -f "$_cc" ]]; then
    source "$_cc"
else
    load_config 2>/dev/null || true
fi
```

No mtime comparison anywhere. The consequence for me: after
`tmux set -g @agent-tracker-on-transition '<my script>'`, the cache still held
`HOOK_ON_TRANSITION=''`, and `_fire_transition_hook` checks `_HAS_HOOKS` from that
same cache, so my hook never fired and nothing said why. My `install.sh` deletes
`$TRACKER_DIR/config_cache` and my `doctor` asserts on the cache contents rather
than on the option, which is a workaround in the wrong repo.

This is exactly the bug `tk_config_load` was written to delete. Porting tracker
onto it (step 4's tracker note) fixes it for free.

## NG-4. `tk_lock` has no "steal from a live holder", which barge-in needs

Not a defect, a missing shape. `tk_lock` is deliberately non-blocking: acquire, or
return 1. That is right for a status render. It is wrong for a speaker, where the
newest utterance should win and the current holder should be terminated.

I composed it by hand instead: `tk_lock_dir` to find the pid file, TERM the
holder, `tk_unlock`, then `tk_lock`. That works because `tk_lock_dir` is public,
but every consumer that wants newest-wins will re-derive the same four lines.

**Suggested shape, if you agree it generalises:** `tk_lock_steal <name>`, or
`tk_lock <name> --preempt`, returning the pid it displaced so the caller can
decide how hard to kill it. Two consumers minimum would use it: this plugin, and
whatever eventually replaces resumer's `_try_lock`.

## NG-5. Landmine to add, verified while writing the test suite

The landmine list in `docs/remaining-work.md` earned its keep. One to add, which
cost me two false-green test runs:

> A stub `tmux` that resolves options from its **last argument** silently breaks
> `tk_opt_bulk`. `tk_opt` calls `show-option -gqv <key>`; `tk_opt_bulk` calls
> `show-options -g` with **no key** and greps the output by prefix. A stub keyed on
> `${!#}` answers `-g`, returns nothing, and every option falls back to its
> default. The tests then pass while exercising none of the options they name.

My gate suite had two tests passing this way before I caught it, and the only
reason I caught it was a test whose expected value differed from the default.
`tests/stub/tmux` in this repo does handle both forms; the trap is for consumers
writing their own. Worth a line in the README's Tests section, next to the
`assert_list_nonempty` note, which is the same class of failure.

## Nits, take or leave

- `README.md:66-70` still lists `toolkit-ui.sh` as carrying
  `target fmt menu status hook sched notify lock identity harness`.
  `lib/toolkit-ui.sh:11-14` has the honest list (menu, lock, notify) and says a
  contract test enforces it. The README is now the only place that overstates.
- `notify.sh` reads `@<ns>-on-<event>` for the *consumer's* namespace, which means
  a plugin cannot use it to read tracker's `@agent-tracker-on-*`. That is probably
  correct, but it meant `tk_notify` was not the integration point I first assumed
  it was, and the header does not say so.
