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
  if (!url || url.length > MEDIA_MAX_URL) {
    return `a link is 1–${MEDIA_MAX_URL} characters`;
  }
  if (/[\s"'<>()\\,|`]/.test(url)) {
    return "that link contains a character the court cannot store — try the image's direct URL";
  }
  if (!/^[\x21-\x7e]+$/.test(url)) return "a link is plain ASCII with no spaces";
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

  const res = await fetchFn(base + "/m", {
    method: "POST", headers: {"Content-Type": mime}, body: bytes,
  });
  if (!res.ok) throw new Error("the archive would not take that image (" + res.status + ")");
  const body = await res.json();
  if (body.sha256 !== mine) {
    throw new Error("the archive stored something other than what was sent");
  }
  return {sha256: mine, url: base + "/m/" + mine};
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

  return {
    items, add, addLink, remove, restore, move, setCaption,
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MEDIA_MAX_ITEMS, MEDIA_MAX_MIRRORS, MEDIA_MAX_URL, MEDIA_MAX_CAPTION,
    MEDIA_MAX_BYTES, MEDIA_TYPES,
    mediaHostAllowed, mediaHostOf, mediaMirrorFault, mediaCaptionFault,
    mediaItemFault, mediaFault, mediaArgLine, mediaArg, mediaArchiveURL,
    mediaDigest, mediaFitWithin, MEDIA_MAX_EDGE, mediaUpload, mediaClaimed,
    MEDIA_STATES, mediaFileable, mediaNewComposer, mediaReview,
    mediaHelpLinkFits, MEDIA_HELP_LINK_BUDGET, MEDIA_HELP_LINK_TOO_LONG,
  };
}
