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
# index.html loads two local files — chat.js, the court chat panel, and
# media.js, the rules for evidence filed with a claim. The
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
	media.js
	LIST
done
# THE PREVIEW IMAGE MUST EXIST, and at the URL the tags claim. A card that 404s
# is worse than no card: X and Slack cache the miss for days, so the fix does not
# show up when you make it. The page names https://<host>/og.png absolutely
# because no crawler follows a data: URI.
say "checking the link-preview image"
OG=$(grep -oE '<meta property="og:image" content="[^"]+"' web/index.html |
     sed 's/.*content="//;s/"//' | head -1)
if [ -n "$OG" ]; then
	OGFILE="web/$(basename "$OG")"
	[ -f "$OGFILE" ] || { echo "the overlay claims og:image $OG but $OGFILE does not exist" >&2; exit 1; }
	# and it is the card the source draws, not a stale export
	if command -v node >/dev/null 2>&1; then
		node scripts/make-og-card.js --check || exit 1
	fi
	echo "    $OGFILE  $(wc -c < "$OGFILE" | tr -d ' ') bytes  →  $OG"
fi

say "stamping the overlay's chain config"
# THE SHIPPED PAGE MUST NOT OPEN IN DEMO. web/index.html defaults to
# {mode:"demo", rpc:"http://127.0.0.1:26657", chainid:"dev"} because that is the
# right default for a file:// copy on a laptop — and exactly the wrong one for a
# public site, where it means every visitor sees sample data and a loopback RPC
# they cannot reach. The repo keeps the demo default; the DEPLOYED copy is
# stamped with this chain, so what a reader gets is fixed at deploy time rather
# than left to a settings panel they have to find.
#
# Stamped on a COPY. Editing web/index.html in place would leave the working tree
# dirty with deployment values and put them in the next commit.
STAMPED="$(mktemp -t kourt-index).html"
trap 'rm -f "$STAMPED" /tmp/kourtchat-linux' EXIT
SITE_MODE="${SITE_MODE:-live}"
SITE_RPC="${SITE_RPC:-https://rpc.kourt.xyz}"
SITE_CHAINID="${SITE_CHAINID:-kourt-1}"
# gnoweb is where every action button sends a reader to sign: tx() builds
# CFG.gnoweb + "/r/kourt/kourtv2$help&func=…". There is no gnoweb on this host,
# so the honest default is the repo's — and that points at gno.land, which does
# NOT carry this realm. Say so rather than stamping a link that 404s quietly.
SITE_GNOWEB="${SITE_GNOWEB:-https://gnoweb.kourt.xyz}"
python3 - "$STAMPED" <<PYEOF
import re, sys
src = open("web/index.html", encoding="utf-8").read()
cfg = {"mode": "$SITE_MODE", "rpc": "$SITE_RPC", "chainid": "$SITE_CHAINID"}
gnoweb = "$SITE_GNOWEB"
pat = re.compile(r'const CFG_DEFAULTS = \{[^}]*\};')
if len(pat.findall(src)) != 1:
    sys.exit("deploy: expected exactly one CFG_DEFAULTS line to stamp")
old = pat.search(src).group(0)
keep = re.search(r'gnoweb:"([^"]*)"', old).group(1)
line = ('const CFG_DEFAULTS = {mode:"%s", rpc:"%s", gnoweb:"%s", chainid:"%s"};'
        % (cfg["mode"], cfg["rpc"], gnoweb or keep, cfg["chainid"]))
out = pat.sub(lambda _: line, src, count=1)

# The source panel is not shown on a deployed site. It offers mode, RPC, gnoweb,
# chain id and chat — a way to point this page at another node and then read the
# answer as though it came from this court. The repo copy keeps it, because
# choosing a node is what that copy is for.
lockpat = re.compile(r'^const LOCKED = false;$', re.M)
if len(lockpat.findall(out)) != 1:
    sys.exit("deploy: expected exactly one LOCKED line to stamp")
out = lockpat.sub("const LOCKED = true;", out, count=1)

open(sys.argv[1], "w", encoding="utf-8").write(out)
print("    " + line)
print("    const LOCKED = true;   (source panel hidden)")
PYEOF
grep -q "mode:\"$SITE_MODE\"" "$STAMPED" || { echo "deploy: the stamp did not apply" >&2; exit 1; }
grep -q 'const LOCKED = true;' "$STAMPED" || { echo "deploy: the lock did not apply" >&2; exit 1; }
if [ -z "$SITE_GNOWEB" ]; then
	echo "    NOTE: gnoweb left at the repo default — action buttons link to a chain"
	echo "          that does not carry this realm. Set SITE_GNOWEB= to fix."
fi

LOCAL_SHA=$(shasum -a 256 "$STAMPED" | cut -d' ' -f1)
CHAT_SHA=$(shasum -a 256 web/chat.js | cut -d' ' -f1)
MEDIA_SHA=$(shasum -a 256 web/media.js | cut -d' ' -f1)
echo "    index.html  sha ${LOCAL_SHA:0:16}…  $(wc -c < "$STAMPED" | tr -d ' ') bytes"
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
"${SCP[@]}" "$STAMPED" "$HOST:$WEBROOT/index.html.new"
"${SCP[@]}" web/chat.js "$HOST:$WEBROOT/chat.js.new"
"${SCP[@]}" web/media.js "$HOST:$WEBROOT/media.js.new"
# `[ ... ] && cmd` would abort the whole script under `set -e` when the test is
# false, which is the ordinary case of a page with no card.
if [ -n "${OGFILE:-}" ]; then
	"${SCP[@]}" "$OGFILE" "$HOST:$WEBROOT/$(basename "$OGFILE").new"
fi
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
  mv $WEBROOT/media.js.new $WEBROOT/media.js
  chmod 0644 $WEBROOT/media.js
  # the link-preview card, before index.html — so the page never names a file
  # that is not there yet
  if [ -f $WEBROOT/og.png.new ]; then mv $WEBROOT/og.png.new $WEBROOT/og.png; chmod 0644 $WEBROOT/og.png; fi
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
  rmedia=\$(sha256sum $WEBROOT/media.js | cut -d' ' -f1)
  if [ \"\$rmedia\" != '$MEDIA_SHA' ]; then
    echo \"    media.js on disk does NOT match what was shipped (\$rmedia)\"; exit 1
  fi
  echo \"    site  index.html + chat.js + media.js  match\"
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
