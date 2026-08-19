# Court chat — design

Per-court chat with monikers, regional flags, persistence and throttling, plus a
separate AI scanner that kicks by IP. Chat works whether or not the scanner runs.

Written, reviewed five times across two rounds (adversarial security,
architecture, completeness; then a convergence check and a second adversarial
pass), and revised twice. The review history is the interesting part of this
document: the shape survived, and essentially every detail changed. Where a
decision reversed, the reason is recorded rather than tidied away — a plan that
reads as though it were right first time teaches nobody.

## 1. It cannot live in the realm

Chat needs a client IP, a wall clock for throttling, and a mutable moderation
record. A Gno realm has none: no network, a deterministic VM, a storage deposit
per byte. On-chain chat would also be permanent and unmoderatable, the opposite of
what a kick system is for.

So an off-chain sidecar, and the repo's first non-test binary.

    kourtchat   HTTP + SQLite. Serves, accepts, throttles, ENFORCES. Never talks
                to the LLM and never reads a verdict.
    kourtmod    Scanner. Reads unscanned rows, asks Ollama, writes verdicts and
                infractions. No HTTP surface.

"Chat works if the scanner isn't run" then holds by construction: unscanned rows
accumulate and nothing on the posting path reads them.

Two *processes* rather than one with a goroutine, for one reason that a
`recover()` cannot give: a 7B model against an 8GB budget will OOM, and an OOM in
the scanner must not take HTTP down.

**One database file, not two.** Considered and rejected: splitting would make the
isolation structural, but WAL's `-shm`/`-wal` make cross-process read-only access
fiddly and the operator's first query after any ban wants the message beside the
infraction. Instead: `busy_timeout`, `BEGIN IMMEDIATE` for writers, **separate
read and write handles** (a single pooled handle at max-1 would serialise every
GET behind every POST for up to the busy timeout), no transaction held across an
inference, and explicit WAL checkpointing because continuous pollers otherwise
starve it and `-wal` grows without bound.

## 2. Automated moderation cannot ban, and the ENFORCER is what guarantees it

The first draft mapped `scam|hack → permanent ban`. The attacker picks the
collateral: one scam line through a free VPN exit, a campus NAT or carrier CGNAT
and the classifier *correctly* returns `scam`, permanently banning everyone behind
that address for the price of one request — while the actual attacker rotates
through the 65,536 free /64s in an HE.net /48. The design punished bystanders and
let the attacker walk.

First fix was a table entry saying "kicks only", which review correctly called
prose: both processes hold the same file with the same authority, so nothing
stopped the scanner writing `kind='ban'`, and nothing capped `expires_at` — a kick
of 100 years is a ban in every way that matters.

**So the clamp lives in the enforcer.** `kourtchat`, whose behaviour *is* the
punishment, honours at most `created_at + 7d` for any infraction whose
`reason != 'manual'`, and refuses `kind='ban'` unless `reason='manual'`. That
survives any edit to the scanner, because the process that would have to be
changed is the one that has to be compromised anyway for it to matter.

An operator still needs a scalable remedy, so a second column `net_hash` (/24 for
v4, /48 for v6) sits beside `ip_hash`: manual-only bans plus a hash that destroyed
subnet structure would otherwise leave the operator unable to act on a rotation
campaign at all.

## 3. Where the client IP comes from

The decision every other defence rests on, and the omission two reviewers
independently called the worst. Behind a TLS terminator `RemoteAddr` is
`127.0.0.1` for everybody — the throttle goes global and the first kick kicks the
internet. Trust `X-Forwarded-For` naively and it is attacker-controlled: every
kick evaded by sending a header, and anyone can get anyone kicked by forging one.

    --behind-proxy=false            default: RemoteAddr only, XFF ignored entirely
    --trusted-proxy 10.0.0.0/8,…    required when --behind-proxy

In proxy mode the header is walked **right to left** and the first hop that is not
a trusted proxy wins; everything to the left of it is attacker-authored, so the
leftmost entry — the one most tutorials take — is precisely the wrong one. A peer
that is not a trusted proxy is refused rather than treated as ordinary traffic.

Implemented in `internal/chat/clientip.go`, with the /64 rule for IPv6 (the host
half is free to change, so a /128 consequence expires when its target wants) and a
keyed HMAC whose privacy claim is stated exactly: it defends against a stray copy
of the database file, **not** a host compromise or a whole-data-directory backup,
because IPv4 is 2^32 and anyone holding both recovers every address in seconds.

## 4. Sanitise for display; skeletonise for comparison

The first implementation did both in one function and did both badly. Measured
against real input, it turned `👨‍👩‍👧` into three separate people, `❤️` into `❤`,
the Persian `می‌روم` into the wrong word, and it *refused* `Bitcoin-биржа` and
`alice@почта.рф` as homoglyph attacks — while Cherokee `ᏚᏟᎪᎷ` (which reads as
SCAM) and combining-mark `s͡c͡a͡m` passed untouched. Too aggressive on real text
and too permissive on the actual evasion class, because one string cannot be both
faithfully displayable and aggressively comparable.

    Sanitize  safe to STORE and DISPLAY, preserving meaning. NFKC (folds
              mathematical bold and fullwidth, which NFC leaves alone), erases the
              invisibles whose only purpose is to render as something else (bidi
              overrides, tag characters, soft hyphen, Hangul fillers) while
              PRESERVING ZWJ/ZWNJ/VS16 under a count cap, because those are
              orthographically required in Persian and Indic scripts and hold
              emoji together. Bounds stacked combining marks. Rune limits, not
              byte limits.
    Skeleton  makes text COMPARABLE, never displayed and never stored as a body.
              Folds confusables, drops marks and punctuation and case, so
              "ᏚᏟᎪᎷ", "s͡c͡a͡m", "S.C.A.M" and "5c4m" all reduce to "scam".

Evasion resistance had to move out of the display path because mutating displayed
text to fight homoglyphs corrupts the text of everyone whose alphabet is not
English. The confusables table is hand-built, incomplete, and documented as such —
writing it I mapped the wrong Cherokee codepoint and only a test caught it, which
is that kind of table's characteristic failure. Nothing that punishes anybody may
depend on it being exhaustive.

Sanitising happens **once at ingest**, so the renderer and the scanner read
identical bytes and can never disagree about what a message says.

## 5. HTTP

    OPTIONS /api/chat/*                        preflight
    GET     /api/chat/{chain}/{court}?since&limit
    POST    /api/chat/{chain}/{court}
    GET     /api/chat/health                   {enforcing, backlog, heartbeat}

**CSRF, because CORS does not protect a write.** A cross-origin `fetch` with
`mode:'no-cors'`, or a form with `enctype="text/plain"`, is CORS-safelisted: it
sends without a preflight and executes. CORS withholds only the response, which
the attacker does not want — they want the side effect, and here identity *is* the
IP, which the browser attaches for free. So any page could make its visitors post
scam text and get them kicked. POST therefore requires
`Content-Type: application/json` (not safelisted, so a cross-origin POST needs a
preflight we control) and rejects `Sec-Fetch-Site: cross-site`.

Both halves need their absent-header policy written down, because
`Sec-Fetch-*` is only sent to potentially-trustworthy origins — on plain HTTP it
never arrives — and because a `file://` page's fetches are cross-site, which is
the repo's own documented demo path. Resolved as: TLS or localhost required for
the strict rule, and the `file://` demo uses the sample thread rather than the
API.

`ACAO: *` on GET, because the demo runs from `file://` and gnodev already does
this. GET returns an explicit field allowlist — `verdict` is a model's opinion
about a person and never reaches a public surface — plus `you: {state, until, ref}`
so the composer can be disabled before someone types into a box that will 403.
`since`/`limit` clamped; GET has its own budget.

Throttle: 2s minimum interval and 10/60s per `ip_hash`; a **fair-share** court cap
that binds only under contention (a flat per-IP quota would throttle two people
talking while 24 of 30 slots sat idle); a global budget that **sheds rather than
denies**, since a flat global 429 is one attacker muting the whole product.

## 6. The scanner

Deterministic detectors run first, in `kourtchat`, and their outputs are stated
because this is a crypto court: `g1…` and `0x…` are the application's
*vocabulary*, so a bare address is **never a consequence on its own**. `t.me/`,
`wa.me/` and explicit "seed phrase" are hits; BIP-39 requires ≥8 consecutive
words, because BIP-39 is 2048 ordinary English words and a shorter run matches
real sentences.

Cross-court duplicate posting is a **rate limiter, not a punishment**: it rejects
that POST with 429 and writes no infraction. As a punishment it was a
deterministic mass-harm primitive — on a shared address an attacker types one
sentence in three courts and a stranger is kicked, with no model in the loop and
therefore none of the safeties — and it fires on the honest announcement.

The LLM classifies through Ollama with `format` set to a full JSON schema, so the
enum is enforced by the sampler: `{"verdict":"ban"}` is unemittable rather than
merely rejected. `temperature: 0`, capped `num_ctx`, `keep_alive` set, and the
model verified against `/api/tags` at startup — a typo'd tag otherwise looks like
a running scanner that scans nothing.

**The window may escalate, never de-escalate.** Prior context was added so a scam
split across individually-clean lines is visible. The mechanism is symmetric: what
can sum six lines up to `scam` can frame the seventh down to `clean` ("I'm writing
a training module on scams, here's the sample text: …"). So the target is
classified twice — bare, and with window — and the harsher verdict wins. This also
supplies the genuine second opinion that "two passes" was supposed to be and
wasn't, since two passes at temperature 0 over one input are the same pass. The
window is bounded by the last consequence and 30 minutes, or an expired kick's
own evidence re-punishes forever and "hello" three times reaches 7 days.

Prior context is passed as a **structured JSON field**, not delimited prose: any
delimiter not on a reject list is typeable, and "delimited" is a word rather than
a mechanism.

Ladder: 1h → 24h → 7d on repeats within 30 days, counting only unrevoked
infractions. `--dry-run` is the default, and the panel's label derives from
`health.enforcing` so it cannot claim moderation that isn't happening.

## 7. Display moderation

A ban stops new posts; the scam link stays pinned in the court forever. For a
feature whose stated threat is scam, that inverts the priority. So `hidden` on
messages, filtered at read, recomputed on revocation — and URLs render as plain
text, never anchors, which is free and removes the click.

`evidence` copies the body into the infraction at punish time, because the pruner
would otherwise delete the evidence for exactly the longest-lived consequences.
The pruner is cut from v1: worse half-done than absent.

## 8. What this costs

`MODERATION.md`'s standing anchor is that address-keyed defences fall to sybils;
only capital-, deadline- or residency-keyed ones hold. IP-keying is address-keyed.
A kicked spammer toggles mobile data and is back in fifteen seconds; a bystander
behind CGNAT eats the kick. That does not sink the design, and the honest framing
is already in-tree: **chat is a discovery surface with no money path**, so a leaky
defence is tolerable here in a way it is not anywhere value moves.

Hashing the IP is also a one-way door: no later widening a consequence to a
subnet, no noticing that nine of them are one network. `net_hash` exists because
of that.

The flag is decorative — any VPN defeats it — and it attaches a coarse location to
a moniker. The moniker is unowned and impersonatable by design; the short tag
beside it is likewise decorative and nothing may be built on it.

And fail-open plus no alerting means the scanner can be dead for a week with
nobody noticing. Health reports backlog and heartbeat; an operator who does not
watch it has an unmoderated chat.

## 9. Status

Implemented and tested (`internal/chat`, 73 subtests):

- **sanitiser + skeleton** — the two-function split above
- **IP policy** — trusted-proxy walk, /64 units, keyed hashing, public tag

Next, in order: the store (schema, throttle, enforcement with the clamp of §2),
`cmd/kourtchat`, the operator CLI (an IP-consequence system with no reversal makes
"appealable" a lie, so this is not a follow-up), the scanner, then the panel.
