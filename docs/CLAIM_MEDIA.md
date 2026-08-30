# CLAIM_MEDIA — evidence a claim carries, and proof it hasn't changed

> **v0.9 — built, run, and driven end to end in a browser. Supersedes v0.1; two owner rulings settled; griefing pass applied; §8 rewritten from the code after the plan and the build drifted apart.** A claim may carry up to **seven**
> media items. The chain stores a **sha256 and a list of mirrors**, never the
> bytes. kourt.xyz keeps its own copy of every image at an address derived from
> that hash, so no third party can take a claim's evidence away.
>
> v0.1 stored a bare imgur URL. It was withdrawn for the reason the owner gave:
> **imgur removes exactly the controversial images**, and a court whose evidence a
> third party can delete is not a court of record. v0.1 had a second hole it never
> saw — a URL's contents can be swapped after filing, so the author could reframe
> the claim without touching the chain, which is precisely what the body's
> append-only rule exists to prevent.
>
> Both are answered by the same move: **put the hash on the chain and let the
> hosting be replaceable.** Integrity becomes arithmetic instead of trust, and
> imgur drops from a dependency to one CDN among several.
>
> An earlier design, `r/img` — bytes on-chain behind an AI approval oracle — is
> recorded in §11 as the road not taken.
>
> ---
>
> **STATUS.** The header above is the design record and is kept as written; this
> is where the code actually is.
>
> | piece | state |
> |---|---|
> | realm: storage, validator, `OpenClaimPM`, `ClaimMedia`, `PurgeClaimMedia` | built |
> | realm: claim-page render, archive-first, numbered exhibits | built |
> | realm: `ClaimMediaPage`, one read for a map's worth | built |
> | archive: store, upload, serve, promotion, sweeper, backfill | built |
> | archive: mounted in kourtchat, `/m` routed, CSP and deploy updated | built |
> | overlay: rules mirrored, intake, composer, panel, placement | built |
> | overlay: map card strip, node badges, lightbox with verification | built |
> | archive: the classifier — queue, auto-block, human undo | built |
> | archive: operator surface — queue, block, unblock, destroy | built |
> | archive: health, and heartbeats that fail separately | built |
> | archive: a vision backend for it (Ollama) | built |
> | drafts in `localStorage` (§2.5) | built |
> | video as a second tier (§7) | built |
>
> **That hole is closed.** `internal/archive/browser_test.go` stands up the real
> archive and the real page on one TLS origin and drives the real composer with
> a real 3000x2000 photograph: `createImageBitmap` → `mediaFitWithin` → canvas →
> `toBlob("image/webp")` → the encode ladder → `mediaDigest` → `POST /m` → the
> archive stores it → `GET /m/<sha256>` → `mediaVerify` answers `matches`. It
> came down to 1600x1067 and 206,858 bytes with the aspect held to four decimal
> places.
>
> Its first run found two bugs that between them made this whole design inert,
> and both had been invisible to every other harness — see §9 rows 14 and 15.
>
> The chain-side seam is exercised end to end too —
> `gnoland/testdata/kourtv2_media.txtar` files a claim carrying evidence against
> a real node and asks it the questions the page asks.
>
> So both halves are now driven against something real, from opposite ends: a
> node for the chain seam, a browser and a live archive for the client one.
>
> **The join between them is covered by transitivity, and the equalities that
> carry it are now checked.** No test files a claim from a browser and reads it
> back off a chain — that needs a node and a browser in one test, and the
> broadcast itself goes through a wallet no harness can drive. What stands in for
> it is a chain of pinned equalities: `media_test.js` pins the line web/media.js
> emits, `media_test.gno` pins that the realm's parser takes that exact line, and
> `kourtv2_media.txtar` files it against a real node and asks the questions the
> page asks. `check-media-hosts` compares all five holders of that line, so the
> chain cannot come apart quietly — which it could until row 31, because the
> txtar held its own hand-typed copy.
>
> What remains genuinely unexercised is narrow and worth naming exactly: the
> signature itself. Everything either side of it is driven against something
> real.

---

## 1. The model on one page

Per media item, the chain holds:

| field | why |
|---|---|
| `sha256` | the commitment: what was filed |
| `mime`, `w`, `h`, `bytes` | render without layout shift; bound what a mirror may send |
| `caption` | the exhibit label, and the alt text |
| `mirrors[]` | where to look; order is preference, not authority |

The chain holds **no bytes**. A 100 KB image would lock ~10 GNOT of storage
deposit at 100 ugnot/byte, and — decisively — on a public chain upload *is*
publication, so an "approve before it renders" gate would still put the bytes in
front of anyone with an RPC endpoint. A hash is ~150 bytes and gives the property
that actually matters.

**The archive address is derived, not stored.** kourt.xyz always serves at
`https://kourt.xyz/m/<sha256>`, so the client can try it as an implicit final
mirror even for claims that never listed it. Zero on-chain cost, automatic
fallback.

**What this buys, plainly:** if imgur deletes the image, anyone can re-serve the
same bytes and the hash proves they are the same bytes. If someone swaps the
bytes, every viewer sees that they no longer match what was filed. Losing the
pixels never loses the proof.

---

## 2. The composer — where nearly all the work is

**There is no composer today.** Every action on kourt.xyz is one of three things
`btn()` renders: a link into gnoweb's `$help` form with arguments prefilled, a
`gnokey` command behind the CLI toggle, or a one-click **✍ Sign** through Adena.
None of them can accept a file. Media therefore requires the page's first real
input surface, and the quality of that surface *is* the quality of this feature.

The governing rule: **a person filing evidence should never meet a technical
concept.** Its corollary is that a condition which dooms every exhibit is said
ONCE, up front, rather than once per exhibit after each has failed — the
composer checks the deployment (an http page cannot produce an https mirror, so
nothing it copies is filable) as soon as there is anything at stake. Not "sha256", not "mirror", not "256 KB", not "unsupported format".
Every one of those is the machine's problem and every one has a fix that can be
applied silently.

### 2.1 Getting a file in

Three ways, all first-class:

- **Paste.** ⌘V with a screenshot on the clipboard. This is the single most
  important path — screenshots are the dominant evidence type for a claim of
  fact, and every competing product makes people save-then-upload. Paste anywhere
  in the composer, not only in a drop zone.
- **Drag and drop**, with the whole composer as the target and a visible state
  when a drag enters the window.
- **Pick.** ⚠︎ **Not** with `capture="environment"`, which this section asked for
  and the code deliberately omits. `capture` is not a hint that a camera is
  *available* — on iOS and Android it sends the picker straight to the camera and
  removes the photo library, so the commonest evidence there is, a screenshot
  already saved on the phone, becomes unreachable. Without the attribute both
  platforms offer a chooser with the camera in it, which is the behaviour this
  line wanted. `multiple` is set, so seven exhibits are one trip.

A fourth, **paste a URL**: fetch it, hash it, adopt it as an item with the
original URL kept as a mirror. When CORS blocks the fetch — and it often will —
say so in one sentence with the fix ("this host won't let us read the file;
download it and drop it here") rather than an error code.

⚠︎ **This is not a nicety, and for a while it was not built.** A pasted image
link was filed the way a video link is — kept, marked "the court keeps no copy"
— and the chain does not accept that: `mediaItemFault`, on both sides, requires
64 hex characters of `sha256` for every image and lets only a video go without
one. So the row sat in the composer looking accepted while `composer.fault()`
said *"this image has no fingerprint yet"* and the claim could not be signed at
all.

So the fetch is what makes this path work, and the refusal ends the exhibit
rather than filing an unfilable one: **broken**, with the action that works.
`mediaFileable` excludes broken, so it blocks nothing else in the claim. When
the host does allow it the link becomes a full exhibit — fingerprinted, copied,
checkable — with the pasted address kept behind the archive's as provenance.

### 2.2 Never say "too big"

On accept, the browser downscales to a max edge of 1600px and re-encodes to WebP,
targeting under 256 KB, via canvas. The user is told nothing. A 12 MP phone photo
becomes a 90 KB WebP and the size cap they never learned about is never violated.

Only if a file survives that and is still oversized — a pathological PNG, an
unrecognised type — does a message appear, and it names the file and the reason.

The 256 KB target also bounds what a hostile mirror can stream at a viewer, and
keeps the file a single block if anyone later pins it to IPFS. That
compatibility is free, not designed for; **do not build on CIDs** — a CID is not
a plain sha256, and above one block it covers a DAG rather than the content.

### 2.3 The item's life, visible the whole way

An item appears **the instant it is dropped**, thumbnailed from a local object
URL. Nothing about the network is allowed to delay that.

```
dropped → shrinking → hashing → uploading → mirrored ✓
                                     ↓
                                  failed ⟳ retry
```

Each state is a caption under the thumbnail in plain words ("making a copy on
kourt.xyz…"). A failed upload does **not** block filing, and what that means is exact: an
exhibit that still has a link is filed without a copy, and one that has none
— a dropped file, whose only mirror IS the copy — is shown broken and left out,
so the claim itself is never held up. The **⟳ is real**: the prepared bytes stay
in memory, so `retry` can try the copy again without asking for the file back.
That matters most for a pasted screenshot, where the clipboard is often the only
other copy. Losing an upload must never lose a draft.

### 2.4 Order, captions, removal

- **Order matters** and the UI must say why: the first item is what the map node
  shows — the row says so, in as many words, on exhibit one.
- **Reordering is ↑ / ↓ buttons, and there is no drag.** This section asked for
  drag "with keyboard equivalents", which puts the accessible path second and
  the pointer path first. The buttons are one control that works identically
  with a mouse, a finger and a keyboard, in a list that is at most seven rows
  long; drag would add a second mechanism, a touch story of its own, and a
  well-known set of screen-reader problems, to reorder a list that short. The
  divergence is deliberate — recorded here so it does not read as unbuilt.
- **Caption** per item, optional, one line, ~120 characters. It is the exhibit
  label *and* the alt text, which is why it is worth the extra untrusted string:
  "Exhibit A — the email header" is better evidence and better accessibility than
  a generated "image 1 of 3". Sanitised with `sanitize.InlineText`, which is the
  right tool for a caption exactly as it is the wrong tool for a URL.
- **Remove** with an × and an undo, not a confirm dialog.

⚠︎ **A caption cannot be fixed after filing.** Owner ruling §10.6 makes captions
claim text, which means they inherit the body's append-only rule — there is no
editor, not even inside the polish window where a *title* can still be corrected.
A typo is permanent, and the only remedy is to close the claim and re-file it.

The composer therefore owes the author a real last look: a review step before
signing that shows each caption as it will appear, at the size it will appear,
with the append-only consequence stated in one sentence. This is the one place in
the composer where friction is correct — everywhere else the job is to remove it.

### 2.5 Nothing is lost

The composer autosaves to `localStorage` — title, body, captions, order, hashes,
mirrors. A closed tab, a rejected signature, a failed broadcast: reopening
restores the draft with uploads intact, since the bytes are already archived and
addressed by hash.

After signing, the draft clears only on a confirmed broadcast.

### 2.6 Preserve the three affordances

kourt.xyz's contract is that every action is available three ways. The composer
must keep it:

- **✍ Sign** — the primary path, arguments built from composer state.
- **CLI** — the `gnokey maketx` command, media argument included verbatim.
- **gnoweb `$help` link** — the one with a length limit, though **less of a
  problem than v0.2 guessed.** Measured: seven exhibits with two mirrors each
  encode to ~2.8 KB, which every browser and proxy accepts. The worst case the
  validator permits — seven exhibits with four 300-character mirrors — encodes to
  ~10.3 KB, and nginx's default header buffer is 8 KB, so *that* request is
  refused before gnoweb ever sees it.

  So the link is offered normally and withdrawn only when it would actually
  overflow, at a budget well under 8 KB so the cutoff is reached by a check that
  can explain itself rather than by a proxy returning 414 to somebody who has
  just written a claim. The refusal names the two paths that still carry the
  whole claim — Adena and the command line — because "this does not work"
  without "this does" is the shape of every unhelpful error.

  v0.2 said this affordance simply could not survive media and should be
  disabled for every media-bearing claim. That was a guess, and it would have
  removed a working path for the sake of a rare one.

### 2.7 Cost, shown before signing

The composer shows the storage-deposit delta before the signature. An item is
about 200 bytes typically and up to ~1.4 KB at the cap of four 300-character
mirrors, so a full seven-item claim ranges from roughly 1.4 KB to 9.7 KB — a
fifth of a GNOT at worst, refundable. Small either way, but a court that
surprises people with costs is a court people stop using, and the figure shown
must be the real one rather than the typical one.

---

## 3. The archive

A small service, and the page's first server-side dependency:

- `POST /m` — accepts bytes, verifies its own sha256, **stages** them, returns the
  digest.
- `GET /m/<sha256>` — serves with the stored mime, long-lived immutable caching
  (content-addressed URLs can never go stale), CORS open so any client can verify.
- A **backfill worker** walks claim media, fetches anything not yet held, verifies
  the hash, and archives it. This is what closes the loop for claims filed
  through the CLI or gnoweb, which never touched the composer.

### 3.1 Griefing: an open upload endpoint is a free file host

⚠︎ **The first draft of this section was an unauthenticated, unmetered,
anonymous place to put arbitrary bytes on someone else's disk forever.** Nothing
tied an upload to a claim, so nothing stopped a script uploading terabytes of
unrelated data — or using kourt.xyz as free hosting for content that has no
connection to any court.

**Staging with a TTL fixes it, and costs the composer nothing.** An upload lands
in a staging area with a short life (an hour is ample — the composer uploads
seconds before signing). Bytes are promoted to permanent only when an on-chain
claim references their hash. Anything never referenced expires and is swept.

This ties archive cost directly to on-chain commitment, which is the only thing
an attacker cannot fake and cannot get for free: to keep a byte, they must file a
claim, and filing costs a deposit the court already charges.

It also fails in the right direction for the honest user. A draft abandoned
mid-compose simply expires. A signature rejected and retried an hour later
re-uploads, which the composer already handles as a failed-mirror retry (§2.3).

Belt and braces on top, none of it load-bearing: per-address and per-IP rate
limits, a max staged bytes per address, and the classifier from §3.2 running at
promotion rather than at upload — there is no point classifying bytes that are
about to expire.

⚠︎ **That last clause had a hole in it, and the TTL did not cover it.** Classify
at promotion is right about which bytes are worth the compute. It says nothing
about which bytes are worth PUBLISHING, and the read path served anything that
was not blocked — so a staged upload was fetchable by anyone holding its URL,
with `Access-Control-Allow-Origin: *` and a year of `immutable` caching, while
the classifier's queue (`WHERE promoted = 1`) structurally never looked at it.

`POST /m` was therefore a way to publish an arbitrary picture on this court's own
domain, unreviewed, and hand the address out. The TTL bounds how long **we** keep
those bytes; it does not bound how long a cache serves them, and it never
bounded who could read them in the meantime.

**The public read now serves claimed bytes only** (`GetServable`). Nothing
legitimate is lost: the composer previews from a local object URL and never
fetches its own upload, a restored draft draws no thumbnail at all, and by the
time any reader has a claim to look at, `/m/claimed` or `Backfill` has promoted
it. Before that, the only party who knows the address is whoever just uploaded
it. A staged blob, a blocked one and an absent one all answer 404, for the same
reason a takedown does not announce itself.

The rule to keep, since it is the one that was missing: **the archive publishes
what the chain has committed to, and nothing else.**

**The archive is a mirror, never an authority.** It cannot forge: the hash is on
chain and every client checks. The single question it must answer honestly is
availability.

### 3.2 Moderation lives here

Its second job is where **content moderation finally belongs**. The archive is
the one place that has both the bytes and the legal obligation, so the classifier
runs here — refusing to *serve*, never rewriting the chain. A refused image is
still filed, still hashed, still verifiable from another mirror. That separation
is what `r/img` got wrong: it fused a censorship gate to a persistence mechanism,
so every question about one became a question about the other.

**The model sorts a queue for a person; it is not a gate.** A verdict removes an
image by itself only at `illegal` and above 0.90 confidence, and every automatic
refusal has a human undo. A model that times out, answers nonsense, or is not
running leaves the image *serving* and records nothing, so the next pass tries
again — failing closed would mean an outage silently withdrawing every exhibit
in every court, which is worse than the thing it guards against. `internal/scan`
settled the same question for text: an unreadable verdict carries no more weight
than a clean one.

The model is asked what an image **is** — clean, explicit, violent, illegal — and
has no vocabulary for what should happen to it, so an image containing text that
argues for an outcome cannot reach the part that decides. Its prose is stored for
a person to read and never parsed for instructions; control characters are
stripped, because that prose is printed to a terminal.

### 3.3 What an operator actually does

**The origin is written once.** The queue groups by `filed_court` so a filing's
seven exhibits read as one incident, which means that field is what an operator
decides about — and a hash is public, so any stranger can file a claim quoting
someone else's image. It is therefore the FIRST claim to reference the bytes,
not the last. A later claim is a re-use; nothing is lost by saying so, because
blocking is by hash and acting on the origin still removes the bytes everywhere
they are quoted.

`kourtchatctl` carries the whole surface, beside the `review`/`dismiss` this
repository already had for chat:

| command | what it does |
|---|---|
| `images` | the queue: what was flagged, how sure, and whether it is already off the site |
| `block SHA256 -why S` | stop serving something the model let through |
| `unblock SHA256` | overrule the model and serve it again |
| `forget SHA256 -apply` | **destroy the bytes**; dry run by default |

**Blocking hides; forgetting destroys.** Both exist because they answer different
questions, and the second is the only one that answers `illegal`. Neither
unfiles anything: the chain still holds the hash, the claim still records that
evidence was filed, and another mirror may still serve it. Removing the court's
pointer is `PurgeClaimMedia`, on chain, by the global DAO — and archive-side
refusal and chain-side purge stay independent on purpose, so either alone
suffices and neither can rewrite what was filed.

**The queue groups by the filing that produced it.** A claim carries up to seven
exhibits, so a flat worst-first list reads one filing's decoys as seven separate
incidents — which is how a flood buries the entry that matters. `internal/chat`
reached the same conclusion about its own review queue and states the rule: the
answer to flooding is a *view* that resists it, not a new punishment. The deposit
already bounds this here, since seven decoys cost a claim; that makes it a
smaller problem, not a reason for the queue to be unreadable when somebody pays.

### 3.4 Knowing it still works

`GET /m/health` answers `{"ok":true}` publicly and the numbers only under
`-health-detail` — the same flag the chat's own numbers use. `pending_review` is
why: published, it is a live count of what the classifier flagged, so somebody
probing what the model blocks could upload, poll, and read the answer off the
counter without ever filing a claim.

Under that flag it carries three heartbeats, and they are separate because they
fail separately:

- `swept_at` — the TTL sweep, which is what stops this being free hosting. It is
  silent when it finds nothing, which is almost always, so without a stamp
  "swept and found nothing" and "the goroutine died after boot" look identical.
- `backfilled_at` — a completed backfill pass. Stamped only on a complete one:
  stamping the failures would make a backfill that never works look like one
  that always does.
- `chain_seen_at` — when the node last **answered**. Separate because a pass with
  nothing staged completes without asking anything, so a fresh `backfilled_at`
  says the loop is alive and nothing about whether the chain is reachable. That
  was observed on a live service showing a healthy backfill against an
  unreachable node.

---

## 4. Verification, and where it can happen

**And where it is announced.** Both surfaces now say what they can do about it,
and they say different things because they can do different things. gnoweb
states that a fingerprint exists and that this page cannot check it, naming the
one that can. kourt.xyz states that a fingerprint exists and offers to check it,
because the lightbox does — and the affordance itself says so, for a reader
going by aria-label alone. Neither is offered for an exhibit with no fingerprint
behind it: a video, or a purged slot whose hash was destroyed.

The client fetches the bytes, hashes with `crypto.subtle.digest`, compares.

⚠︎ **Only kourt.xyz can do this.** gnoweb's CSP is
`connect-src 'self' <remote>/abci_query` — it cannot `fetch()` third-party bytes
at all, so it cannot verify anything. That is not a defect to route around; it is
a division of labour worth leaning into. gnoweb renders the image plainly;
kourt.xyz is the surface that can *attest* to it. The overlay having a capability
the raw realm view lacks is already why it exists.

Three states, each a plain sentence rather than a badge to decode:

| state | shown |
|---|---|
| hash matches | quiet ✓ "matches what was filed" |
| hash differs | **loud.** The image is replaced, not annotated: "this no longer matches what was filed" |
| no mirror answers | grey placeholder at the stored dimensions: "not currently available" |

The middle state is the whole feature. It must be impossible to miss and must
never be a small icon in a corner.

⚠︎ **Try the kourt.xyz archive first, third-party mirrors second** — the reverse
of what "order is preference" suggests. See §4.1: fetching a listed mirror is an
action every viewer performs on the filer's instruction, and the filer chooses
the target.

### 4.1 Griefing: the mirror list is an amplifier

A claim's mirrors are URLs an attacker supplies and every viewer's browser
fetches. A popular claim pointed at a victim's endpoint turns the map into a
modest DDoS, and the requests carry viewers' IPs to a host the attacker picked.

Three mitigations, none of which cost usability:

- **Archive first.** kourt.xyz holds a copy of everything (§3), so the normal
  fetch goes to a host we operate and cache. A third-party mirror is touched only
  when the archive misses, which should be rare and is itself a signal.
- **`referrerpolicy="no-referrer"`** so the target learns nothing about which
  claim sent the traffic.
- **Abort past `bytes`.** The declared length is a contract; a mirror streaming
  more than it should is cut off rather than trusted, which also caps what a
  hostile mirror can push at a viewer.

Node thumbnails never touch a third-party mirror at all — archive or nothing.
Fifty nodes fanning out to attacker-chosen hosts on a single map draw is the
worst version of this, and it is also the one with the least to gain.

---

## 5. The realm

**Storage.** `media []mediaItem` on `claimState`; `maxClaimMediaCount = 7`,
`maxMirrorsPerItem = 4`, `maxCaptionLen = 120`. An empty slice means no media —
unlike `provisional`, whose `int8` zero is a real side and needed an explicit
`-1`, absence and the zero value say the same thing here.

**Entrypoint** `OpenClaimPM(cur, courtSlug, title, body, media string)`.
Additive, for the reason `OpenClaimP` states about itself: `OpenClaim` is called
by every committed filetest, txtar and scenario in the tree, and widening it
breaks all of them. No `OpenClaimSeededPM`, following the existing rule that
writing on another author's behalf is a different act from filing.

**Wire format is single-line JSON**, both in and out. The read path is what
forces it: the map's `parseTyped` splits raw qeval output on newlines *before*
matching a typed value, so any newline in the payload parses as garbage. JSON on
one line carries captions with spaces, several mirrors, dimensions and the
tombstone without inventing a separator scheme, and `ClaimMedia` returning it
costs the client one `JSON.parse`.

Captions therefore reject raw newlines at validation — which they should anyway.

**Validator** `mediaItemFault(...) string`, reached through
`parseMediaFault`, with `parseMediaArg` panicking on a non-empty fault. The split is `siteDomainFault`'s and for its reason: the render
path must ask the same question without being able to abort a page. **A bad
stored value costs the item, never the claim underneath it.**

- `sha256` is exactly 64 lowercase hex characters
- every mirror is `https://`, host on the allowlist, length ≤ 300
- ⚠︎ mirror charset excludes whitespace, `\`, `"`, `'`, `<`, `>`, `(`, `)`,
  `` ` ``, `,`, `|` and controls. The last two are the wire separators: a mirror
  carrying one would turn one field into two, or one item into two. **The parentheses are not stylistic**: the URL is emitted into a
  markdown destination `![alt](url)`, and a `)` inside closes it early and spills
  the remainder into the page. Same class as the `kourt\.xyz` escape that broke
  the site link — a string put through the wrong text machinery. Validate
  fail-closed, emit raw, and never reach for `sanitize.InlineText` on a URL.
- `w`, `h`, `bytes` positive and within bounds
- the host is whatever precedes the first `/`, `?` or `#` — so a fragment cannot
  smuggle a trusted-looking name past the check, and a query following the host
  directly is not read as part of it
- **no file-extension rule.** One was considered and refused: the archive serves
  at `/m/<sha256>`, which has no extension, so requiring one would reject the
  copy kourt.xyz keeps of every image. The declared `mime` is author-supplied
  and equally unauthoritative; a non-image in an `<img>` simply fails to load
- caption ≤ 120 chars, single line

**Host allowlist** mirrors gnoweb's `cspImgHost`, plus `kourt.xyz`. Drift is the
hazard: if gnoweb narrows its CSP, images silently break. Whether this is a
`const` or an admin parameter is open (§10).

⚠︎ **Re-validate on render, not only on write.** Write-time-only validation
grandfathers every URL stored under an older, wider allowlist, so removing a host
would fail to retract the images already pointing at it.

⚠︎ **Media does not go into the claim-opened event.** `openClaim` deliberately
emits "no user text beyond the title", and captions and URLs are user text.

### 5.1 What gnoweb's markdown must point at

⚠︎ **The destination is the ARCHIVE, not a listed mirror** —
`https://<siteDomain>/m/<sha256>`, derived, falling back to a listed mirror only
when no site is configured.

This follows from §4.1 and from what gnoweb cannot do. A markdown image has ONE
destination and no `onerror`, so there is no fallback chain on that surface:
whichever host is named is the host every reader's browser contacts. Naming a
filer-chosen URL would make every gnoweb claim page a small amplifier pointed
wherever the filer liked, at readers who cannot verify what comes back.

The cost is real and worth paying. If the archive lacks the bytes the image is
broken on gnoweb while kourt.xyz still finds it through a mirror — and a broken
image on the surface that cannot verify beats a working one that cannot be
trusted and discloses its readers.

⚠︎ **Number the images.** `PurgeClaimMedia` takes a zero-based `idx` and nothing
on any page shows which image is which, so a moderator taking down the third
exhibit would be counting positions in a JSON payload. The caption line carries
the position ("2 of 5") — which the alt text wants anyway — and the moderator
view shows the index it would pass.

**Neither is built yet:** `render.gno` does not touch media at all, so the field
is stored and unreachable on the page. That is the next realm-side step.

---

## 6. Moderation

`claimMediaVisible(c, cs)` mirrors `claimBodyVisible` — empty for a purged or
globally-redacted claim — and every read goes through it. `ClaimMedia` is gated
for the reason `ClaimBody`'s own comment gives: a raw accessor would defeat
purge, the legal-compliance power, with a single qeval.

`PurgeClaimMedia(cur, courtSlug, claimID, idx, categoryCode)` is moderator-only,
category-coded and court-logged, following the `PurgeClaim` family.

⚠︎ **Tombstone the slot; never remove it.** Compacting shifts every later index,
so a moderator working through seven items would have their second call land on
one they had already reviewed and kept. The JSON keeps the position with a
`purged` marker, and the client renders the gap honestly rather than silently
renumbering.

Chain-side purge stops it rendering. Archive-side refusal stops it serving. They
are independent on purpose: either alone is enough to take an image off kourt.xyz,
and neither can rewrite what was filed.

---

## 7. Video

Video items carry a URL and a caption, and **no hash** — a streaming host serves
no stable bytes to commit to. They must therefore be labelled as what they are:
*linked, not verified*. Presenting an unverifiable item with the same chrome as a
verified one would make the verification badge meaningless everywhere.

gnoweb has no `media-src` and no `frame-src`, so `<video>` and embeds fall back to
`default-src 'self'` and are blocked outright; gnoweb renders a video item as a
link ("video ↗") rather than a broken frame. kourt.xyz plays it and needs its own
`media-src` entry.

The archive does not mirror video in v1. Say so in the composer, in one line, at
the moment a video link is added — a person who believes their evidence is
preserved when it is not has been misled by the product.

---

## 8. Where a reader meets an exhibit

Three surfaces, all fed by `claimExhibits` except the node, and this section is
written from the code rather than from the plan — an earlier version of it
described a horizontal strip, an `object-fit:cover`, a circular clip and a
per-claim read, none of which is what got built.

- **Node** — first live item, clipped to a rounded square by a `clipPath` at a
  fixed `width`/`height`, so a filed image cannot influence the map's layout at
  all. `loading="lazy"`, `referrerpolicy="no-referrer"`, and a delegated `error`
  listener removes it: a broken glyph inside a 20px node is worse than no image,
  and the alt text has nowhere to go. (This section asserted that behaviour
  before it existed — there was no error handling anywhere in the page until
  archive-first started working and made a failed fetch the only outcome.) Nodes
  do **not** verify — fifty hashes on a map draw is not a trade worth making; and they draw
  **only** from the archive, never a mirror, because fifty nodes fanning out to
  filer-chosen hosts is fifty readers' addresses sent wherever the filer liked.
- **Claim page and map card** — the same vertical list from `claimExhibits`,
  each exhibit numbered `N of M`, directly under the body. The claim page went
  without this until late: `claimDetail` had always read `ClaimMedia` into
  `d.media` and only the card ever drew it, so evidence appeared on gnoweb and on
  a card you reach by opening the map and clicking the right node, and was
  invisible on the surface every link, share and search result points at.
- **A failure is reported, and nothing else is tried.** An exhibit whose bytes
  will not load loses its image and its zoom affordance and says "not currently
  available", keeping its number and caption so the others do not renumber. It
  does **not** fall back to a mirror, and that is the point: the archive refuses
  a BLOCKED blob, which from an `<img>` is indistinguishable from any other 404,
  so a fallback would re-publish the one image an operator destroyed — from the
  claim's own page, automatically, for every reader.
- **The box is reserved, but not on the filer's word.** `w`/`h` set an
  `aspect-ratio` so the page does not jump as each exhibit lands. They are also
  unverified filer input, and the realm bounds each to `maxMediaDim` without
  bounding the ratio: `mediaBoxRatio` therefore honours a ratio up to 8:1 and
  refuses anything past it, with `max-height:60vh` as a second bound on the image
  that actually arrives. See §9 row 12 for what that cost before it was there.
- **Lightbox** — gallery with next/prev, count, caption, and the verification
  line. Esc and backdrop close, focus trapped and restored, arrow keys navigate.

**The map's read is batched.** `ClaimMediaPage(court, fromID, count)` answers for
a run of claims in one qeval, with a missing claim as an empty hole rather than
an abort. Asking per claim would be a round trip per node before a fifty-claim
map could draw. Failure is silent and total: no thumbnails, same map.

**The offline demo carries its own bytes.** `web/README.md` promises a page that
runs from `file://` and makes no network calls in demo mode, and a real exhibit
resolves to the archive — so the sample would either break that promise or draw
a broken image. `DEMO_OVERLAY.media` holds one exhibit as a `data:` URI,
`mediaSrc` prefers inline bytes over the archive, and the restriction to `data:`
keeps the no-network property true by construction. `mediaVerify` answers
`sample` for anything carrying them: `fetch()` resolves a `data:` URI, so
without that it would hash its own embedded bytes, agree with its own digest,
and print "matches what was filed" about an archive that has never seen it.

---

## 9. What review caught

Recorded because each is easy to make again:

| # | Defect | Consequence |
|---|---|---|
| 1 | `)` allowed in a mirror URL | closes the markdown destination early; the rest spills into the page |
| 2 | tombstoned slots dropped from the payload | client and chain indices diverge; the next purge hits the wrong item |
| 3 | validation only at write time | a narrowed allowlist cannot retract images already stored |
| 4 | media in the claim-opened event | user text in a stream that deliberately carries none |
| 5 | newline-separated wire format | `parseTyped` splits on newlines first; payload parses as garbage |
| 6 | assuming gnoweb could verify | its CSP forbids the fetch outright |
| 7 | a `$help` link carrying seven items | multi-kilobyte query string, fails opaquely |
| 8 | `POST /m` open and unmetered | free anonymous file host on kourt.xyz's disk, forever |
| 9 | mirrors fetched in listed order | filer-chosen URLs fetched by every viewer: a DDoS amplifier that also leaks their IPs |
| 10 | the claim page never drew exhibits | the read was paid for and discarded; evidence visible on gnoweb and the map card, invisible on the page every link points at |
| 11 | every `.line` rule written as `.ticket .line` | the same helper renders as two grid tracks on the ballot and as one run-together word on the quality panel; three tests pinned the rule's text and passed |
| 12 | the declared `w`/`h` trusted for the reserved box | `1x20000` reserves 40,000px, seven per claim, unfixable until a global-DAO purge — a takedown built for illegal content spent on a layout attack |
| 13 | the demo sample carried no evidence | a feature that works but is absent from the only build most people run demonstrates itself as missing |
| 14 | the overlay's site domain read a config key nothing ever set | the archive-first rule off everywhere in the page: no map thumbnails at all, cards falling through to the filer's host, the composer refusing its own upload |
| 15 | `archiveBase()` returned `""`, leaving the uploaded mirror relative | `mediaMirrorFault` refuses a non-https link, so **no uploaded image could ever be filed** — only pasted ones |
| 16 | paste bound to the drop zone, a sibling of the title and body | the path §2.1 calls the most important one did nothing from where the cursor actually is — a unit test proved the listener existed, not that anything reached it |
| 17 | the public read served staged bytes | the classifier only ever queues promoted rows, so `POST /m` published unreviewed images on the court's own domain, CORS-open and cached past the sweep |
| 18 | the realm capped captions in BYTES, the client in code points | an ordinary 82-character Russian caption is 152 bytes: the composer accepted it and the transaction aborted saying "at most 120 characters" about a caption of 82 — every non-Latin script refused at half the stated limit |
| 19 | "no control characters" checked only the ASCII ones | Unicode direction overrides are three bytes each, so neither side ever saw one; U+202E in a caption makes the rendered exhibit label disagree with the label the chain stores, permanently |
| 20 | backfill returned on the first court it could not answer | the court hint is client-supplied, so `POST /m?court=does-not-exist` once an hour stopped promotion for everybody and the sweep then deleted the bytes honest claims referenced |
| 21 | the archive accepted 32-character court hints | the realm's slugs are at most 11, so the archive took names no court could have and asked a node about each one |
| 22 | a pasted image link was filed without a fingerprint | both validators require a sha256 for every image, so the exhibit looked accepted and `composer.fault()` quietly made the claim unsignable — "this image has no fingerprint yet", to someone with no way to make one |
| 23 | a dropped file whose copy failed kept a hash and no link | `MEDIA_STATES.failed` says "no copy yet — it will still be filed" while `mediaItemFault` refused the set with "this exhibit has no link yet"; the test that should have caught it asserted the mechanism and never `fault()` |
| 24 | `mediaUpload` adopted whatever address the archive returned | a malformed one became the exhibit's mirror, so a misconfigured service blocked every uploader with a message about a link they never supplied |
| 25 | an old draft restored a mirrorless exhibit as fileable | drafts live in `localStorage` indefinitely, so anyone whose upload failed once carried a permanently unsignable draft |
| 26 | the composer had no CSS at all — eighteen classes, zero rules | the page's first real input surface rendered as browser defaults, and `rowscope_layout` cannot see it because the composer does not mount in demo mode |
| 27 | `draw()` and `refresh()` both printed `composer.fault()` | the identical sentence in two `.medianote` paragraphs, with the other warnings glued onto the second copy |
| 28 | the page scrolled behind an open lightbox | somebody studying an exhibit scrolls, sees nothing move, and closes to find themselves somewhere else in a claim page thousands of pixels tall |
| 29 | a blob's origin was rewritten on every promotion | hashes are public, so anyone could file a claim quoting somebody else's image and take the row — pointing an operator's "decide about the source" action at a court of their choosing |
| 30 | the overlay never mentioned verification | the surface that CANNOT check an exhibit announced the promise, and the one that can said nothing — the only hint was an aria-label reading "full size" |
| 31 | the txtar held its own hand-typed copy of the wire format | the one holder that proves a REAL node accepts what the composer builds was the one nothing compared — a field-order change would have left it proving the old format, green |
| 32 | an http deployment could not file any upload, and was not told why | a mirror must be https on both sides, so a local overlay — a developer's first encounter — broke every exhibit in turn with a message naming the symptom |
| 33 | the composer had only ever been rendered on a desktop | at 320px its action bar squeezed rather than wrapped — "try the copy again" 54px across and 44px tall, four words stacked into a column, with nothing overflowing to give it away |
| 34 | the error colour was a literal behind a `var()` fallback, then half-wired | `var(--bad, #c0564f)` hid a token that did not exist; adding it to two of the palette's four blocks left the composer's error text pale salmon on light grey for anyone whose system is dark and who chose light |

**The method these last rows came from is worth stating, because it is
repeatable.** The defects stopped being wrong computations some time ago. Every
one since has been a SITUATION NOTHING HAD BEEN RUN IN — a panel nothing
rendered, a modal nobody scrolled, a wire-format copy nothing compared, a
deployment nothing served, a width nothing measured. So the useful question is
no longer "what does this code do wrong" but "what state can this be in that
nobody has ever looked at", and then going and looking. Enumerating deployments
found row 32; enumerating screen sizes found row 33; enumerating themes found
row 34. The dimensions are ordinary and the list is short — deployment, width,
theme, locale, exhibit count, exhibit state, claim phase — which is what makes
it worth writing down rather than rediscovering.

**Rows 15, 22, 23 and 24 are one defect found four times**, and the rule
underneath them is now a test rather than a habit: *a fault may only ever
describe something the person did.* Too many exhibits, a caption too long, a
host browsers will not load — theirs to fix, and worth saying. Anything the
composer produced by itself, including every way its own network calls can fail,
must leave a set that can be signed. `media_test.js` crosses every intake path
with every way it can go wrong and asserts exactly that; it found row 24 on its
first run.

Rows 18 and 19 are the same oversight twice: a rule stated in characters and
implemented in bytes. Row 18 refuses honest captions, row 19 accepts hostile
ones. Both survived because the two sides had only ever been compared on
`"x".repeat()`, where a byte and a character are the same thing — the fixture
chose the one input class that cannot tell them apart.

**The same pattern is realm-wide, and is NOT changed here.** Five user-written
fields are capped in bytes while the surface that collects them counts
characters:

| field | realm | what collects it |
|---|---|---|
| claim title | `len(title) > 200` | `title.maxLength = 200` (UTF-16 units) |
| claim body | `len(body) > maxClaimBodyLen` | `body.maxLength = 2000` |
| board text | `len(text) > maxBoardTextLen` | the board composer |
| court description | `len(desc) > maxCourtDescLen` | the court form |
| moderation reason | `len(reason) > maxReasonLen` | the moderation form |

A 200-character Russian claim title is about 370 bytes, so the composer accepts
it and the chain refuses it — the same abort row 18 describes, on the primary
fields rather than on a caption. Each is a one-line change of the shape made
here, and each makes the realm strictly MORE permissive, so no existing claim
becomes invalid; the cost is that claim text can occupy up to 4x the bytes it
can today, which the author already pays for through the storage deposit.

Left alone because it is consensus validation spread across `claim.gno`,
`board.gno`, `court.gno` and `moderation.gno` rather than anything media owns.
Recorded so the next person to touch those files has the measurement.

Rows 14 and 15 are the pair worth dwelling on: a server-side mechanism complete
and correct, its client half quietly not using it, and every unit test on both
sides passing. The doc already recorded that happening twice during the build.
It happened twice more, and what caught it was the first harness to run the path
a person actually takes.

Rows 10–12 were all found the same way: by rendering the page in a browser and
looking at it. None is visible in the source, and each had passing tests over the
exact code that was wrong — which is the argument for `rowscope_layout.js`, and
against believing a green suite about anything a reader sees.

---

## 10. Open owner rulings

1. **Allowlist as `const` or admin parameter.** A parameter mirrors
   `SetSiteDomain` — global-DAO-admin only, not overridable by meta or a court —
   and needs no redeploy when gnoweb's CSP moves. A `const` drifts in silence.
2. **`OpenClaimPM`** as the name, where `P` already means "with body"?
3. **Folders** — claims only, or may a folder carry an image?
4. **Host kill switch** — may a moderator retract every image on a host at once?
5. **How much of the claim page may evidence occupy?** Now that exhibits render
   there, this is a real trade with a measurement behind it. Seven of the demo's
   small 240x160 sample already push the Resolution heading down 1,281px — 1.42
   screens at 1100x900 — and a real 1600px-wide exhibit renders around 470px
   tall, so seven of those put the ballot roughly four screens below the title.

   Reading the evidence before voting is the right order, and "everything filed
   with a claim counts as claim text" (ruling 7) argues for showing it whole and
   inline. Against that: a reader who has already read the claim and wants to act
   must travel past all of it, every visit. The usual answer is a strip of
   thumbnails with the lightbox one click away — evidence fully present, nothing
   hidden, one row instead of four screens — but that trades reading for clicking
   on the page a court is read on. Recorded rather than quietly fixed.

**Settled by the owner:**

6. **kourt.xyz runs the archive.** It is the project's own service, not a
   delegated one. Two consequences follow and both belong in public documentation
   rather than in a later surprise: kourt.xyz carries the hosting obligations for
   everything filed, which is why the classifier lives there (§3); and if the
   service ever stops, **the hash survives and anyone may re-serve the bytes** —
   evidence degrades to unavailable, never to unprovable.
7. **Everything on a claim counts as claim text.** Captions are claim text, so
   they take the body's rule whole: **fixed at creation, no editor**, and subject
   to the same purge and redaction gates. An author who could revise a caption
   could reframe the exhibit after watching the market, which is the attack the
   body's rule exists to prevent, at a smaller scale but through the same door.
   See §2.4 for what this obliges the composer to do.

---

## 11. The road not taken: `r/img`

Bytes on-chain in a dedicated realm, each with an approval status an AI oracle
toggles, batch approval and deletion, and tiered DAO delegation so a compromised
oracle could not wipe older evidence.

Dropped on two findings. The bytes are public the instant the tx lands, so
pre-moderation moderates the portal and not the chain. And "deletion" clears
current state while block history and archive nodes keep the bytes permanently —
for the one category of content that carries real legal weight, that is the whole
question, and the design answered it only in appearance.

Its worthwhile part survives here: the archive does the classifying, at the layer
that actually holds the bytes.

---

## 12. Gates, and the traps in them

`make check` runs everything. The pieces this feature touches, and what each is
actually protecting:

| gate | holds |
|---|---|
| `realm-test` | the realm suite, plus the structural censuses — a new purge verb or purged-court gate must be registered, not merely written |
| `anchors` | every mutation-corpus row still anchors exactly once; run it after ANY wording change and before a probe |
| `controls` | every selftest plant still applies. A plant that stops matching runs the guard against an unmodified tree and reports SILENT |
| `guards` | every committed guard is named in `selftest-checks.py`. A guard nobody can break is a guard nobody has tested |
| `web-test` | 31 harnesses, including the two media suites |
| `web-constants` | includes `check-media-hosts.py`: the host list in the realm, the overlay and the page's CSP must agree, and `/m` must be routed |
| `txtar-test` | `kourtv2_media.txtar` files a claim carrying evidence against a real node |

**The traps, all of which cost time here:**

- **`sanitize.InlineText` escapes `-`, `#`, `.`, `_`, `(`, `)`.** A rendered act
  code reads `media\-purge\#0:csam` on the page, correct to a reader and
  invisible to a substring match. Assert what the page carries. This has caught
  three assertions in this feature and once broke a link destination outright.
- **A mutant that does not compile is not a caught mutant.** `if true { continue }`
  makes the rest of a loop unreachable and gno refuses it; the probe reports
  INVALID and reporting that as CAUGHT is a false green. Mutate to something
  that still builds.
- **The web harnesses count their own assertions.** Both media suites end with
  an `EXPECTED` total and fail if fewer ran. That exists because three
  concurrent async IIFEs with one `process.exit` between them silently skipped a
  third of the suite while printing ALL PASS. Add assertions, update the count —
  and if it fires unexpectedly, an edit half-applied.
- **`testStore` names its database after the test**, so two calls inside one
  test share it. `namedStore` is for a fixture that must be empty.
- **`Get` refuses a blocked blob deliberately.** It is the wrong question for
  "is there anything here", which is what `Held` is for. A correct contract can
  still be the wrong call at a particular site.

**Where the two implementations are pinned against each other.** Each of these
holds one literal in two suites, because testing both sides against the spec
proves the spec is self-consistent and nothing about whether they agree:

| seam | held in |
|---|---|
| the argument the overlay builds | `media_test.gno` `clientImageLine` / `media_test.js` |
| the JSON the realm sends the overlay | `media_test.gno` / `media_test.js` `fromChain` |
| the JSON the realm sends the archive | `media.gno` / `archive_test.go` `realmPayload` |
| the calls the overlay makes to the archive | `media_test.js` / `archive_test.go` `clientClaimedPath` |
