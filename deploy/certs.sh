#!/usr/bin/env bash
# TLS for the chain's two names, issued by certbot against the nginx site that
# deploy/chain.sh installed.
#
#   EMAIL=you@example.com ./deploy/certs.sh root@kourt.xyz
#   ./deploy/certs.sh root@kourt.xyz rpc.kourt.xyz faucet.kourt.xyz other.name
#
# WHY THIS IS ITS OWN SCRIPT. setup.sh does the same job for the apex domain and
# does it LAST, because certbot is the one step that legitimately fails on a
# fresh domain — DNS has to have propagated and the :80 server block has to be
# serving already. The chain's names arrive later than the apex and can fail
# independently, so they get their own runnable step rather than being buried in
# a deploy that also moves binaries.
#
# ONE CERTIFICATE PER NAME, issued in a loop, rather than one SAN certificate
# covering both. A single `certbot -d rpc -d faucet` run fails ENTIRELY if either
# name is not yet resolvable, and then neither gets TLS; separately, a name that
# is not ready costs only itself.
set -euo pipefail

HOST="${1:?usage: certs.sh user@host [domain ...]}"
shift || true
DOMAINS=("$@")
if [ ${#DOMAINS[@]} -eq 0 ]; then
    DOMAINS=(rpc.kourt.xyz faucet.kourt.xyz gnoweb.kourt.xyz)
fi
EMAIL="${EMAIL:-}"

CTL="${TMPDIR:-/tmp}/kourt-certs-$$"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120)
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

if [ -n "$EMAIL" ]; then
    REG=(--email "$EMAIL")
else
    REG=(--register-unsafely-without-email)
fi

echo "==> preflight"
# certbot's HTTP-01 challenge fails with a message about the challenge file when
# the real problem is one of these two. Checking them here turns a confusing
# certbot error into a sentence that names the actual cause.
"${SSH[@]}" "$HOST" 'command -v certbot >/dev/null' || {
    echo "certs.sh: certbot is not installed on $HOST — run ./deploy/setup.sh first" >&2; exit 2; }
"${SSH[@]}" "$HOST" 'ls /etc/nginx/sites-enabled/kourt-rpc /etc/nginx/sites-enabled/kourt-faucet \
    /etc/nginx/sites-enabled/kourt-gnoweb >/dev/null 2>&1' || {
    echo "certs.sh: the kourt vhosts are not all enabled — run:" >&2
    echo "    ./deploy/chain.sh $HOST --config-only" >&2; exit 2; }
"${SSH[@]}" "$HOST" 'nginx -t' >/dev/null 2>&1 || {
    echo "certs.sh: nginx config is invalid on $HOST; fix that before issuing certificates" >&2
    "${SSH[@]}" "$HOST" 'nginx -t' || true; exit 2; }

SERVER_IP=$("${SSH[@]}" "$HOST" 'curl -s -m 10 https://api.ipify.org || hostname -I | awk "{print \$1}"')
echo "    host answers as ${SERVER_IP:-unknown}"

rc=0
for D in "${DOMAINS[@]}"; do
    echo "==> $D"

    # DNS, checked from the SERVER. Checking from here would pass on a laptop
    # with a stale resolver cache and then fail inside certbot for a reason the
    # output does not connect to DNS.
    RESOLVED=$("${SSH[@]}" "$HOST" "getent hosts '$D' | awk '{print \$1}' | head -1" || true)
    if [ -z "$RESOLVED" ]; then
        echo "    SKIP: $D does not resolve yet"; rc=1; continue
    fi
    if [ -n "$SERVER_IP" ] && [ "$RESOLVED" != "$SERVER_IP" ]; then
        # A warning, not a refusal: split-horizon DNS, a proxy, or IPv6-only are
        # all legitimate reasons for these to differ, and certbot is the real
        # authority on whether the challenge can be answered.
        echo "    note: $D resolves to $RESOLVED, host reports $SERVER_IP — continuing"
    fi

    # ISSUED IS NOT INSTALLED, and conflating the two is why faucet.kourt.xyz
    # reported "already present" while answering nothing on 443. certbot can
    # obtain a certificate and then fail to deploy it — "Could not automatically
    # find a matching server block" — leaving a valid cert on disk and no TLS
    # listener. So check for the certificate AND for an nginx block that
    # references one for this name; when the first holds and the second does not,
    # install the existing cert rather than requesting a new one, which would
    # burn a rate-limit slot to fix a problem issuance cannot fix.
    HAVE_CERT=no; HAVE_INSTALL=no
    "${SSH[@]}" "$HOST" "certbot certificates 2>/dev/null | grep -q 'Domains:.*\\b$D\\b'" && HAVE_CERT=yes
    # ASK THE SERVER TO SERVE IT, rather than inferring from files. The previous
    # test grepped sites-enabled for a block naming $D and piped that into
    # `xargs -r grep -l ssl_certificate` — and it reported "installed" for every
    # name, always: `grep -r` does not follow the symlinks sites-enabled is made
    # of, so the first grep matched nothing, and `xargs -r` with empty input runs
    # nothing and EXITS 0. A test that could not fail reported TLS as fine while
    # nothing at all answered on 443.
    #
    # --resolve pins the name to loopback, so this asks THIS host for THIS
    # certificate without depending on public DNS; -k because the question is
    # whether a TLS vhost exists, not whether the chain validates.
    TLSCODE=$("${SSH[@]}" "$HOST" "curl -sk -o /dev/null -m 8 -w '%{http_code}' --resolve '$D:443:127.0.0.1' 'https://$D/' 2>/dev/null" || true)
    { [ -n "$TLSCODE" ] && [ "$TLSCODE" != "000" ]; } && HAVE_INSTALL=yes || true

    if [ "$HAVE_CERT" = yes ] && [ "$HAVE_INSTALL" = yes ]; then
        echo "    certificate present and installed"
        continue
    fi
    if [ "$HAVE_CERT" = yes ]; then
        echo "    certificate exists but is not installed — installing it"
        if "${SSH[@]}" -t "$HOST" "certbot install --cert-name '$D' --nginx --non-interactive --redirect"; then
            echo "    installed"
        else
            echo "    FAILED to install $D — is there a server_name block for it?" >&2
            rc=1
        fi
        continue
    fi

    # --redirect writes the :443 server and the 80->443 redirect into the site
    # config, which is why deploy/nginx-chain.conf ships HTTP-only and why
    # chain.sh refuses to overwrite the file once these edits exist.
    if "${SSH[@]}" -t "$HOST" \
        "certbot --nginx -d '$D' --agree-tos ${REG[*]} --non-interactive --redirect"; then
        echo "    issued"
    else
        echo "    FAILED for $D — the other names are unaffected" >&2
        rc=1
    fi
done

echo "==> reloading nginx"
"${SSH[@]}" "$HOST" 'nginx -t && systemctl reload nginx'

echo "==> verifying over TLS, from the outside"
for D in "${DOMAINS[@]}"; do
    # From HERE, not from the server: a certificate that only validates against
    # the machine's own loopback is not a certificate a browser will accept, and
    # the overlay reads these names from other people's browsers.
    # NOT `$(curl ... || echo 000)`: on failure curl still prints its own "000"
    # and then the echo appends another, so the variable reads "000000" and the
    # case below matches nothing. Capture, then default only if empty.
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$D/" 2>/dev/null) || true
    [ -n "$code" ] || code=000
    case "$D:$code" in
        *:000) echo "    $D  no answer over https"; rc=1 ;;
        *)     echo "    $D  https $code" ;;
    esac
done

cat <<EOF

Renewal is certbot's own systemd timer; nothing here needs a cron entry.
Check it with:  ssh $HOST 'systemctl list-timers certbot*'

Now point the overlay at the chain:
  mode=live, RPC=https://rpc.kourt.xyz, chain=\${CHAINID:-kourt-1}
EOF
exit $rc
