#!/usr/bin/env bash
#
# Ship both halves of Kourt to one box.
#
#   ./deploy/deploy.sh root@kourt.xyz
#
# There are two things to deploy and they are unrelated to each other:
#
#   the overlay   web/index.html — ONE self-contained static file. No build, no
#                 bundler, no assets directory: it is a copy into a webroot.
#   the chat      cmd/kourtchat — a Go service with a SQLite database. It never
#                 talks to the model (the scanner is a separate process that
#                 wants a GPU; this does not), so it is at home on the same
#                 ordinary box as the static file.
#
# The realm is NOT deployed from here. It goes to a gno chain with gnokey, and
# the overlay reads whichever chain you point it at.
#
# NOT COPIED, EVER: the database, the IP-hashing key, and anything else under
# /var/lib/kourt. The database is the service's whole memory and the key
# reverses its address hashes; both belong only on the server. This script
# creates the paths and then keeps its hands off them.

set -euo pipefail

HOST="${1:?usage: deploy.sh user@host}"
WEBROOT="${WEBROOT:-/var/www/kourt}"
APPDIR="${APPDIR:-/opt/kourt}"
STATEDIR="${STATEDIR:-/var/lib/kourt}"
SKIP_CHECKS="${SKIP_CHECKS:-}"

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- one password
# This script opens about nine connections. With password auth that is nine
# prompts, which is how people end up pasting a key into a script or leaving an
# agent unlocked. OpenSSH multiplexes: the first connection opens a control
# socket and every ssh and scp after it rides the same authenticated session.
#
# The trap closes the socket on the way out INCLUDING ON FAILURE — a deploy that
# dies halfway must not leave a live root session on the machine, which is the
# failure mode that makes multiplexing worse than the prompts.
CTL="${TMPDIR:-/tmp}/kourt-deploy-$$"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60)
SCP=(scp -q -o ControlPath="$CTL")
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

say() { printf '==> %s\n' "$*"; }

# ------------------------------------------------------------- refuse to ship
# Cheap gates only — the full `make check` wants a gno toolchain and a node, and
# a deploy script that takes ten minutes gets bypassed. These are the ones that
# catch the class of thing that has actually shipped broken: a syntax error in
# the overlay, and two functions sharing a name in its one flat scope (that one
# reached a user, as a court page that threw on load).
if [ -z "$SKIP_CHECKS" ]; then
	say "checking what is about to be shipped"
	python3 scripts/check-web-dupes.py

	# node --check on the overlay's script block. If node is absent, say so
	# rather than skipping quietly: a check that silently does not run is worse
	# than no check.
	if command -v node >/dev/null; then
		python3 - <<-'PY' >/tmp/kourt-overlay.js
		import io
		s = io.open("web/index.html", encoding="utf-8").read()
		a = s.index("<script>") + len("<script>")
		b = s.rindex("</script>")
		io.open("/tmp/kourt-overlay.js", "w", encoding="utf-8").write(s[a:b])
		PY
		node --check /tmp/kourt-overlay.js
		rm -f /tmp/kourt-overlay.js
		echo "    overlay parses"
	else
		echo "    node not found — overlay NOT syntax-checked (set SKIP_CHECKS=1 to stop being told)" >&2
	fi

	gofmt -l cmd internal | { ! grep .; } || { echo "unformatted Go above" >&2; exit 1; }
	go vet ./internal/... ./cmd/... >/dev/null
	go test ./internal/... ./cmd/... >/dev/null
	echo "    go vet + tests pass"
fi

# The overlay's one promise is that it is self-contained; a deploy that shipped
# a page reaching for a CDN would break every offline and file:// use of it, and
# the CSP on a hardened host would break it in production too.
say "checking the overlay is still self-contained"
if grep -nE '(src|href)="https?://' web/index.html | grep -v 'rel="noopener"' ; then
	echo "the overlay references an external URL (above) — it must be self-contained" >&2
	exit 1
fi
# index.html loads exactly one local file — chat.js, the court chat panel. The
# first version of this script shipped index.html ALONE, so the deployed page
# 404'd on chat.js and the panel could never mount however the service was
# configured. The check is not "no external URLs" but "every file it asks for is
# a file we are shipping".
LOCAL_SCRIPTS=$(grep -oE '<script src="[^"]+"' web/index.html | sed 's/.*src="//;s/"//')
for f in $LOCAL_SCRIPTS; do
	case "$f" in
	http*|//*) echo "the overlay loads a remote script: $f" >&2; exit 1;;
	esac
	[ -f "web/$f" ] || { echo "the overlay loads web/$f, which does not exist" >&2; exit 1; }
	grep -qx "$f" <<-LIST || { echo "the overlay loads web/$f, which this script does not ship" >&2; exit 1; }
	chat.js
	LIST
done
LOCAL_SHA=$(shasum -a 256 web/index.html | cut -d' ' -f1)
CHAT_SHA=$(shasum -a 256 web/chat.js | cut -d' ' -f1)
echo "    index.html  sha ${LOCAL_SHA:0:16}…  $(wc -c < web/index.html | tr -d ' ') bytes"
echo "    chat.js     sha ${CHAT_SHA:0:16}…  $(wc -c < web/chat.js | tr -d ' ') bytes"

say "building kourtchat for linux/amd64"
# Fully static: the SQLite driver is modernc.org/sqlite, pure Go, so CGO stays
# off and the binary runs on any distro regardless of libc.
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
	go build -trimpath -ldflags="-s -w" -o /tmp/kourtchat-linux ./cmd/kourtchat
echo "    $(wc -c < /tmp/kourtchat-linux | tr -d ' ') bytes"

# ------------------------------------------------------------------ the server
# Idempotent: every step is a no-op once done, so a fresh box needs no manual
# preparation and an existing one is not disturbed.
say "preparing $HOST"
"${SSH[@]}" "$HOST" "
  set -e
  id kourt >/dev/null 2>&1 || adduser --system --group --home $APPDIR kourt
  mkdir -p $APPDIR $WEBROOT $STATEDIR/secret
  chown -R kourt:kourt $APPDIR $STATEDIR
  # The key that reverses the address hashes must not be readable by anyone
  # else on the box, and must not share a directory with the database it
  # reverses — kourtchat warns about both configurations.
  chmod 0750 $STATEDIR
  chmod 0700 $STATEDIR/secret
"

say "uploading"
# Alongside, then rename. Replacing a running binary in place fails ETXTBSY,
# and a half-written index.html served to a reader is a broken page — a rename
# within the same filesystem is atomic, so nobody sees either.
"${SCP[@]}" /tmp/kourtchat-linux "$HOST:$APPDIR/kourtchat.new"
"${SCP[@]}" web/index.html "$HOST:$WEBROOT/index.html.new"
"${SCP[@]}" web/chat.js "$HOST:$WEBROOT/chat.js.new"
"${SCP[@]}" deploy/kourtchat.service "$HOST:/tmp/kourtchat.service"

say "installing"
"${SSH[@]}" "$HOST" "
  set -e
  mv $APPDIR/kourtchat.new $APPDIR/kourtchat
  chmod 0755 $APPDIR/kourtchat
  chown kourt:kourt $APPDIR/kourtchat

  # chat.js before index.html: for the moment between the two renames, a reader
  # must never get a new page pointing at an old panel. The other order is the
  # one that breaks.
  mv $WEBROOT/chat.js.new $WEBROOT/chat.js
  chmod 0644 $WEBROOT/chat.js
  mv $WEBROOT/index.html.new $WEBROOT/index.html
  chmod 0644 $WEBROOT/index.html

  # Keep the unit in step with the repo, and reload only when it changed — a
  # daemon-reload on every deploy hides which one actually altered the service.
  if ! cmp -s /tmp/kourtchat.service /etc/systemd/system/kourtchat.service; then
    mv /tmp/kourtchat.service /etc/systemd/system/kourtchat.service
    systemctl daemon-reload
    systemctl enable kourtchat >/dev/null 2>&1
    echo '    unit changed'
  fi
  rm -f /tmp/kourtchat.service
"

say "restarting kourtchat"
"${SSH[@]}" "$HOST" "
  set -e
  systemctl restart kourtchat
  sleep 1
  systemctl is-active --quiet kourtchat || { journalctl -u kourtchat -n 40 --no-pager; exit 1; }
"

# ------------------------------------------------------------------- verifying
# Ask the unit where it listens rather than assuming 8788. A deploy that worked
# but reported a failed health check is the kind of false alarm that gets
# ignored the next time it is real.
say "verifying"
"${SSH[@]}" "$HOST" "
  set -e
  # POSIX BRE: \+ is a GNU extension and the target is not guaranteed to be GNU.
  # [^ ]* stops at the space before the line-continuation backslash, so the
  # backslash never needs escaping through two layers of quoting.
  addr=\$(sed -n 's/.*--addr[[:space:]][[:space:]]*\([^ ]*\).*/\1/p' /etc/systemd/system/kourtchat.service | head -1)
  addr=\${addr:-127.0.0.1:8788}
  out=\$(curl -fsS \"http://\$addr/api/chat/health\") || { echo 'chat health check FAILED'; exit 1; }
  echo \"    chat  \$addr  \$(echo \"\$out\" | head -c 120)\"
"

# The file that left this machine is the file being served. A webroot with a
# stale copy, a proxy caching the old one, or a server root pointed somewhere
# else all look identical from here without this.
"${SSH[@]}" "$HOST" "
  set -e
  remote=\$(sha256sum $WEBROOT/index.html | cut -d' ' -f1)
  if [ \"\$remote\" != '$LOCAL_SHA' ]; then
    echo \"    index.html on disk does NOT match what was shipped (\$remote)\"; exit 1
  fi
  rchat=\$(sha256sum $WEBROOT/chat.js | cut -d' ' -f1)
  if [ \"\$rchat\" != '$CHAT_SHA' ]; then
    echo \"    chat.js on disk does NOT match what was shipped (\$rchat)\"; exit 1
  fi
  echo \"    site  index.html + chat.js  match\"
"

say "deployed"
cat <<MSG

  The overlay is at $WEBROOT/index.html and the chat service is listening on
  loopback. Serving them to the world is nginx's job, not this script's — see
  deploy/README.md. Nothing has been done to TLS or to the firewall here.

  The database and the hashing key were not touched:
    $STATEDIR/chat.db
    $STATEDIR/secret/iphash.key
MSG
