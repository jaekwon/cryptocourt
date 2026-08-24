#!/bin/sh
# Lived in a session scratchpad under /private/tmp until 2026-08-24, where it was
# one tmp reap away from gone while the audit VERIFY list depended on it. Now in
# git, which is the only durable place for a tool a checklist names.
# Stage the tree the way `make realm-test` does and run ONE realm's tests, with an
# optional -run filter. The Makefile target stages every package and realm and
# runs them all; this is the same recipe narrowed to one realm so the edit/test
# loop is seconds instead of minutes.
#
#   t.sh kourtv2 TestQualityWeightIsFlooredByWhatIsStillHeld
#   t.sh kourtv2                # the whole realm
set -e
# The repo root is derived from THIS SCRIPT'S location, not hardcoded: the
# corpus runs from a --depth 1 clone in a scratchpad, and a hardcoded path
# silently measured the wrong tree from there.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
REALM="${1:-kourtv2}"
FILTER="$2"
root=$(python3 scripts/gnoroot.py build --label onetest --pid $$)
# Absolute: the trap fires after a cd, so a relative script path cannot resolve
# and the GNOROOT leaks silently.
trap 'python3 "$REPO/scripts/gnoroot.py" remove --path "$root"' EXIT
export GNOROOT="$root"
pbase="$root/examples/gno.land/p/kourt"
rbase="$root/examples/gno.land/r/kourt"
for p in checkpoint grc20votes governor twap cshares tickbook curve; do
	mkdir -p "$pbase/$p/v0"
	cp realm/p/$p/*.gno realm/p/$p/gnomod.toml "$pbase/$p/v0/"
done
mkdir -p "$rbase/$REALM"
cp realm/r/$REALM/*.gno realm/r/$REALM/gnomod.toml "$rbase/$REALM/"
cd "$rbase/$REALM"
if [ -n "$FILTER" ]; then
	# `gno test -run` EXITS 0 WHEN THE FILTER MATCHES NOTHING, and its output is
	# indistinguishable from a pass: -run does not suppress filetests, so a typo'd
	# name still prints a screen of GAS lines and then `ok . 3.76s`. Measured side
	# by side — a real name adds `=== RUN` and `--- PASS`, a bad one adds neither,
	# and both exit 0. So every green from this loop was ambiguous between "the
	# test passed" and "the test never ran".
	#
	# Buffered rather than piped on purpose: `gno test ... | tee` would hand the
	# shell tee's status and swallow a genuine failure, which is the same class of
	# bug this check exists to close.
	log=$(mktemp)
	rc=0
	gno test -run "$FILTER" -v . > "$log" 2>&1 || rc=$?
	cat "$log"
	if [ "$rc" -ne 0 ]; then
		rm -f "$log"
		exit "$rc"
	fi
	if ! grep -q '^=== RUN' "$log"; then
		rm -f "$log"
		echo "" >&2
		echo "t.sh: NO TEST MATCHED '$FILTER' — zero tests ran, so this is NOT a" >&2
		echo "pass. Check the name against realm/r/$REALM/*_test.gno; gno test" >&2
		echo "reports ok for an empty selection." >&2
		exit 1
	fi
	rm -f "$log"
else
	gno test .
fi
