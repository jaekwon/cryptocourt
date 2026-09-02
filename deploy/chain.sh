#!/usr/bin/env bash
# Stand up the Kourt chain and its faucet on one host.
#
#   GNOROOT=~/gopath/src/github.com/gnolang/gno ./deploy/chain.sh root@kourt.xyz
#
# TWO PHASES, AND THE ORDER IS FORCED. The genesis file has to name the
# validator's public key and premine the faucet's address — but neither secret
# should be born on this laptop and travel over the wire. So the server generates
# them first (phase 1), this script reads back only the PUBLIC halves, builds the
# genesis locally where the packages are (phase 2), and ships it. The validator
# private key and the faucet mnemonic never leave the box.
#
# WHAT THIS IS NOT. It does not touch the overlay or the chat — deploy.sh owns
# those, and a chain restart must not imply a website deploy. It also refuses to
# run twice over a live chain: a new genesis against an existing data directory
# is a node that will not start, so replacing the chain is an explicit --reset.
set -euo pipefail

HOST="${1:?usage: chain.sh user@host [--reset|--config-only]}"
RESET="${2:-}"
# --config-only ships the units and the nginx vhosts and nothing else. Adding a
# name, or fixing a unit, must not require RESET — and RESET destroys the chain.
# Without this mode the refusal that protects a live chain also locks out every
# subsequent config change, which is how the gnoweb vhost failed to arrive.
CONFIG_ONLY=""
[ "$RESET" = "--config-only" ] && { CONFIG_ONLY=1; RESET=""; }
CHAINID="${CHAINID:-kourt-1}"
APPDIR="${APPDIR:-/opt/kourt}"
STATEDIR="${STATEDIR:-/var/lib/kourt}"
CHAINDIR="$STATEDIR/chain"
# Premined at genesis, in ugnot. The faucet needs enough to answer grants for a
# long time without a refill ceremony; 5M GNOT is 50,000 grants at 100 each.
FAUCET_PREMINE="${FAUCET_PREMINE:-5000000000000}"
OWNER_ADDR="${OWNER_ADDR:-}"          # optional: an address to premine for yourself
OWNER_PREMINE="${OWNER_PREMINE:-1000000000000}"
# EXTRA PREMINES, space-separated `g1...=<ugnot>` pairs. Genesis is the only place
# balances can be created from nothing, so an account that must hold coin on a
# fresh chain has to be named here — after the chain is up the only routes are the
# faucet's 100-GNOT drip or a transfer from somebody who already holds some.
#
# This exists so a SCENARIO can be seeded onto a remote chain. Its actors are
# random keys made per run (scripts/seed-node.sh does the same locally), and they
# need funding before the first block; OWNER_ADDR premines exactly one address and
# a scenario needs seventeen. scripts/seed-remote.sh builds this string.
EXTRA_PREMINE="${EXTRA_PREMINE:-}"
# gnoweb's loopback port. NOT 8888: that is gnodev's default, and on a host that
# runs anything else it is likely already taken — which is exactly how the first
# deploy failed, inside systemd, with "bind: address already in use".
GNOWEB_PORT="${GNOWEB_PORT:-8899}"

cd "$(dirname "$0")/.."
REPO="$PWD"
# Only the full run needs a gno checkout: --config-only ships files that are all
# in this repo, so demanding GNOROOT there would be a requirement with no use.
if [ -z "$CONFIG_ONLY" ]; then
    : "${GNOROOT:?set GNOROOT to a gno checkout (needs examples/ for p/nt packages)}"
    [ -d "$GNOROOT/examples" ] || { echo "chain.sh: no examples/ under GNOROOT"; exit 2; }
fi

CTL="${TMPDIR:-/tmp}/kourt-chain-$$"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=180)
SCP=(scp -q -o ControlPath="$CTL")
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

if [ -z "$CONFIG_ONLY" ]; then
echo "==> building linux binaries"
# CGO_ENABLED=0 so they run on any distro, matching deploy.sh's kourtchat build.
( cd "$GNOROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnoland" ./gno.land/cmd/gnoland )
( cd "$GNOROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnokey"  ./gno.land/cmd/gnokey )
( cd "$GNOROOT/contribs/gnogenesis" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnogenesis" . )
( cd "$GNOROOT/contribs/gnofaucet"  && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnofaucet"  . )
( cd "$GNOROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnoweb"    ./gno.land/cmd/gnoweb )
# gnogenesis also runs HERE, on this machine, to build the genesis from the
# packages in this repo. Build a host copy alongside the linux one.
( cd "$GNOROOT/contribs/gnogenesis" && go build -o "$WORK/gnogenesis-host" . )
( cd "$GNOROOT" && go build -o "$WORK/gnokey-host" ./gno.land/cmd/gnokey )
ls -l "$WORK" | awk '{print "    " $9, $5}' | grep -v '^    $'

# THE NODE READS THE GO STDLIBS OFF DISK AT CHAIN INIT, from
# $GNOROOT/gnovm/stdlibs — 253 .gno files it loads before the first block. The
# binary only GUESSES that path when GNOROOT is unset, and its last-resort guess
# is the build machine's own source tree, which is why a node built here and run
# there dies in loadStdlib with a path like /Users/<you>/gopath/... in the stack.
# So the stdlibs travel with the binary and the unit sets GNOROOT explicitly.
echo "==> packing the stdlibs ($(du -sh "$GNOROOT/gnovm/stdlibs" | cut -f1))"
tar -C "$GNOROOT" -czf "$WORK/stdlibs.tgz" gnovm/stdlibs

echo "==> phase 1: server-side secrets"
"${SCP[@]}" "$WORK/gnoland" "$WORK/gnokey" "$WORK/gnogenesis" "$WORK/gnofaucet" \
    "$WORK/gnoweb" "$WORK/stdlibs.tgz" "$HOST:/tmp/"
PUBLIC=$("${SSH[@]}" "$HOST" APPDIR="$APPDIR" STATEDIR="$STATEDIR" CHAINDIR="$CHAINDIR" \
  RESET="$RESET" 'bash -seu' <<'REMOTE'
mkdir -p "$APPDIR/bin" "$CHAINDIR/data/secrets" "$STATEDIR/secret"
for b in gnoland gnokey gnogenesis gnofaucet gnoweb; do
    install -m 0755 "/tmp/$b" "$APPDIR/bin/$b"; rm -f "/tmp/$b"
done

# Unpacked fresh every run: these must match the binaries they were built beside,
# and a stale stdlib tree against a newer gnoland is a chain that fails at init
# for reasons that read as corruption.
rm -rf "$APPDIR/gnoroot/gnovm/stdlibs"
mkdir -p "$APPDIR/gnoroot"
tar -C "$APPDIR/gnoroot" -xzf /tmp/stdlibs.tgz && rm -f /tmp/stdlibs.tgz
test -d "$APPDIR/gnoroot/gnovm/stdlibs" || { echo "stdlibs did not unpack" >&2; exit 5; }

# A live chain is not silently replaced. A fresh genesis over an existing data
# directory produces a node that refuses to start, which is a worse outcome than
# stopping here and saying so.
if [ -f "$CHAINDIR/genesis.json" ] && [ "$RESET" != "--reset" ]; then
    echo "REFUSE: $CHAINDIR/genesis.json exists; re-run with --reset to replace the chain" >&2
    exit 3
fi
if [ "$RESET" = "--reset" ]; then
    systemctl stop kourtfaucet kourtnode 2>/dev/null || true
    rm -rf "$CHAINDIR/data/db" "$CHAINDIR/genesis.json"
    # AND THE VALIDATOR'S SIGNING STATE, which is the half this used to miss.
    #
    # priv_validator_state.json remembers the highest height this validator has
    # signed, so that it cannot be tricked into double-signing. A new chain starts
    # at 1, the file still said 444 from the old one, and the validator refused:
    #
    #   Error signing vote  height regression: expected >= 444, got 1
    #
    # Consensus then stalled before block 1 — and since the realm ships as genesis
    # TRANSACTIONS, which execute in block 1, the chain came up with no realm on
    # it at all. Diagnosed twice: once by hand on kourt-1, and once by the guard
    # added for it, which is what caught this on the next --reset.
    #
    # THE KEY IS KEPT, only the state is zeroed. The genesis validator set names
    # this key's public half, so replacing it would produce a chain whose only
    # validator is unknown to its own genesis.
    if [ -f "$CHAINDIR/data/secrets/priv_validator_state.json" ]; then
        printf '{"height":"0","round":"0","step":0}\n' \
            > "$CHAINDIR/data/secrets/priv_validator_state.json"
        echo "    reset the validator's signing state to height 0"
    fi
fi

# Validator + node keys. secrets init writes them to the directory it is GIVEN,
# while `gnoland start -data-dir X` looks for them in X/secrets — so point it at
# the secrets directory directly rather than at the data dir.
if [ ! -f "$CHAINDIR/data/secrets/priv_validator_key.json" ]; then
    "$APPDIR/bin/gnoland" secrets init -data-dir "$CHAINDIR/data/secrets" >/dev/null
fi
# config.toml is addressed by -config-path, not -data-dir.
[ -f "$CHAINDIR/data/config/config.toml" ] || \
    "$APPDIR/bin/gnoland" config init -config-path "$CHAINDIR/data/config/config.toml" >/dev/null
# ONE VALIDATOR, SO THERE IS NOBODY TO WAIT FOR. tm2 defaults timeout_commit to
# 5s, which is time held open for other validators' precommits — this chain has
# none, so every block costs five seconds for nothing. Seeding a scenario is a
# few hundred transactions, one per block, and that default alone made it a
# forty-minute job.
#
# Set unconditionally, not guarded by the init above: an existing chain must
# pick this up on the next restart too.
"$APPDIR/bin/gnoland" config set -config-path "$CHAINDIR/data/config/config.toml" \
    consensus.skip_timeout_commit true >/dev/null

# The faucet's wallet. Generated here, printed nowhere: the mnemonic goes
# straight into a root-owned 0600 file that systemd hands to the unit as a
# credential, and only the ADDRESS is echoed back to the deploying machine.
if [ ! -s "$STATEDIR/secret/faucet.mnemonic" ]; then
    out=$("$APPDIR/bin/gnokey" add faucet -home "$STATEDIR/secret/keyring" \
            -insecure-password-stdin <<EOF 2>&1
kourt-faucet
kourt-faucet
EOF
)
    printf '%s\n' "$out" | awk 'NF>=12 && $1 ~ /^[a-z]+$/ && $NF ~ /^[a-z]+$/ {m=$0} END{print m}' \
        > "$STATEDIR/secret/faucet.mnemonic"
    chmod 0600 "$STATEDIR/secret/faucet.mnemonic"
fi
[ -s "$STATEDIR/secret/faucet.mnemonic" ] || { echo "FAILED to capture faucet mnemonic" >&2; exit 4; }
chown -R root:root "$STATEDIR/secret"; chmod 0700 "$STATEDIR/secret"

FAUCET_ADDR=$("$APPDIR/bin/gnokey" list -home "$STATEDIR/secret/keyring" 2>/dev/null \
    | sed -n 's/^[0-9]*\. faucet (.*addr: \(g1[a-z0-9]*\).*/\1/p' | head -1)
VAL=$("$APPDIR/bin/gnoland" secrets get validator_key -data-dir "$CHAINDIR/data/secrets" 2>/dev/null)
echo "PUBLIC ${FAUCET_ADDR} $(printf '%s' "$VAL" | tr -d ' \n' | sed 's/.*"address":"\([^"]*\)".*"pub_key":"\([^"]*\)".*/\1 \2/')"
REMOTE
)
FAUCET_ADDR=$(echo "$PUBLIC" | awk '/^PUBLIC/{print $2}')
VAL_ADDR=$(echo   "$PUBLIC" | awk '/^PUBLIC/{print $3}')
VAL_PUB=$(echo    "$PUBLIC" | awk '/^PUBLIC/{print $4}')
[ -n "$FAUCET_ADDR" ] && [ -n "$VAL_PUB" ] || { echo "chain.sh: could not read back server secrets"; exit 4; }
echo "    faucet    $FAUCET_ADDR"
echo "    validator $VAL_ADDR"

echo "==> phase 2: genesis, built here from this repo"
python3 scripts/genesis-pkgs.py "$WORK/pkgs" --gno "$GNOROOT"
# THE DEPLOYER KEY OUTLIVES THE DEPLOY, and it used to not — GNOHOME was
# "$WORK/gnohome", a temp dir, and the comment here said the key was "ephemeral by
# design" because it signs nothing after genesis and the node runs with
# -skip-genesis-sig-verification. That is true about SIGNING and wrong about
# consequences.
#
# testclock.gno captures the address that deployed the package:
#
#     func init() { tcDeployer = unsafe.OriginCaller() }
#
# and mustDeployer gates every test-clock write on it. Throwing the key away
# therefore left tcDeployer set to an address nobody could ever sign as, so the
# clock could never be armed and no owner-only entrypoint was reachable for the
# life of the chain. Measured on kourt-1: exactly that.
#
# Reused across deploys ON PURPOSE. A --reset gives a new chain, and the same
# deployer owning it is what makes a re-seed possible; a fresh key each time would
# reintroduce the bug one reset later.
#
# LOSING THIS DIRECTORY IS UNRECOVERABLE for owner-only entrypoints. It is a key,
# not a cache; back it up with the rest of the chain's secrets.
DEPLOYER_HOME="${DEPLOYER_HOME:-$HOME/.kourt/deployer-$CHAINID}"
GNOHOME="$DEPLOYER_HOME"; mkdir -p "$GNOHOME"; chmod 700 "$GNOHOME"
# EXISTENCE IS THE ADDRESS BEING READABLE, not a grep over the listing. The first
# version asked `list | grep -q '\bdeployer\b'`, which came back FALSE here while
# being true when run by hand, so it fell through to `add` — and `gnokey add` on a
# name that already exists PROMPTS ("Override the existing name deployer [Y/n]:"),
# reads the piped password as the answer, aborts, and returns non-zero. With its
# output sent to /dev/null and set -e in force, chain.sh died between two echoes
# with no message at all.
#
# So: read the address, and treat "I can read it" as "it exists". That is the same
# fact the rest of the script needs anyway, it needs no pattern to be portable,
# and it cannot disagree with itself the way two separate probes can.
deployer_addr() {
    "$WORK/gnokey-host" list -home "$GNOHOME" 2>/dev/null \
      | sed -n 's/^[0-9]*\. deployer (.*addr: \(g1[a-z0-9]*\).*/\1/p' | head -1
}
DEPLOYER_ADDR="$(deployer_addr)"
if [ -n "$DEPLOYER_ADDR" ]; then
    echo "    reusing the deployer key in $GNOHOME"
else
    # NOT SILENCED. Suppressing this is what hid the failure above; if it cannot
    # make the key, the reason is the only useful thing on the screen.
    if ! "$WORK/gnokey-host" add deployer -home "$GNOHOME" -insecure-password-stdin >/dev/null <<EOF
kourt-genesis
kourt-genesis
EOF
    then
        echo "REFUSE: could not create a deployer key in $GNOHOME" >&2
        exit 1
    fi
    DEPLOYER_ADDR="$(deployer_addr)"
    echo "    made a deployer key in $GNOHOME — BACK THIS UP, it owns the realm"
fi
[ -n "$DEPLOYER_ADDR" ] || { echo "REFUSE: could not read the deployer address back" >&2; exit 1; }
echo "    deployer $DEPLOYER_ADDR (owns the realm; only it may drive the test clock)"
"$WORK/gnogenesis-host" generate --chain-id "$CHAINID" --output-path "$WORK/genesis.json" >/dev/null
"$WORK/gnogenesis-host" validator add -genesis-path "$WORK/genesis.json" \
    -address "$VAL_ADDR" -pub-key "$VAL_PUB" -name kourt0 -power 1 >/dev/null
"$WORK/gnogenesis-host" balances add -genesis-path "$WORK/genesis.json" \
    -single "$FAUCET_ADDR=${FAUCET_PREMINE}ugnot" >/dev/null
if [ -n "$OWNER_ADDR" ]; then
    "$WORK/gnogenesis-host" balances add -genesis-path "$WORK/genesis.json" \
        -single "$OWNER_ADDR=${OWNER_PREMINE}ugnot" >/dev/null
    echo "    premined owner $OWNER_ADDR"
fi
# VALIDATED, NOT PASSED THROUGH. A malformed pair here fails inside gnogenesis
# with a message about the genesis file rather than about the argument, and the
# operator is then debugging the wrong thing.
for pair in ${EXTRA_PREMINE:-}; do
    case "$pair" in
        g1*=*[0-9]) ;;
        *) echo "REFUSE: EXTRA_PREMINE entry is not g1<addr>=<ugnot>: $pair" >&2; exit 2 ;;
    esac
    "$WORK/gnogenesis-host" balances add -genesis-path "$WORK/genesis.json" \
        -single "${pair}ugnot" >/dev/null
    echo "    premined ${pair%%=*} with ${pair##*=} ugnot"
done
# The whole closure in ONE call: gnogenesis sorts per invocation and cannot see
# packages already in the file (scripts/genesis-pkgs.py says more).
"$WORK/gnogenesis-host" txs add packages "$WORK/pkgs" -genesis-path "$WORK/genesis.json" \
    -key-name deployer -gno-home "$GNOHOME" -insecure-password-stdin <<EOF | tail -1
kourt-genesis
EOF

else
    echo "==> config only: units and nginx, chain untouched"
fi

echo "==> shipping units and vhosts"
[ -n "$CONFIG_ONLY" ] || "${SCP[@]}" "$WORK/genesis.json" "$HOST:$CHAINDIR/genesis.json"
"${SCP[@]}" deploy/kourtnode.service deploy/kourtfaucet.service "$HOST:/tmp/"
# The unit and the vhost have to agree on the port, so both are rendered here
# from the same variable rather than edited in two places.
sed "s/__GNOWEB_PORT__/$GNOWEB_PORT/" deploy/kourtweb.service  > "$WORK/kourtweb.service"
sed "s/__GNOWEB_PORT__/$GNOWEB_PORT/" deploy/nginx-gnoweb.conf > "$WORK/nginx-gnoweb.conf"
"${SCP[@]}" "$WORK/kourtweb.service" "$HOST:/tmp/kourtweb.service"
"${SCP[@]}" "$WORK/nginx-gnoweb.conf" "$HOST:/tmp/nginx-gnoweb.conf"
"${SCP[@]}" deploy/nginx-zones.conf deploy/nginx-rpc.conf deploy/nginx-faucet.conf "$HOST:/tmp/"

"${SSH[@]}" "$HOST" APPDIR="$APPDIR" STATEDIR="$STATEDIR" CHAINDIR="$CHAINDIR" \
  CONFIG_ONLY="$CONFIG_ONLY" GNOWEB_PORT="$GNOWEB_PORT" 'bash -seu' <<'REMOTE'
chown -R kourt:kourt "$CHAINDIR"
install -m 0644 /tmp/kourtnode.service   /etc/systemd/system/kourtnode.service
install -m 0644 /tmp/kourtfaucet.service /etc/systemd/system/kourtfaucet.service
install -m 0644 /tmp/kourtweb.service    /etc/systemd/system/kourtweb.service
install -m 0644 /tmp/nginx-zones.conf /etc/nginx/conf.d/kourt-zones.conf
# ONE FILE PER NAME, and each is left alone once certbot has edited it. certbot
# --nginx rewrites the file holding a server block to add its :443 listener; a
# plain reinstall would put the HTTP-only version back and drop TLS silently,
# while refusing to touch a COMBINED file made it impossible to add a new name at
# all. Per-name files give both: TLS is preserved, new names still arrive.
# LEFT UNTOUCHED IS NOT THE SAME AS UP TO DATE, and saying only the first is how a
# fix to a vhost in this repo sat unshipped while `RESET=--config-only` reported
# success. Observed: nginx-rpc.conf gained proxy_hide_header directives to stop a
# duplicated Access-Control-Allow-Origin breaking every browser read, --config-only
# was run, it printed "left untouched", and the live file was unchanged. The header
# stayed duplicated and the site stayed broken.
#
# So a skipped file is DIFFED against the repo copy, ignoring the lines certbot owns
# — those differ by design and are the reason for skipping. Anything else is drift,
# and drift is printed as the exact lines plus the command to apply them, because
# "these differ" is a diagnosis and the operator needs the fix.
drift=0
for n in rpc faucet gnoweb; do
    dst="/etc/nginx/sites-available/kourt-$n"
    if grep -q ssl_certificate "$dst" 2>/dev/null; then
        # DIRECTIVES ONLY — not comments, not blank lines, not indentation. The first
        # version of this compared the files as text and reported all three as drifted,
        # because a comment reworded by hand on the box differs from the repo's prose
        # while the config is identical. A drift check that cries wolf gets ignored,
        # which would leave it no better than the silence it replaced.
        #
        # Certbot's own lines go too: it rewrites the listeners (moving :80 into a
        # redirect block of its own), adds the cert paths and its include. Those differ
        # BY DESIGN on every file this branch touches — they are why we are skipping.
        #
        # AND THE STRUCTURAL TOKENS, because certbot appends an ENTIRE extra server
        # block for the HTTP->HTTPS redirect, which after the filtering above reduces
        # to a bare `server {`, a server_name and a `}` — and that was reported as
        # drift on all three files when it is just certbot doing its job. Dropping
        # them leaves the DIRECTIVES, which is what a drift check is for; nginx -t
        # validates the structure and this does not need to.
        strip() {
            grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" \
              | grep -vE 'ssl_certificate|ssl_(protocols|ciphers|session|dhparam|prefer)|managed by Certbot|include /etc/letsencrypt|listen |return 301|if \(\$host =' \
              | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
              | grep -vE '^(server \{|server_name |\}$)'
        }
        if diff -q <(strip "$dst") <(strip "/tmp/nginx-$n.conf") >/dev/null 2>&1; then
            echo "    nginx: kourt-$n carries certbot's TLS edits — left untouched, and matches the repo"
        else
            drift=1
            echo "    nginx: kourt-$n DRIFTED — left untouched, and it does NOT match the repo:"
            diff <(strip "$dst") <(strip "/tmp/nginx-$n.conf") | sed 's/^/        /' | head -40
            echo "        (< live, > repo).  This file was NOT updated. To apply the repo copy"
            echo "        while keeping certbot's TLS, edit /etc/nginx/sites-available/kourt-$n"
            echo "        by hand, then: nginx -t && systemctl reload nginx"
        fi
    else
        install -m 0644 "/tmp/nginx-$n.conf" "$dst"
        echo "    nginx: kourt-$n installed"
    fi
    ln -sf "$dst" "/etc/nginx/sites-enabled/kourt-$n"
    rm -f "/tmp/nginx-$n.conf"
done

# DRIFT IS A FAILURE FOR --config-only, whose ENTIRE job is to ship config. Left
# exit-0 it reported success having changed nothing, which is the shape of the bug
# this whole block exists for. A full run still proceeds: the chain is the point
# there, and a drifted vhost is a warning beside a working deploy.
if [ "$drift" = 1 ] && [ -n "${CONFIG_ONLY:-}" ]; then
    echo "FAIL: --config-only shipped no vhost change — every file it would have written" >&2
    echo "      is held by certbot's TLS edits and has drifted from the repo. See above." >&2
    exit 1
fi
# The old combined site, if a previous run installed one: its names now live in
# the per-name files, and leaving it enabled would declare each server_name twice.
if [ -e /etc/nginx/sites-enabled/kourt-chain ]; then
    # THE COMBINED FILE MAY BE THE ONLY THING SERVING TLS. certbot wrote its :443
    # blocks in there; the per-name files replacing it are HTTP-only until certbot
    # runs again. Retiring it quietly takes a working site off 443 and leaves the
    # next run reporting certificates that exist and serve nothing.
    had_tls=no
    grep -q ssl_certificate /etc/nginx/sites-available/kourt-chain 2>/dev/null && had_tls=yes
    rm -f /etc/nginx/sites-enabled/kourt-chain
    echo "    nginx: retired the combined kourt-chain site"
    if [ "$had_tls" = yes ]; then
        echo "    WARNING: it carried certbot's TLS blocks. The per-name files are"
        echo "             HTTP-only until you re-run:  ./deploy/certs.sh <host>"
    fi
fi
rm -f /tmp/kourtnode.service /tmp/kourtfaucet.service /tmp/kourtweb.service /tmp/nginx-zones.conf

# The faucet will not start without an hCaptcha secret, and starting it without
# one produces a unit that flaps. Say so once, here, instead.
if [ ! -s "$STATEDIR/secret/captcha.secret" ]; then
    echo "NOTE: no $STATEDIR/secret/captcha.secret yet — the faucet stays stopped."
    echo "      printf %s '<hcaptcha-secret>' > $STATEDIR/secret/captcha.secret"
    echo "      chmod 600 $STATEDIR/secret/captcha.secret && systemctl start kourtfaucet"
    FAUCET_READY=no
else
    FAUCET_READY=yes
fi

# A PORT CHECK THAT NAMES THE OCCUPANT. Without it the only symptom is a unit
# that flaps and a stack trace in the journal, which says the port is taken but
# not by what — and on a shared host that is the whole question.
if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$GNOWEB_PORT " ; then
    holder=$(ss -ltnp 2>/dev/null | grep "127.0.0.1:$GNOWEB_PORT " | sed 's/.*users:(("\([^"]*\)".*/\1/' | head -1)
    if ! systemctl is-active --quiet kourtweb; then
        echo "REFUSE: 127.0.0.1:$GNOWEB_PORT is already held by ${holder:-another process}." >&2
        echo "        Re-run with a free port, e.g. GNOWEB_PORT=8901 make chain ... --config-only" >&2
        exit 8
    fi
fi

systemctl daemon-reload
systemctl enable kourtnode >/dev/null 2>&1
if [ -n "${CONFIG_ONLY:-}" ]; then
    # A running chain is not restarted for a vhost change.
    systemctl is-active --quiet kourtnode || systemctl start kourtnode
else
    systemctl restart kourtnode
fi

echo "==> waiting for the chain"
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:26657/status >/dev/null 2>&1 && break
    sleep 3
done
curl -sf http://127.0.0.1:26657/status >/dev/null 2>&1 || {
    journalctl -u kourtnode -n 40 --no-pager; exit 5; }

# gnoweb only reads the node, so it needs no secret and can start unconditionally.
systemctl enable kourtweb >/dev/null 2>&1
systemctl restart kourtweb
sleep 2
systemctl is-active --quiet kourtweb || { journalctl -u kourtweb -n 20 --no-pager; exit 7; }

if [ "$FAUCET_READY" = yes ]; then
    systemctl enable kourtfaucet >/dev/null 2>&1
    systemctl restart kourtfaucet
    sleep 3
    systemctl is-active --quiet kourtfaucet || { journalctl -u kourtfaucet -n 30 --no-pager; exit 6; }
fi

nginx -t && systemctl reload nginx
REMOTE

# VERIFYING MEANS FAILING WHEN IT FAILS. This step used to curl the realm and pipe
# the answer to `head -c 200`: it PRINTED the response and never looked at it, so a
# deploy where nothing landed printed vm.InvalidPkgPathError and then the "Chain is
# up" banner, and exited 0. That is how a chain with no realm on it was reported as
# deployed.
#
# TWO THINGS, IN ORDER, because the second cannot pass while the first is broken:
#
#   1. BLOCKS. The realm ships as genesis TRANSACTIONS, which execute in block 1 —
#      so a chain stuck at height 0 has no realm no matter how well the genesis was
#      built. Observed: --reset wipes the chain but NOT the validator's signing
#      state, so the validator refused to sign at height 1 ("height regression:
#      expected >= 444, got 1"), consensus stalled before block 1, and the packages
#      never ran. The remedy is named in the failure rather than left to be
#      rediscovered.
#   2. THE REALM. A qeval that returns an Error field is a failure even though the
#      HTTP status is 200 — which is exactly why piping to head hid it.
echo "==> verifying the chain is producing blocks"
h=""
for _ in $(seq 1 30); do
    h="$("${SSH[@]}" "$HOST" 'curl -s -X POST http://127.0.0.1:26657 -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"status\",\"params\":{}}"' \
      | sed -n 's/.*"latest_block_height": *"\([0-9]*\)".*/\1/p' | head -1)"
    [ -n "$h" ] && [ "$h" -ge 1 ] 2>/dev/null && break
    sleep 2
done
if [ -z "$h" ] || ! [ "$h" -ge 1 ] 2>/dev/null; then
    echo "FAIL: the chain is at height ${h:-unknown} after 60s — it is not committing blocks," >&2
    echo "      so the genesis transactions that carry the realm have not run." >&2
    echo "      FIRST THING TO CHECK, because --reset does not do it:" >&2
    echo "        journalctl -u kourtnode -n 50 | grep -i 'height regression'" >&2
    echo "      A hit there means the validator still remembers signing a HIGHER height" >&2
    echo "      on the previous chain and will not sign this one. Keep the key, zero the" >&2
    echo "      state:" >&2
    echo "        systemctl stop kourtnode" >&2
    echo "        printf '{\"height\":\"0\",\"round\":\"0\",\"step\":0}' \\" >&2
    echo "          > $CHAINDIR/data/secrets/priv_validator_state.json" >&2
    echo "        systemctl start kourtnode" >&2
    exit 1
fi
echo "    height $h"

echo "==> verifying the realm answers on the chain"
out="$("${SSH[@]}" "$HOST" 'curl -s -X POST http://127.0.0.1:26657 -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"abci_query\",\"params\":{\"path\":\"vm/qrender\",\"data\":\"$(printf "gno.land/r/kourt/kourtv2:" | base64)\",\"height\":\"0\",\"prove\":false}}"')"
case "$out" in
    *InvalidPkgPathError*|*InvalidPackageError*)
        echo "FAIL: the realm is not on the chain — the genesis packages did not install." >&2
        echo "      The chain IS committing blocks (height $h), so this is not the validator" >&2
        echo "      state; look at the genesis build above and at:" >&2
        echo "        journalctl -u kourtnode -n 200 | grep -iE 'genesis|addpkg|panic'" >&2
        exit 1 ;;
esac
# A POSITIVE CHECK, because the obvious negative one is vacuous: ResponseBase
# carries "Error": null on SUCCESS, so matching '"Error"' matched every response
# ever and this step failed against a realm that was demonstrably rendering.
# Data is null on any failure and holds base64 markdown on success, so requiring
# Data is the assertion that distinguishes them.
case "$out" in
    *'"Data": "'*|*'"Data":"'*) echo "    the realm renders" ;;
    "") echo "FAIL: the realm read returned nothing at all." >&2; exit 1 ;;
    *)  echo "FAIL: the realm read returned no data:" >&2
        printf '      %s\n' "$(printf '%s' "$out" | tr -d '\n' | head -c 400)" >&2
        exit 1 ;;
esac
cat <<EOF

Chain is up as $CHAINID.

  RPC     http://rpc.kourt.xyz      (certbot: certbot --nginx -d rpc.kourt.xyz)
  faucet  http://faucet.kourt.xyz   (certbot: certbot --nginx -d faucet.kourt.xyz)

  A grant is 100 GNOT. Test it once TLS and the captcha secret are in place:
    curl -X POST https://faucet.kourt.xyz -H 'Content-Type: application/json' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"drip","params":["g1..."],"meta":{"captcha":"<token>"}}'

  Point the overlay at it: mode=live, RPC=https://rpc.kourt.xyz, chain=$CHAINID
EOF
