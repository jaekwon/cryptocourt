// Claim media, browser side — and above all, DOES IT AGREE WITH THE CHAIN?
//
// web/media.js exists to refuse what the realm would refuse, while the person
// can still fix it. Every rule in it is a copy of one in media.gno, and a copy
// that drifts is worse than no copy at all: the composer would wave something
// through, the transaction would abort with a realm message written for nobody,
// and the claim cannot be amended afterward because media is fixed at creation.
//
// So most of this file reads media.gno and compares. The rest exercises the
// cases with a consequence.
const fs = require("fs");
const path = require("path");
const M = require(path.join(__dirname, "..", "media.js"));
const gno = fs.readFileSync(
  path.join(__dirname, "..", "..", "realm", "r", "kourtv2", "media.gno"), "utf8");

let fails = 0;
function ok(name, cond, extra) {
  if (cond) { console.log("ok: " + name); return; }
  fails++; console.log("FAIL " + name + (extra ? "  " + extra : ""));
}

// ---- the two sides agree -------------------------------------------------
function gnoConst(name) {
  const m = gno.match(new RegExp(name + "\\s*=\\s*(\\d+)"));
  return m ? parseInt(m[1], 10) : null;
}
ok("item cap matches the realm", M.MEDIA_MAX_ITEMS === gnoConst("maxClaimMediaCount"),
   `js ${M.MEDIA_MAX_ITEMS} vs gno ${gnoConst("maxClaimMediaCount")}`);
ok("mirror cap matches the realm", M.MEDIA_MAX_MIRRORS === gnoConst("maxMirrorsPerItem"));
ok("url length matches the realm", M.MEDIA_MAX_URL === gnoConst("maxMediaURLLen"));
ok("caption length matches the realm", M.MEDIA_MAX_CAPTION === gnoConst("maxCaptionLen"));
ok("byte cap matches the realm", M.MEDIA_MAX_BYTES === gnoConst("maxMediaBytes"));

function gnoList(varName) {
  const start = gno.indexOf("var " + varName + " = []string{");
  if (start < 0) throw new Error("missing " + varName + " in media.gno");
  const end = gno.indexOf("}", start);
  return [...gno.slice(start, end).matchAll(/"([^"]+)"/g)].map(m => m[1]);
}
const gnoExact = gnoList("mediaHostsExact");
const gnoSuffix = gnoList("mediaHostSuffixes");
ok("the exact host list matches the realm",
   JSON.stringify(gnoExact.sort()) === JSON.stringify([...M.MEDIA_HOSTS_EXACT || []].sort())
   || gnoExact.every(h => M.mediaHostAllowed(h, "")),
   "gno: " + gnoExact.join(","));
ok("every suffix the realm allows is allowed here",
   gnoSuffix.every(s => M.mediaHostAllowed("sub" + s, "")), "gno: " + gnoSuffix.join(","));
ok("a suffix the realm does NOT list is refused here", !M.mediaHostAllowed("sub.evil.com", ""));

// ---- the host is what precedes the first / ? # ---------------------------
ok("a path ends the host", M.mediaHostOf("https://i.imgur.com/a.webp") === "i.imgur.com");
ok("a query ends the host", M.mediaHostOf("https://i.imgur.com?v=2") === "i.imgur.com");
ok("a fragment ends the host", M.mediaHostOf("https://evil.example/#i.imgur.com") === "evil.example");
ok("a fragment cannot smuggle a trusted name",
   M.mediaMirrorFault("https://evil.example/#i.imgur.com", "") !== "");
ok("credentials do not make a host trusted",
   M.mediaMirrorFault("https://i.imgur.com@evil.example/a.webp", "") !== "");
ok("the bare suffix is not a host", !M.mediaHostAllowed(".github.io", ""));

// ---- the characters with a consequence -----------------------------------
// A mirror is emitted into ![alt](url), so a ")" inside closes the destination
// early and spills the rest of the URL onto the page as text.
ok("a closing paren is refused", M.mediaMirrorFault("https://i.imgur.com/a).webp", "") !== "");
ok("an opening paren is refused", M.mediaMirrorFault("https://i.imgur.com/a(b.webp", "") !== "");
ok("a comma is refused (it separates mirrors)",
   M.mediaMirrorFault("https://i.imgur.com/a,b.webp", "") !== "");
ok("a bar is refused (it separates fields)",
   M.mediaMirrorFault("https://i.imgur.com/a|b.webp", "") !== "");
ok("http is refused with a reason a person can act on",
   /https/.test(M.mediaMirrorFault("http://i.imgur.com/a.webp", "")));
ok("a good mirror passes", M.mediaMirrorFault("https://i.imgur.com/a.webp", "") === "");
ok("the archive's own host passes once a site is configured",
   M.mediaMirrorFault("https://kourt.xyz/m/" + "a".repeat(64), "kourt.xyz") === "");
ok("...and not before one is",
   M.mediaMirrorFault("https://kourt.xyz/m/" + "a".repeat(64), "") !== "");

// ---- captions ------------------------------------------------------------
ok("an ordinary caption passes", M.mediaCaptionFault("Exhibit A — the email header") === "");
ok("quotes are allowed", M.mediaCaptionFault('the "smoking gun" memo') === "");
ok("a newline is refused", M.mediaCaptionFault("two\nlines") !== "");
ok("a bar is refused", M.mediaCaptionFault("a|b") !== "");
ok("an over-long caption is refused",
   M.mediaCaptionFault("x".repeat(M.MEDIA_MAX_CAPTION + 1)) !== "");

// ---- the argument the chain will parse -----------------------------------
const img = {
  kind: "img", sha256: "b".repeat(64), mime: "image/webp",
  w: 800, h: 600, bytes: 90210, caption: "the memo",
  mirrors: ["https://i.imgur.com/a.webp"],
};
ok("an item is eight fields", M.mediaArgLine(img).split("|").length === 8);
ok("the realm expects eight too", /8 fields separated by \|/.test(gno));
ok("a good item passes", M.mediaItemFault(img, "") === "");
ok("several items are newline separated", M.mediaArg([img, img]).split("\n").length === 2);
ok("an eighth exhibit is refused",
   M.mediaFault(Array(M.MEDIA_MAX_ITEMS + 1).fill(img), "") !== "");
ok("seven are not", M.mediaFault(Array(M.MEDIA_MAX_ITEMS).fill(img), "") === "");

// A message naming no exhibit is useless with seven thumbnails on screen.
const bad = Object.assign({}, img, {mirrors: ["http://i.imgur.com/a.webp"]});
ok("a problem names which exhibit it is about",
   /^exhibit 2:/.test(M.mediaFault([img, bad], "")), M.mediaFault([img, bad], ""));

// ---- video ---------------------------------------------------------------
const vid = {kind: "vid", caption: "the hearing", mirrors: ["https://i.imgur.com/x.webp"]};
ok("a video needs no fingerprint", M.mediaItemFault(vid, "") === "");
ok("a video may not carry one",
   M.mediaItemFault(Object.assign({}, vid, {sha256: "c".repeat(64)}), "") !== "");
ok("an image without one is refused",
   M.mediaItemFault(Object.assign({}, img, {sha256: ""}), "") !== "");

// ---- intake: never say "too big" -----------------------------------------
// A 12MP phone photo must become something fileable without anyone learning
// that a cap exists.
const big = M.mediaFitWithin(4032, 3024, M.MEDIA_MAX_EDGE);
ok("a large photo is scaled to the long edge", big.w === M.MEDIA_MAX_EDGE, JSON.stringify(big));
ok("...keeping its aspect ratio", Math.abs(big.w / big.h - 4032 / 3024) < 0.01);
const tall = M.mediaFitWithin(1000, 4000, M.MEDIA_MAX_EDGE);
ok("a tall image is scaled by its height", tall.h === M.MEDIA_MAX_EDGE);
// UPSCALING WOULD SPEND BYTES INVENTING DETAIL. A 200x100 screenshot must stay
// 200x100, or a tiny image costs more than the memo it shows.
const small = M.mediaFitWithin(200, 100, M.MEDIA_MAX_EDGE);
ok("a small image is left alone", small.w === 200 && small.h === 100, JSON.stringify(small));
ok("a degenerate size does not divide by zero",
   JSON.stringify(M.mediaFitWithin(0, 0, M.MEDIA_MAX_EDGE)) === '{"w":0,"h":0}');

// ---- the archive is not trusted about what it received -------------------
(async () => {
  const bytes = new TextEncoder().encode("some image bytes");
  const mine = await M.mediaDigest(bytes);

  const honest = async () => ({ok: true, json: async () => ({sha256: mine})});
  const got = await M.mediaUpload(bytes, "image/webp", {fetch: honest, base: "https://k"});
  ok("an honest archive yields the item's link", got.url === "https://k/m/" + mine);

  // A MISMATCH MUST BE REFUSED, NOT ADOPTED. If the archive names a different
  // digest, the bytes that arrived are not the bytes we hashed — filing that
  // hash would commit the author to an image nobody has.
  const liar = async () => ({ok: true, json: async () => ({sha256: "f".repeat(64)})});
  let refused = false;
  try { await M.mediaUpload(bytes, "image/webp", {fetch: liar, base: ""}); }
  catch (_) { refused = true; }
  ok("an archive that answers with another digest is refused", refused);

  const down = async () => ({ok: false, status: 503, json: async () => ({})});
  let failed = false;
  try { await M.mediaUpload(bytes, "image/webp", {fetch: down, base: ""}); }
  catch (_) { failed = true; }
  ok("an archive that is down is an error, not a silent success", failed);

  // Promotion is best-effort: the claim is already on chain, so a failure here
  // costs availability rather than the record.
  ok("a failed promotion is not an exception",
     await M.mediaClaimed("covid", 7, {fetch: async () => { throw new Error("nope"); }}) === 0);
  ok("a successful promotion reports the count",
     await M.mediaClaimed("covid", 7, {
       fetch: async () => ({ok: true, json: async () => ({promoted: 3})}),
     }) === 3);

  // A flaky upload must not cost somebody their claim: the hash and the original
  // link are what the chain records, and the archive copy is durability.
  ok("an exhibit whose copy failed is still fileable", M.mediaFileable({state: "failed"}));
  ok("an exhibit still uploading is not", !M.mediaFileable({state: "uploading"}));

// ---- the fingerprint -----------------------------------------------------
  const digest = await M.mediaDigest(new TextEncoder().encode("kourt"));
  ok("a digest is 64 lowercase hex", /^[0-9a-f]{64}$/.test(digest));
  ok("the archive address is derived from it",
     M.mediaArchiveURL("kourt.xyz", digest) === "https://kourt.xyz/m/" + digest);
  ok("and there is no address without a site", M.mediaArchiveURL("", digest) === "");

  console.log(fails ? `\n${fails} FAILURES` : "\nALL PASS");
  process.exit(fails ? 1 : 0);
})();
