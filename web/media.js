/* Claim media, browser side: what an exhibit is, and what the chain will accept.
 *
 * THIS FILE'S JOB IS TO SAY NO BEFORE THE CHAIN DOES. Every rule here mirrors
 * one in realm/r/kourtv2/media.gno. When they agree, a person is told what is
 * wrong while they can still fix it. When they disagree, they find out from an
 * aborted transaction reading `kourtv2: a mirror may not contain )` — after
 * composing a claim they cannot amend, since media is fixed at creation.
 *
 * So the duplication is deliberate and the messages are written for a person
 * rather than translated from the realm's. media_test.js pins them together.
 *
 * Nothing here touches the DOM: the composer's UI is separate so this core can
 * be tested by a standalone node script, the way every harness in web/tests is.
 *
 * See docs/CLAIM_MEDIA.md.
 */

const MEDIA_MAX_ITEMS = 7;
const MEDIA_MAX_MIRRORS = 4;
const MEDIA_MAX_URL = 300;
const MEDIA_MAX_CAPTION = 120;
const MEDIA_MAX_BYTES = 262144; // 256 KiB, the realm's cap and the archive's

/* The five raster types the archive will store and serve.
 *
 * SVG IS ABSENT ON PURPOSE. The archive serves from kourt.xyz's own origin, and
 * an SVG followed directly is a document that can carry script — which would
 * then run as kourt.xyz. The composer re-encodes everything to WebP anyway, so
 * nobody meets this list by accident. */
const MEDIA_TYPES = ["image/webp", "image/png", "image/jpeg", "image/gif", "image/avif"];

/* Hosts gnoweb's CSP will actually load an image from. Kept in step with
 * `mediaHostsExact` / `mediaHostSuffixes` in media.gno, which is kept in step
 * with gnoweb's own cspImgHost. A host outside this list renders an <img> that
 * the browser refuses, and the realm gets no signal at all — which is why the
 * refusal has to happen here, in front of somebody who can choose another host. */
const MEDIA_HOSTS_EXACT = [
  "gnolang.github.io", "assets.gnoteam.com", "sa.gno.services",
  "imgur.com", "github.com", "imgflip.com", "ipfs.io", "cloudflare-ipfs.com",
];
const MEDIA_HOST_SUFFIXES = [
  ".imgur.com", ".github.io", ".githubusercontent.com", ".imgflip.com",
];

/* siteDomain is the overlay's own domain, which is also where the archive lives.
 * Passed in rather than read from a global so the rules are testable without a
 * page around them. */
function mediaHostAllowed(host, siteDomain) {
  if (!host) return false;
  if (siteDomain && host === siteDomain) return true;
  if (MEDIA_HOSTS_EXACT.includes(host)) return true;
  // A longer host than the suffix, so the bare suffix is never itself a host we
  // trust: ".github.io" must not admit "github.io".
  return MEDIA_HOST_SUFFIXES.some(s => host.length > s.length && host.endsWith(s));
}

/* The authority is whatever precedes the first "/", "?" or "#". Cutting at only
 * one of them lets a fragment carry a trusted-looking name past the check:
 * in https://evil.example/#i.imgur.com the host is and stays evil.example. */
function mediaHostOf(url) {
  const scheme = "https://";
  if (!url.startsWith(scheme)) return "";
  let host = url.slice(scheme.length);
  for (const sep of ["/", "?", "#"]) {
    const i = host.indexOf(sep);
    if (i >= 0) host = host.slice(0, i);
  }
  return host;
}

/* Characters a mirror may not contain, and the reason each matters.
 *
 * The parentheses are the ones with a consequence rather than a preference: the
 * realm emits a mirror into a markdown image destination, ![alt](url), so a ")"
 * inside closes it early and spills the rest onto the page. "," and "|" are the
 * wire separators — one inside a URL would turn one field into two. */
function mediaMirrorFault(url, siteDomain) {
  // Answering an empty box with a character-count rule is the machine talking
  // about itself. Nothing was pasted; say what to do instead.
  if (!url) return "paste the image's link, or drop the file in and we will copy it";
  if (url.length > MEDIA_MAX_URL) {
    return `that link is too long — over ${MEDIA_MAX_URL} characters`;
  }
  if (/\s/.test(url)) {
    // Almost always a sentence rather than a link: somebody copied the text
    // around it, or the page put a line break in the middle.
    return "that looks like text rather than a link — copy the image's address on its own";
  }
  if (/["'<>()\\,|`]/.test(url)) {
    return "that link contains a character the court cannot store — try the image's direct URL";
  }
  // Reached only by a character OUTSIDE printable ASCII, because the two checks
  // above already took the spaces and the punctuation. It used to say "no
  // spaces", which described a case it can never see.
  if (!/^[\x21-\x7e]+$/.test(url)) {
    return "that link has an accented or non-Latin character in it — use the plain address";
  }
  if (!url.startsWith("https://")) {
    return url.startsWith("http://")
      ? "that link is http, which browsers block on a secure page — use https"
      : "a link starts with https://";
  }
  const host = mediaHostOf(url);
  if (!host) return "that link has no host";
  if (!mediaHostAllowed(host, siteDomain)) {
    return `browsers will not load images from ${host} here — imgur or GitHub work`;
  }
  return "";
}

function mediaCaptionFault(text) {
  if (!text) return "";
  if ([...text].length > MEDIA_MAX_CAPTION) {
    return `a caption is at most ${MEDIA_MAX_CAPTION} characters`;
  }
  if (/[\n\r]/.test(text)) return "a caption is one line";
  if (text.includes("|")) return "a caption cannot contain a vertical bar";
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x08\x0b-\x1f]/.test(text)) return "a caption cannot contain control characters";
  return "";
}

/* An item is {kind, sha256, mime, w, h, bytes, caption, mirrors[]}. */
function mediaItemFault(item, siteDomain) {
  if (!item || (item.kind !== "img" && item.kind !== "vid")) {
    return "an exhibit is an image or a video link";
  }
  if (item.kind === "img") {
    if (!/^[0-9a-f]{64}$/.test(item.sha256 || "")) {
      return "this image has no fingerprint yet";
    }
    if (!MEDIA_TYPES.includes(item.mime)) return "that image type cannot be stored";
    if (!(item.w > 0 && item.h > 0)) return "this image has no size yet";
    if (!(item.bytes > 0 && item.bytes <= MEDIA_MAX_BYTES)) {
      return "this image is too large";
    }
  } else if (item.sha256) {
    // A streaming host serves no stable bytes, so there is nothing to fingerprint
    // and nothing that could later prove the video is what was filed.
    return "a video link carries no fingerprint";
  }
  const cf = mediaCaptionFault(item.caption || "");
  if (cf) return cf;
  const mirrors = item.mirrors || [];
  if (!mirrors.length) return "this exhibit has no link yet";
  if (mirrors.length > MEDIA_MAX_MIRRORS) {
    return `an exhibit lists at most ${MEDIA_MAX_MIRRORS} links`;
  }
  for (const u of mirrors) {
    const f = mediaMirrorFault(u, siteDomain);
    if (f) return f;
  }
  return "";
}

/* mediaFault checks the whole set the way the realm will. Returns "" or the
 * first problem, prefixed with which exhibit it is about — a bare message is
 * useless when seven thumbnails are on screen. */
function mediaFault(items, siteDomain) {
  if (!items || !items.length) return "";
  if (items.length > MEDIA_MAX_ITEMS) {
    return `a claim carries at most ${MEDIA_MAX_ITEMS} exhibits`;
  }
  for (let i = 0; i < items.length; i++) {
    const f = mediaItemFault(items[i], siteDomain);
    if (f) return `exhibit ${i + 1}: ${f}`;
  }
  return "";
}

/* The argument OpenClaimPM takes: one line per item,
 * kind|sha256|mime|w|h|bytes|caption|mirror[,mirror...] */
function mediaArgLine(item) {
  const mirrors = (item.mirrors || []).join(",");
  return [
    item.kind, item.sha256 || "", item.mime || "",
    item.w || 0, item.h || 0, item.bytes || 0,
    item.caption || "", mirrors,
  ].join("|");
}

function mediaArg(items) {
  return (items || []).map(mediaArgLine).join("\n");
}

/* The archive's address for a hash. Derived, never stored — which is what lets
 * the realm's own markdown and every client reach it with nothing on chain
 * pointing the way. */
function mediaArchiveURL(siteDomain, sha256) {
  return siteDomain ? `https://${siteDomain}/m/${sha256}` : "";
}

/* sha256 of bytes, as lowercase hex.
 *
 * THE HASH IS THE AUTHOR'S OWN COMMITMENT and is computed here, in their
 * browser, over the exact bytes that will be filed. Nothing server-side vouches
 * for it: a wrong one only makes their own image fail to verify, and its value
 * is that nobody — the author included — can swap the bytes afterward. */
async function mediaDigest(bytes) {
  const buf = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
}

/* ---- intake -------------------------------------------------------------
 *
 * THE RULE THIS SECTION EXISTS FOR: a person filing evidence should never meet
 * a technical concept. Not "sha256", not "256 KiB", not "unsupported format".
 * A 12-megapixel phone photo becomes a 90 KB WebP and the cap it would have
 * violated is never mentioned, because the machine's problem was the machine's
 * to solve. Only a file that survives all of that and is still impossible gets
 * a message, and then it names the file and the reason.
 */

/* The size to draw at: never larger than maxEdge, and NEVER LARGER THAN THE
 * ORIGINAL. Upscaling a small screenshot would spend bytes inventing detail
 * that was never there, and make a 200-byte image cost more than the memo it
 * shows. */
function mediaFitWithin(w, h, maxEdge) {
  if (!(w > 0 && h > 0)) return {w: 0, h: 0};
  const scale = Math.min(1, maxEdge / Math.max(w, h));
  return {w: Math.max(1, Math.round(w * scale)), h: Math.max(1, Math.round(h * scale))};
}

const MEDIA_MAX_EDGE = 1600;

/* The qualities tried, in order, and the FIRST one that fits wins.
 *
 * Descending because the cheapest acceptable answer is the best one: stopping at
 * the first size under the cap spends the fewest bytes that still show what the
 * exhibit shows. Trying them ascending, or picking the smallest, would throw
 * away detail somebody may need to read a document in a photograph.
 */
const MEDIA_QUALITIES = [0.82, 0.7, 0.6, 0.5];

/* mediaEncodeUnder is the resize POLICY, separated from the two browser calls
 * it used to be tangled with.
 *
 * `encode(quality)` is whatever produces bytes — canvas.toBlob in a page, a stub
 * in a test. Extracting it means the loop that decides WHICH attempt to keep is
 * exercised by the harness, and only createImageBitmap and toBlob themselves
 * remain untested outside a browser. A policy nobody can test because it sits
 * next to a primitive nobody can test is two untestable things, not one.
 */
async function mediaEncodeUnder(encode, cap, qualities) {
  const tries = qualities || MEDIA_QUALITIES;
  for (const q of tries) {
    const blob = await encode(q);
    // A browser that cannot encode at all answers null, and trying lower
    // qualities of nothing is a slower way to fail.
    if (!blob) break;
    if (blob.size <= cap) return {blob, quality: q};
  }
  throw new Error("that image will not compress small enough");
}

/* mediaUpload sends bytes to the archive and returns the item fields.
 *
 * IT CHECKS THE ARCHIVE'S ANSWER. The digest is computed here first, and if the
 * server names a different one the upload is refused rather than adopted: a
 * mismatch means the bytes that arrived are not the bytes we hashed, and filing
 * that hash would commit the author to an image nobody has. The archive is a
 * mirror, never an authority — including about what it just received.
 *
 * `fetchFn` and `base` are injected so this is testable without a network. */
async function mediaUpload(bytes, mime, opts) {
  const o = opts || {};
  const fetchFn = o.fetch || (typeof fetch !== "undefined" ? fetch : null);
  const base = o.base || "";
  const mine = o.sha256 || await mediaDigest(bytes);
  if (!fetchFn) throw new Error("no way to reach the archive");

  // The court is a HINT, and it is what makes the archive's backfill work: if
  // this tab closes before the claim is broadcast, nothing ever calls
  // /m/claimed, and the court is the only thread back to these bytes. It grants
  // no access — a wrong one just means they rely on /m/claimed as before.
  const q = o.court ? "?court=" + encodeURIComponent(o.court) : "";
  const res = await fetchFn(base + "/m" + q, {
    method: "POST", headers: {"Content-Type": mime}, body: bytes,
  });
  if (!res.ok) throw new Error("the archive would not take that image (" + res.status + ")");
  const body = await res.json();
  if (body.sha256 !== mine) {
    throw new Error("the archive stored something other than what was sent");
  }
  // USE THE ADDRESS THE ARCHIVE GAVE, not one built here. The service returns it
  // saying in as many words that it does so "so the composer never has to build
  // it, and so this stays the one place that knows the shape" — and this built
  // its own anyway, which made two places that had to agree about a path. The
  // fallback covers a service too old to answer with one.
  const at = typeof body.url === "string" && body.url ? body.url : "/m/" + mine;
  return {sha256: mine, url: at.startsWith("http") ? at : base + at};
}

/* mediaClaimed tells the archive a claim now references these bytes, which is
 * what turns an hour-long staging into permanent storage. Best-effort by
 * design: the claim is already on chain, and a failure here costs availability
 * rather than the record. */
async function mediaClaimed(court, claimID, opts) {
  const o = opts || {};
  const fetchFn = o.fetch || (typeof fetch !== "undefined" ? fetch : null);
  if (!fetchFn) return 0;
  try {
    const res = await fetchFn(
      (o.base || "") + "/m/claimed?court=" + encodeURIComponent(court) +
      "&claim=" + encodeURIComponent(String(claimID)), {method: "POST"});
    if (!res.ok) return 0;
    const body = await res.json();
    return body.promoted || 0;
  } catch (_) {
    return 0;
  }
}

/* The states an exhibit passes through, and the words the person sees. Plain
 * language on purpose: "making a copy on kourt.xyz" tells someone what is
 * happening to their file; "uploading blob" tells them what the program is
 * doing to itself. */
const MEDIA_STATES = {
  shrinking: "resizing…",
  hashing: "fingerprinting…",
  uploading: "making a copy on kourt.xyz…",
  ready: "",
  failed: "no copy yet — it will still be filed",
};

/* An exhibit is FILEABLE even when its copy failed. The hash and the original
 * link are what the chain records; the archive copy is durability, not validity,
 * and blocking a filing on it would let a flaky upload cost somebody their
 * claim. */
function mediaFileable(item) {
  return !!item && (item.state === "ready" || item.state === "failed");
}

/* ---- the composer -------------------------------------------------------
 *
 * A LIST OF EXHIBITS AND THE FOUR THINGS A PERSON DOES TO IT: add one, caption
 * it, reorder them, remove one. Everything else here is bookkeeping in service
 * of those four staying instant.
 *
 * The DOM work and the slow work are separated on purpose. `prepare` (resize and
 * re-encode, which needs a canvas) and `upload` (which needs a network) are
 * injected, so this file's behaviour can be exercised by a standalone node
 * script the way every other harness in web/tests is, and so a browser that
 * fails at either still gets a composer that works.
 */

function mediaNewComposer(opts) {
  const o = opts || {};
  const items = [];
  let seq = 0;

  /* An exhibit appears the INSTANT it is dropped, from a local preview, and
   * every slow step happens to a row that is already on screen. Making somebody
   * watch a blank panel while a 12-megapixel photo is resized would be the same
   * wait dressed as a failure. */
  function add(file) {
    if (items.length >= MEDIA_MAX_ITEMS) {
      return {error: `a claim carries at most ${MEDIA_MAX_ITEMS} exhibits`};
    }
    const item = {
      id: ++seq, kind: "img", state: "shrinking", caption: "",
      mirrors: [], preview: o.previewURL ? o.previewURL(file) : "",
      name: (file && file.name) || "",
    };
    items.push(item);
    o.onChange && o.onChange(items);
    run(item, file);
    return {item};
  }

  /* A pasted link is adopted as an exhibit, with the original kept as its
   * mirror. It cannot be fingerprinted here — reading a cross-origin image is
   * exactly what CORS refuses — so it is filed as a LINK and says so, rather
   * than pretending to a verification nobody performed. */
  function addLink(url, kind) {
    if (items.length >= MEDIA_MAX_ITEMS) {
      return {error: `a claim carries at most ${MEDIA_MAX_ITEMS} exhibits`};
    }
    const fault = mediaMirrorFault(url, o.siteDomain);
    if (fault) return {error: fault};
    const item = {
      id: ++seq, kind: kind === "vid" ? "vid" : "img", state: "ready",
      caption: "", mirrors: [url], preview: url, linkOnly: true,
    };
    items.push(item);
    o.onChange && o.onChange(items);
    return {item};
  }

  async function run(item, file) {
    try {
      const prepared = await o.prepare(file);
      Object.assign(item, {
        mime: prepared.mime, w: prepared.w, h: prepared.h,
        bytes: prepared.bytes.length, state: "hashing",
      });
      o.onChange && o.onChange(items);

      item.sha256 = await mediaDigest(prepared.bytes);
      item.state = "uploading";
      o.onChange && o.onChange(items);

      const up = await o.upload(prepared.bytes, prepared.mime, item.sha256);
      item.mirrors = [up.url];
      item.state = "ready";
    } catch (e) {
      /* THE COPY FAILED AND THE EXHIBIT SURVIVES. The hash and whatever link it
       * already has are what the chain records; the archive copy is durability,
       * not validity. A flaky upload must never cost somebody their claim — it
       * costs them a warning. */
      item.state = item.sha256 ? "failed" : "broken";
      item.error = (e && e.message) || String(e);
    }
    o.onChange && o.onChange(items);
  }

  function remove(id) {
    const i = items.findIndex(x => x.id === id);
    if (i < 0) return null;
    const [gone] = items.splice(i, 1);
    o.onChange && o.onChange(items);
    return gone; // returned so the caller can offer an undo rather than a confirm
  }

  function restore(item, at) {
    items.splice(Math.max(0, Math.min(at, items.length)), 0, item);
    o.onChange && o.onChange(items);
  }

  /* Order is not decoration: the first exhibit is what the map node shows. */
  function move(id, delta) {
    const i = items.findIndex(x => x.id === id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= items.length) return false;
    const t = items[i]; items[i] = items[j]; items[j] = t;
    o.onChange && o.onChange(items);
    return true;
  }

  function setCaption(id, text) {
    const item = items.find(x => x.id === id);
    if (!item) return "";
    item.caption = text;
    return mediaCaptionFault(text);
  }

  /* What the chain will be asked to store, and whether it will accept it. */
  function argument() { return mediaArg(items.filter(mediaFileable)); }
  function fault() { return mediaFault(items.filter(mediaFileable), o.siteDomain); }
  function busy() { return items.some(x => !mediaFileable(x) && x.state !== "broken"); }

  /* Put a restored draft's exhibits back. `seq` advances past them so a new
     exhibit added afterwards cannot take an id one of these already has. */
  function seed(restored) {
    for (const it of restored || []) {
      items.push(it);
      seq = Math.max(seq, Math.abs(it.id || 0));
    }
    o.onChange && o.onChange(items);
  }

  return {
    items, add, addLink, remove, restore, move, setCaption, seed,
    argument, fault, busy,
    count: () => items.length,
  };
}

/* Whether the gnoweb $help link can still carry this claim.
 *
 * MEASURED, NOT GUESSED. The page offers every action three ways — a $help
 * link, a CLI command and a one-click sign — and only the link has a length
 * limit. A typical claim is nowhere near it: seven exhibits with two mirrors
 * each encode to about 2.8 KB, which every browser and proxy accepts. The worst
 * case the validator permits — seven exhibits with four 300-character mirrors —
 * encodes to about 10.3 KB, and nginx's default header buffer is 8 KB, so that
 * request is refused before gnoweb ever sees it.
 *
 * The limit here is deliberately well under 8192: the media argument is only
 * part of the request line, which also carries the realm path, the function
 * name, the title and the body. Leaving room means the cutoff is reached by
 * this check, which can explain itself, rather than by a proxy returning 414 to
 * somebody who has just written a claim.
 *
 * An earlier draft of docs/CLAIM_MEDIA.md said this affordance simply could not
 * survive media. That was a guess and it was wrong — most claims are fine, and
 * disabling the link for all of them would have removed a working path for the
 * sake of a rare one. */
const MEDIA_HELP_LINK_BUDGET = 6000;

function mediaHelpLinkFits(arg) {
  return encodeURIComponent(arg || "").length <= MEDIA_HELP_LINK_BUDGET;
}

/* What to say when it does not fit. Never a dead link and never silence: the
 * two paths that still work are named, because "this does not work" without
 * "this does" is the shape of every unhelpful error. */
const MEDIA_HELP_LINK_TOO_LONG =
  "Too many links on these exhibits for the gnoweb form. Sign with Adena, or " +
  "use the command line — both carry the whole claim.";

/* mediaReview is the last look before a signature, and it exists because of an
 * owner ruling: a caption is claim text, so it takes the body's rule whole —
 * fixed at creation, no editor, not even in the polish window where a TITLE can
 * still be corrected. A typo is permanent and the only remedy is to close the
 * claim and file it again.
 *
 * So this is the ONE place in the composer where friction is correct. Everywhere
 * else the job is to remove it. */
function mediaReview(items) {
  const live = (items || []).filter(mediaFileable);
  const lines = live.map((it, i) => ({
    n: i + 1,
    caption: it.caption || "(no caption)",
    kind: it.kind === "vid" ? "video link" : "image",
    verified: it.kind === "img" && !it.linkOnly,
    copied: (it.mirrors || []).length > 0 && it.state === "ready",
  }));
  const warnings = [];
  if (live.some(x => x.state === "failed")) {
    warnings.push("Some exhibits have no copy on kourt.xyz yet. They will still " +
      "be filed, and the copy can be made later.");
  }
  if (live.some(x => x.kind === "vid")) {
    warnings.push("A video is filed as a link. The court keeps no copy and " +
      "cannot vouch for what it shows later.");
  }
  if (live.some(x => x.linkOnly)) {
    warnings.push("An exhibit added by link has no fingerprint, so nothing can " +
      "later prove it is the image you filed.");
  }
  return {
    lines, warnings,
    permanent: "Captions cannot be edited after filing. Read them once more.",
  };
}

/* ---- reading a claim's evidence back ------------------------------------ */

/* ClaimMedia answers with one line of JSON. A realm deployed before media
 * existed answers with nothing at all, and a map that fails whole because of a
 * missing optional field would be the worse bug. */
function mediaParse(raw) {
  try {
    const v = JSON.parse(raw || "[]");
    return Array.isArray(v) ? v : [];
  } catch (_) {
    return [];
  }
}

/* Where to fetch an exhibit's bytes.
 *
 * THE ARCHIVE FIRST, ALWAYS, and on the map ONLY the archive. A listed mirror is
 * a URL the FILER chose, and every viewer's browser fetches it: on a map draw
 * that is fifty nodes fanning out to hosts an attacker picked, carrying fifty
 * readers' addresses. The archive is a host we operate and cache.
 *
 * A card may fall back to a mirror because it is one image, chosen by the
 * reader, and being able to see the evidence at all is worth more there. A node
 * thumbnail may not: nobody asked for it, and there are fifty.
 */
function mediaSrc(item, siteDomain, allowMirrors) {
  if (!item || item.purged) return "";
  // BYTES ALREADY IN HAND NEED NO HOST. Only the offline demo sets this, and it
  // must: web/README.md promises a page that runs from file:// and makes no
  // network calls in demo mode, so a sample exhibit pointing at the archive
  // would break that promise AND draw a broken image off a network.
  //
  // Restricted to data: on purpose. Nothing on chain can produce this field —
  // encodeMedia writes a fixed set and none of it is named inline — but the
  // restriction means the no-network property holds by construction rather than
  // by trusting that, since a data: URI cannot name a host.
  if (typeof item.inline === "string" && item.inline.slice(0, 5) === "data:") {
    return item.inline;
  }
  if (item.kind !== "vid" && item.sha256 && siteDomain) {
    return mediaArchiveURL(siteDomain, item.sha256);
  }
  if (!allowMirrors) return "";
  const mirrors = item.mirrors || [];
  for (const u of mirrors) {
    if (!mediaMirrorFault(u, siteDomain)) return u;
  }
  return "";
}

/* The one image a map node shows: the first exhibit that is an image and has an
 * archive copy to point at. Never a mirror — see mediaSrc. */
function mediaNodeThumb(items, siteDomain) {
  for (const it of items || []) {
    const src = mediaSrc(it, siteDomain, false);
    if (src) return src;
  }
  return "";
}

/* A DECLARED RATIO IS ATTACKER INPUT, and it is used to reserve a box before the
 * bytes arrive. w and h are numbers the filer put in the transaction; nothing
 * verifies them against the image, and the realm bounds each to maxMediaDim
 * without bounding the RATIO between them. Declaring 1x20000 reserved a box
 * measured at 40,000px tall and 2px wide — seven of those on one claim, and the
 * page is a quarter of a million pixels of nothing. Media is fixed at creation,
 * so it would stay that way until a global-DAO purge: a takedown built for
 * illegal content, spent on a layout attack.
 *
 * Dropping the ratio entirely would be the safe answer and the wrong one — the
 * reservation is what stops the page jumping as each exhibit lands. So it is
 * honoured inside the range real evidence lives in and refused outside it. Eight
 * is deliberately generous: a long screenshot of a chat log genuinely is many
 * times taller than it is wide, and that is ordinary evidence, not an attack. */
const MEDIA_BOX_LIMIT = 8;
function mediaBoxRatio(w, h) {
  if (!(w > 0) || !(h > 0)) return "";
  if (h / w > MEDIA_BOX_LIMIT || w / h > MEDIA_BOX_LIMIT) return "";
  return w + "/" + h;
}

/* What the selection card shows: every exhibit, in order, each with the number
 * a reader and a moderator both refer to it by, and a reason when there is
 * nothing to show. A gap that silently renumbered the rest would leave every
 * later exhibit meaning something different than it did yesterday. */
function mediaCardItems(items, siteDomain) {
  const list = items || [];
  return list.map((it, i) => {
    const label = `${i + 1} of ${list.length}`;
    if (it.purged) return {n: i + 1, label, src: "", note: "taken down"};
    if (it.kind === "vid") {
      return {n: i + 1, label, src: "", video: mediaSrc(it, siteDomain, true),
              caption: it.caption || "", note: "video — linked, not verified"};
    }
    const src = mediaSrc(it, siteDomain, true);
    return {n: i + 1, label, src, caption: it.caption || "",
            w: it.w || 0, h: it.h || 0,
            note: src ? "" : "not currently available"};
  });
}

/* Verification, and the three things it can say.
 *
 * ONLY THIS PAGE CAN DO THIS. gnoweb's CSP is connect-src 'self' and its own
 * node, so it cannot fetch third-party bytes and cannot check anything. That is
 * the division of labour: gnoweb renders, kourt.xyz attests. */
async function mediaVerify(item, src, opts) {
  const o = opts || {};
  const fetchFn = o.fetch || (typeof fetch !== "undefined" ? fetch : null);
  if (!item || item.kind === "vid" || !item.sha256) return "unverifiable";
  // BYTES THE PAGE HANDED ITSELF CANNOT CHECK THE PAGE. fetch() resolves a data:
  // URI perfectly well, so without this the sample would hash its own embedded
  // bytes, agree with its own digest, and print "matches what was filed" — a
  // verdict about an ARCHIVE, shown for an exhibit no archive has ever seen and
  // no chain has ever recorded. Passing a check nothing performed is the one
  // wrong answer this whole panel exists to avoid.
  if (typeof item.inline === "string") return "sample";
  if (!src || !fetchFn) return "unavailable";
  try {
    const res = await fetchFn(src, {referrerPolicy: "no-referrer"});
    if (!res.ok) return "unavailable";

    // REFUSE BEFORE READING, not after. The hash already catches bytes that are
    // not the filed ones, so this check can never change a verdict — its whole
    // job is to avoid pulling a hundred megabytes into memory to reach that
    // conclusion. An earlier version compared lengths AFTER arrayBuffer(), which
    // is the same check written where it protects nothing; an ablation caught
    // it by not failing.
    const declared = res.headers && res.headers.get && res.headers.get("content-length");
    if (item.bytes && declared && Number(declared) > item.bytes) return "altered";

    const buf = await res.arrayBuffer();
    if (item.bytes && buf.byteLength > item.bytes) return "altered";
    return (await mediaDigest(new Uint8Array(buf))) === item.sha256 ? "matches" : "altered";
  } catch (_) {
    return "unavailable";
  }
}

/* The words for each verdict. "altered" is the whole feature and must be
 * impossible to miss — it is a sentence, not a badge to decode. */
const MEDIA_VERDICTS = {
  matches: "matches what was filed",
  altered: "THIS NO LONGER MATCHES WHAT WAS FILED",
  unavailable: "not currently available",
  unverifiable: "linked — the court keeps no copy and cannot check it",
  sample: "a sample — no court filed this, so there is nothing to check it against",
};

/* ---- drawing it ---------------------------------------------------------
 *
 * Deliberately small: create, append, listen, set text. No innerHTML anywhere
 * near a caption or a URL, because every string in this panel came from a person
 * and one of them is a link the chain will store.
 */

function mediaEl(doc, tag, attrs, text) {
  const el = doc.createElement(tag);
  for (const k of Object.keys(attrs || {})) el.setAttribute(k, attrs[k]);
  if (text !== undefined && text !== null) el.textContent = String(text);
  return el;
}

/* mediaMount draws a composer into `root` and keeps it drawn.
 *
 * Every redraw rebuilds the list, which is the right trade at seven rows: the
 * alternative is a diff whose bugs look like an exhibit refusing to disappear.
 * The caption input is the exception — it is rebuilt too, so the caller restores
 * focus through `opts.focus`, and losing a cursor mid-sentence is the one thing
 * this cannot be allowed to do.
 */
function mediaMount(root, composer, opts) {
  const o = opts || {};
  const doc = o.doc || (typeof document !== "undefined" ? document : null);
  if (!doc || !root) return null;

  const drop = mediaEl(doc, "div", {class: "mediadrop", tabindex: "0", role: "group",
    "aria-label": "Evidence for this claim"});
  const prompt = mediaEl(doc, "p", {class: "mediahint"},
    "Drop images here, paste a screenshot, or choose files. " +
    "The first one is what the map shows.");
  const pick = mediaEl(doc, "input", {type: "file", accept: MEDIA_TYPES.join(","),
    multiple: "multiple", class: "mediapick"});
  const list = mediaEl(doc, "div", {class: "medialist"});
  const note = mediaEl(doc, "p", {class: "medianote", role: "status"});

  drop.appendChild(prompt);
  drop.appendChild(pick);
  drop.appendChild(list);
  drop.appendChild(note);
  root.appendChild(drop);

  function say(msg) { note.textContent = msg || ""; }

  function addAll(files) {
    for (const f of files || []) {
      const r = composer.add(f);
      if (r.error) { say(r.error); return; }
    }
    say("");
  }

  function draw() {
    list.innerHTML = "";
    const items = composer.items;
    items.forEach((item, i) => {
      const row = mediaEl(doc, "figure", {class: "mediaitem", "data-id": String(item.id)});

      if (item.preview) {
        // No referrer, so a pasted link's host does not learn which claim is
        // being written before the claim even exists.
        row.appendChild(mediaEl(doc, "img", {
          src: item.preview, alt: "", class: "mediathumb",
          loading: "lazy", referrerpolicy: "no-referrer",
        }));
      }

      const cap = mediaEl(doc, "figcaption", {class: "mediacap"});
      cap.appendChild(mediaEl(doc, "span", {class: "medianum"},
        `${i + 1} of ${items.length}` + (i === 0 ? " — shown on the map" : "")));

      const input = mediaEl(doc, "input", {
        type: "text", class: "mediacaption", maxlength: String(MEDIA_MAX_CAPTION),
        placeholder: "Label this exhibit (optional)", value: item.caption || "",
        "aria-label": `Caption for exhibit ${i + 1}`,
      });
      input.value = item.caption || "";
      input.addEventListener("input", () => {
        const fault = composer.setCaption(item.id, input.value);
        say(fault ? `exhibit ${i + 1}: ${fault}` : "");
      });
      cap.appendChild(input);

      // The state in plain words. "making a copy on kourt.xyz" says what is
      // happening to their file; "uploading blob" says what the program is
      // doing to itself.
      const state = MEDIA_STATES[item.state];
      if (state) cap.appendChild(mediaEl(doc, "span", {class: "mediastate"}, state));
      if (item.state === "broken") {
        cap.appendChild(mediaEl(doc, "span", {class: "mediabroken"},
          "could not read that file — " + (item.error || "unknown reason")));
      }
      if (item.linkOnly) {
        cap.appendChild(mediaEl(doc, "span", {class: "medialink"},
          "added by link — the court keeps no copy and cannot check it later"));
      }

      const bar = mediaEl(doc, "div", {class: "mediabar"});
      const up = mediaEl(doc, "button", {type: "button", class: "mediamove",
        "aria-label": `Move exhibit ${i + 1} earlier`}, "↑");
      up.addEventListener("click", () => { composer.move(item.id, -1); });
      const down = mediaEl(doc, "button", {type: "button", class: "mediamove",
        "aria-label": `Move exhibit ${i + 1} later`}, "↓");
      down.addEventListener("click", () => { composer.move(item.id, 1); });
      const del = mediaEl(doc, "button", {type: "button", class: "mediadel",
        "aria-label": `Remove exhibit ${i + 1}`}, "×");
      del.addEventListener("click", () => {
        const gone = composer.remove(item.id);
        // An undo, not a confirm. A confirm taxes every correct removal to
        // prevent a rare wrong one; an undo charges only the mistake.
        if (gone) {
          say("Removed. ");
          const undo = mediaEl(doc, "button", {type: "button", class: "mediaundo"}, "undo");
          undo.addEventListener("click", () => { composer.restore(gone, i); say(""); });
          note.appendChild(undo);
        }
      });
      bar.appendChild(up); bar.appendChild(down); bar.appendChild(del);
      cap.appendChild(bar);

      row.appendChild(cap);
      list.appendChild(row);
    });

    const fault = composer.fault();
    if (fault) say(fault);
    if (o.onDraw) o.onDraw(items);
  }

  pick.addEventListener("change", () => addAll(pick.files));

  // Paste anywhere in the panel, not only on a drop target: a screenshot on the
  // clipboard is the commonest evidence there is, and hunting for the right box
  // to click first is a step nobody should have to learn.
  //
  // AND IT WAS BOUND TO THE DROP ZONE, which is a sibling of the title and body
  // rather than their ancestor — so the comment above described an intention the
  // code did not carry out. A paste event goes to the focused element and
  // bubbles from there, and after typing a claim the cursor is in the title. The
  // most important intake path in the whole design did nothing from the one
  // place a person actually is. Only a browser can see that: a unit test can
  // prove the listener exists, not that anything reaches it.
  //
  // pasteScope is the composer's whole panel when mountCompose supplies one, and
  // the drop zone otherwise, so a caller that mounts this alone still works.
  const pasteScope = o.pasteScope || drop;
  pasteScope.addEventListener("paste", ev => {
    const data = ev.clipboardData;
    if (!data) return;
    const files = [...(data.files || [])];
    if (files.length) { ev.preventDefault(); addAll(files); return; }
    const text = data.getData ? data.getData("text") : "";
    // A TYPED-IN BOX KEEPS ITS PASTE. Adopting a pasted link as an exhibit is
    // right on the drop zone and wrong in the title or the body: a claim about
    // a web page has to be able to quote its address. Files are not ambiguous
    // in the same way — a screenshot cannot be pasted into a text input as
    // anything — so those are taken from anywhere above.
    const t = ev.target, tag = t && t.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)) return;
    if (text && /^https?:\/\//.test(text.trim())) {
      ev.preventDefault();
      const url = text.trim();
      // A pasted link that names a video file is filed as a video: it has no
      // hash either way, but the reader is told which kind of thing it is, and
      // a <video> is what will actually play it.
      const kind = /\.(mp4|webm|ogg|ogv|mov|m4v)(\?|#|$)/i.test(url) ? "vid" : "img";
      const r = composer.addLink(url, kind);
      say(r.error || (kind === "vid"
        ? "Added as a video. The court keeps no copy and cannot check it later."
        : ""));
    }
  });

  drop.addEventListener("dragover", ev => { ev.preventDefault(); drop.classList.add("over"); });
  drop.addEventListener("dragleave", () => drop.classList.remove("over"));
  drop.addEventListener("drop", ev => {
    ev.preventDefault();
    drop.classList.remove("over");
    addAll(ev.dataTransfer && ev.dataTransfer.files);
  });

  draw();
  return {draw, say, el: drop};
}

/* ---- drafts -------------------------------------------------------------
 *
 * NOTHING IS LOST. A closed tab, a rejected signature, a broadcast that failed:
 * reopening restores the claim with its exhibits intact. This is cheap to build
 * and expensive to omit — the work being protected is somebody writing out what
 * they believe and why, and losing it is the kind of thing people do not come
 * back from.
 *
 * The bytes are already safe: they were uploaded and are addressed by hash, so a
 * draft only has to remember the ADDRESS. That is also why a draft is small
 * enough to keep in localStorage without thinking about it.
 */

const MEDIA_DRAFT_PREFIX = "kourt.draft.";

function mediaDraftKey(court) { return MEDIA_DRAFT_PREFIX + (court || ""); }

/* What is worth writing down. Not `preview`: a blob: URL is dead the moment the
 * page unloads, and storing one would restore an exhibit whose thumbnail is a
 * broken image. Not `state` either — it is re-derived on load from what the item
 * actually has, which is the only honest source after a reload. */
function mediaDraftOf(title, body, items) {
  return {
    v: 1, title: title || "", body: body || "",
    items: (items || []).filter(mediaFileable).map(it => ({
      kind: it.kind, sha256: it.sha256 || "", mime: it.mime || "",
      w: it.w || 0, h: it.h || 0, bytes: it.bytes || 0,
      caption: it.caption || "", mirrors: it.mirrors || [],
      linkOnly: !!it.linkOnly,
    })),
  };
}

function mediaSaveDraft(store, court, title, body, items) {
  if (!store) return false;
  const d = mediaDraftOf(title, body, items);
  // An empty draft is a deletion. Leaving one behind would greet the next
  // person to open the composer with a blank form they have to dismiss.
  if (!d.title && !d.body && !d.items.length) return mediaClearDraft(store, court);
  try {
    store.setItem(mediaDraftKey(court), JSON.stringify(d));
    return true;
  } catch (_) {
    // A full or disabled store is not a reason to lose the composer; the draft
    // is a convenience and must never be load-bearing.
    return false;
  }
}

function mediaLoadDraft(store, court) {
  if (!store) return null;
  let raw = null;
  try { raw = store.getItem(mediaDraftKey(court)); } catch (_) { return null; }
  if (!raw) return null;
  let d;
  try { d = JSON.parse(raw); } catch (_) { return null; }
  if (!d || d.v !== 1 || !Array.isArray(d.items)) return null;
  return {
    title: String(d.title || ""), body: String(d.body || ""),
    items: d.items.map((it, i) => Object.assign({}, it, {
      id: -(i + 1),                       // negative: never collides with a live id
      // The preview is whatever can be SHOWN now. The archive copy survived the
      // reload even though the blob: URL did not.
      preview: (it.mirrors || [])[0] || "",
      // Re-derived rather than restored: an item with somewhere to be found is
      // ready, and one without is a failed copy the person can retry.
      state: (it.mirrors || []).length ? "ready" : "failed",
    })),
  };
}

function mediaClearDraft(store, court) {
  if (!store) return false;
  try { store.removeItem(mediaDraftKey(court)); return true; } catch (_) { return false; }
}

/* ---- the lightbox -------------------------------------------------------
 *
 * Full size, one exhibit at a time, and THE ONE PLACE THAT SAYS WHETHER THE
 * BYTES ARE THE FILED ONES. gnoweb cannot: its CSP forbids fetching a
 * third-party image at all, so it renders and stays silent. This page can, so
 * this page must — an overlay that could check and did not would be worse than
 * one that never offered.
 */
function mediaLightbox(items, start, opts) {
  const o = opts || {};
  const doc = o.doc || (typeof document !== "undefined" ? document : null);
  const host = o.host || (doc && doc.body);
  if (!doc || !host || !items || !items.length) return null;

  let at = Math.max(0, Math.min(start | 0, items.length - 1));
  const restore = o.activeElement || (doc.activeElement || null);

  const box = mediaEl(doc, "div", {class: "lbox", role: "dialog", "aria-modal": "true",
    "aria-label": "Exhibit", tabindex: "-1"});
  const fig = mediaEl(doc, "figure", {class: "lbox-fig"});
  const img = mediaEl(doc, "img", {class: "lbox-img", alt: "", referrerpolicy: "no-referrer"});
  const cap = mediaEl(doc, "figcaption", {class: "lbox-cap"});
  const num = mediaEl(doc, "span", {class: "lbox-n"});
  const verdict = mediaEl(doc, "p", {class: "lbox-v", role: "status"});
  const prev = mediaEl(doc, "button", {type: "button", class: "lbox-prev",
    "aria-label": "Previous exhibit"}, "‹");
  const next = mediaEl(doc, "button", {type: "button", class: "lbox-next",
    "aria-label": "Next exhibit"}, "›");
  const shut = mediaEl(doc, "button", {type: "button", class: "lbox-x",
    "aria-label": "Close"}, "×");

  fig.appendChild(img); fig.appendChild(num); fig.appendChild(cap); fig.appendChild(verdict);
  box.appendChild(shut); box.appendChild(prev); box.appendChild(fig); box.appendChild(next);
  host.appendChild(box);

  let token = 0;
  function show() {
    const it = items[at] || {};
    const src = mediaSrc(it, o.siteDomain, true);
    img.setAttribute("src", src || "");
    // The caption is the alt text: an exhibit labelled "the email header" is
    // better to a screen reader than "exhibit 2 of 5", and it is what the
    // author wrote for exactly this purpose.
    img.setAttribute("alt", it.caption || `exhibit ${at + 1} of ${items.length}`);
    num.textContent = `${at + 1} of ${items.length}`;
    cap.textContent = it.caption || "";
    prev.disabled = at === 0;
    next.disabled = at === items.length - 1;

    // Checking is asynchronous and the reader may move on before it lands, so
    // every check carries a token and a stale one is dropped. Without this a
    // slow verdict for exhibit 2 can arrive over exhibit 3 and label the wrong
    // image as altered, which is the worst thing this feature could do.
    const mine = ++token;
    verdict.textContent = "checking…";
    verdict.setAttribute("class", "lbox-v");
    mediaVerify(it, src, o).then(v => {
      if (mine !== token) return;
      verdict.textContent = MEDIA_VERDICTS[v] || "";
      verdict.setAttribute("class", "lbox-v lbox-" + v);
    });
  }

  function go(d) { const n = at + d; if (n >= 0 && n < items.length) { at = n; show(); } }
  function close() {
    token++;                       // any verdict still in flight is now stale
    if (box.remove) box.remove();
    if (doc.removeEventListener) doc.removeEventListener("keydown", onKey);
    // Focus goes back where it came from, or a reader who opened this from the
    // keyboard is returned to the top of the document.
    if (restore && restore.focus) restore.focus();
    if (o.onClose) o.onClose();
  }
  function onKey(ev) {
    if (ev.key === "Escape") { ev.preventDefault(); close(); }
    else if (ev.key === "ArrowLeft") go(-1);
    else if (ev.key === "ArrowRight") go(1);
  }

  prev.addEventListener("click", () => go(-1));
  next.addEventListener("click", () => go(1));
  shut.addEventListener("click", close);
  // Only the backdrop closes. A click on the picture is how somebody looks at
  // the picture, and closing on it would make the thing they came for the thing
  // that dismisses it.
  box.addEventListener("click", ev => { if (ev.target === box) close(); });
  if (doc.addEventListener) doc.addEventListener("keydown", onKey);
  if (box.focus) box.focus();

  show();
  return {el: box, close, go, at: () => at};
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MEDIA_MAX_ITEMS, MEDIA_MAX_MIRRORS, MEDIA_MAX_URL, MEDIA_MAX_CAPTION,
    MEDIA_MAX_BYTES, MEDIA_TYPES,
    mediaHostAllowed, mediaHostOf, mediaMirrorFault, mediaCaptionFault,
    mediaItemFault, mediaFault, mediaArgLine, mediaArg, mediaArchiveURL,
    mediaDigest, mediaFitWithin, MEDIA_MAX_EDGE, mediaUpload, mediaClaimed,
    mediaEncodeUnder, MEDIA_QUALITIES, mediaBoxRatio, MEDIA_BOX_LIMIT,
    MEDIA_STATES, mediaFileable, mediaNewComposer, mediaReview,
    mediaHelpLinkFits, MEDIA_HELP_LINK_BUDGET, MEDIA_HELP_LINK_TOO_LONG,
    mediaMount, mediaEl, mediaParse, mediaSrc, mediaNodeThumb,
    mediaCardItems, mediaVerify, MEDIA_VERDICTS, mediaLightbox,
    mediaSaveDraft, mediaLoadDraft, mediaClearDraft, mediaDraftKey, mediaDraftOf,
  };
}
