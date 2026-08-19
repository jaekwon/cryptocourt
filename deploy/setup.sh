#!/usr/bin/env bash
#
# One-time server setup: nginx, TLS, firewall, the service account and the
# IP-hashing key. Idempotent — safe to re-run, and it never overwrites a key or
# a database that already exists.
#
#   ./deploy/setup.sh root@kourt.xyz kourt.xyz
#
# Afterwards, deploy.sh ships the overlay and the binary. This script is the
# part you run once; that one is the part you run every time.

set -euo pipefail

HOST="${1:?usage: setup.sh user@host [domain]}"
DOMAIN="${2:-kourt.xyz}"
WEBROOT="${WEBROOT:-/var/www/kourt}"
APPDIR="${APPDIR:-/opt/kourt}"
STATEDIR="${STATEDIR:-/var/lib/kourt}"
EMAIL="${EMAIL:-}"

# One password for the whole run. Same block as deploy.sh: the first connection
# opens a control socket and every ssh and scp after it reuses that
# authenticated session, and the trap closes it on the way out INCLUDING on
# failure, so a run that dies halfway leaves nothing holding a root session.
CTL="${TMPDIR:-/tmp}/kourt-setup-$$"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120)
SCP=(scp -q -o ControlPath="$CTL")
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

cd "$(dirname "$0")"

echo "==> uploading the nginx site for $DOMAIN"
# The checked-in config names kourt.xyz; substitute whatever was asked for.
sed "s/kourt\.xyz/$DOMAIN/g" nginx.conf > /tmp/kourt-nginx.conf
"${SCP[@]}" /tmp/kourt-nginx.conf "$HOST:/tmp/kourt-nginx.conf"
rm -f /tmp/kourt-nginx.conf

"${SSH[@]}" "$HOST" DOMAIN="$DOMAIN" WEBROOT="$WEBROOT" APPDIR="$APPDIR" \
	STATEDIR="$STATEDIR" 'bash -seu' <<'REMOTE'
export DEBIAN_FRONTEND=noninteractive

echo "==> packages"
command -v nginx   >/dev/null || { apt-get update -qq; apt-get install -y -qq nginx; }
command -v certbot >/dev/null || apt-get install -y -qq certbot python3-certbot-nginx
command -v curl    >/dev/null || apt-get install -y -qq curl

echo "==> service account and directories"
id kourt >/dev/null 2>&1 || adduser --system --group --home "$APPDIR" kourt >/dev/null
mkdir -p "$APPDIR" "$WEBROOT" "$STATEDIR/secret"
chown -R kourt:kourt "$APPDIR" "$STATEDIR"
chmod 0750 "$STATEDIR"
chmod 0700 "$STATEDIR/secret"

echo "==> IP-hashing key"
# WITHOUT --secret-file the key is stored as a row INSIDE the database, so one
# file would carry both the address hashes and the key that reverses them. The
# unit passes --secret-file for exactly that reason, and the key gets its own
# 0700 directory because kourtchat also warns when the two merely share one.
#
# Never regenerated: rotating it silently would orphan every existing hash, so
# the throttle would stop recognising anyone it already knows.
KEY="$STATEDIR/secret/iphash.key"
if [ -s "$KEY" ]; then
	echo "    key already present, left alone"
else
	head -c 32 /dev/urandom | base64 > "$KEY"
	chown kourt:kourt "$KEY"
	chmod 0600 "$KEY"
	echo "    generated $KEY"
fi

echo "==> nginx"
mv /tmp/kourt-nginx.conf /etc/nginx/sites-available/kourt
ln -sf /etc/nginx/sites-available/kourt /etc/nginx/sites-enabled/kourt
# Debian ships a default site on port 80 that would answer for this name first.
rm -f /etc/nginx/sites-enabled/default
# A placeholder so the domain answers before deploy.sh has shipped anything —
# certbot's HTTP-01 challenge needs this server block serving, and a 404 root
# is indistinguishable from a broken install when you go looking.
if [ ! -e "$WEBROOT/index.html" ]; then
	printf '%s\n' '<!doctype html><title>Kourt</title><p>Set up. Not deployed yet.' \
		> "$WEBROOT/index.html"
	echo "    wrote a placeholder index.html (deploy.sh replaces it)"
fi
nginx -t
systemctl reload nginx

echo "==> firewall"
# Only if ufw is present and already the machine's story — enabling a firewall
# on a box that never had one is a good way to lock yourself out of the SSH
# session you are currently holding, so 22 goes in FIRST either way.
if command -v ufw >/dev/null; then
	ufw allow 22/tcp  >/dev/null
	ufw allow 80/tcp  >/dev/null
	ufw allow 443/tcp >/dev/null
	ufw --force enable >/dev/null
	echo "    22, 80, 443 open"
else
	echo "    ufw not installed, skipped"
fi
REMOTE

echo "==> TLS"
# LAST, and for two reasons: certbot needs this server block already serving on
# port 80, and it needs DNS for the domain already pointing at this machine. It
# is also the one step that legitimately fails on a fresh domain, so everything
# that can succeed has succeeded before it runs.
if "${SSH[@]}" "$HOST" "certbot certificates 2>/dev/null | grep -q 'Domains:.*$DOMAIN'"; then
	echo "    certificate for $DOMAIN already present"
else
	# --redirect makes certbot write the :443 server and the 80->443 redirect
	# into the site config. This is why nginx.conf ships HTTP-only.
	if [ -n "$EMAIL" ]; then
		REG=(--email "$EMAIL")
	else
		REG=(--register-unsafely-without-email)
	fi
	"${SSH[@]}" -t "$HOST" "certbot --nginx -d '$DOMAIN' --agree-tos ${REG[*]} --non-interactive --redirect" || {
		echo
		echo "certbot failed. Almost always DNS: check that $DOMAIN resolves to this"
		echo "machine and that port 80 is reachable from the internet, then re-run."
		echo "Everything above is already done, so re-running is cheap."
		exit 1
	}
fi

# Renewal is certbot's own systemd timer, installed by the package. Say so
# rather than leaving it to be wondered about in ninety days.
"${SSH[@]}" "$HOST" "systemctl is-enabled certbot.timer >/dev/null 2>&1 \
	&& echo '    renewal: certbot.timer is enabled' \
	|| echo '    renewal: certbot.timer NOT enabled — run: systemctl enable --now certbot.timer'"

echo
echo "==> setup complete"
cat <<MSG

  https://$DOMAIN answers, with a placeholder page. Ship the real one:

    make deploy HOST=$HOST

  The database and the hashing key live under $STATEDIR and are never
  copied from a laptop — setup made the key, deploy will not touch it.
MSG
