.PHONY: help test test-unit test-integration lint bash32 checksum sync-check dist fanout version

SHELL      := /bin/bash
LIB_FILES  := $(shell find lib -name '*.sh' | sort)
CHECKSUM   := lib/.checksum
VERSION    := $(shell cat lib/VERSION)

help:
	@printf 'tmux-toolkit %s\n\n' '$(VERSION)'
	@printf '  make test              unit + integration\n'
	@printf '  make test-unit         T1: stubbed tmux, no server\n'
	@printf '  make test-integration  T2: real tmux on a private socket\n'
	@printf '  make bash32            run the suite under /bin/bash 3.2 (macOS)\n'
	@printf '  make lint              shellcheck -S warning\n'
	@printf '  make checksum          regenerate lib/.checksum\n'
	@printf '  make sync-check        verify a vendored lib/ has not drifted\n'
	@printf '  make fanout            subtree-pull + test + commit in every consumer\n'

test: test-unit test-integration

test-unit:
	bats tests/unit/

test-integration:
	@if [ -d tests/integration ] && ls tests/integration/*.bats >/dev/null 2>&1; then \
		bats tests/integration/; \
	else \
		printf 'no integration tests yet\n'; \
	fi

# The tier that actually catches things: bats on macOS may pick up brew's bash 5,
# which defeats the point of testing the system bash. Pin it explicitly.
bash32:
	@if [ -x /bin/bash ] && /bin/bash --version | head -1 | grep -q 'version 3'; then \
		/bin/bash "$$(command -v bats)" tests/unit/; \
	else \
		printf 'no bash 3.2 at /bin/bash; skipping\n'; \
	fi

lint:
	shellcheck -S warning $(LIB_FILES) tests/stub/tmux bin/*

# ── vendoring guards ─────────────────────────────────────────────────
#
# The checksum is what stops "I edited lib/ inside the plugin and it diverged
# again", which is precisely how 26 duplicated capabilities accumulated across
# the five plugins in the first place.

checksum:
	@find lib -name '*.sh' | sort | xargs shasum | shasum | cut -d' ' -f1 > $(CHECKSUM)
	@printf 'lib/.checksum = %s\n' "$$(cat $(CHECKSUM))"

sync-check:
	@have=$$(find lib -name '*.sh' | sort | xargs shasum | shasum | cut -d' ' -f1); \
	want=$$(cat $(CHECKSUM) 2>/dev/null || printf 'missing'); \
	if [ "$$have" != "$$want" ]; then \
		printf 'lib/ has drifted from tmux-toolkit %s\n' '$(VERSION)' >&2; \
		printf '  expected %s\n  actual   %s\n' "$$want" "$$have" >&2; \
		printf 'Edit the toolkit repo and run `make fanout`, not lib/ in place.\n' >&2; \
		exit 1; \
	fi; \
	printf 'lib/ matches tmux-toolkit %s\n' '$(VERSION)'

version:
	@cat lib/VERSION

# Consumers vendor the library at their own lib/, so they cannot subtree from
# this repo's root: `subtree add --prefix=lib <toolkit> main` puts the whole repo
# there, giving lib/lib/core.sh plus a copy of the tests and this Makefile. The
# dist branch is a subtree split of lib/, so its root *is* the library.
#
# Never `subtree split --rejoin`: it writes a merge commit back onto main, so
# main accumulates a duplicate of every release commit. Re-splitting from
# scratch is deterministic and cheap.
dist:
	@git rev-parse --verify -q refs/heads/dist >/dev/null && git branch -D dist >/dev/null || true
	@git branch -f dist "$$(git subtree split --prefix=lib 2>/dev/null | tail -1)"
	@printf 'dist = %s (%s)\n' "$$(git rev-parse --short dist)" '$(VERSION)'

# fanout: push this lib/ into every consumer listed in consumers.txt, running
# that consumer's own suite before committing and stopping on the first red.
fanout: checksum dist
	@while read -r dir; do \
		case "$$dir" in ''|\#*) continue ;; esac; \
		dir=$$(eval printf '%s' "$$dir"); \
		if [ ! -d "$$dir/.git" ]; then printf 'skip (not a git repo): %s\n' "$$dir"; continue; fi; \
		if [ ! -d "$$dir/lib" ]; then printf 'skip (lib/ not vendored yet): %s\n' "$$dir"; continue; fi; \
		printf '\n=== %s\n' "$$dir"; \
		( cd "$$dir" && git subtree pull --prefix=lib "$(CURDIR)" dist --squash \
			-m "chore: sync tmux-toolkit $(VERSION)" ) || exit 1; \
		if [ -f "$$dir/Makefile" ]; then \
			( cd "$$dir" && $(MAKE) test ) || { printf 'TESTS FAILED in %s; stopping\n' "$$dir" >&2; exit 1; }; \
		else \
			( cd "$$dir" && bats tests/ ) || { printf 'TESTS FAILED in %s; stopping\n' "$$dir" >&2; exit 1; }; \
		fi; \
	done < consumers.txt
