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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MEDIA_MAX_ITEMS, MEDIA_MAX_MIRRORS, MEDIA_MAX_URL, MEDIA_MAX_CAPTION,
    MEDIA_MAX_BYTES, MEDIA_TYPES,
    mediaHostAllowed, mediaHostOf, mediaMirrorFault, mediaCaptionFault,
    mediaItemFault, mediaFault, mediaArgLine, mediaArg, mediaArchiveURL,
    mediaDigest, mediaFitWithin, MEDIA_MAX_EDGE, mediaUpload, mediaClaimed,
    MEDIA_STATES, mediaFileable,
  };
}
