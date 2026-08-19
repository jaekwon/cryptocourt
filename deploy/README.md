# Deploying Kourt

Three things exist and only two of them are deployed from here.

| | what it is | where it goes |
|---|---|---|
| **the overlay** | `web/index.html`, one self-contained static file | a webroot, `/var/www/kourt` |
| **the chat** | `cmd/kourtchat`, a Go service with a SQLite database | `/opt/kourt`, under systemd |
| the realm | `realm/r/kourtv2` | a gno chain, with `gnokey` — **not** from this script |

The overlay reads whichever chain you point it at, so shipping the page and
deploying the realm are separate acts with separate blast radii. That is the
point: `web/README.md` calls the overlay a presentation layer, and every screen
in it can be served by the realm's own `Render`.

**The scanner is not here either.** It wants a GPU and runs on its own box.
`cmd/kourtchat` never talks to the model — CHAT.md is explicit that accepting,
storing, throttling and enforcing keep working whether or not the scanner is
running — which is why the chat is at home on an ordinary VPS beside the static
file, and why its unit orders itself against nothing.

## Every deploy

```sh
make deploy HOST=root@kourt.example
```

You are asked for the SSH password **once**. The script makes about nine
connections; OpenSSH multiplexes them over one control socket, and a `trap`
closes that socket on the way out including on failure — a deploy that dies
halfway must not leave a live root session behind.

What it does, in order:

1. **Refuses to ship a broken build.** `check-web-dupes.py` (two functions
   sharing a name in the overlay's one flat scope shipped once and broke the
   court page), `node --check` on the overlay's script block, `gofmt`, `go vet`,
   `go test`. Set `SKIP_CHECKS=1` to bypass, and know that you did.
2. **Refuses to ship an overlay that is not self-contained** — one `src=` or
   `href=` pointing at an external host and it stops. That promise is what makes
   the page work from `file://`, offline, and under the CSP below.
3. Cross-compiles `kourtchat`, fully static (`CGO_ENABLED=0` — the SQLite driver
   is `modernc.org/sqlite`, pure Go), so it runs on any distro.
4. Uploads both alongside their live copies and **renames into place**.
   Overwriting a running binary fails `ETXTBSY`, and a half-written `index.html`
   served to a reader is a broken page; a rename is atomic.
5. Restarts the service and **verifies**: the chat's own
   `/api/chat/health`, at the address read out of the unit rather than assumed,
   and a `sha256` of the deployed `index.html` against the one that left your
   machine — a stale webroot, a caching proxy and a misdirected server root all
   look identical from here without that check.

Overridable: `WEBROOT`, `APPDIR`, `STATEDIR`.

### What it never touches

The database and the IP-hashing key. Both live under `/var/lib/kourt` and only
on the server. The database is the service's whole memory; the key reverses the
address hashes inside it, which is why they are not even in the same directory
(`kourtchat` warns about both arrangements). The script creates the paths, sets
the modes, and keeps its hands off the contents.

It also never touches nginx, TLS or the firewall. A deploy script that rewrites
the web server's config can take the site down without shipping anything.

## First time on a box

The deploy is idempotent and creates the user, the directories and the unit by
itself. Two things remain manual, once:

**1. The IP-hashing key.**

```sh
install -d -m 0700 -o kourt -g kourt /var/lib/kourt/secret
head -c 32 /dev/urandom | base64 > /var/lib/kourt/secret/iphash.key
chown kourt:kourt /var/lib/kourt/secret/iphash.key
chmod 0600 /var/lib/kourt/secret/iphash.key
```

Without `--secret-file` the key is stored as a row *inside* the database, so one
file would carry both the address hashes and the key that reverses them. The
unit passes `--secret-file` for that reason; put the file there before the first
start or the service writes one for you in the place you were avoiding.

**2. nginx and TLS.**

```sh
cp deploy/nginx.conf /etc/nginx/sites-available/kourt
# edit server_name
ln -s /etc/nginx/sites-available/kourt /etc/nginx/sites-enabled/kourt
certbot --nginx -d kourt.example
nginx -t && systemctl reload nginx
```

**HTTPS is not optional for the overlay**, and not only for the usual reasons:
the Clipboard API requires a secure context, so on plain `http://` the share
panel cannot copy at all. It degrades honestly — it selects the text and says
"press Ctrl/⌘-C" — but that is a downgrade nobody should be running.

Two deliberate choices in that config, both easy to "fix" wrongly:

- **`frame-ancestors *`, and no `X-Frame-Options`.** `#/embed/<court>/<id>`
  exists to be embedded in somebody else's article. `SAMEORIGIN` would break the
  one feature built to travel.
- **`X-Forwarded-For` is set, and the unit trusts it only from `127.0.0.1`.**
  Without the header every client looks like the proxy and the per-address
  throttle becomes one global bucket. Without the narrow `--trusted-proxy`, any
  client could set the header and forge its own address.

## Checking on it

```sh
ssh root@kourt.example systemctl status kourtchat
ssh root@kourt.example journalctl -u kourtchat -f
curl -s https://kourt.example/api/chat/health
```

If the health endpoint says no scanner has ever run, that is the service telling
you chat is **unmoderated** — it enforces, it just has nothing classifying. That
is a scanner problem on the GPU box, not a deploy problem here.
