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

That paragraph was written before any of it was measured, and one clause of it was
false. `internal/chat/contention_test.go` now measures all three claims against two
`Store` instances on one file — two *processes*, which is the deployment, and the
case `SetMaxOpenConns(1)` does nothing for:

    reads during a held write transaction        216µs
    read+status pairs while a scanner writes     8118 in 600ms, worst 1.05ms
    a post during another process's write        waits 441ms, then succeeds

The third one **failed** on first measurement, with `database is locked (5)`. Cause:
`BEGIN IMMEDIATE` was documented here and never implemented — `database/sql`'s
`BeginTx` issues a *deferred* `BEGIN`, so the transaction opened as a reader and
tried to upgrade on its first write, and `busy_timeout` does not retry that upgrade
by design (waiting could hand the transaction a stale snapshot). Every post landing
while the scanner wrote would have been refused with a 503. Fixed with
`_txlock=immediate` on the write handle only. The one-file decision stands, but it
stood on a pragma that wasn't there until this test went looking.

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

**The joiner cap was the same mistake, one constant later.** It was a whole-message total of
16 — and measured, ordinary Persian prose of 20 ZWNJ words (177 runes) was refused, as were six
family emoji. ZWNJ is orthographically required in Persian, which this section already said two
paragraphs above the cap that broke it, so a total punished the language and not the abuse: a
long legitimate message simply holds more joiners than a short one.

The abuse is density. It is now a run cap of 4 (❤️‍🔥 stacks VS16 and ZWJ inside a single glyph)
plus a rule that joiners may not outnumber visible characters — Persian runs about 0.13, family
emoji about 0.6, and "hi" with a hundred bare ZWJ runs 10. That is safe to be permissive about
because the cap never carried the evasion argument in the first place: `Skeleton` reduces
"s‍c‍a‍m" to "scam" on its own, which is asserted beside the permissive cases so the reasoning
cannot quietly lapse.

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
    GET     /api/chat/health                   {ok, enforcing}
                                               + backlog/heartbeat/unscannable
                                               ONLY with --health-detail

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

**What "under contention" turns out to mean, measured.** Not what the constants look
like they say. The rule is `courtTotal >= 30 && courtMine >= 3`, and the obvious
reading — a busy room tightens up for everybody — is wrong. Twelve people talking at
one message per twenty seconds is 36 a minute, comfortably past the cap, and **nothing
is refused**: the window holds three rounds and an author's own pending message is not
counted yet, so `courtMine` peaks at 2 however many people are present.

So the second clause keys on how fast ONE address talks, not on how crowded the court
is. It bites when a busy court also contains somebody posting faster than three a
minute, and then it caps *them* at three while a newcomer who has said nothing still
gets in. That is the property worth having, and it is the one the fixtures pin:
`TestOrdinaryConversationIsNeverThrottled` at 2, 5 and 12 people, and
`TestUnderContentionAFairShareStillLetsANewcomerSpeak` for the other arm.

Two smaller things the same measurement settled. `TestAQuietCourtHoldsNobodyToTheFairShare`
exists because deleting `courtTotal >= 30` — turning the rule into a flat three a
minute — survived every other fixture, since none of them had a fast talker in an empty
room. And the global shed's "already posted" is counted across ALL courts, so a shed
address is one that has said nothing anywhere. Saturating that window at all needs at
least 30 addresses — `PerIPMax` caps each at 10 a minute — and they have to speak
concurrently, since the 2s interval is per address rather than global. Advancing a
fixture's clock per message instead of per round spreads 300 messages over fifteen
minutes and the window never holds more than twenty.

## 6. The scanner

Deterministic detectors run first, in `kourtchat`, and their outputs are stated
because this is a crypto court: `g1…` and `0x…` are the application's
*vocabulary*, so a bare address is **never a consequence on its own**. `t.me/`,
`wa.me/` and explicit "seed phrase" are hits — **and which normalisation each pattern gets is
load-bearing, not incidental.** The off-platform rule searched the skeleton for "tme", and a
skeleton is one long word with no spaces or punctuation, so ordinary English matched it:
measured, "the planning department rejected it" earned a floor of spam, as did "apartment",
"compartment" and "postmen". An hour of silence for a word this court's users type constantly.

The evasion the skeleton was there for is separator substitution — "t·me/", "t(dot)me/" — so
that is folded now, and nothing else. Word forms like "telegram" stay on raw and skeleton, where
letters-only matching cannot collide, so "te1egram" is still caught. The rule is: fold what the
attacker substitutes, not everything.

**A recovery phrase is matched by its CHECKSUM, not by a run of words**, and both halves of
that sentence were learned the hard way. The rule used to be "≥8 consecutive words" against a
136-word list, which was the alphabetical first 136 of BIP-39 — so of the published test vectors
it caught the all-`abandon` phrase and nothing else, a realistic phrase scoring a run of 1. The
comment beside it warned about detectors that stay "permanently silent while looking
implemented", and there was no test for it, which is how it managed to be one.

The full 2048-word list fixes the runs and not the rule. BIP-39 is drawn from short common
English nouns, so "list apple orange lemon cherry olive garlic onion potato tomato pepper salt
sugar" runs 13 and a list of materials runs 12, while the shortest real phrase is 12 — no
threshold separates them, and this floor sets `scam`, which is a 24-hour timeout that must not
land on somebody listing fruit. So the concatenated 11-bit indices are checked against their own
SHA-256, which is the thing that makes a phrase a phrase: a noun list passes by luck one time in
16 at twelve words, and must also be exactly a phrase length.

Two details that only testing the real thing would produce. The wordlist carries its canonical
CRC (`c1dbd296`) asserted at startup, because one mistyped word weakens the detector with no
symptom. And numbering does not break a run — wallets display recovery words numbered, so it is
the likeliest way a phrase is ever pasted, and it was the one format the detector missed.

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

**Dilution, and the trade-off that closes it.** The window is attacker-writable — it is
that author's own last five messages — so the obvious attack is to bury a lure in enough
harmless text that the model stops seeing it. It works:

    bare lure, 66 runes                     scam  0.90
    padded lure, 397 runes                  scam  0.95
    lure + 2,000 runes of prior             scam  0.95
    padded lure + same prior (2,407)        CLEAN 0.95

Two plausible explanations are both wrong. It is **not the context window**: the same
payload came back clean 0.95 at `num_ctx` 2048, 4096 and 8192, so the model is reading the
text and diluting, and a bigger window fixes nothing. And it is **not the bare pass saving
it**, which is the tidy story — the bare pass reads no prior and so cannot be diluted, but
deleting it entirely, and separately letting the window's verdict win outright, both left
the scanner still catching the lure. Those were mutations that SURVIVED; the bare pass is a
backstop here, not the defence.

What closes it is that the attacker cannot have both halves. The filler that dilutes is
repetitive, and repetitive filler is flagged as spam on its own — an early probe produced a
consequence for every padding message as well as the lure. Filler that is *not* punished
does not dilute: five varied natural messages at the rune cap, 1,916 runes of free text,
left the windowed verdict at `spam 0.95` on three runs of three. Padding can be free or it
can be diluting.

That is a property of one 4B model at one moment, not a theorem, so it is pinned as four
live fixtures rather than asserted here — including one that logs loudly if free padding
ever starts diluting, which would make this paragraph wrong.

Ladder: 1h → 24h → 7d on repeats within 30 days, counting only unrevoked
infractions. `--dry-run` is the default, and the panel's label derives from
`health.enforcing` so it cannot claim moderation that isn't happening — which was a claim
this document made for some time before anything implemented it. No client fetched that
endpoint at all. The panel now asks once per mount and, when timeouts are not being applied,
says so.

**What that endpoint may disclose is a decision, not an oversight.** Unauthenticated, it was
returning the operator's whole telemetry, and an anonymous GET on a running server gave back
`enforcing`, `backlog`, `scanner_seen_at` and `unscannable` — four of the things somebody
choosing a moment would want, of which the heartbeat is the worst, because whether the scanner
is alive and how long ago it ran is not otherwise observable. The numbers now require
`--health-detail`; `kourtchatctl status` reads them from the database and never needed the
endpoint.

`enforcing` stays public on an asymmetry rather than on comfort: an attacker learns dry-run
mode from a single post, while a reader cannot learn it at all, so disclosing it helps the
honest side more than the other. The wording is factual for the same reason — "not applying
timeouts on this server right now", never "you will not be punished" — and a failed health
read stays silent, because not knowing is not the same as knowing it is off.

**Why the ladder forgets.** Thirty days is a real decision and it cuts both ways. An
address that carried a scam forever eventually punishes a stranger: addresses are
reassigned constantly — DHCP, carrier NAT, a café's router — so a permanent record
attaches to whoever inherits the address, not to whoever earned it. A short window means a
repeat offender is never more than an hour from posting again. Thirty days is the
compromise, and both sides of it are asserted rather than assumed.

Two asymmetries follow, both deliberate and both easy to mistake for oversights. A revoked
consequence does not count, or an upheld appeal would unmute somebody and leave them
silently one rung higher — reversible-looking rather than reversible. And a MANUAL
consequence does not count either: the ladder is the scanner's own record with an address,
and letting an operator's action raise it would mean one human intervention quietly made
every later automated verdict harsher, in a design whose whole safety argument is that
automation cannot reach for the severe end.

## 7. Display moderation

A ban stops new posts; the scam link stays pinned in the court forever. For a
feature whose stated threat is scam, that inverts the priority. So `hidden` on
messages, filtered at read, recomputed on revocation — and URLs render as plain
text, never anchors, which is free and removes the click.

**Revocation RECOMPUTES `hidden`; it does not clear it.** Revoke used to set `hidden=0` for the
whole address, which is the same thing only while an address has one consequence. Measured with
two: reversing a wrong manual call put "send me your seed phrase now" back in the room while its
author stayed kicked by the other decision — §7's own failure mode reached by an operator
granting an appeal. A message is hidden now if any UNREVOKED consequence would hide it. Expiry is
not revocation: a kick that ran its course keeps its evidence out of sight, because a lapsed
timeout is not somebody saying the decision was wrong.

Two consequences of that, both found by running it rather than reading it. The window looks
**backward only** — `Consequence` writes "newer than now minus ten minutes" with no upper bound,
which is exact at the instant it runs and wrong when recomputed later, so an old consequence hid
everything posted after it. And a hide with no consequence behind it, which is what the §7
carve-out produces for a disclosed secret, looked like one to undo: `hidden` distinguishes 1 (a
consequence) from 2 (a secret), and only 1 is recomputed. Nothing un-hides a 2, which is stated
at the code rather than left to be discovered.

**The cited message is hidden whatever its age; the author's other messages only for ten
minutes.** Those are two different rules and they were one for a while — the hide was a
ten-minute window and nothing else, so a consequence acting on an older message left it on
screen. Measured: with the scanner one minute behind the scam was hidden, at eleven minutes it
was not, and a backlog is expected rather than exceptional, since `Claim` scans newest-first
precisely because after an outage the harmful messages are reached last. The failure landed in
the condition that motivated the feature.

The narrow window for everything else is deliberate and the reason is collateral: on a shared
address a wider sweep retroactively removes strangers' messages, and every routine timeout would
carry that. It also means a timeout removes a burst rather than a history — an author's older
messages survive their own kick, which is asserted, because widening the window passed every
other test in the file.

`evidence` copies the body into the infraction at punish time, because the pruner
would otherwise delete the evidence for exactly the longest-lived consequences.
The pruner was cut from v1 as "worse half-done than absent". It is built now, because the
things that made it dangerous are all in place: `evidence` means a deleted message cannot
take the record with it, `reviewed_at` distinguishes a queue somebody has worked from one
nobody has seen, and `Health.Unscannable` separates "not yet classified" from "gave up".

It refuses three kinds outright, whatever the cutoff says. **Unscanned** messages, because
deleting one is not retention policy but silently skipping moderation — which is what
makes an outage safe: if the model has been unreachable for a month, a thirty-day prune
must not erase the backlog instead of anyone classifying it. Messages **awaiting review**,
because the carve-out above defers exactly those to a person and deleting them empties that
queue with nobody deciding anything. And messages **cited by a consequence still in force**,
because `unban` restores a punished author's hidden messages and cannot restore rows that
are gone. Rows that gave up ARE prunable: a decision was made about them, a bad one, and
that is what the unscannable count is for.

Dry run by default, and it reports the refusals even when they are zero — on the screen
where somebody is about to delete a month of history, "nothing is waiting for review" is
worth reading. Bounded per call, because §1's argument for one database file rests on
nothing holding the write lock for long: 20,000 rows went in batches of 2,000 in 193ms
while 2,096 read+status pairs completed alongside, worst 552µs.

**Deleting reclaims no disk, and can temporarily use more.** Measured on 40k messages:

    before pruning      main 7876K   wal 7994K
    after pruning all   main 7876K   wal 7994K    byte-identical
    after a checkpoint  main 7876K   wal    0K    the WAL, not the file
    VACUUM INTO           56K

The deletions are journaled first, so an operator pruning *because* they are low on disk
can make it worse. `PRAGMA wal_checkpoint(TRUNCATE)` frees the `-wal` with no downtime;
only a vacuum returns the main file's free pages, and swapping the compacted file in needs
a stop and start.

### The reporting carve-out, and what it costs

A message that reads as a WARNING is recorded and left for a person. This was not a
preference; it was forced. gemma3:4b cannot separate reporting a scam from sending one —
every variant was flagged, including a warning containing no lure at all (`scam` 0.95) —
and no prompt wording moved it. Punishing the difference means kicking somebody for
protecting the room and hiding what they wrote, so `scan.Reporting` matches the shape and
the scanner records the verdict, applies nothing, and logs it.

It is gameable and known to be: reporting-shaped framing is a reliable way to keep flagged
content on screen, which is asserted as a test rather than hidden.

**But it withheld the HIDE as well as the timeout, and those are different decisions.** Measured:
"fyi here are my words: <a real BIP-39 phrase>" was recorded as scam and left readable
indefinitely, because the message opened with three letters. Withholding the timeout is the
point — the model flags warnings at 0.95, so punishing on its word means kicking people for
protecting the room. Withholding the hide is not: a recovery phrase quoted by a well-meaning
reporter is still a recovery phrase in a public room, and the harm is the disclosure rather than
the intent.

So a message the DETERMINISTIC layer finds a disclosed secret in goes out of sight whoever posted
it, and nobody is punished for it. Narrow on purpose: never on the model's opinion, since that is
the unreliable part, and never on the off-platform floor — a warning that quotes a scam link is
useful, and the panel renders no URL as an anchor, so quoting one is not the harm. Quoting a
secret is. Both arms are pinned, and a dry run still changes nothing, because `--enforce` off has
to mean an operator can watch without the service acting. The carve-out's whole
defence is that a PERSON looks.

**So the queue of deferred messages is a target, and it was open.** Until `review` existed
the deferred messages were visible only as a line on a daemon's stdout — not queryable,
not durable, gone with the next rotation. Verified: a real gemma3:4b run on "careful
everyone, someone just DMed me asking for my seed phrase" stored `verdict='scam'` with no
consequence, and `kourtchatctl list` did not mention it.

And once it existed, filling it turned out to be cheaper than evading the classifier.
Measured against the flat queue, one address staying inside the throttle:

    attempted 200, accepted 70, queue 71 rows
    the first 20 rows an operator reads:  20 of 20 the attacker's
    the single genuine report:            position 71 of 71

No evasion was needed. Reporting-shaped text is what gets carved out, so the attacker
writes exactly that and varies a number so the skeleton dedup never fires.

The answer is NOT a new punishment. Flooding is indistinguishable from diligent reporting
to the same classifier that already failed to separate reporting from sending, so acting
on the pattern automatically just relocates the false positive somewhere less visible.
Instead the view is flood-resistant: `review` groups by author, so seventy messages are one
row saying seventy, and `dismiss -from` clears an author in one command — grouping the view
without grouping the action would have lost at the dismissal step instead of the reading
step. The count is also a better signal than any single message, and one the tool does not
have to interpret: nobody files seventy incidents in twenty minutes. Different names and
different courts from one address are reported for the same reason.

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

## 9. Running it

Three binaries, `make chat`:

    bin/kourtchat      the HTTP server: serves, accepts, throttles, enforces
    bin/kourtmod       the scanner: reads unscanned rows, asks Ollama, records
    bin/kourtchatctl   the operator: list / why / unban / kick / ban / hash /
                       freeze / status

A minimal local run, with the page served from a file:// URL or a static server:

    bin/kourtchat --db chat.db --chain dev
    bin/kourtmod  --db chat.db --model gemma3:4b        # dry run
    bin/kourtchatctl -db chat.db status

Behind a reverse proxy, which is the only deployment where the throttle means
anything:

    bin/kourtchat --db chat.db --chain dev \
      --behind-proxy --trusted-proxy 10.0.0.0/8 \
      --country-header CF-IPCountry \
      --secret-file /etc/kourt/ip.key

**Without `--behind-proxy`, `X-Forwarded-For` is ignored entirely.** That is the safe
default and it is also visible: seed six messages with six different forwarded
addresses against a direct listener and five come back 429, because they are all one
client. With `--behind-proxy` and no `--trusted-proxy`, the server refuses to start.

**`--secret-file` should be outside the data directory.** The fallback keeps the key
in the database, which is convenient and protects nothing: hashing addresses defends
against a stray copy of the `.db` file, and if the key is in that file, a backup
carries both. IPv4 is 2^32 — key plus table recovers every address in seconds.

**Arm the scanner only after watching it.** `--enforce` is off by default. Run the dry
run against real traffic, read `verdict` out of the messages table, and turn it on
when the false-positive rate is something you have measured rather than assumed. A 4B
model at q4 will be wrong sometimes; the design bounds what being wrong costs
(a timeout, never a ban) but it cannot make it not happen.

**Give people somewhere to appeal, or the panel will not offer them one.**

    bin/kourtchat --db chat.db --chain dev --appeal-to "mods@example.org"

The panel told anyone it paused "You can appeal — quote reference 9" while no channel existed
anywhere: not in the panel, not in this file, not in `kourtchatctl`. Everything on the operator
side — `why`, `unban`, the evidence copy that outlives pruning — exists to service appeals, and
the person invited to make one had nowhere to send it. The brief for that surface said a system
with no reversal makes "appealable" a lie; a reversal nobody can reach is the same lie a step
later.

Unset, the panel gives the reference and promises nothing, because inventing a route is worse
than admitting there is none. A contact with a newline, a control character, or more than 200
characters is withheld rather than served — the panel escapes what it writes, so that is not the
last line of defence, but it is somebody's misconfiguration and it should not reach a page.

**Acting on an address you can see but the classifier never flagged.** The CLI takes
hashes, so `hash` is the way in — added after an end-to-end test found there wasn't one:

    bin/kourtchatctl -db chat.db hash 203.0.113.7
    address  42177eeb…   (203.0.113.7/32)
    network  b40f05f8…   (203.0.113.0/24)

    bin/kourtchatctl -db chat.db kick 42177eeb… -for 1h     bounded, reversible
    bin/kourtchatctl -db chat.db ban -net b40f05f8… -why …  a whole /24, by hand

`hash` refuses to create a key, so a mistyped `--secret-file` fails loudly instead of
producing a plausible hash under a fresh key that matches nothing. A manual `kick` is
not clamped by the automated ceiling of §2 — that clamp exists to stop a MODEL reaching
for something permanent, not to overrule a person who decided an hour was right — which
is why `-for` is required rather than defaulted.

**Posting needs the page and the service to be same-site.** Measured, in a browser:

    page on file://                   POST 403,  Sec-Fetch-Site: cross-site
    page served on 127.0.0.1:8080     POST 200,  Sec-Fetch-Site: same-site

Both are §5 working as written: the cross-site refusal is the CSRF defence, and same
host on a different port is same-site, which is the real deployment. Opening the demo
page off disk gives a working read-only panel; serve the directory to post from it.

**YOU BANNED THE WRONG PERSON.** The likeliest thing you will get wrong, and the only
mistake in this system with somebody waiting on the other end of it — a banned address
cannot post, so they cannot appeal through the chat, which is what `--appeal-to` is for.

    kourtchatctl hash <their IP>       the ip_hash, if you have the address
    kourtchatctl list -ip <hash>       their consequences and the state column
    kourtchatctl why <id>              what it was based on: the evidence COPY,
                                       the network it matched, who it hit
    kourtchatctl unban <id>            reverses it (`revoke` is the same command)

`status` is the SERVICE's health — backlog and scanner age — not a person's. `list -ip`
is the per-address view, and it takes a `net_hash` as readily as an `ip_hash`
(`ip_hash = ? OR net_hash = ?`), which is how you find everyone a manual ban caught.

Three things to expect, all measured in `TestTheOperatorsViewOfABadBan`:

**The ban probably took somebody else with it.** A manual consequence matches `net_hash`
as well as `ip_hash` (§2), so everyone sharing that network — a household, an office, a
university — is silenced too. Their messages stay visible, because hiding keys on
`ip_hash` alone and they wrote nothing wrong. A silenced person with all their words
still on screen is the normal appearance of this mistake, and `list -ip <net_hash>` is
how you find out who else is in it.

**`unban` gives back both halves or it has given back nothing.** Reversing restores the
ability to post AND un-hides what the ban hid. Check the second one: `status` reading
`ok` while the messages stay hidden is a person nominally unbanned and still erased.
The reversal is a RECOMPUTE, not a blanket un-hide, so a message another live
consequence covers correctly stays down — including a disclosed secret, which nothing
un-hides.

**The row stays, marked REVERSED.** Reversing does not delete the record, and should
not: the next operator needs to see that something happened and what it was. It also
means a wrongly banned person is not left one rung up the ladder — manual consequences
never counted toward escalation, and a revoked one would not count either way.

**A message the scanner flagged and did NOT act on is waiting for a person.** That is
§7's carve-out working as intended, and `review` is where those live:

    bin/kourtchatctl -db chat.db review
    bin/kourtchatctl -db chat.db kick -msg 41 -for 1h -why "judged a lure"
    bin/kourtchatctl -db chat.db dismiss 41      # looked, doing nothing

`-msg` takes the author and the evidence from the message, so acting on something you
just read needs no hash copied by hand — transcription is where an operator punishes the
wrong person. A dismissed message stays readable under `review -all`, because a decision
to do nothing is a decision.

**Withdrawing a court, for an on-chain purge.** `freeze` latches a court out of service:

    bin/kourtchatctl -db chat.db freeze dev/orem

Latched rather than re-derived from the chain on every request, because a chain read cannot
tell "this court was purged" from "the node is unreachable", and a compliance control whose
fail-open trigger is an RPC hiccup is not a control.

It stops BOTH verbs — 410 on the read as well as the write — and it stops MODERATION too.
Neither was true until it was measured, in two passes:

    frozen consulted in Post only    the transcript was still served to anyone who asked
    then in Post and Recent only     the scanner still spent inference on it, and a
                                     moderator's queue still filled with its messages

A control that announces a property it does not have is worse than no control, because
somebody relies on it — and the tool printed "its history is no longer served" throughout.

The scanner skipping a withdrawn court is `Claim`'s own reasoning applied consistently: it
already skips `hidden`, because punished content must stop driving verdicts, and withdrawn
content is in the same position — unreadable, so no harm is left to prevent, and judging it
is work with no beneficiary. The counter-argument is real and was weighed: a scam is a scam
and its author should be stopped elsewhere. That is what the live courts are for, which is
where the author can still do harm and where the scanner is still looking. Freezing happens
after the fact, so the history has usually been scanned already.

**Freeze does not erase, deliberately.** The rows stay for an operator who needs them, and
the pruner is the separate step. "Stop showing this" and "destroy the evidence" are different
decisions and only one of them cannot be undone, so an operator who needs the content gone
freezes and then prunes. That order matters: pruning first leaves the court still serving
whatever arrives next.

The panel reports a frozen court as closed rather than unreachable. Same reason in miniature:
"unreachable" sends a reader to reload and an operator to check the network, over something
working exactly as intended.

**Why `dismiss -from` has no batch limit when `prune` does.** A fair question, since both are
bulk writes. Measured: 50,000 queued messages dismissed in 91ms, with 937 read+status pairs
completing alongside and a worst case of 467µs. The difference is the population, not the
statement — `dismiss -from` is scoped to ONE address, whose output the throttle already
bounds, while a prune sweeps every author and all of history and is bounded by nothing else.
If a future `dismiss` ever grows a wider scope, it needs prune's limit.

**BACK UP ALL THREE FILES, OR USE `.backup`.** This is the one that will cost somebody
their database. In WAL mode the `.db` file is not the database — measured on a server
that had taken three messages:

    chat.db          4,096 bytes      just the header
    chat.db-wal    168,952 bytes      the schema AND every row
    chat.db-shm     32,768 bytes

`cp chat.db backup.db`, or an rsync of that path, produced a file that opens cleanly and
answers `no such table: messages`. Not "a few messages short" — no tables at all, because
even the schema was still in the WAL. It looks like a database and it is empty, and the
discovery happens during a restore. Either copy all three files together, or take a
consistent snapshot:

    sqlite3 chat.db ".backup '/backups/chat-$(date +%F).db'"
    sqlite3 chat.db "VACUUM INTO '/backups/chat.db'"      # same guarantee, compacted

**Upgrades.** `kourtchat` migrates the database when it opens it, and migrations are
column additions with defaults only, so an older binary reading a newer database is fine
— every query names its columns. Back up first anyway, and start one binary before the
others so a migration failure is one log line rather than three.

**Losing the hashing key is losing every consequence.** Every `ip_hash` is an HMAC under
it, so a new key means every kick and ban in the table matches nobody, and every public
suffix in the room changes at once. The key is as much the state as the database is;
back it up with the same care and, per above, not in the same file.

**One predicate, one place — and an audit rather than a hunch.** After the third bug of this
shape, the remaining ones were found by tabulating every query in `internal/chat/store.go`
against each guard clause and looking for the asymmetries, instead of guessing where to look
next. Nine asymmetries in total, all the same failure:

    freeze        checked in Post, not in Recent       a withdrawn court kept serving
    freeze        then not in Claim                    it was still scanned, at a cost
    freeze        nor in the review queue              a human triaged what nobody could read
    hidden        not in the backlog count             counted work Claim would never take
    hidden        not in the review queue              a human asked about punished messages
    hidden/frozen not in the UNSCANNED warning         warned about work nobody could do
    in force      expiry ignored by count and list     an operator count that only grew
    revoked_at    ignored by the context window        an upheld appeal still truncated it
    same message  named in Consequence's comment only   a late kick left its scam on screen

Four shared predicates now have exactly one definition each — `sqlAwaitingReview`,
`sqlNotFrozen`, `sqlInForce` — and the one deliberate exception is documented where the audit
flags it: the throttle ignores `hidden` and `frozen` on purpose, because it asks what an
address SENT and hiding a message afterwards does not un-send it.

One more of the same shape crossed a language boundary rather than a function: the panel
repeats the server's length limits so a user hears "too long" before a round trip, which
made them two definitions in two languages that no build could compare. `web/chat.js` declares
them once and a Go test reads that file and checks it against the constants, from the side that
enforces them — prevention rather than a bug found, which is the first time this class has

The lesson is cheap to state and was expensive to learn nine times over: a predicate that lives in
more than one place eventually disagrees with itself, and the disagreement surfaces as a
control quietly covering less than its own documentation claims.

Two bugs of the same shape were found in consecutive passes
and they had the same cause. `freeze` was checked in `Post` and not in `Recent`, so a
withdrawn court kept serving. `hidden` was honoured by `Claim`, `Recent` and the prior-context
window but not by the backlog count or the review queue, so the backlog counted rows that
could never be claimed and the queue asked a person to judge messages already hidden.

The second one existed because the queue's definition was written out **seven times**, in four
indentations, across five functions — and three copies had already lost their `hidden = 0`. It
is now a single `sqlAwaitingReview` constant. A predicate that lives in more than one place
eventually disagrees with itself, and the disagreement shows up as a control that quietly
covers less than its documentation claims.

**Watch the backlog — and the UNSCANNED line, which is the one that hides.**
`kourtchatctl status` reports the heartbeat, the unscanned count, and how many messages
gave up. Fail-open is deliberate — chat works with no scanner — but silent fail-open
means moderation can be off for a week with nobody noticing, and the backlog alone does
not catch it.

Measured, with a proxy that answers `/api/tags` so the daemon starts and 503s every
classify — the OOM-after-startup case §1 predicts, not a misconfiguration:

    during the backoff   backlog 2 unscanned, scanner 1s ago, enforcing    honest
    after five attempts  backlog 0, scanner 1s ago, enforcing, queue empty  all green

Every mechanism behaved correctly and together they hid the outage. `RecordFailure` gives
up after five attempts so a malformed row is not retried forever; the row goes `ScanDone`
with an EMPTY verdict, which drops it out of the backlog; `PendingReview` needs a
non-clean verdict, so it never reaches the review queue; and `Run` heartbeats whether or
not it classified anything. A seed-phrase lure sat in the court unclassified while every
number said fine.

So `Health.Unscannable` counts terminal rows with no verdict — `scan_state` alone cannot,
because `ScanDone` is also where every successfully scanned message ends up — and the
scanner logs `GAVE UP` once per message, since the fifth failure otherwise reads exactly
like the first four. If that line or that count is non-zero, moderation did not merely lag;
it skipped those messages permanently, and no human was told either.

The backlog can mislead in the other direction too, and did. It counted hidden rows, which
`Claim` skips by design, so after any consequence it stopped returning to zero — measured at
2 counted against 0 claimable. It now matches `Claim` exactly. A revoked consequence un-hides
those rows and they become pending again, which is the right direction and is asserted.

**Flags** need either a proxy that computes the country (`--country-header`) or a
local GeoLite2 export (`--geo-locations` plus `--geo-blocks`). With neither, no flag
renders and everything else works. No data file is committed and none should be:
GeoLite2 needs an account and is licence-restricted.

## 10. Status

Implemented and verified live against a running server and a real gemma3:4b, and in a
real browser against both. Go tests across three packages, four web harnesses, and two opt-in suites behind a
real model. `make gotest` and `node web/tests/run.js` print the counts; they are not
repeated here, because three separate commits have now corrected a number in this
paragraph that went stale the moment a test was added:

- **`internal/chat`** — sanitiser and skeleton, client-address policy, the store
  (schema, throttle, enforcement with the automated ceiling), the HTTP server
- **`internal/scan`** — the Ollama classifier, the deterministic prefilters, the
  scanner loop with escalate-only windowing
- **`internal/geo`** — the country lookup: none, proxy header, or MaxMind table
- **`cmd/kourtchat`, `cmd/kourtmod`, `cmd/kourtchatctl`**
- **`web/chat.js`** — the panel: rendering, escaping, the poller, demo mode

**The panel is built and wired** — `web/chat.js`, mounted at the foot of every court
page (§11). It went in as a file of its own rather than as another block inside
`index.html`, which turned out better than the plan in two ways: everything the feature
consists of is readable in one place, and it carries its own stylesheet, so the page's
theme did not have to grow a chat section. The page's own `esc()` was hardened to escape
`'` and a backtick anyway — the panel does not depend on it, but `esc()` is what every
other surface uses.

Three properties are load-bearing and each fails a test if removed. Everything is
escaped, including `'` and a backtick, because the server preserves markup on purpose
(§4). Nothing is ever linkified — a scam works when its link is clickable. And the
transcript is REPLACED from a full fetch rather than appended to by id, because
`Recent` only returns unhidden rows, so an incremental client would keep showing a
scam for the rest of the session after §7 hid it.

## 11. The panel in the page

Done. Seven edits to `web/index.html`, and their shape was decided by `web/README.md`
rather than by convenience. That file promises three times over that the page is
self-contained — "no build, no dependencies, no server needed", "just share the file" —
and `chat.js` is the first external file it has ever loaded. So it is loaded OPTIONALLY
and every call into it is guarded on `typeof`: the page opened with no `chat.js` beside
it renders every court exactly as before. Verified by aborting the request in a browser
and checking the docket survived, and by mutation — an unguarded call throws mid-paint
and takes the court's own content down with it.

    esc()            now escapes ' and ` as well as & < > "
    cleanCfg         CFG.chat joins the whitelist, with a rail field
    <script src>     chat.js, before the inline script, so mountChat exists by
                     the time the router can paint a court
    court route      appends the container, mounts, holds the stop in CHATSTOP

`cleanCfg` is the one to notice: it rebuilds config from defaults and copies across only
the keys it knows, so without the whitelist entry the endpoint would have been silently
forgotten on save. A settings box that loses what you type is worse than no box. Blank
turns chat off and clears storage rather than leaving a stale endpoint behind.

The stop function must be called before the container is replaced — `render()` is async
and re-entrant, so a poller can outlive the DOM it was writing to. `mountChat`'s
generation counter makes a stale tick inert; `CHATSTOP` is the half that releases the
timer rather than leaving it to expire.

Still not wired, and still for the same reason — `web/tests/` and the Makefile's web
targets are another workstream's uncommitted work:

    web/tests/run.js            directory scan, picks up chat_test.js already
    web/tests/browser/run.js    add chat_page.js, chat_render.js, chat_live.js
                                to CHECKS
    Makefile                    web-test / web-visual are theirs; the Go half
                                (gotest, chat, the fmt fix) is committed

All five run standalone:

    node web/tests/chat_test.js              89 assertions, no dependencies
    node web/tests/browser/chat_page.js      31 checks, the real court page
    node web/tests/browser/chat_render.js    65 measurements, the panel alone
    node web/tests/browser/chat_live.js      34 checks, against a live server
    OLLAMA_LIVE=1 node .../chat_moderation.js  18, the loop with a real model

**Chat is off in demo mode, deliberately, and that leaves one combination untested.**
`chatBase` returns "" whenever `CFG.mode === "demo"`, which is what keeps the README's
promise that the demo makes no network calls — so live chat requires live mode, and live
mode requires a node. The real court page against a live chat service is therefore not
reachable without seeding a chain, and it is not faked: the wiring on the real page is
covered by `chat_page.js`, and live chat in a browser by `chat_live.js` and
`chat_moderation.js` against `chat-demo.html`, which has no chain to satisfy.

## 12. Two kinds of evidence for one property

`web/chat-demo.html` is the panel with nothing else around it — openable straight off
disk, no node and no service — and it exists for a reason beyond convenience.

The escaping rule is the only thing between a message body and script execution, and
the node harness can only assert things about the STRING `chat.js` produces:
`!/<img/.test(html)` is a regex, and passing it is evidence about a regex. What matters
is that a browser's parser builds no element and no handler runs. So the same property
is checked twice, differently: `chat_render.js` drives that page in headless Chrome,
renders twelve payloads through the shipped function into a real document, and asserts
that no element was constructed, that a sentinel global was never set, that no dialog
opened, and that the payload is nevertheless still READABLE — an escaper that silently
dropped hostile text would satisfy every absence check while censoring the room.

The browser half also measures what no source review can see: that a 400-character
message from a 24-character name does not push the page sideways at 1200, 760 or 380
pixels, and that the flag is a regional-indicator pair rather than the two letters of
the country code.

`chat_live.js` is the other half, and it is a gate rather than a fixture: it BUILDS
both binaries, starts a `kourtchat` on a free port with a throwaway database, and
drives the page against it — no model and no chain, because enforcement comes from
`kourtchatctl`. Thirty-four checks, and what they cover is the set of things that are
only true in a browser: CORS and the CSRF rule (header behaviour, and a browser's
headers are not curl's), the poller converging on another client's message without a
reload, a manual kick appearing in the UI with no category named, a kicked reader still
able to read while their own messages are hidden, the server refusing that reader
regardless of the disabled box, and `unban` restoring both posting and the hidden
messages visibly.

`chat_moderation.js` closes the last gap, and it is the one test that exercises the
feature as described rather than as built: two people in one court, one posts a
seed-phrase lure, gemma3:4b reads it, and what each of them SEES is checked in the DOM.
Everything else stops short — `chat_live.js` applies a consequence with `kourtchatctl`,
so it never asks the model anything, and §6's live fixtures ask the model but have no
browser.

It is built around the rule that has earned its place harder than any other here: test
the BYSTANDER. Both of the worst bugs in this service were invisible to unit tests — the
/24 collateral and the discarded 0-100 confidence — so the bystander is a real second
identity, and the load-bearing assertions are the ones about them: not punished, shown
no notice, still posting, own message still on screen. Making that non-vacuous took
work: everything on one machine is 127.0.0.1, and in proxy mode an absent
`X-Forwarded-For` falls through to the peer, so both browser pages would have been ONE
client and every bystander assertion would have passed while proving nothing. So
`kourtchat` runs behind two one-line proxies that each inject a different forwarded
address — the deployment shape anyway — with a separate browser context each.

Observed: gemma3:4b returned `scam`, the author was kicked, the message was hidden from
both panels, the notice named no category, and the bystander was untouched.

The live half has already paid for itself three times. It found that an operator had no way to
obtain a hash for an address (§9), that `hash` labelled its network hash with the wrong
prefix, and — on its first run — that it was testing a binary one `make chat` behind
the source. It now builds what it tests, because a suite whose subject is whatever was
compiled last reports on the past.

Two mutations survived the browser suite and were left surviving on purpose, because
both are facts about the markup rather than gaps in the tests. Escaping `<` alone
already prevents tag construction, so removing the `>` escape changes nothing a browser
can see (the node harness catches it). And removing the `"`, `'` and backtick escapes
changes nothing either — every message value lands in TEXT position, and the one
attribute built from message data is the flag's `title`, which only renders when the
country has already matched `^[A-Z]{2}$`. Rather than pin a mechanism nothing currently
depends on, the suite pins the REASON it does not: a sentinel is placed in every field
of a message and every attribute of every rendered element is searched for it. Write
`title="${moniker}"` one day and that check fails, escaped or not.

Still deferred: validating a court against the chain. It was the last item on this list
and it stays deferred, now for a measured reason rather than a predicted one.

The original argument was that a chain read cannot distinguish "no such court" from "node
unreachable", so a fail-open gate is not a control and a fail-closed one breaks chat on an
RPC hiccup. Attempting it produced a sharper version of the same problem. Asked for a court
that exists and a court that does not, a live node answered IDENTICALLY:

    CoinPrice("orem")                 vm.InvalidPkgPathError
    CoinPrice("definitelynotacourt")  vm.InvalidPkgPathError

— because the realm was not deployed on that node at all. Existence, a wrong realm path, a
node on the wrong chain and a node still syncing all arrive as one error class. So a
fail-closed gate has a failure mode worse than the one it prevents: a single
misconfiguration refuses chat for EVERY court while reporting "no such court", which points
whoever is debugging it at precisely the wrong thing.

**And the harm it would have prevented is smaller than it looks**, which is the other half
of the decision. One address can invent rooms freely — 110 distinct rooms in ten minutes of
clock — but scattering buys it nothing: 20 attempts in one room and 20 across 20 rooms both
land exactly `PerIPMax`, because the per-address window ignores which room a message went
to. The namespace is untidy; the volume is not. Both properties are pinned in
`internal/chat/abuse_test.go` so the second one stays true, and the pruner (§7) bounds what
the untidiness costs over time.

What would make this worth revisiting is a way to tell the four failures apart — verifying
the realm answers at all, once, at startup, so "the realm is reachable and this court is
not in it" becomes a distinct and reportable state. Until then `freeze` covers the
compliance half, and an operator who wants a closed namespace has the chain allowlist.
