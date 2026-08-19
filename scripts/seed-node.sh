#!/bin/sh
# Bring up a throwaway gnodev node and seed it from a scenario, so the web
# overlay has a real chain to read in live mode.
#
#   scripts/seed-node.sh [scenarios/smoke.py]
#
# Everything it makes is disposable: a fresh keyring in a temp dir, a fresh
# chain in memory. Stopping the script stops the node and the chain is gone.
#
# WHY A FRESH DEPLOYER KEY. The realm captures its deployer at init() and only
# that address may ever drive the test clock. gnodev's default deploy key is
# test1, whose mnemonic is published — anyone who can reach the RPC port could
# then move the node's clock. So this script makes a random key, premines it,
# and hands it to gnodev as -deploy-key. Nothing here is reusable by a stranger.
set -eu

SCN="${1:-scenarios/smoke.py}"
CHAINID="${CHAINID:-dev}"
RPC_PORT="${RPC_PORT:-26657}"
WEB_PORT="${WEB_PORT:-8888}"
REMOTE="http://127.0.0.1:$RPC_PORT"
PASS="${PASS:-scenario}"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$SCN" ] || { echo "seed-node: no such scenario: $SCN" >&2; exit 2; }
command -v gnodev >/dev/null || { echo "seed-node: gnodev not on PATH" >&2; exit 2; }
command -v gnokey >/dev/null || { echo "seed-node: gnokey not on PATH" >&2; exit 2; }

# Refuse to touch a port someone else is on. Without this the script would
# happily "seed" a node it did not start — a stranger's chain, or a stale one
# from an earlier run — and every later query would describe the wrong world.
for p in "$RPC_PORT" "$WEB_PORT"; do
	if curl -sf -o /dev/null "http://127.0.0.1:$p" 2>/dev/null ||
		nc -z 127.0.0.1 "$p" 2>/dev/null; then
		echo "seed-node: 127.0.0.1:$p is already in use — refusing to seed a node I did not start." >&2
		echo "           Stop it, or re-run with RPC_PORT=... WEB_PORT=... for a free pair." >&2
		exit 2
	fi
done

WORK="$(mktemp -d)"
KEYDIR="$WORK/keys"
NODELOG="$WORK/gnodev.log"
NODE_PID=""
cleanup() {
	[ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null || true
	[ -n "$NODE_PID" ] && wait "$NODE_PID" 2>/dev/null || true
	if [ -n "${KEEP:-}" ]; then
		echo "seed-node: KEEP set — leaving $WORK in place"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT INT TERM

key() { gnokey "$@" -home "$KEYDIR" -insecure-password-stdin <<EOF
$PASS
$PASS
EOF
}
addr() {
	key list 2>/dev/null |
		sed -n "s/^[0-9]*\. $1 (.*addr: \(g1[a-z0-9]*\).*/\1/p" | head -1
}

echo "seed-node: generating the plan from $SCN"
python3 scripts/scenario.py "$SCN" --emit plan --out "$WORK/seed.sh" >/dev/null
python3 scripts/scenario.py "$SCN" --emit accounts >"$WORK/accounts"
chmod +x "$WORK/seed.sh"

# 1. Keys, before the node: gnodev fixes the premine set and the deploy key at
#    genesis, so the addresses have to exist first.
echo "seed-node: making keys in $KEYDIR"
PREMINE=""
while IFS="	" read -r name bal; do
	[ -n "$name" ] || continue
	key add "$name" >/dev/null 2>&1
	a="$(addr "$name")"
	[ -n "$a" ] || { echo "seed-node: could not create key $name" >&2; exit 1; }
	PREMINE="$PREMINE -add-account $a=${bal}ugnot"
	echo "  $name $a"
done <"$WORK/accounts"
DEPLOYER_ADDR="$(addr deployer)"

# 2. The node. -empty-blocks=false so height tracks transactions and not
#    wall-clock, which is what makes the scenario's block counts mean anything.
#    The package dirs are named individually: `realm/` holds no gno files of its
#    own, so handing gnodev the parent silently loads nothing at all.
#
#    DEPENDENCY ORDER MATTERS. Genesis type-checks each package as it lands, so
#    every import has to be on chain already. gnodev's on-demand resolution
#    happens too late for that, hence the explicit list.
#
#    We name the handful of examples we need instead of eager-loading the whole
#    tree (-extra-root "$GNOROOT/examples"), because that tree also carries a
#    STALE COPY of this project under examples/gno.land/{r,p}/kourt, which
#    shadows the working tree: the node comes up serving an old realm, missing
#    whichever files you just wrote, and every query answers plausibly and
#    wrongly. Verified: with -extra-root the node had no clock.gno, no
#    stakeseries.gno and no testclock.gno.
echo "seed-node: starting gnodev (log: $NODELOG)"
GNOEX="${GNOROOT:-/Users/jk/gopath/src/github.com/gnolang/gno}/examples/gno.land/p/nt"
[ -d "$GNOEX" ] || { echo "seed-node: no gno examples at $GNOEX (set GNOROOT)" >&2; exit 2; }
# shellcheck disable=SC2086
gnodev local \
	"$GNOEX/ufmt/v0" \
	"$GNOEX/uassert/v0" \
	"$GNOEX/avl/v0" \
	"$GNOEX/seqid/v0" \
	"$GNOEX/bptree/v0/rotree" \
	"$GNOEX/bptree/v0" \
	"$GNOEX/cford32/v0" \
	"$GNOEX/markdown/sanitize/v0" \
	"$ROOT/realm/p/checkpoint" \
	"$ROOT/realm/p/grc20votes" \
	"$ROOT/realm/p/governor" \
	"$ROOT/realm/p/twap" \
	"$ROOT/realm/p/curve" \
	"$ROOT/realm/r/kourtv2" \
	-chain-id "$CHAINID" \
	-node-rpc-listener "127.0.0.1:$RPC_PORT" \
	-web-listener "127.0.0.1:$WEB_PORT" \
	-deploy-key "$DEPLOYER_ADDR" \
	-home "$KEYDIR" \
	-no-watch -empty-blocks=false -interactive=false \
	$PREMINE >"$NODELOG" 2>&1 &
NODE_PID=$!

# 3. Wait for RPC. A node that dies during package load never opens the port,
#    so check liveness too rather than spinning for the full timeout.
echo "seed-node: waiting for $REMOTE"
i=0
until curl -sf "$REMOTE/status" >/dev/null 2>&1; do
	i=$((i + 1))
	if ! kill -0 "$NODE_PID" 2>/dev/null; then
		echo "seed-node: gnodev exited before serving. Last lines:" >&2
		tail -25 "$NODELOG" >&2
		exit 1
	fi
	[ "$i" -gt 120 ] && { echo "seed-node: RPC never came up" >&2; tail -25 "$NODELOG" >&2; exit 1; }
	sleep 1
done
echo "seed-node: node is up after ${i}s"

# 4. The scenario itself.
KEYDIR="$KEYDIR" REMOTE="$REMOTE" CHAINID="$CHAINID" PASS="$PASS" sh "$WORK/seed.sh"

cat <<EOF

  Seeded. The scenario reported its clock state above.

    RPC      $REMOTE
    gnoweb   http://127.0.0.1:$WEB_PORT/r/kourt/kourtv2
    overlay  set mode=live, RPC=$REMOTE, chain=$CHAINID
             (the settings panel's "gnodev" preset fills all three)

  READING the chain works straight from disk — open web/index.html as a
  file:// URL and it will query this node; gnodev answers with
  Access-Control-Allow-Origin: *, so the browser allows it (verified).

  SIGNING does not. Browser extensions are not injected into file:// pages,
  so a wallet is invisible there and the page reports "no wallet found".
  To connect one, serve the folder over http first:

      (cd web && python3 -m http.server 8777) &
      open http://127.0.0.1:8777/index.html

  Conformance-check the overlay's live reads against this node:

      python3 scripts/check-live-reads.py --remote $REMOTE

  Ctrl-C stops the node and discards the chain and the keys.
EOF
wait "$NODE_PID"
