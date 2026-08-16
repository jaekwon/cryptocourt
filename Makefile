.PHONY: check realm-test chain-test txtar-test isolation-test selftest fmt vet

# Everything that can run without a node.
#
# realm-test skips cleanly with no gno toolchain and says so; REQUIRE_GNO=1
# makes a missing toolchain a failure instead of a quiet pass.
check: fmt vet realm-test

fmt:
	gofmt -l .

vet:
	go vet -tags gnochain ./...

# The realms' own tests, plus the three guards that hold the documentation to
# the code.
#
# They have to run from inside GNOROOT/examples: the realms resolve their
# imports from the examples tree, and gno test will not find a sibling package
# any other way. The staged copies are removed afterwards.
realm-test:
	@if ! command -v gno >/dev/null 2>&1; then \
		if [ -n "$$REQUIRE_GNO" ]; then echo "gno not installed"; exit 1; fi; \
		echo "gno not installed - skipping realm tests"; exit 0; \
	fi; \
	python3 scripts/check-citations.py || exit 1; \
	python3 scripts/check-docnumbers.py || exit 1; \
	python3 scripts/check-storage.py || exit 1; \
	root=$$(gno env GNOROOT); \
	rbase="$$root/examples/gno.land/r/cryptocourt"; \
	pbase="$$root/examples/gno.land/p/cryptocourt"; \
	trap 'rm -rf "$$rbase" "$$pbase"' EXIT; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		mkdir -p "$$pbase/$$p/v0" && \
		cp realm/p/$$p/*.gno realm/p/$$p/gnomod.toml "$$pbase/$$p/v0/" || exit 1; \
	done; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		( cd "$$pbase/$$p/v0" && gno test . ) || exit 1; \
	done; \
	for r in govern offerer court courtv2; do \
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
txtar-test:
	go test -tags txtar -count=1 -timeout 20m ./gnoland/

# Every realm suite run on its own. A gno test file shares package state and
# these suites do not rewind the clock, so a test can pass only because of what
# ran before it. Slow — each suite once per test — hence its own target.
isolation-test:
	python3 scripts/check-isolation.py

# Break each guard on purpose and check it notices. Periodic rather than
# per-commit: a check that reports success while measuring nothing is the
# failure this catches, and it has caught it.
selftest:
	python3 scripts/selftest-checks.py
