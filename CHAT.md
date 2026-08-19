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

**A chain of nothing but trusted hops identifies NO client, and used to name the proxy.** The walk
returns the first hop from the right that is not a trusted proxy. If every hop is one of ours the
client was never recorded — and the fallback returned the peer, so every such request shared one
identity. That is the failure this section opens with, arrived at from the other direction: the
throttle goes global and the first kick kicks the internet.

Measured while probing the header for a denial of service, which it is not — twenty thousand hops
walk in 644µs against 375ns for the ordinary case, and Go's header cap bounds it. What was wrong was
the answer: those hops came back as `127.0.0.1` with no error.

It is reached by configuration rather than by attack. A proxy that appends puts the real client
rightmost, where it wins at once; but list a whole VPC as `--trusted-proxy` and every client arriving
from inside it is "ours". Refused now — a 403 tells an operator their range is too wide, and silently
bucketing everyone together tells them nothing until somebody is kicked.

**And a refusal the operator cannot see is a service that silently stopped.** The 403 goes to the
client, so when the cause is a range too wide the symptom is "nobody can post" and the log said
nothing. One line, once per cause:

    refusing requests: every X-Forwarded-For hop is inside --trusted-proxy, so no client can be
    identified. Narrow the range. peer="127.0.0.1:61938" header="203.0.113.7". Logged once.

Once, not per request, because both causes are persistent conditions rather than events — a
misconfiguration fires on every request and would fill the disk, and somebody probing the origin
directly chooses the rate. Verified live: four refused requests, one line. An ACCEPTED request logs
nothing, which matters more than usual here — a logger that narrates every request buries the one
line that means something.

The header is printed with `%q`. It is attacker-controlled and passes through no sanitiser, unlike a
court name (bounded by `courtRe`) or a body (`SanitizeBody`), so a raw print puts escape sequences
into an operator's terminal — and ANSI can rewrite the lines above it, which is a way to hide the
refusal being reported. `%q` renders them as `\x1b`, still visible as an attempt.

**Two situations that looked identical are now separate**, and the second had to keep working: a
header of only malformed hops, or no header at all, is not a chain. That is a request from the proxy
itself — a health check, an operator's curl — and there the peer IS the client. Both branches are
asserted, along with a real client behind trusted hops still winning, so this could not become
"refuse everything with a header".

Implemented in `internal/chat/clientip.go`, with the /64 rule for IPv6 (the host
half is free to change, so a /128 consequence expires when its target wants) and a
keyed HMAC whose privacy claim is stated exactly: it defends against a stray copy
of the database file, **not** a host compromise or a whole-data-directory backup,
because IPv4 is 2^32 and anyone holding both recovers every address in seconds.

**One address, one hash, however it is spelled** — and this was broken in the direction that reports
success. `Prefix` keyed on `Is4()`, and an IPv4-MAPPED address is not `Is4()`: "::ffff:203.0.113.7",
which is how a dual-stack access log and some proxies write an IPv4 client, took the IPv6 /64 branch.

    hash of ::ffff:203.0.113.7    1689b677c286   prefix ::/64
    hash of 203.0.113.7           3cb5bdc7c74a   prefix 203.0.113.7/32

`ClientIP` unmapped before hashing, so the server stored the second. An operator pasting the mapped
form into `kourtchatctl hash` got the first, banned it, was told the consequence was recorded, and
the person kept posting. **A ban that reports success and does nothing is the worst failure this
tool has**, because every surface an operator can check agrees the matter was handled. The same line
also meant the /64 of any mapped address is `::/64`, so every IPv4 client collapsed onto one hash.

`Prefix` and `NetPrefix` unmap themselves now, rather than the CLI doing it, because there were
already four call sites and a caller that forgets gets a confident wrong answer instead of an error.

**The two granularities differ on purpose, and an operator has to know which one they are using.**
IPv4 is hashed per address (/32) so a routine kick does not take the neighbours; IPv6 is hashed per
/64 because a host is normally delegated the whole thing and a /128 consequence expires whenever its
target likes. So two IPv6 addresses in one /64 SHARE a hash, by design — banning an IPv6 "address"
bans its /64. Both are asserted, including the sharing, so neither can be mistaken for the collapse
bug above.

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

**And the mark cap was the same mistake a THIRD time.** `maxMarks` was 3 — labelled "Zalgo
defence", which reads as though lowering it were a security measure. Pointed Hebrew puts four
marks on one consonant as a matter of course, dagesh and sin-dot and vowel and meteg, and five
with a cantillation accent:

    consonant + vowel                    1   accepted
    + dagesh                             2   accepted
    shin + dagesh + sin-dot + vowel      3   accepted
    + meteg                              4   REFUSED
    + cantillation accent as well        5   REFUSED

Fully-voweled Arabic and Hebrew niqqud with cantillation both landed exactly ON the cap, so the
scripts that need marks most had none of its headroom, and what the sender was told is that their
message "stacks too many marks on one character".

The paragraph above had already written the answer down twice and this constant still had the
bug: `Skeleton` folds every mark away on its own — "s͡c͡a͡m", "s̈c̈äm̈" and a 14-mark monster all
reduce to exactly "scam", and an obscured "s̈ëëd̈ p̈ḧräs̈ë" to "sendmeyourseedphrase", which the
deterministic prefilter matches without help. So raising the cap costs zero evasion resistance,
and that is asserted in a fixture beside the permissive cases rather than argued here.

What survives is the LAYOUT argument, which is real but only at volume: a stack sits above its
character until roughly a dozen marks and only then smears up through the line above. So the cap
now sits above real text's ceiling rather than on top of it — 8, three clear of the measured
maximum of five, still far below where a stack damages a page. The lesson these three share is
that a small bare number guarding a display path is nearly always sitting inside the ordinary
band, and that the two errors either side of it are not symmetric: refusing does not inconvenience
somebody, it tells them their writing system is unacceptable.

Note that the RUN cap (8 identical consecutive runes) behaves differently on purpose — it
truncates rather than refusing, so "============" is stored as eight of them and "what!!!!!!!!!!!"
keeps eight marks of emphasis. Silent, but it alters nobody's alphabet.

**And a FOURTH: the limits themselves were counting the wrong thing.** `MaxMonikerRunes` counted
code points, which is the fix for the byte version of this bug and not the end of it, because in
Hebrew, Arabic and Thai a letter costs two or three code points:

    Bartholomew Smythe-Jones        24 runes  24 letters   accepted
    عَبْدُ الرَّحْمَٰنِ بْنُ مُحَمَّدٍ            34 runes  18 letters   REFUSED

An eighteen-letter name refused where a twenty-four-letter one passes. A display name is long or
short by how many letters a reader sees, so the moniker counts letters now.

**The body deliberately still counts runes,** and that asymmetry is a decision rather than an
oversight. The inequality is real and measured — pointed Hebrew runs about 1.9 runes per letter
and voweled Arabic 1.7, so those writers get roughly 212 and 231 letters against an English
writer's 400 — but 212 letters is still a long chat message, whereas 18 letters is somebody's
name. Counting letters in a body would also move the binding constraint to `MaxInputBytes` and
roughly double the worst-case stored message, which is a §8 storage decision and not a fairness
one. Both rules carry fixtures; a mutation flipping the body survived until the second was written.

Two things worth knowing about the shape of this bug. **NFKC hides it from English**: "a" plus a
combining acute is composed into "á", one rune, so Latin text rarely pays the penalty at all —
the scripts that pay are exactly the ones with no precomposed forms, which is to say the ones
normalisation cannot help. And **skipping `Mn`/`Me` is an approximation of grapheme clusters**,
exact for Hebrew, Arabic and Thai and partial for Devanagari, where a matra is a SPACING mark
(`Mc`) and still costs a letter. Grapheme clusters would need a segmentation dependency in Go and
`Intl.Segmenter` in the panel; every name measured fits at 24 either way, so the approximation was
taken and its boundary pinned rather than left to be rediscovered.

**The panel had to learn the identical rule, and `\p{M}` is a trap.** `chatValidate` counted code
points too, and worse, a `maxlength` of 24 UTF-16 units stopped a voweled Arabic name from being
TYPED — a dead keystroke with no message, which is the worst way for a limit to be wrong.
`maxlength` is a looser derived stop now and the real check counts letters. The panel's predicate
must mirror Go's exactly, and `\p{M}` includes `\p{Mc}`: a panel using it would refuse Devanagari
names the server accepts. So the drift test grew to police the RULE and not only the number.

**A FIFTH, and this one was silent.** The four above all refused a message, which at least tells
somebody something. `erase()` instead *removes* characters, and its exemption list was nine
hand-written codepoints described as "Arabic and Syriac format characters ... part of well-formed
text in those scripts". That description names an actual Unicode property —
`Prepended_Concatenation_Mark`, the format characters that precede digits and belong to the text —
and the list was that property as of an older Unicode. It had since gained four members, which
fell through to the `remaining Cf` catch-all:

    U+0890   ARABIC POUND MARK ABOVE
    U+0891   ARABIC PIASTRE MARK ABOVE
    U+110BD  KAITHI NUMBER SIGN
    U+110CD  KAITHI NUMBER SIGN ABOVE

Two Arabic CURRENCY marks, dropped without a diagnostic, in an application about money and claims:
a figure losing its unit rather than a message being turned away. `erase()` reads the property now,
and the fixture iterates it instead of listing members, so a fifth mark added by a future Unicode
is covered when the toolchain learns of it rather than when somebody notices Arabic text is wrong.
The general form of this one is different from the thresholds: **a copy of an external table is a
threshold that moves on its own.** But **a property is the right source only when the
design wants the whole property**, and the same audit run one step further shows why. `erase()` does
not catch every invisible — 3,740 default-ignorable codepoints reach a reader, including the
assigned Khmer inherent vowels U+17B4/U+17B5 — and the tempting fix is to sweep the whole
default-ignorable set the way the concatenation marks were fixed. That would erase
U+E0100..U+E01EF, the ideographic variation selectors, which are how Japanese picks which kanji a
reader sees: the same defect, introduced while fixing it. §4 keeps VS16 for emoji and IVS for CJK
deliberately, and both are asserted.

The incompleteness is safe for a measurable reason rather than a hopeful one: **`Skeleton` is an
allowlist.** It keeps letters and digits and drops everything else, so an invisible does not have to
be enumerated to be folded — an obscured "send me your s​еed phrase" still earns a deterministic
scam floor, and a lure with an invisible wedged into it still collides with its plain form for the
duplicate rule. That property is what licenses `erase()` being conservative, so it is pinned as a
fixture over all 3,740 rather than left as an argument here.

**Where this file chooses against the writer, once, on purpose.** LRM (U+200E), RLM (U+200F) and
ALM (U+061C) are erased. They are bidi MARKS, not overrides — they cannot reorder text arbitrarily,
and they are the standard way to make mixed-direction text render correctly, which a court
discussing "claim 7" in Arabic produces constantly. The old comment filed them under "bidi
overrides", which is wrong about what they are. They stay erased because the neutrals whose
direction they resolve are, here, claim numbers and amounts, and a mark that can move a digit
across a figure is worth more to an attacker than to a writer. The cost is real and bounded: no
character of anybody's message is lost, and some mixed-direction sentences render with a trailing
number or punctuation on the wrong side.

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
about a person and never reaches a public surface — plus `you: {state, until, seconds, ref}`
so the composer can be disabled before someone types into a box that will 403.
`since`/`limit` clamped; GET has its own budget.

**`now` is the server's clock, and every rendered time is corrected against it.** The same
arithmetic as `seconds` below, on a much wider surface: every message carries an absolute
`created_at` and the panel turns it into "5m" by subtracting. Measured through the shipped
`chatWhen`:

    clock correct      1s=just now   5min=5m         2h=2h
    ten minutes FAST   1s=10m        5min=15m        2h=2h
    two hours SLOW     1s=just now   5min=just now   2h=just now

The two-hour row is the one that matters here: a statement made two hours ago presented as "just
now" misrepresents the order things were said in, which is exactly what a court is for. The panel
learns the offset from every reply and corrects every timestamp through one value, which also fixes
the status line's fallback path for free.

**The first attempt at this looked right and did nothing**, and the reason is worth keeping.
`chatFetch` returns an explicit allowlist — `{messages, you, next}` — and dropped `now` on the
floor, so the panel had nothing to learn from. It was "verified" by simulating the arithmetic by
hand, which never went through `chatFetch`; a browser mount reading "10m" for a message posted a
second ago is what found it. The test drives the whole path now, with a discriminating case: strip
`now` from the reply and the same panel falls back to "10m".

**`seconds` exists because a countdown differenced against the reader's clock shows them their own
skew.** `until` is absolute, and the panel used to subtract `Date.now()` from it. Measured on a
five-minute kick through the shipped status line:

    clock correct       "paused for another 5 minutes"
    ten minutes SLOW    "paused for another 15 minutes"     wrong by three times over
    ten minutes FAST    "paused"                            no duration at all

The state was never affected — nobody is wrongly let through and the composer stays disabled — so
what was wrong is the one number a punished person actually needs, and in the fast case they were
told they are paused with nothing to say when to come back. Browsers take their time from the OS.

`seconds` is computed where the deadline was, so it needs no clock at the other end, and a panel
that re-polls gets a fresh value every few seconds. `until` stays for an appeal to quote and as the
fallback for a client that predates the field. A permanent ban carries neither, because there is
nothing to count to.

The drift guard covers it, and this one fails SILENTLY without help: a renamed tag leaves the panel
subtracting from the local clock again, with the state still correct, so only the duration lies.

**The body is bounded before it is read, and too big is not malformed.** `http.MaxBytesReader` caps
a POST at twice `MaxInputBytes` before `Decode` touches it — the sanitiser's per-field limit is
checked afterwards and cannot bound memory. That part was already right. What the client was told
was not:

    100 kB of valid JSON   400  expected {"moniker":…,"body":…}     the JSON was fine
    5 kB body              400  your message is far too long to process (4096 bytes maximum)
    malformed JSON         400  expected {"moniker":…,"body":…}
    ordinary post          200

One condition — too much data — reported two ways depending on which check caught it, and the larger
case blamed the JSON, sending a client to their serialiser when the fix is to send less. It is 413
now, with the same number both regimes quote: the per-field limit that is the client's to work with,
not the internal cap. Malformed JSON keeps its own message, asserted, because otherwise the fix
could have been "call everything too large".

413 was a status the panel had never seen. `chatPost` maps 429 and 410 by hand and falls back to
"could not send (N)", so the server's sentence surviving that fallback is asserted rather than read
off the code.

**A REFUSAL HAS TO NAME THE RIGHT FIELD AND SAY WHAT WOULD BE ACCEPTED,** and for a while it did
neither. The server wrote `"moniker: " + err.Error()`, and the sanitiser's messages are phrased for
a message BODY, so a rejected name came back as `moniker: message is too long` — the wrong field,
named twice, with no limit. The throttle two cases along says "one message every 2s" and "10 per
1m0s"; a caller told only "too long" can do nothing but guess, and the moniker's rule is not
guessable, because it counts LETTERS and 24 is therefore not a character count.

    your name is too long (24 letters maximum)
    your message is too long (400 characters maximum)
    pick a name first  /  type something
    your message stacks too many accents on one character

The sentinels stay as identities and the sentence is composed at the boundary, where presentation
belongs — callers want `errors.Is`, not prose. The numbers come from the constants, and a fixture
checks each refusal quotes the limit that is enforced AND no other, since a name refusal quoting
400 would send somebody trimming to the wrong length. The wording follows `chatValidate` so the
panel and the API do not contradict each other about one rule.

**No refusal names the category behind a consequence.** `posting is blocked for this address`, and
`you: {state, until, ref}` carries no reason — so the evasion oracle stays shut, which
`chat_moderation.js` checks in the DOM rather than trusting. The same audit renamed `ErrPurged` to
`ErrWithdrawn`: a frozen court is withdrawn and a pruned one is purged, and since §7 rests on those
being different decisions, the vocabulary should not blur them.

**A CURSOR IS ONLY MEANINGFUL WITHIN A RETENTION EPOCH,** and the endpoint used to pretend
otherwise. `next` comes back in every response, which invites incremental polling, and
`messages.id` is a rowid that restarts at 1 once prune empties a court (§7). So a saved cursor
asks for `id > 40000` where the newest row is 12 and receives an empty room until forty thousand
messages accumulate again. Measured: cursor 8, room holding 2, client shown 0.

`Recent` falls back to a full read when the cursor is past every row that exists — a value the
server cannot have issued for the rows now present — and one fallback re-syncs the client, since
the read it gets back carries current ids. The idle case is untouched and that is the half worth
asserting: an idle client's cursor EQUALS the newest visible id, so the fallback does not fire and
a quiet room still answers with nothing rather than fifty rows.

It does not fix the boundary. If new ids have climbed back to exactly the old cursor,
`since == max(id)` is indistinguishable from idle using ids alone, and the client keeps a gap below
its cursor instead of a frozen room. The unbounded case was the one that mattered.

**The panel does not poll incrementally at all,** for an unrelated and better reason: `Recent`
returns only unhidden messages, so a client appending by id would keep displaying a scam for the
rest of its session after a moderator hid it. Re-reading the last fifty rows every few seconds is
how hiding becomes visible. The fix above is for every other client and for the contract this
endpoint advertises.

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

**Its threshold refused ordinary speech and had to move.** `DupMinSkeleton` was a
bare 12, and 12 is shorter than the things people repeat between rooms. Measured
over 29 such phrases and 13 lures a broadcaster would send:

    >=12   ordinary refused 13/29    lures exempt from this rule  3/13
    >=16   ordinary refused  4/29    lures exempt  4/13
    >=24   ordinary refused  0/29    lures exempt  7/13
    >=26   ordinary refused  0/29    lures exempt 10/13

At 12 it refused "thanks everyone", "still waiting" and eleven more. **Length does
not separate the two classes** — ordinary phrases reach 23 skeleton runes and lures
start at 7 ("dm me now") — so no threshold avoids both errors and the only real
question is which error to prefer. A false positive refuses an innocent person for
saying thanks in a third room, with nothing to tell them but this rule's own
message. A false negative lets one broadcast past a coarse rate limit while the
scanner still reads every copy. So the threshold sits ABOVE the ordinary band at
24 — the first value with no ordinary refusals, where 26 gives up three more lures
to buy nothing. 16 was tried first and still refused four.

Of the seven lures exempt at 24, two never needed this rule: "send me your seed
phrase" earns a deterministic SCAM floor and "t.me/support" a spam one, and a floor
is a consequence rather than a refused message. The other five are short DM-asks,
which is the scanner's shape.

**And 429 is not one wait.** A throttle clears in seconds; a duplicate is
remembered for ten minutes. Both shared one `Retry-After: 10`, so a client
honouring it retried into the same refusal for the rest of the window — wrong by
sixty times, and invisible because the status code was right. The duplicate's
value is derived from `DupWindow` now, and its message names the remedy, since
waiting is not the only one: post something different.

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

**A HEDGED VERDICT REACHES NOBODY, AND THAT IS TWO RULES MEETING.** `MinConfidence` is 0.6:
a label the model is less sure of than that is rewritten to `unknown`, because a punishment
path must not be a dice roll. Separately, `sqlAwaitingReview` excludes `unknown`, because a
message nobody suspects is not a review item. Each is right alone. Together they mean a
suspicion the model half-believes earns no consequence AND no human look — it is recorded,
the message stays on screen, and nothing surfaces it. Same composition shape as the outage in
§9: two defensible rules whose product is a silence.

It is left as it stands, deliberately. Routing every 0.25 hunch about a stranger into the
queue defeats what §7's queue is for, and where that line belongs is an operator's judgement
rather than a default worth guessing at. It is pinned as current behaviour in
`TestAHedgedVerdictReachesNeitherAConsequenceNorAReviewer`, so moving it is a decision
somebody makes rather than a thing that drifts.

**THE MONIKER IS NEVER CLASSIFIED**, and that is on evidence, not just the §8 design note.
`Claim` selects the body; "Kourt Support" and "admin" are invisible to moderation, so a scam's
credibility half is structurally outside the input. Closing that looked obviously right and
measurement says the opposite:

    "[dave] I can restore your account access…"             scam 0.25 -> 0.85
    "[kourt-moderator] I can restore your account access…"  scam 0.25 -> 0.25

gemma3:4b reads a claimed moderator restoring accounts as legitimate, and the same sentence
from "dave" as a scam that crosses the confidence bar. The name is not uninformative to the
model — it is a DISCOUNT on precisely the message an impersonator sends, and feeding it in
would hand that discount over.

What holds the line instead is that the ASK is in the body: "message me privately", "DM me",
"contact me directly" cannot be smuggled into a 24-rune name. Two of the three asks measured
are acted on at 0.85. The third is the 0.25 above — which, per the previous point, is the one
that disappears.

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
consequence) from 2 (a secret), and only 1 is recomputed.

**Nothing un-hid a 2, and the limitation had been weighed against the wrong probability.** The
comment at the code reasoned about "a noun list of exactly phrase length whose checksum passes by
luck, one chance in sixteen at twelve words" — and luck is not the case that happens. A message
reaches that path only when it is Reporting AND Secret: somebody asking **"is this a scam?"** and
quoting the phrase they were sent. Measured live, their message goes out of sight with **zero
consequences**, which is the carve-out working exactly as intended — and it was then invisible for
good, with `dismiss` unable to help because dismiss records that a person looked and does not touch
visibility. The carve-out exists to protect people who report abuse; permanently hiding the report
was the wrong other half of it.

    bin/kourtchatctl -db chat.db hide 41       # out of sight, nobody punished
    bin/kourtchatctl -db chat.db reveal 41     # and back again

The hiding itself stays right: a detector cannot tell a published test vector from somebody's actual
key without a list of every vector ever published — both canonical BIP-39 vectors come back
`secret=true` — and the harm is wildly asymmetric. What was wrong is that a KICK for the same
message is reversible with `unban` while this was not.

**`hide` is the other half, and it shipped a commit late.** `reveal`'s own output ends "if that
phrase is real rather than a published test vector, hide it again and tell its owner" — advice for
an action the tool did not offer. The store has had `HideMessage` since the scanner needed it for the
carve-out; only the operator verb was missing, so somebody who revealed a message and then realised
it was a real key had no way back. Guidance the code cannot support is the defect this document keeps
catching elsewhere, committed here in its own.

**And it must say what it did in terms a person reads.** `kick` refuses a MISSING `-for` with "a
timeout with no end is a ban" and then accepted one with no end in practice:

    kick -for 876000h   accepted; `list` showed "876000h0m0s left"
    kick -for 1ns       accepted; state=ok, and both the author's messages hidden
    kick -for -1h       correctly refused

No policy ceiling was added. Wherever it landed it would be arbitrary, and it would refuse a
legitimate long timeout while doing nothing about the likelier problem: 876000h is a plausible typo
for 876h and neither reads as a length anybody recognises. So the confirmation names it — "about 100
years", and the date it runs to — which catches the extra zero at every magnitude.

**The nanosecond case exposed a real asymmetry.** state=ok, so nobody is kept out for any measurable
time, and both the author's messages hidden — indefinitely, until somebody runs `unban`. The
duration is presented as the scope of the action and governs only the posting block; `HideWindow`
governs the other half and outlasts it. Both verbs now say so, and take the window from the constant
rather than a literal.

**Every action must say whether it actually did anything**, which is a different audit from the
reversibility one and turned up two more lies. Both were in the tool, both measured live:

    unban 1 -by bob      "reversed by bob" while the row said alice — the second attempt
                         affected zero rows, returned nil, and credited the caller with
                         somebody else's decision, in the record that makes "appealable" mean
                         something
    unban 999            "sql: no rows in result set", the driver's words for a typo
    kick -msg 1 twice    "kicked … [consequence 0]" then "unban 0" — a punishment that never
                         happened and an id that cannot exist

The store's `(0, nil)` on a replay is right and load-bearing: it is what stops a crash between
"punish" and "mark scanned" from walking the ladder. Presenting it as success was the defect. Both
verbs now name the row that already covers the evidence, and `unban` distinguishes "already
reversed by X on <date>" from "no consequence N".

`dismiss` and `freeze` were already honest, which is why only two changed.

**The reversibility audit, and where it stopped.** Asking which operations cannot be undone turned
up four:

    prune       deletion, and the one that stays irreversible on purpose — dry run by default
    freeze      a court unreachable to everybody; `unfreeze` now
    hidden=2    a report invisible to everybody; `reveal` now, and `hide` to put it back
    dismiss     a queue entry gone from the default view — left alone, on purpose

`dismiss` is the one that got a fixture instead of a verb, because it forecloses nothing:
`review -all` still lists the rows, a dismissed message can still be kicked, banned or hidden, and
the author was never told anything. What would change that is written into the fixture — if `-all`
grew unusable on a busy court, or if dismissal ever gated an ACTION rather than only a default view,
the lost worklist would stop being recoverable and it would need an undo like the others.

Both verbs report three outcomes rather than one refusal — hidden now, already out of sight (naming
which kind, and which verb undoes it), or no such message — because `HideMessage` requires
`hidden=0` and cannot tell the first two apart on its own.

`reveal` is restricted to `hidden=2` and refuses anything else, because clearing `hidden` directly
on a punished row would bypass the recompute above. It prints an eighteen-rune PREVIEW rather than
the body: that body may be a real recovery phrase, and an operator's terminal and shell history are
not where it belongs. A message that merely CONTAINS a phrase without reporting it is punished as
scam and hidden=1 instead, where `unban` is the right verb — measured, because the first live run
assumed otherwise.

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

**A CITATION MUST NOT OUTLIVE THE MESSAGE IT CITES,** and it did. Note that the third refusal
above says "in force" — so a revoked or expired consequence's message IS deletable, while
infractions are never pruned at all. `messages.id` is a bare INTEGER PRIMARY KEY, which is a
rowid, and SQLite hands out `max(rowid)+1` with no high-water mark. Empty the table and ids
restart at 1, so a surviving citation points at a future stranger's message.

Both consumers of `evidence_id` were then wrong about that message, and neither said anything:

    revoked citation    sqlAwaitingReview's NOT EXISTS matched the stale row, so a freshly
                        flagged message left the review queue and reached no human
    expired citation    worse — an unrelated revocation for the same address HID the new
                        message, because Revoke's recompute matches evidence_id and an
                        expired kick is not a revoked one. Two of three messages visible,
                        and nothing to tell the author why

Prune clears the citation when it deletes the row, which is what a reference to a deleted row
should do, and is written as "not in messages" so it repairs anything an earlier prune left
behind. **The appeal record is the `evidence` and `detail` copies**, which is what they were
taken for; the id was only a link to a row nobody can read. An existing fixture asserted the
opposite — "the dangling evidence_id is fine" — and its read half still holds while its premise
does not.

Not fixed by preventing reuse: SQLite cannot add `AUTOINCREMENT` without rebuilding the table,
and §9 promises migrations are column additions with defaults only.

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

**`--secret-file` should be outside the data directory — and `kourtchat` now says so when it is
not.** Two configurations warn at startup, beside the UNMODERATED line and for the same reason: a
defence that is not operating should say so where an operator is looking, not only in a document.

    no --secret-file        the key is a row IN the database; one copy of that file carries the
                            address hashes and the key that reverses them
    key beside the database  a backup or rsync of one directory carries both

A key in another directory prints nothing, which is the half worth testing — a warning that fires
on a correct setup is one an operator learns to skip. It warns rather than refuses, because
refusing would break every deployment running this way today.

`internal/chat/clientip.go` used to say the key was "required" to live outside the data directory.
Nothing required it and nothing checked it; the verb is "belongs" now, and the startup warning is
what lets a recommendation be one.

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

**`ban` and `kick` with `-msg` echo the message they acted on**, which is how you notice you typed
the wrong id:

    kicked address c21475603635 for 1h0m0s [consequence 2]
    for message 2: "is the settle window still open on claim 7"
    reverse it early with: kourtchatctl unban 2

That is a bystander, not a lure, and the line above the reversal instruction is the whole point.
It cannot stop the wrong action — the tool is non-interactive so it stays scriptable — but a wrong
action you can see is a wrong action you undo in the next command. A hash-based ban prints no such
line, because it cited nothing. Message ids are also rowids that restart after a prune (§7), so an
id read from `review` a while ago can resolve to a different message; the echo covers that too,
though a typo is the likelier way in.

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

**And for a while only one of them COULD be undone in principle.** That sentence was true about
the data and false about the tool: there was no `Unfreeze` in the store and no command, so
`freeze dev/oren` for `dev/orem` withdrew a live court for good — 410 to every reader, posts
refused, moderation stopped, recovery only by hand-editing SQLite. "Latches", above, means sticky
rather than re-derived from the chain; it was never a claim that a person could not reverse it.

    bin/kourtchatctl -db chat.db unfreeze dev/orem

Freeze reaches three places and took two passes to get there, so the lift had to give back all
three — the read, the write, and MODERATION. A fix restoring the obvious two leaves a court
serving traffic that nothing is scanning, which is another row for the table above rather than a
repair, and dropping the new clause from `sqlNotFrozen` alone is caught by name.

The row is **stamped, not deleted**, for the same reason `Revoke` keeps an infraction: somebody
arriving later and asking what happened to this court needs to see that it was frozen at all, and
when, and that a person lifted it. `freeze` also had to stop being `INSERT OR IGNORE` — a court
frozen, lifted, then frozen again would have hit the surviving row and been ignored while the tool
printed "its history is no longer served" over a live court, which is precisely the failure named
two paragraphs up, reintroduced by the fix.

`unfreeze` refuses when nothing was frozen, because a typo in this argument is as likely as one in
`freeze` and a cheerful "back in service" over a court that never left it is the same lie one verb
along. It also says what it cannot know: if the content was withheld for a purge, check that it
should be public again before telling anyone.

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

**A wrong `--db` used to report itself as "out of memory".** Three different filesystem problems
— a missing parent directory, a path that is a directory, a read-only parent — all produced the
same driver message, `unable to open database file: out of memory (14)`. Code 14 is
SQLITE_CANTOPEN and "out of memory" is code 7's text, so the wrong string was paired with the
code, and it sends a reader to look at RAM. It cost two wrong diagnoses in this repo before
anybody checked what the message meant.

The cause is established from the filesystem now rather than by matching the driver's string, so
it cannot drift with a driver version, and the actionable half leads:

    schema: the directory /var/lib/kourt does not exist; create it or correct --db
            (driver said: unable to open database file: out of memory (14))

A path with nothing wrong with it adds nothing, so a real SQLite error is never buried under a
filesystem theory that does not apply.

**Upgrades.** `kourtchat` migrates the database when it opens it, and migrations are
column additions with defaults only, so an older binary reading a newer database is fine
— every query names its columns. Back up first anyway, and start one binary before the
others so a migration failure is one log line rather than three.

That last sentence is about LEGIBILITY, not safety, and it is worth saying which: starting
both binaries in the same second against a database that does not exist yet was measured
and is fine — both come up, the schema is complete and `PRAGMA integrity_check` returns
`ok`. Ordering two systemd units takes extra configuration, and it buys a clearer log
rather than a correct database.

**TWO SCANNERS ARE SAFE, and you will have two eventually** — a restart overlap, or an
operator starting a second instance to work through a backlog. Measured with two
`--enforce` daemons and three lures against one database: every message scanned once,
exactly one consequence each, the clean message untouched, a bystander still posting, and
no busy or lock errors in either log. The infraction ids came out interleaved across the
two processes, which is what shows they genuinely raced rather than one doing the work.

What makes it safe is `infractions_once` — UNIQUE(evidence_id, kind) on unrevoked rows —
plus `Consequence` turning that violation into a no-op rather than an error. A scanner
treats an error as a failure and retries, so a duplicate has to look like
success-with-nothing-done or the retry loop never ends. `Claim` marks rows and reclaims
anything a dead daemon left held after five minutes, so the second daemon picks up work
rather than colliding over it.

It is still not something to run on purpose: two daemons do the same Ollama work twice for
no extra throughput, since the model is the bottleneck and both queue against the same one.

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

Re-running the method later turned up a TENTH of the same shape that is **not** a failure, which
is worth separating from the nine above rather than filed with them:

    revoked_at    ignored by the review queue too      an upheld appeal is never re-reviewed

Three shared predicates now have exactly one definition each — `sqlAwaitingReview`,
`sqlNotFrozen` and `sqlInForce` — and two exceptions are deliberate rather than missed. The
throttle ignores `hidden` and `frozen` on purpose, because it asks what an address SENT and
hiding a message afterwards does not un-send it.

The other is the tenth row above, which is the first of these that is arguably RIGHT.
`sqlAwaitingReview` excludes any message an infraction cites and does not ask whether that
infraction survives, so an upheld appeal puts the message back on screen and into neither
`review` nor `review -all`. Measured, and left alone: the operator engaged with that exact
consequence and reversed it, and there is no bulk revoke — `unban` takes one id — so every
revocation is one deliberate act about one message. **Adding a bulk reversal would end that
argument**, because five hundred messages would return to view with nobody having read any of
them, and the missing clause would become the bug it currently resembles.

What is genuinely uneven is what the two exits leave behind. `dismiss` marks a message reviewed
and says "see it again with: `kourtchatctl review -all`", and it does come back there. A revoke
removes it from both views with no such affordance. **`unban` is for the consequence; `dismiss`
is for the record** — reach for the second when the point is that somebody looked.

One more of the same shape crossed a language boundary rather than a function: the panel
repeats the server's length limits so a user hears "too long" before a round trip, which
made them two definitions in two languages that no build could compare. `web/chat.js` declares
them once and a Go test reads that file and checks it against the constants, from the side that
enforces them — prevention rather than a bug found, which is the first time this class has

**And the operator tool holds THREE copies of its own flags** — the `FlagSet` that defines them,
`takesValue` (which `split` needs before parsing, so it cannot ask the FlagSet), and the help text.
The third had drifted furthest, measured by comparing each verb's usage entry against its FlagSet:

    kick     showed only -for, omitting -msg, -net AND -why
    ban      omitted -msg
    unban    omitted -by
    list, review, prune   each omitted -n
    revoke   an accepted alias for unban, mentioned nowhere

`kick` is the one that mattered. `-msg` is the path `review`'s own output tells an operator to
take, and `-net` widens a consequence to a whole /24 or /48 — the only consequence that reaches
more than one address, and the help did not say the verb could do it. **A flag nobody can discover
is a flag nobody uses**, and here that means reaching for a broader instrument than the situation
needed. Both copies now have a guard that reads the FlagSets out of the source; the help one also
refuses a flag shown but not accepted, which is worse than an omission because somebody will type
it.

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

**THE BROWSER HALF WAS NOT BEING RUN, which is how a wrong assertion survived two commits.**
`web/tests/browser/run.js` lists `CHECKS = ["banner_layout.js"]`, so the four chat harnesses beside
it — 149 assertions — executed only when somebody typed their names. `make web-visual` reported a
clean pass the whole time.

    chat_page.js        the panel ON the real court page: esc(), cleanCfg, the optional load
    chat_render.js      the panel in isolation, at 380px and 760px, and the composer's limits
    chat_live.js        against a running kourtchat: post, poll, refusal, a closed court
    chat_moderation.js  against a real gemma3:4b, with OLLAMA_LIVE=1

The cost was already banked when this was noticed. `chat_render.js` asserted that the moniker
input's `maxlength` equalled the server's limit, and that stopped being true when the limit moved
to counting LETTERS and the attribute became a looser paste bound — `maxlength` counts UTF-16
units, so 24 stopped an eighteen-letter voweled Arabic name from being typed at all. The Go-side
drift test was updated for that change; this one was not, and could not fail. It now checks that
the attribute is looser AND bounded, and calls `chatValidate` in the page for the half that
actually enforces the limit.

`run.js` is uncommitted and belongs to the other session, so `chat_all.js` wraps the four rather
than editing it: one entry in `CHECKS` later picks all of them up. Until that lands, the browser
half runs with `node web/tests/browser/chat_all.js`, and `chat_moderation.js` is where the
bystander rule is checked end to end in a browser — not punished, shown no notice, still sees
their own message, still able to post.

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
`kourtchatctl`. Forty-six checks — the runner's own count, not a hand tally, because the
number this sentence used to give was thirty-four and had been overtaken. What they cover is
the set of things that are only true in a browser: CORS and the CSRF rule (header behaviour, and a browser's
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

**BOTH KINDS OF EVIDENCE ARE GATED OFF BY DEFAULT, and that is worth knowing before trusting a
green run.** Nine `TestLive*` fixtures in `internal/scan` need `OLLAMA_LIVE=1`, and nothing in the
Makefile, the scripts or CI sets it — so `go test ./internal/scan/` prints `ok` while every one of
them skips, and `go test` shows a skip only under `-v`. The browser harnesses were worse: they were
not in the runner's `CHECKS` at all, so `make web-visual` reported a clean pass over one file out
of five, and `chat_render.js` was asserting something false for two commits before anybody ran it.

The gating itself is right — a 3GB model and a headless Chrome do not belong in every `make check`
— so the answer is not to ungate them but to run them deliberately and say when:

    OLLAMA_LIVE=1 go test ./internal/scan/ -run TestLive -timeout 1800s
    node web/tests/browser/chat_all.js          # add OLLAMA_LIVE=1 for chat_moderation.js

Measured together on one machine: all nine live fixtures pass in 225s, and the four browser
harnesses in 149 checks plus the model-backed one. **A suite that cannot fail is not evidence**, and
the only way to know which of these two states a gated fixture is in is to run it.
