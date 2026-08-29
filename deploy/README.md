# Deploying Kourt

Three things exist and only two of them are deployed from here.

| | what it is | where it goes |
|---|---|---|
| **the overlay** | `web/index.html`, one self-contained static file | a webroot, `/var/www/kourt` |
| **the chat** | `cmd/kourtchat`, a Go service with a SQLite database | `/opt/kourt`, under systemd |
| the realm | `realm/r/kourtv2` | a gno chain — `chain.sh`, at genesis, not `deploy.sh` |
| **the chain** | a persistent `gnoland` node | `/var/lib/kourt/chain`, under systemd |
| **the faucet** | `gnofaucet`, hCaptcha-gated | `faucet.kourt.xyz`, under systemd |
| **gnoweb** | the realm's own pages | `gnoweb.kourt.xyz`, under systemd |

The overlay reads whichever chain you point it at, so shipping the page and
deploying the realm are separate acts with separate blast radii. That is the
point: `web/README.md` calls the overlay a presentation layer, and every screen
in it can be served by the realm's own `Render`.

**The scanner is not here either.** It wants a GPU and runs on its own box.
`cmd/kourtchat` never talks to the model — CHAT.md is explicit that accepting,
storing, throttling and enforcing keep working whether or not the scanner is
running — which is why the chat is at home on an ordinary VPS beside the static
file, and why its unit orders itself against nothing.

## The chain, once

`deploy.sh` ships the website. The chain is a separate act with a separate blast
radius, and its own script:

```sh
make chain HOST=root@kourt.xyz GNOROOT=~/gopath/src/github.com/gnolang/gno \
     OWNER_ADDR=g1youraddress...
make certs HOST=root@kourt.xyz EMAIL=you@example.com
```

**Two phases, and the order is forced.** The genesis has to name the validator's
public key and premine the faucet's address — but neither secret should be born
on a laptop and travel over the wire. So the server generates them first, the
script reads back only the public halves, builds the genesis locally where the
packages are, and ships that. The validator private key and the faucet mnemonic
never leave the box.

**The realm is deployed AT GENESIS**, with its whole dependency closure — ten
packages, ~1.08MB of prod source. No fee, no storage deposit, and no deploy key
that has to stay online afterwards. `scripts/genesis-pkgs.py` computes the
closure because `gnogenesis` sorts packages per invocation and cannot see what is
already in the genesis file, so they must all be handed over at once.

**It refuses to replace a live chain.** A fresh genesis against an existing data
directory is a node that will not start, so a second run stops unless you pass
`RESET=--reset`, which drops the chain and its state.

**The faucet stays stopped until it has a captcha secret.** `gnofaucet serve`
has exactly two modes, `captcha` and `github`, and both require credentials —
there is no anonymous mode. Put the hCaptcha secret in place and start it:

```sh
printf %s '<hcaptcha-secret>' > /var/lib/kourt/secret/captcha.secret
chmod 600 /var/lib/kourt/secret/captcha.secret
systemctl start kourtfaucet
```

**gnoweb is deployed too, and it is not optional.** Every action button in the
overlay links out to a `$help` page — `tx()` builds
`CFG.gnoweb + "/r/kourt/kourtv2$help&func=…"` — so without one of our own those
links point at gno.land, which does not carry this realm. It also gets
`-help-remote https://rpc.kourt.xyz`, which becomes the `gnoconnect:rpc` meta a
wallet reads: left at its default it is the node's listener **verbatim**,
`tcp://127.0.0.1:26657`, which no browser extension can open. And `-faucet-url`
registers `gnoweb.kourt.xyz/faucet` as a 302 to the faucet.

A grant is **100 GNOT**. The mnemonic reaches the process as a systemd
`LoadCredential`, never as a flag: `-mnemonic "<24 words>"` would put the
faucet's entire wallet in the process table. Gas is pinned at 2,000,000 because
the tool's own default of 100,000 fails every transfer with `transaction failed
initial validation, out of gas error`.

**Changing a unit or a vhost does not touch the chain:**

```sh
make chain HOST=root@kourt.xyz RESET=--config-only
```

`--reset` destroys the chain, and the refusal that protects a live chain would
otherwise lock out every later config change — which is how the gnoweb vhost
failed to arrive on the first attempt.

**certbot owns the TLS half**, which is why `nginx-chain.conf` ships HTTP-only —
`nginx -t` refuses an `ssl` listener with no certificate, so a hand-written :443
block stops nginx from starting and certbot can then never reach :80 to prove the
domain. `certs.sh` issues one certificate per name rather than one SAN
certificate for both, so a name whose DNS is not ready costs only itself. Once
certbot has edited the site config, `chain.sh` detects the certificate and leaves
the file alone rather than reverting TLS on the next run.

## Every deploy

```sh
make deploy HOST=root@kourt.xyz
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

It also never touches nginx, TLS or the firewall — that is `setup.sh`'s job,
run once. A deploy script that rewrites the web server's config can take the
site down without shipping anything.

## First time on a box

```sh
make setup HOST=root@kourt.xyz DOMAIN=kourt.xyz
```

Idempotent, so re-running it is cheap and is the right response to a failure.
It installs nginx and certbot, creates the `kourt` user and the directories,
generates the IP-hashing key, opens 22/80/443 if `ufw` is present, and then
gets a certificate.

**TLS runs last, and that ordering is the whole trick.** certbot needs this
server block already answering on port 80 and DNS already pointing here, and it
is the one step that legitimately fails on a fresh domain — so everything that
can succeed has succeeded before it is attempted. If it fails, the message says
what to check and you re-run.

**`deploy/nginx.conf` is HTTP-only on purpose.** `certbot --nginx --redirect`
writes the `:443` server, the certificate paths and the 80→443 redirect into it.
A hand-written `listen 443 ssl` with the cert lines commented out does not
merely fail to help: `nginx -t` refuses a listener declared `ssl` with no
certificate, so nginx would not start at all and certbot could never reach port
80 to prove the domain.

Renewal is certbot's own `certbot.timer`, installed by the package; setup
reports whether it is enabled rather than leaving you to find out in ninety
days.

**The IP-hashing key is generated once and never regenerated.** Without
`--secret-file` the key lives as a row *inside* the database, so one file would
carry both the address hashes and the key that reverses them — and it gets its
own `0700` directory because `kourtchat` also warns when the two merely share
one. Re-running setup leaves an existing key alone: rotating it silently would
orphan every hash already stored, so the throttle would stop recognising anyone
it already knows.

**HTTPS is not optional for the overlay**, and not only for the usual reasons:
the Clipboard API requires a secure context, so on plain `http://` the share
panel cannot copy at all. It degrades honestly — it selects the text and says
"press Ctrl/⌘-C" — but that is a downgrade nobody should be running.

Two choices in `nginx.conf` that are easy to "fix" wrongly:

- **`frame-ancestors *`, and no `X-Frame-Options`.** `#/embed/<court>/<id>`
  exists to be embedded in somebody else's article. `SAMEORIGIN` would break the
  one feature built to travel.
- **`X-Forwarded-For` is set, and the unit trusts it only from `127.0.0.1`.**
  Without the header every client looks like the proxy and the per-address
  throttle becomes one global bucket. Without the narrow `--trusted-proxy`, any
  client could set the header and forge its own address.

## Checking on it

```sh
ssh root@kourt.xyz systemctl status kourtchat
ssh root@kourt.xyz journalctl -u kourtchat -f
curl -s https://kourt.xyz/api/chat/health
```

If the health endpoint says no scanner has ever run, that is the service telling
you chat is **unmoderated** — it enforces, it just has nothing classifying. That
is a scanner problem on the GPU box, not a deploy problem here.
