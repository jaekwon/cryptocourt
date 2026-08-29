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

HOST="${1:?usage: chain.sh user@host [--reset]}"
RESET="${2:-}"
CHAINID="${CHAINID:-kourt-1}"
APPDIR="${APPDIR:-/opt/kourt}"
STATEDIR="${STATEDIR:-/var/lib/kourt}"
CHAINDIR="$STATEDIR/chain"
# Premined at genesis, in ugnot. The faucet needs enough to answer grants for a
# long time without a refill ceremony; 5M GNOT is 50,000 grants at 100 each.
FAUCET_PREMINE="${FAUCET_PREMINE:-5000000000000}"
OWNER_ADDR="${OWNER_ADDR:-}"          # optional: an address to premine for yourself
OWNER_PREMINE="${OWNER_PREMINE:-1000000000000}"

cd "$(dirname "$0")/.."
REPO="$PWD"
: "${GNOROOT:?set GNOROOT to a gno checkout (needs examples/ for p/nt packages)}"
[ -d "$GNOROOT/examples" ] || { echo "chain.sh: no examples/ under GNOROOT"; exit 2; }

CTL="${TMPDIR:-/tmp}/kourt-chain-$$"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=180)
SCP=(scp -q -o ControlPath="$CTL")
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

echo "==> building linux binaries"
# CGO_ENABLED=0 so they run on any distro, matching deploy.sh's kourtchat build.
( cd "$GNOROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnoland" ./gno.land/cmd/gnoland )
( cd "$GNOROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnokey"  ./gno.land/cmd/gnokey )
( cd "$GNOROOT/contribs/gnogenesis" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnogenesis" . )
( cd "$GNOROOT/contribs/gnofaucet"  && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$WORK/gnofaucet"  . )
# gnogenesis also runs HERE, on this machine, to build the genesis from the
# packages in this repo. Build a host copy alongside the linux one.
( cd "$GNOROOT/contribs/gnogenesis" && go build -o "$WORK/gnogenesis-host" . )
( cd "$GNOROOT" && go build -o "$WORK/gnokey-host" ./gno.land/cmd/gnokey )
ls -l "$WORK" | awk '{print "    " $9, $5}' | grep -v '^    $'

echo "==> phase 1: server-side secrets"
"${SCP[@]}" "$WORK/gnoland" "$WORK/gnokey" "$WORK/gnogenesis" "$WORK/gnofaucet" "$HOST:/tmp/"
PUBLIC=$("${SSH[@]}" "$HOST" APPDIR="$APPDIR" STATEDIR="$STATEDIR" CHAINDIR="$CHAINDIR" \
  RESET="$RESET" 'bash -seu' <<'REMOTE'
mkdir -p "$APPDIR/bin" "$CHAINDIR/data/secrets" "$STATEDIR/secret"
for b in gnoland gnokey gnogenesis gnofaucet; do
    install -m 0755 "/tmp/$b" "$APPDIR/bin/$b"; rm -f "/tmp/$b"
done

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
# A deployer key for the genesis txs. It signs nothing after genesis and the node
# starts with -skip-genesis-sig-verification, so it is ephemeral by design.
GNOHOME="$WORK/gnohome"; mkdir -p "$GNOHOME"
"$WORK/gnokey-host" add deployer -home "$GNOHOME" -insecure-password-stdin >/dev/null 2>&1 <<EOF
kourt-genesis
kourt-genesis
EOF
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
# The whole closure in ONE call: gnogenesis sorts per invocation and cannot see
# packages already in the file (scripts/genesis-pkgs.py says more).
"$WORK/gnogenesis-host" txs add packages "$WORK/pkgs" -genesis-path "$WORK/genesis.json" \
    -key-name deployer -gno-home "$GNOHOME" -insecure-password-stdin <<EOF | tail -1
kourt-genesis
EOF

echo "==> shipping genesis and units"
"${SCP[@]}" "$WORK/genesis.json" "$HOST:$CHAINDIR/genesis.json"
"${SCP[@]}" deploy/kourtnode.service deploy/kourtfaucet.service "$HOST:/tmp/"
"${SCP[@]}" deploy/nginx-chain.conf "$HOST:/tmp/nginx-chain.conf"

"${SSH[@]}" "$HOST" APPDIR="$APPDIR" STATEDIR="$STATEDIR" CHAINDIR="$CHAINDIR" 'bash -seu' <<'REMOTE'
chown -R kourt:kourt "$CHAINDIR"
install -m 0644 /tmp/kourtnode.service   /etc/systemd/system/kourtnode.service
install -m 0644 /tmp/kourtfaucet.service /etc/systemd/system/kourtfaucet.service
# NEVER CLOBBER CERTBOT'S EDITS. `certbot --nginx` rewrites this very file to add
# the :443 server, the certificate paths and the 80->443 redirect. Re-running
# chain.sh with a plain install would put the HTTP-only version back and take TLS
# down silently — the site would still answer, on port 80, and nothing would say
# why. If the installed copy has a certificate in it, leave it alone and say so.
if grep -q ssl_certificate /etc/nginx/sites-available/kourt-chain 2>/dev/null; then
    echo "    nginx: kourt-chain carries certbot's TLS edits — left untouched"
    echo "           (delete it and re-run ./deploy/certs.sh to rebuild from the repo copy)"
else
    install -m 0644 /tmp/nginx-chain.conf /etc/nginx/sites-available/kourt-chain
fi
ln -sf /etc/nginx/sites-available/kourt-chain /etc/nginx/sites-enabled/kourt-chain
rm -f /tmp/kourtnode.service /tmp/kourtfaucet.service /tmp/nginx-chain.conf

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

systemctl daemon-reload
systemctl enable kourtnode >/dev/null 2>&1
systemctl restart kourtnode

echo "==> waiting for the chain"
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:26657/status >/dev/null 2>&1 && break
    sleep 3
done
curl -sf http://127.0.0.1:26657/status >/dev/null 2>&1 || {
    journalctl -u kourtnode -n 40 --no-pager; exit 5; }

if [ "$FAUCET_READY" = yes ]; then
    systemctl enable kourtfaucet >/dev/null 2>&1
    systemctl restart kourtfaucet
    sleep 3
    systemctl is-active --quiet kourtfaucet || { journalctl -u kourtfaucet -n 30 --no-pager; exit 6; }
fi

nginx -t && systemctl reload nginx
REMOTE

echo "==> verifying the realm answers on the chain"
"${SSH[@]}" "$HOST" 'curl -s -X POST http://127.0.0.1:26657 -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"abci_query\",\"params\":{\"path\":\"vm/qrender\",\"data\":\"$(printf "gno.land/r/kourt/kourtv2:" | base64)\",\"height\":\"0\",\"prove\":false}}" \
  | head -c 200'
echo
cat <<EOF

Chain is up as $CHAINID.

  RPC     http://rpc.kourt.xyz      (certbot: certbot --nginx -d rpc.kourt.xyz)
  faucet  http://faucet.kourt.xyz   (certbot: certbot --nginx -d faucet.kourt.xyz)

  A grant is 100 GNOT. Test it once TLS and the captcha secret are in place:
    curl -X POST https://faucet.kourt.xyz -H 'Content-Type: application/json' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"drip","params":["g1..."],"meta":{"captcha":"<token>"}}'

  Point the overlay at it: mode=live, RPC=https://rpc.kourt.xyz, chain=$CHAINID
EOF
