# CLAIM_MEDIA — evidence a claim carries, and proof it hasn't changed

> **v0.6 — built. Supersedes v0.1; two owner rulings settled; griefing pass applied.** A claim may carry up to **seven**
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
> | archive: a vision backend for it (Ollama) | built |
> | drafts in `localStorage` (§2.5) | built |
> | video as a second tier (§7) | built |
>
> One thing is worth knowing before trusting any of it: `mountCompose` needs a
> real canvas and `createImageBitmap`, so the resize path is the one piece no
> harness covers and it has never run against a real image.
>
> The chain-side seam IS now exercised end to end —
> `gnoland/testdata/kourtv2_media.txtar` files a claim carrying evidence against
> a real node and asks it the questions the page asks. What remains untested is
> the browser half: the composer's canvas work, and the archive serving bytes to
> a page that verifies them.

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
concept.** Not "sha256", not "mirror", not "256 KB", not "unsupported format".
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
- **Pick**, including `capture="environment"` on mobile so a phone offers the
  camera for photographing a document.

A fourth, **paste a URL**: fetch it, hash it, adopt it as an item with the
original URL kept as a mirror. When CORS blocks the fetch — and it often will —
say so in one sentence with the fix ("this host won't let us read the file;
download it and drop it here") rather than an error code.

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
kourt.xyz…"). A failed upload does **not** block filing: the item keeps its hash
and whatever mirrors it has, and the composer says the copy can be made later.
Losing an upload must never lose a draft.

### 2.4 Order, captions, removal

- **Order matters** and the UI must say why: the first item is what the map node
  shows. Drag to reorder, with keyboard equivalents.
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

---

## 4. Verification, and where it can happen

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

## 8. The map

There is no bulk claim fetch: `listClaimsPage` already issues per-claim qevals
inside one `Promise.all`. `ClaimMedia` joins that batch with `.catch(()=>"")`,
the tolerance `ClaimBody` already carries for realms predating the field. Honest
cost: one more read per claim, so a fifty-claim docket is fifty more. If that
bites, the answer is a batched accessor, not dropping thumbnails.

- **Node** — first live item, `clipPath` circle, `loading="lazy"`,
  `referrerpolicy="no-referrer"`, `onerror` removes the element. A broken glyph
  inside a node is worse than no image. Nodes do **not** verify — fifty hashes on
  a map draw is not a trade worth making; verification happens on selection.
- **Card** — horizontal scroll strip in a reserved aspect box using the stored
  `w`/`h`, with `object-fit:cover`. The box must be reserved: `.mapsel` is tuned
  closely enough that an image arriving after paint resizes the card mid-glide.
  Seven does not grid evenly, which is the second reason for a strip.
- **Lightbox** — gallery with next/prev, count, caption, and the verification
  line. Esc and backdrop close, focus trapped and restored, arrow keys navigate.

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

---

## 10. Open owner rulings

1. **Allowlist as `const` or admin parameter.** A parameter mirrors
   `SetSiteDomain` — global-DAO-admin only, not overridable by meta or a court —
   and needs no redeploy when gnoweb's CSP moves. A `const` drifts in silence.
2. **`OpenClaimPM`** as the name, where `P` already means "with body"?
3. **Folders** — claims only, or may a folder carry an image?
4. **Host kill switch** — may a moderator retract every image on a host at once?
**Settled by the owner:**

5. **kourt.xyz runs the archive.** It is the project's own service, not a
   delegated one. Two consequences follow and both belong in public documentation
   rather than in a later surprise: kourt.xyz carries the hosting obligations for
   everything filed, which is why the classifier lives there (§3); and if the
   service ever stops, **the hash survives and anyone may re-serve the bytes** —
   evidence degrades to unavailable, never to unprovable.
6. **Everything on a claim counts as claim text.** Captions are claim text, so
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

## 12. Gates

Run `check-mutation-anchors.py` immediately after any wording change and before
any probe. Gate on the twelve non-web targets. Corpus rows to add:

- `ClaimMedia` answers a purged claim with nothing
- each reject branch of `mediaItemFault`, the `)` case named separately
- a malformed sha256 (wrong length, uppercase, non-hex) is refused
- `PurgeClaimMedia` refuses a non-moderator
- a tombstoned slot survives the round trip in position
- render-time revalidation drops a mirror whose host has left the allowlist

Web tests extend `web/tests/mapclick_test.js` and add a composer suite: paste
inserts an item, oversized input is downscaled rather than refused, a failed
upload still permits filing, the draft survives a reload, a hash mismatch
replaces the image, reorder changes which item the node shows.
