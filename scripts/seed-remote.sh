#!/bin/sh
# Seed a REMOTE chain with a scenario: keys, genesis, then the scenario's own
# transactions. scripts/seed-node.sh does this against a gnodev it starts itself;
# this does it against a chain deploy/chain.sh puts on a server.
#
# WHY IT IS ONE SCRIPT AND NOT A RUNBOOK. Three facts have to line up, and getting
# any of them wrong fails late and confusingly:
#
#   1. THE SCENARIO'S ACTORS MUST BE FUNDED AT GENESIS. Balances come from nothing
#      only there; after the first block the routes are the faucet's 100-GNOT drip
#      or a transfer from somebody who already holds coin. Seventeen random keys
#      are made per run, so their addresses cannot be written into a runbook.
#
#   2. THE SCENARIO'S `deployer` MUST BE THE REALM'S DEPLOYER. testclock.gno
#      captures `tcDeployer = unsafe.OriginCaller()` at package init and gates
#      every clock write on it, and the scenario signs EnableTestClockAt and every
#      AdvanceTestClock as `deployer`. So the key that signs the genesis packages
#      and the key the scenario drives the clock with have to be the same one —
#      which is why chain.sh is handed this keyring as DEPLOYER_HOME rather than
#      making its own.
#
#   3. ONE PASSWORD. chain.sh's genesis signing uses `kourt-genesis`, hardcoded,
#      so every key here is created with it and the scenario is run with
#      PASS=kourt-genesis. A keyring cannot hold two.
#
# DESTRUCTIVE. This resets the chain: every balance, court, claim and position on
# it is discarded. The scenario also ARMS THE TEST CLOCK, so every date on the
# seeded chain is fabricated — and EnableTestClock refuses on a realm with any
# history, which is the deeper reason a re-seed cannot be incremental.
#
#   HOST=root@kourt.xyz CHAINID=kourt-1 REMOTE=https://rpc.kourt.xyz \
#   OWNER_ADDR=g1yours... CONFIRM=yes sh scripts/seed-remote.sh scenarios/covid_demo.py
set -eu

SCN="${1:-scenarios/covid_demo.py}"
HOST="${HOST:?set HOST=user@server}"
CHAINID="${CHAINID:-kourt-1}"
REMOTE="${REMOTE:-https://rpc.$(echo "$HOST" | sed 's/.*@//')}"
GNOROOT="${GNOROOT:-$HOME/gopath/src/github.com/gnolang/gno}"
# Jae's wallet. Defaulted rather than left empty because a reset wipes every
# balance, and an unpremined owner gets "insufficient network fee" from their
# wallet — which means no coin at all, not an expensive fee. Override to premine
# somebody else; set it empty to premine nobody.
OWNER_ADDR="${OWNER_ADDR-g1w746drdmenjdg0ll38dltjt7kkgtq5lmsmghcg}"
PASS="kourt-genesis"                    # chain.sh's, and not ours to choose
KEYDIR="${DEPLOYER_HOME:-$HOME/.kourt/deployer-$CHAINID}"

cd "$(dirname "$0")/.."
[ -f "$SCN" ] || { echo "seed-remote: no such scenario: $SCN" >&2; exit 2; }
command -v gnokey >/dev/null || { echo "seed-remote: gnokey not on PATH" >&2; exit 2; }
[ -d "$GNOROOT" ] || { echo "seed-remote: GNOROOT is not a directory: $GNOROOT" >&2; exit 2; }

if [ "${CONFIRM:-}" != "yes" ]; then
    cat >&2 <<EOF
seed-remote: this DISCARDS the chain at $REMOTE — every balance, court, claim and
             position on it — and rebuilds it with $SCN, on a fabricated clock.
             Re-run with CONFIRM=yes when that is what you want.
EOF
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

key() { gnokey "$@" -home "$KEYDIR" -insecure-password-stdin <<EOF
$PASS
$PASS
EOF
}
addr() {
    gnokey list -home "$KEYDIR" 2>/dev/null |
      sed -n "s/^[0-9]*\. $1 (.*addr: \(g1[a-z0-9]*\).*/\1/p" | head -1
}

echo "==> the scenario's accounts"
python3 scripts/scenario.py "$SCN" --emit accounts >"$WORK/accounts"
mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
PREMINE=""
while IFS="	" read -r name bal; do
    [ -n "$name" ] || continue
    # IDEMPOTENT, so a failed run can be retried without new addresses — and so
    # the deployer that already owns this chain keeps owning it.
    a="$(addr "$name")"
    if [ -z "$a" ]; then
        key add "$name" >/dev/null 2>&1 || true
        a="$(addr "$name")"
    fi
    [ -n "$a" ] || { echo "seed-remote: could not create or read key $name" >&2; exit 1; }
    PREMINE="$PREMINE $a=$bal"
    printf '    %-14s %s  %s\n' "$name" "$a" "$bal"
done <"$WORK/accounts"

DEP="$(addr deployer)"
[ -n "$DEP" ] || { echo "seed-remote: no deployer key" >&2; exit 1; }

# TWO WAYS TO SEED, and the fast one is the default — the same split
# scripts/seed-node.sh has run locally for a while, brought over here.
#
#   genesis  every transaction goes into the genesis file, applied at InitChain
#   plan     every transaction is a `gnokey maketx -broadcast`, one at a time
#
# MEASURED against kourt.xyz on covid_demo: 656 transactions, ~0.36s each, which
# is very nearly the whole ten-minute run. Almost none of it is the chain — the
# node answers a query in ~30ms and commits one to two blocks a second — it is
# the LOCAL keyring decrypt and signature, once per transaction. The genesis path
# pays none of it: nothing is signed and no gnokey is spawned, because a genesis
# transaction signs over (chainID, 0, 0) and the node skips verifying it.
#
# THE PLAN PATH STAYS, and not for sentiment: it checks every transaction as it
# lands and prints the realm's own panic when one fails. Genesis application is
# bulk and does not stop on a failure, so reach for SEED_MODE=plan when a
# scenario is being debugged rather than merely served.
SEED_MODE="${SEED_MODE:-genesis}"

# name, address AND pubkey, for BOTH modes: --emit txs needs the key for its
# signature slot (std.Tx.ValidateBasic refuses an empty signatures array
# outright, so each transaction carries its caller's pubkey with empty signature
# bytes — the shape gno.land's own genesis_txs.jsonl uses), and --emit checks
# needs the addresses to assert against. Built here, above the split, because
# the assertions run either way.
gnokey list -home "$KEYDIR" 2>/dev/null |
  sed -n 's/^[0-9]*\. \([a-z0-9]*\) (.*addr: \(g1[a-z0-9]*\) pub: \(gpub1[a-z0-9]*\).*/\1	\2	\3/p' \
  >"$WORK/accounts.map"
[ -s "$WORK/accounts.map" ] || {
    echo "seed-remote: read no name/addr/pubkey lines out of $KEYDIR" >&2; exit 1; }

GENESIS_TXS=""
if [ "$SEED_MODE" = genesis ]; then
    echo "==> the scenario's transactions, into genesis"
    python3 scripts/scenario.py "$SCN" --emit txs \
        --accounts-map "$WORK/accounts.map" --out "$WORK/genesis_txs.jsonl" >/dev/null
    GENESIS_TXS="$WORK/genesis_txs.jsonl"
    echo "    $(wc -l <"$GENESIS_TXS" | tr -d ' ') transactions, signed by nobody, applied at boot"
elif [ "$SEED_MODE" != plan ]; then
    echo "seed-remote: SEED_MODE is genesis or plan, not $SEED_MODE" >&2; exit 2
fi

echo "==> the chain, with those accounts premined at genesis"
# DEPLOYER_HOME is the whole trick: chain.sh signs the genesis packages with THIS
# keyring's deployer, so tcDeployer lands on a key the scenario below can use.
DEPLOYER_HOME="$KEYDIR" EXTRA_PREMINE="$PREMINE" GENESIS_TXS="$GENESIS_TXS" \
  make chain HOST="$HOST" GNOROOT="$GNOROOT" OWNER_ADDR="$OWNER_ADDR" RESET=--reset

if [ "$SEED_MODE" = plan ]; then
    echo "==> the scenario's transactions, against $REMOTE"
    python3 scripts/scenario.py "$SCN" --emit plan --out "$WORK/seed.sh" >/dev/null
    chmod +x "$WORK/seed.sh"
    KEYDIR="$KEYDIR" REMOTE="$REMOTE" CHAINID="$CHAINID" PASS="$PASS" sh "$WORK/seed.sh"
fi

echo "==> checking the chain agrees"
# RUN, not merely emitted. This line used to print above a call that emitted
# checks.sh and never executed it — and `--emit checks` requires
# --accounts-map, so the call failed and `|| true` swallowed that too: the
# heading printed and nothing whatsoever was checked. On the genesis path these
# reads are the ONLY evidence the seed applied, because bulk application does
# not stop on a failed transaction, so a silent no-op here is the one thing this
# script cannot afford.
python3 scripts/scenario.py "$SCN" --emit checks \
    --accounts-map "$WORK/accounts.map" --out "$WORK/checks.sh" >/dev/null
chmod +x "$WORK/checks.sh"
REMOTE="$REMOTE" sh "$WORK/checks.sh"
cat <<EOF

Seeded $CHAINID at $REMOTE from $SCN.

  deployer $DEP
           owns the realm and is the only address that may drive the test clock.
           It lives in $KEYDIR — back that up; losing it is unrecoverable.
EOF
[ -n "$OWNER_ADDR" ] && echo "  premined $OWNER_ADDR so you can try it from a wallet."
exit 0
