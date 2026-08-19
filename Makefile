.PHONY: check realm-test chain-test txtar-test isolation-test mutate selftest fmt vet gotest chat anchors paths guards staleguards \
	scenarios scenarios-check demo-physics height-shim dump-demo seed-demo web-test web-visual

# Everything that can run without a node.
#
# realm-test skips cleanly with no gno toolchain and says so; REQUIRE_GNO=1
# makes a missing toolchain a failure instead of a quiet pass.
check: fmt vet gotest anchors paths guards staleguards demo-physics scenarios-check web-test height-shim realm-test

# Guards that need no gno toolchain, kept OUT of realm-test on purpose: that
# target exits 0 early when gno is missing, so every guard inside it is skipped
# on a machine without one. Neither of these needs a toolchain, a staged tree or
# a lock, so neither should be switched off by a missing binary. check-paths.py
# was inside realm-test and moved here for that reason, and
# demo-physics/scenarios-check followed it for the same one — both are pure
# Python and were silently skipped on a toolchain-less machine.
anchors:
	python3 scripts/check-mutation-anchors.py

paths:
	python3 scripts/check-paths.py

# Every committed guard is named in selftest-checks.py, so an unarmed one fails
# here rather than in the next periodic selftest — which is days later and fails
# for a reason unrelated to whatever its author is doing. Costs a directory
# listing; runs no arms and touches no file.
guards:
	python3 scripts/check-guards-armed.py

# Every crossing entrypoint refuses a stale realm frame. No test can assert this
# — cross() is IsCurrent-strict, so a returned frame cannot be handed to an
# entrypoint from any harness — which is why the invariant is held by reading, and
# why a machine should do the reading.
staleguards:
	python3 scripts/check-stale-guards.py

demo-physics:
	python3 scripts/check-demo-physics.py

# Every height read in the realm must go through heightNow(), or a seeded
# chain sees two different heights in one transaction. 65 call sites; nobody
# re-checks those by eye.
height-shim:
	python3 scripts/check-height-shim.py

# The overlay's own regression suite. It lived in a scratch directory until r31,
# where it could not be enumerated: two harnesses had been broken for fourteen
# rounds by a rename, and ten more by one commit that was reported green because
# only four were run by hand. Skips cleanly with no node, like realm-test does
# with no gno; REQUIRE_NODE=1 makes a missing node a failure instead.
# The browser half: real layout measurement, needs puppeteer. NOT in `check` —
# it wants a headless Chrome, and the gate must not. It caught a grid rule that
# put the whole page body below the sidebar, which reading the CSS did not.
web-visual:
	@if ! command -v node >/dev/null 2>&1; then \
		echo "node not installed - skipping browser checks"; exit 0; \
	fi; \
	node web/tests/browser/run.js

web-test:
	@if ! command -v node >/dev/null 2>&1; then \
		if [ -n "$$REQUIRE_NODE" ]; then echo "node not installed"; exit 1; fi; \
		echo "node not installed - skipping web tests"; exit 0; \
	fi; \
	node web/tests/run.js

# Regenerate the chain-true half of the demo dataset from a seeded node. NOT part
# of `check`: it needs a running chain, and `check` must not. Seed one first with
# scripts/seed-node.sh, then point this at it via REMOTE=.
dump-demo:
	python3 scripts/dump-demo.py --remote "$${REMOTE:-http://127.0.0.1:26657}"

seed-demo:
	sh scripts/seed-node.sh scenarios/deep.py

# `gofmt -l` PRINTS the offenders and exits 0, so this target was permanently
# green: it listed unformatted files and passed anyway. Harmless while every Go
# file in the tree was behind a build tag and gofmt found nothing; a real gate now
# that internal/ and cmd/ exist.
fmt:
	@out=$$(gofmt -l .); \
	if [ -n "$$out" ]; then echo "unformatted:"; echo "$$out"; exit 1; fi; \
	echo "gofmt: clean"

vet:
	go vet -tags gnochain ./...

# The Go tests. `go test ./...` matched NO packages until the chat service arrived —
# every file in the tree was behind a gnochain or txtar tag — so `check` had no Go
# test step at all and 162 subtests would have sat in the tree unrun. That is
# exactly the position web/tests/ was in before it got a runner.
gotest:
	go test ./internal/... ./cmd/...

# The off-chain chat service: an HTTP server, an Ollama-backed scanner, and the
# operator CLI. Three binaries into ./bin, which is not committed.
#
# Nothing here touches a realm: chat needs a client address, a wall clock and a
# mutable moderation record, none of which a deterministic VM has.
chat:
	@mkdir -p bin
	go build -o bin/kourtchat    ./cmd/kourtchat
	go build -o bin/kourtmod     ./cmd/kourtmod
	go build -o bin/kourtchatctl ./cmd/kourtchatctl
	@echo "built bin/kourtchat bin/kourtmod bin/kourtchatctl"

# The realms' own tests, plus the three guards that hold the documentation to
# the code.
#
# They have to run from inside GNOROOT/examples: the realms resolve their
# imports from the examples tree, and gno test will not find a sibling package
# any other way. The staged copies are removed afterwards.
#
# That tree used to be SHARED — one $GNOROOT for every runner and every worktree,
# each ending in an rm -rf of a directory the others might be reading. This now
# builds its own GNOROOT instead (scripts/gnoroot.py): symlinks to everything
# except a private copy of examples/, named after this SHELL's pid ($$) so two
# runs in one checkout do not share it either. Import paths are untouched, so the
# code under test is byte-identical to the code that is committed.
realm-test:
	@if ! command -v gno >/dev/null 2>&1; then \
		if [ -n "$$REQUIRE_GNO" ]; then echo "gno not installed"; exit 1; fi; \
		echo "gno not installed - skipping realm tests"; exit 0; \
	fi; \
	python3 scripts/check-citations.py || exit 1; \
	python3 scripts/check-docnumbers.py || exit 1; \
	python3 scripts/check-storage.py || exit 1; \
	python3 scripts/check-nontransferable.py || exit 1; \
	python3 scripts/check-membership-clears.py || exit 1; \
	python3 scripts/check-read-purity.py || exit 1; \
	root=$$(python3 scripts/gnoroot.py build --label realm-test --pid $$$$) || exit 1; \
	trap 'python3 scripts/gnoroot.py remove --path "$$root"' EXIT; \
	export GNOROOT="$$root"; \
	rbase="$$root/examples/gno.land/r/kourt"; \
	pbase="$$root/examples/gno.land/p/kourt"; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		mkdir -p "$$pbase/$$p/v0" && \
		cp realm/p/$$p/*.gno realm/p/$$p/gnomod.toml "$$pbase/$$p/v0/" || exit 1; \
	done; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		( cd "$$pbase/$$p/v0" && gno test . ) || exit 1; \
	done; \
	for r in govern offerer kourtv1 kourtv2; do \
		mkdir -p "$$rbase/$$r" && \
		cp realm/r/$$r/*.gno realm/r/$$r/gnomod.toml "$$rbase/$$r/" && \
		( cd "$$rbase/$$r" && gno test . ) || exit 1; \
	done

# The claims that need a chain: that the source compiles on one, what a
# transaction costs, what an indexer sees, and whether the deploy fits.
#
# Needs gnodev on 127.0.0.1:26657 (chain id dev). REQUIRE_GNODEV turns a
# missing node into a failure rather than a skip, since this is the only target
# that compiles the realms on chain.
#
# -p 1 because every test drives the SAME node with keys from one mnemonic. Run
# in parallel they interleave transactions on one account and fail on sequence
# numbers, which reads as a realm bug and is not one.
chain-test:
	REQUIRE_GNODEV=1 go test -tags gnochain -count=1 -p 1 -timeout 40m ./...

# The .txtar integration tests: the realms run against a real (in-memory) gnoland
# node, exactly as gno.land/pkg/integration/testdata does. Needs no external node —
# the harness spins one up per script. TestMain stages the realms into
# GNOROOT/examples (where `loadpkg` looks) and removes them after. This is the only
# place the on-chain coin invariant — real GNOT to treasury, real CC through escrow —
# is checkable; the unit harness can only assert internal consistency.
# Its own GNOROOT too. TestMain stages through gnoenv.RootDir(), which reads
# GNOROOT from the environment, so the same shadow works here — and it matters
# as much as anywhere: this staged the widest set of packages of any runner and
# removed all of p/kourt and r/kourt when it finished.
# Recompile every scenario. The generated txtars name this target in their own
# header ("Regenerate with: make scenarios"), so it has to exist — and `check`
# runs it with --check so a stale generated file fails the build instead of
# quietly disagreeing with its source.
scenarios:
	@for f in $$(python3 scripts/scenario.py --list-ci); do \
		out="gnoland/testdata/scn_$$(basename $$f .py).txtar"; \
		python3 scripts/scenario.py "$$f" --out "$$out" || exit 1; \
	done

scenarios-check:
	@rc=0; tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	for f in $$(python3 scripts/scenario.py --list-ci); do \
		n="$$(basename $$f .py)"; out="gnoland/testdata/scn_$$n.txtar"; \
		python3 scripts/scenario.py "$$f" --out "$$tmp/$$n.txtar" >/dev/null || exit 1; \
		if ! cmp -s "$$out" "$$tmp/$$n.txtar"; then \
			echo "$$out is stale — run 'make scenarios'"; rc=1; \
		fi; \
	done; \
	for t in gnoland/testdata/scn_*.txtar; do \
		[ -e "$$t" ] || continue; \
		src="scenarios/$$(basename $$t .txtar | sed 's/^scn_//').py"; \
		[ -e "$$src" ] || { echo "$$t has no scenario ($$src) — it runs in txtar-test with no source"; rc=1; continue; }; \
		python3 scripts/scenario.py --list-ci | grep -q "/$$(basename $$src)$$" || \
			{ echo "$$t was generated from $$src, which is now CI = False — delete the txtar"; rc=1; }; \
	done; \
	[ $$rc -eq 0 ] && echo "scenarios-check: every generated txtar matches its scenario."; \
	exit $$rc

txtar-test:
	@root=$$(python3 scripts/gnoroot.py build --label txtar --pid $$$$) || exit 1; \
	trap 'python3 scripts/gnoroot.py remove --path "$$root"' EXIT; \
	GNOROOT="$$root" go test -tags txtar -count=1 -timeout 20m ./gnoland/

# Every realm suite run on its own. A gno test file shares package state and
# these suites do not rewind the clock, so a test can pass only because of what
# ran before it. Slow — each suite once per test — hence its own target.
isolation-test:
	python3 scripts/check-isolation.py

# Break the MONEY PATH on purpose and check the suite objects: every row in
# scripts/mutations-kourtv2.json applied and reverted in turn, over kourtv2 and the
# packages it imports. Run this before any money-path change — a green suite proves
# nothing on its own, since it passes against correct code and against code whose
# guard you deleted.
#
# Sharded across concurrent runners (scripts/mutate-parallel.py), which is safe
# because each builds its own GNOROOT and mutates only its staged copy.
#
# THE COST, stated structurally rather than as a number, because the number was
# wrong within months of being written (this comment said "56 named mutations" and
# "~2.5 minutes" when the corpus had reached 865 rows):
#
#     wall time ~= rows / shards * runtime of the mutated package's suite
#
# Staging is noise beside it — 0.03s against seconds for a suite — so the cost is
# irreducibly ONE SUITE RUN PER ROW.
#
# To get the dominant term, TIME THE SUITE rather than trusting a figure in here:
#
#     root=$(python3 scripts/gnoroot.py build --label t --pid $$)
#     ...stage as realm-test does, then: GNOROOT=$root gno test .   # in r/kourtv2
#
# and time it on an IDLE machine. Three readings of the same kourtv2 suite, all
# real: 3.67s when an earlier version of this comment was written, ~8s idle today,
# and ~34s while another session's `make isolation-test` ran alongside. The middle
# one is the suite's actual growth; the last is contention, and it is 4x. That
# spread is why the recipe is here and the digit is not. Two consequences before
# you either wait on this target or lengthen a test:
#
#   * Most rows target kourtv2, so each one pays the WHOLE kourtv2 suite.
#     Lengthening one shared test there multiplies across all of them.
#   * A wall time measured while anything else heavy is running (another session's
#     `make isolation-test`, say) measures the contention, not this target. Check
#     `pgrep -f 'gno test|check-isolation|mutate'` before believing a duration.
#
# The output is every row plus ONE verdict; shard boundaries are not shown. Nothing
# is printed until every shard has finished, because the parent collects each
# shard's stdout with subprocess.run — so a quiet log is not a stalled run. To see
# whether it is alive, watch the `gno test` children cycle.
#
# Exists as a target because the batch is otherwise invisible: mutate.py was in this repo
# for the whole of the v0.51-v0.62 work and went unused because nothing pointed at it,
# so every guard was mutated by hand instead.
#
# An interrupted run needs nothing from you. Mutations are applied to the STAGED COPY in
# the run's own shadow GNOROOT, never to the repo, so a killed run cannot leave one in the
# source — which also means several runs may go at once. What it leaves behind is a
# directory in the system temp named after a pid that no longer exists, and the next run
# builds its own.
mutate:
	python3 scripts/mutate-parallel.py scripts/mutations-kourtv2.json

# Break each guard on purpose and check it notices. Periodic rather than
# per-commit: a check that reports success while measuring nothing is the
# failure this catches, and it has caught it.
selftest:
	python3 scripts/selftest-checks.py
