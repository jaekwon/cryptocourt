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

let fails = 0, ran = 0;
function ok(name, cond, extra) {
  ran++;
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
// EVERY REFUSAL NAMES ITS OWN CASE. Read together, two of these used to lie: an
// empty box answered with a character-count rule, and the non-ASCII message
// said "no spaces" — a case it can never see, because the charset check takes
// spaces first. A message that describes the wrong problem is worse than a
// generic one, because it sends somebody looking in the wrong place.
ok("an empty link says what to do, not how long a link is",
   /paste the image's link/.test(M.mediaMirrorFault("", "")));
ok("an over-long link says it is too long",
   /too long/.test(M.mediaMirrorFault("https://i.imgur.com/" + "x".repeat(320), "")));
ok("a link with a space is named as text, not as a bad character",
   /looks like text/.test(M.mediaMirrorFault("https://i.imgur.com/a b.webp", "")));
ok("a non-Latin character is named as itself",
   /accented or non-Latin/.test(M.mediaMirrorFault("https://i.imgur.com/caf\u00e9.webp", "")));
ok("...and each of those is a DIFFERENT message",
   new Set(["", "https://i.imgur.com/" + "x".repeat(320), "https://i.imgur.com/a b.webp",
            "https://i.imgur.com/caf\u00e9.webp", "https://i.imgur.com/a).webp"]
     .map(u => M.mediaMirrorFault(u, ""))).size === 5);
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

// COUNTED THE SAME WAY ON BOTH SIDES, and for a while they were not. This side
// counts code points; the realm counted len(s), which is UTF-8 BYTES. An
// ordinary 82-character Russian caption is 152 bytes, so the composer accepted
// it and the transaction aborted saying "a caption is at most 120 characters"
// about a caption of 82 — every non-Latin script hitting the wall at roughly
// half the stated limit, with a message contradicting what the person could
// count. Both sides had only ever been compared on "x".repeat(), where a byte
// and a character are the same thing, which is exactly why it survived.
const cyrillic = "Протокол заседания городского совета от 12 октября";
ok("an ordinary non-Latin caption is accepted", M.mediaCaptionFault(cyrillic) === "",
   `${[...cyrillic].length} chars, ${Buffer.byteLength(cyrillic, "utf8")} bytes`);
ok("...and it is longer in bytes than in characters, so the two rules differ",
   Buffer.byteLength(cyrillic, "utf8") > [...cyrillic].length);
ok("the realm counts characters too, not bytes",
   /for range s\s*\{\s*n\+\+/.test(gno) && !/len\(s\) > maxCaptionLen/.test(gno));
ok("a caption of exactly the cap passes, in any script",
   M.mediaCaptionFault("\u0431".repeat(M.MEDIA_MAX_CAPTION)) === "");
ok("...and one character past it does not",
   M.mediaCaptionFault("\u0431".repeat(M.MEDIA_MAX_CAPTION + 1)) !== "");

// THE DIRECTION CONTROLS. A caption is claim text: permanent, unamendable, and
// printed beside the exhibit number on a page a stranger reads. U+202E reorders
// what follows it, so the rendered line can disagree with the line the chain
// stores — which is the one property a record of evidence exists to have. Both
// sides already said "no control characters" and both checked only the ASCII
// ones; these are three bytes each, so neither ever saw one.
for (const [name, ch] of [["RLO", "\u202E"], ["LRO", "\u202D"], ["RLE", "\u202B"],
                          ["LRE", "\u202A"], ["PDF", "\u202C"], ["LRI", "\u2066"],
                          ["RLI", "\u2067"], ["FSI", "\u2068"], ["PDI", "\u2069"]]) {
  ok(`a caption may not carry ${name}`, M.mediaCaptionFault("the memo " + ch + " x") !== "");
}
ok("the realm refuses the same range", /0x202A && r <= 0x202E/.test(gno)
   && /0x2066 && r <= 0x2069/.test(gno));
// AND ORDINARY RIGHT-TO-LEFT TEXT STILL WORKS. Refusing the marks as well would
// break honest Arabic and Hebrew captions to prevent nothing: they carry no
// override power. If this ever fails, the rule got greedy.
ok("Arabic is not a control character", M.mediaCaptionFault("\u0645\u062d\u0636\u0631 \u0627\u062c\u062a\u0645\u0627\u0639") === "");
ok("Hebrew with a right-to-left MARK is still fine",
   M.mediaCaptionFault("\u200F\u05de\u05e1\u05de\u05da \u05e8\u05e9\u05de\u05d9") === "");

// ---- the argument the chain will parse -----------------------------------
const img = {
  kind: "img", sha256: "b".repeat(64), mime: "image/webp",
  w: 800, h: 600, bytes: 90210, caption: "the memo",
  mirrors: ["https://i.imgur.com/a.webp"],
};
ok("an item is eight fields", M.mediaArgLine(img).split("|").length === 8);
// THE OTHER SIDE HAS THESE EXACT STRINGS. realm/r/kourtv2/media_test.gno holds
// them as clientImageLine and clientVideoLine and asserts its parser accepts
// them. Until that existed, both sides were written to the same spec and
// checked against the spec rather than against each other — which proves the
// spec is self-consistent and nothing about whether they agree.
const asFiledImage = M.mediaArgLine({
  kind: "img", sha256: "1".repeat(64), mime: "image/webp", w: 800, h: 600,
  bytes: 90210, caption: "the memo", mirrors: ["https://i.imgur.com/abc.webp"]});
const asFiledVideo = M.mediaArgLine({
  kind: "vid", caption: "the hearing", mirrors: ["https://i.imgur.com/v.mp4"]});
ok("the image line is the one the realm test holds",
   asFiledImage === "img|" + "1".repeat(64) +
     "|image/webp|800|600|90210|the memo|https://i.imgur.com/abc.webp", asFiledImage);
// A video carries no hash, type or dimensions, so this line is mostly empty —
// and the realm reads those blanks as zero. If either side stops agreeing about
// that, one of these two tests fails.
ok("the video line is the one the realm test holds",
   asFiledVideo === "vid|||0|0|0|the hearing|https://i.imgur.com/v.mp4", asFiledVideo);
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
async function section1() {
  const bytes = new TextEncoder().encode("some image bytes");
  const mine = await M.mediaDigest(bytes);

  // ---- the resize policy, without a canvas -------------------------------
  // THE CHEAPEST ACCEPTABLE ANSWER WINS. Stopping at the first size under the
  // cap spends the fewest bytes that still show what the exhibit shows; picking
  // the smallest would throw away detail somebody may need to read a document
  // in a photograph.
  const tried = [];
  const encoder = sizes => q => { tried.push(q); return Promise.resolve({size: sizes[q]}); };

  let enc = await M.mediaEncodeUnder(encoder({0.82: 300, 0.7: 90, 0.6: 40, 0.5: 20}), 100);
  ok("the first quality that fits is kept", enc.quality === 0.7 && enc.blob.size === 90);
  ok("...and nothing below it is tried", tried.join(",") === "0.82,0.7", tried.join(","));

  tried.length = 0;
  enc = await M.mediaEncodeUnder(encoder({0.82: 50, 0.7: 10, 0.6: 5, 0.5: 1}), 100);
  ok("an image that already fits is not degraded", enc.quality === 0.82);
  ok("...with exactly one attempt", tried.length === 1);

  // Equal to the cap is under it: a boundary that refused here would reject an
  // image the archive would have accepted.
  enc = await M.mediaEncodeUnder(encoder({0.82: 100}), 100, [0.82]);
  ok("a size exactly at the cap is accepted", enc.quality === 0.82);

  let gaveUp = false;
  try { await M.mediaEncodeUnder(encoder({0.82: 9e6, 0.7: 9e6, 0.6: 9e6, 0.5: 9e6}), 100); }
  catch (e) { gaveUp = /compress small enough/.test(e.message); }
  ok("an image that will never fit says so", gaveUp);

  // A browser that cannot encode at all answers null, and trying lower
  // qualities of nothing is a slower way to fail.
  tried.length = 0;
  let broke = false;
  try { await M.mediaEncodeUnder(q => { tried.push(q); return Promise.resolve(null); }, 100); }
  catch (_) { broke = true; }
  ok("an encoder that returns nothing stops immediately", broke && tried.length === 1,
     tried.join(","));

  const honest = async () => ({ok: true, json: async () => ({sha256: mine})});
  const got = await M.mediaUpload(bytes, "image/webp", {fetch: honest, base: "https://k"});
  ok("an honest archive yields the item's link", got.url === "https://k/m/" + mine);

  // THE ADDRESS COMES FROM THE ARCHIVE, not from a second place that has to
  // agree with it. The service returns one saying in as many words that it does
  // so "so the composer never has to build it, and so this stays the one place
  // that knows the shape" — and this built its own anyway. Two places that must
  // agree about a path is one place too many.
  const moved = async () => ({ok: true, json: async () => ({sha256: mine, url: "/blobs/" + mine})});
  const m2 = await M.mediaUpload(bytes, "image/webp", {fetch: moved, base: "https://k"});
  ok("a moved archive is followed rather than second-guessed",
     m2.url === "https://k/blobs/" + mine, m2.url);
  const absolute = async () => ({ok: true, json: async () => ({sha256: mine, url: "https://cdn.example/x"})});
  ok("an absolute address is used as given",
     (await M.mediaUpload(bytes, "image/webp", {fetch: absolute, base: "https://k"})).url
       === "https://cdn.example/x");
  const silent = async () => ({ok: true, json: async () => ({sha256: mine})});
  ok("a service too old to answer with one still works",
     (await M.mediaUpload(bytes, "image/webp", {fetch: silent, base: "https://k"})).url
       === "https://k/m/" + mine);

  // A MISMATCH MUST BE REFUSED, NOT ADOPTED. If the archive names a different
  // digest, the bytes that arrived are not the bytes we hashed — filing that
  // hash would commit the author to an image nobody has.
  const liar = async () => ({ok: true, json: async () => ({sha256: "f".repeat(64)})});
  let refused = false;
  try { await M.mediaUpload(bytes, "image/webp", {fetch: liar, base: ""}); }
  catch (_) { refused = true; }
  ok("an archive that answers with another digest is refused", refused);

  // THE COURT HINT MUST REACH THE ARCHIVE. Without it backfill has no thread
  // back to these bytes, and a tab closed before broadcast loses them — which
  // is the whole reason backfill exists.
  let seen = "";
  await M.mediaUpload(bytes, "image/webp", {
    court: "covid", base: "",
    // The stub answers with a usable address because mediaUpload now refuses one
    // it could not turn into a filable mirror. The subject here is the REQUEST
    // url, which base:"" keeps readable.
    fetch: async (url) => { seen = url;
      return {ok: true, json: async () => ({sha256: mine, url: "https://k/m/" + mine})}; },
  });
  ok("the upload carries the court", /\/m\?court=covid$/.test(seen), seen);
  await M.mediaUpload(bytes, "image/webp", {
    base: "", fetch: async (url) => { seen = url;
      return {ok: true, json: async () => ({sha256: mine, url: "https://k/m/" + mine})}; },
  });
  ok("...and omits it cleanly when there is none", seen === "/m", seen);
  // Encoded on BOTH paths. An ablation of the promotion path's encoding was
  // caught while the upload path's was not, because only one of them had an
  // assertion — the same rule tested in one place and assumed in the other.
  await M.mediaUpload(bytes, "image/webp", {
    court: "a b&x=1", base: "",
    fetch: async (url) => { seen = url;
      return {ok: true, json: async () => ({sha256: mine, url: "https://k/m/" + mine})}; },
  });
  ok("the upload encodes its court too", seen === "/m?court=a%20b%26x%3D1", seen);

  const down = async () => ({ok: false, status: 503, json: async () => ({})});
  let failed = false;
  try { await M.mediaUpload(bytes, "image/webp", {fetch: down, base: ""}); }
  catch (_) { failed = true; }
  ok("an archive that is down is an error, not a silent success", failed);

  // Promotion is best-effort: the claim is already on chain, so a failure here
  // costs availability rather than the record.
  ok("a failed promotion is not an exception",
     await M.mediaClaimed("covid", 7, {fetch: async () => { throw new Error("nope"); }}) === 0);
  // THE PROMOTION CALL, PINNED AS A STRING. internal/archive holds this exact
  // path as clientClaimedPath and its handler parses those parameter names. If
  // the overlay sent ?slug= or ?id=, promotion would quietly do nothing —
  // mediaClaimed swallows failures on purpose, because by then the claim is
  // already on chain — and the bytes would expire with nobody told.
  let claimedURL = "";
  await M.mediaClaimed("covid", 7, {
    base: "https://k",
    fetch: async (u) => { claimedURL = u; return {ok: true, json: async () => ({promoted: 1})}; },
  });
  ok("the promotion call is the one the archive parses",
     claimedURL === "https://k/m/claimed?court=covid&claim=7", claimedURL);
  // A court slug is percent-encoded, so an odd one cannot rewrite the query.
  await M.mediaClaimed("a b&claim=9", 1, {
    base: "", fetch: async (u) => { claimedURL = u; return {ok: true, json: async () => ({})}; },
  });
  ok("a hostile court name cannot forge a second parameter",
     claimedURL === "/m/claimed?court=a%20b%26claim%3D9&claim=1", claimedURL);

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

}

// ---- the composer --------------------------------------------------------
async function section2() {
  // Injected so the composer's behaviour is testable without a canvas or a
  // network — and so a browser that fails at either still has a composer.
  const prepared = new TextEncoder().encode("resized bytes");
  function newComposer(over) {
    return M.mediaNewComposer(Object.assign({
      siteDomain: "kourt.xyz",
      previewURL: () => "blob:preview",
      prepare: async () => ({mime: "image/webp", w: 800, h: 600, bytes: prepared}),
      upload: async (bytes, mime, sum) => ({sha256: sum, url: "https://kourt.xyz/m/" + sum}),
    }, over || {}));
  }
  const settle = () => new Promise(r => setTimeout(r, 0));

  // AN EXHIBIT APPEARS THE INSTANT IT IS DROPPED. Making somebody watch a blank
  // panel while a 12MP photo is resized is the same wait dressed as a failure.
  let c = newComposer();
  const added = c.add({name: "shot.png"});
  ok("an exhibit exists before any slow work", c.count() === 1 && !!added.item);
  ok("...with a local preview to show immediately", added.item.preview === "blob:preview");
  ok("...and it is not yet fileable", !M.mediaFileable(added.item));
  await settle(); await settle(); await settle();
  ok("once the copy is made it is ready", c.items[0].state === "ready", c.items[0].state);
  ok("and the chain would accept it", c.fault() === "", c.fault());

  // A FLAKY UPLOAD MUST NOT COST SOMEBODY THEIR CLAIM — and this used to assert
  // only the mechanism it expected, never the outcome it is named for. It
  // checked that the item was "failed" and that mediaFileable said yes, and both
  // were true; it never asked c.fault(), which is what decides whether anything
  // can be signed. A dropped file's only mirror IS the archive copy, so the
  // fileable item went into the argument with no link and mediaItemFault refused
  // the lot: "exhibit 1: this exhibit has no link yet". The claim was blocked by
  // the very case this header says must never block it.
  c = newComposer({upload: async () => { throw new Error("archive down"); }});
  c.add({name: "shot.png"});
  await settle(); await settle(); await settle();
  ok("a failed copy still lets the claim be signed", c.fault() === "", c.fault());
  ok("...the exhibit is what is lost, not the claim", c.items[0].state === "broken");
  ok("...and it says how to get it back",
     /try adding it again/.test(c.items[0].error || ""), JSON.stringify(c.items[0].error));

  // An exhibit that never got a fingerprint is NOT fileable: there is nothing
  // to file, and offering it would put a claim on chain pointing at nothing.
  c = newComposer({prepare: async () => { throw new Error("cannot read that file"); }});
  c.add({name: "weird.tiff"});
  await settle(); await settle();
  ok("an exhibit that could not be read is not fileable", !M.mediaFileable(c.items[0]));

  // ---- the four things a person does -------------------------------------
  c = newComposer();
  const a = c.add({name: "a"}).item, b = c.add({name: "b"}).item;
  await settle(); await settle(); await settle();
  ok("order can be changed", c.move(b.id, -1) && c.items[0].id === b.id);
  ok("...and cannot run off the end", !c.move(c.items[0].id, -1));
  ok("a caption reports its own fault", c.setCaption(a.id, "x|y") !== "");
  ok("a good caption does not", c.setCaption(a.id, "the memo") === "");
  const gone = c.remove(a.id);
  ok("removing returns the exhibit so it can be undone", !!gone && c.count() === 1);
  c.restore(gone, 0);
  ok("...and restoring puts it back where it was", c.items[0].id === a.id && c.count() === 2);

  // The seventh is fine; the eighth is refused with a reason, not silently.
  c = newComposer();
  for (let i = 0; i < M.MEDIA_MAX_ITEMS; i++) c.add({name: "x"});
  ok("seven exhibits are allowed", c.count() === M.MEDIA_MAX_ITEMS);
  ok("the eighth is refused with a reason", !!c.add({name: "x"}).error);

  // ---- a pasted link -----------------------------------------------------
  c = newComposer();
  ok("a bad link is refused", !!c.addLink("http://i.imgur.com/a.webp").error);
  const link = c.addLink("https://i.imgur.com/a.webp");
  ok("a good link is adopted", !!link.item && link.item.mirrors.length === 1);
  // It cannot be fingerprinted — reading a cross-origin image is exactly what
  // CORS refuses — so it must not pretend to a verification nobody performed.
  ok("...as a link, with no fingerprint", !link.item.sha256 && link.item.linkOnly);

  // ---- the last look -----------------------------------------------------
  // THE "NO COPY YET" WARNING NEEDS AN EXHIBIT THAT REALLY IS STILL FILED.
  // This used to drop a file and fail its upload, which no longer produces one:
  // a dropped file's only mirror IS the archive copy, so that case now ends
  // broken and out of the review entirely. An ADOPTED LINK whose copy failed
  // keeps the pasted address, so it is filed without a copy — which is the
  // situation the warning describes, and now the only one that reaches it.
  c = newComposer({
    fetch: async () => ({ok: true, blob: async () => prepared}),
    upload: async () => { throw new Error("down"); },
  });
  c.addLink("https://i.imgur.com/a.webp", "img");
  c.addLink("https://i.imgur.com/v.webp", "vid");
  await settle(); await settle(); await settle(); await settle();
  const rv = M.mediaReview(c.items);
  ok("the review numbers every exhibit", rv.lines.length === 2 && rv.lines[1].n === 2);
  ok("it says captions are permanent", /cannot be edited/.test(rv.permanent));
  ok("it warns that a copy is missing", rv.warnings.some(w => /no copy/.test(w)));
  ok("it warns a video cannot be vouched for", rv.warnings.some(w => /cannot vouch/.test(w)));

  // ---- the one affordance with a length limit ----------------------------
  // Measured against nginx's 8 KB default header buffer, not guessed. A typical
  // claim fits; the worst case the validator permits does not, and a request
  // refused by a proxy tells the person nothing.
  const twoMirror = {
    kind: "img", sha256: "a".repeat(64), mime: "image/webp", w: 1600, h: 1200,
    bytes: 250000, caption: "x".repeat(M.MEDIA_MAX_CAPTION),
    mirrors: ["https://kourt.xyz/m/" + "a".repeat(64), "https://i.imgur.com/b.webp"],
  };
  const maxURL = "https://i.imgur.com/" + "b".repeat(M.MEDIA_MAX_URL - 25) + ".webp";
  const fourMirror = Object.assign({}, twoMirror, {mirrors: [maxURL, maxURL, maxURL, maxURL]});

  ok("a typical seven-exhibit claim still fits the gnoweb form",
     M.mediaHelpLinkFits(M.mediaArg(Array(7).fill(twoMirror))),
     String(encodeURIComponent(M.mediaArg(Array(7).fill(twoMirror))).length));
  ok("the worst case the validator permits does not",
     !M.mediaHelpLinkFits(M.mediaArg(Array(7).fill(fourMirror))));
  ok("no media always fits", M.mediaHelpLinkFits(""));
  // "This does not work" without "this does" is the shape of every unhelpful
  // error, so the message names the two paths that still carry the claim.
  ok("the refusal names what still works",
     /Adena/.test(M.MEDIA_HELP_LINK_TOO_LONG) && /command line/.test(M.MEDIA_HELP_LINK_TOO_LONG));
  // The budget must stay under nginx's default buffer with room for the rest of
  // the request line — the path, the function, the title and the body.
  ok("the budget leaves room for the rest of the request",
     M.MEDIA_HELP_LINK_BUDGET < 8192 * 0.8, String(M.MEDIA_HELP_LINK_BUDGET));

}

// ---- reading a claim's evidence back -------------------------------------
async function section3() {
  const SITE = "kourt.xyz";
  const hash = "d".repeat(64);
  const img = {kind: "img", sha256: hash, mime: "image/webp", w: 800, h: 600,
               bytes: 12, caption: "the memo",
               mirrors: ["https://i.imgur.com/a.webp"]};

  ok("a realm with no media reads as none", M.mediaParse("").length === 0);
  ok("garbage reads as none, never as a broken map", M.mediaParse("{not json").length === 0);
  ok("a real payload parses", M.mediaParse(JSON.stringify([img])).length === 1);

  // THE BYTES A NODE ACTUALLY SENT. Everything above feeds mediaParse an object
  // this file made and stringified — which checks JSON.parse, not the agreement
  // between two programs. This payload was captured from the realm answering
  // ClaimMedia over RPC in gnoland/testdata/kourtv2_media.txtar, and the realm
  // suite asserts encodeMedia still produces exactly it.
  const fromChain = '[{"kind":"img","sha256":"' + "1".repeat(64) + '","mime":"image/webp"' +
    ',"w":800,"h":600,"bytes":90210,"caption":"the memo"' +
    ',"mirrors":["https://i.imgur.com/abc.webp"]}]';
  const parsed = M.mediaParse(fromChain);
  ok("the realm's own output parses", parsed.length === 1);
  ok("...with every field the page needs",
     parsed[0].kind === "img" && parsed[0].w === 800 && parsed[0].bytes === 90210 &&
     parsed[0].caption === "the memo" && parsed[0].mirrors.length === 1,
     JSON.stringify(parsed[0]));
  ok("...and reaches the card numbered and captioned",
     M.mediaCardItems(parsed, "kourt.xyz")[0].label === "1 of 1" &&
     M.mediaCardItems(parsed, "kourt.xyz")[0].caption === "the memo");
  ok("...pointing at the archive rather than the filer's mirror",
     M.mediaNodeThumb(parsed, "kourt.xyz") === "https://kourt.xyz/m/" + "1".repeat(64));

  // A TOMBSTONED SLOT, in the shape the realm writes it. The page must show the
  // gap rather than renumber around it, and it can only do that if it reads the
  // marker the realm actually emits.
  const withGap = M.mediaParse('[{"kind":"img","purged":true},{"kind":"img","sha256":"' +
    "2".repeat(64) + '","mime":"image/webp","w":8,"h":6,"bytes":9,"caption":"kept","mirrors":[]}]');
  const gapCards = M.mediaCardItems(withGap, "kourt.xyz");
  ok("a purged slot keeps its position",
     gapCards[0].label === "1 of 2" && gapCards[0].note === "taken down");
  ok("...and the one after it keeps its number",
     gapCards[1].label === "2 of 2" && gapCards[1].caption === "kept");

  // THE MAP MUST NEVER FAN OUT TO FILER-CHOSEN HOSTS. Fifty nodes on one draw
  // is fifty readers' addresses sent wherever an attacker liked.
  ok("a node thumbnail uses the archive", M.mediaNodeThumb([img], SITE) === "https://kourt.xyz/m/" + hash);
  ok("a node thumbnail NEVER uses a mirror", M.mediaNodeThumb([img], "") === "");
  ok("a purged exhibit is not a thumbnail", M.mediaNodeThumb([{purged: true, kind: "img", sha256: hash}], SITE) === "");
  ok("a video is never a thumbnail", M.mediaNodeThumb([{kind: "vid", mirrors: ["https://i.imgur.com/v.webp"]}], SITE) === "");
  // The first exhibit with something to show wins, skipping ones that have not.
  ok("the first showable exhibit wins",
     M.mediaNodeThumb([{kind: "vid", mirrors: []}, img], SITE).endsWith(hash));

  // BYTES IN THE PAGE NEED NO HOST — the offline demo's only way to show an
  // exhibit, since a real one resolves to the archive and demo mode is promised
  // to make no network calls. Checked with NO site domain, which is the demo's
  // own configuration: everything else returns "" there.
  const inline = {kind: "img", sha256: hash, inline: "data:image/png;base64,AAAA"};
  ok("carried bytes are the source, with no site to point at",
     M.mediaSrc(inline, "", false) === "data:image/png;base64,AAAA");
  ok("...and they win over the archive when both exist",
     M.mediaSrc(inline, SITE, false) === "data:image/png;base64,AAAA");
  ok("a node thumbnail draws carried bytes", M.mediaNodeThumb([inline], "") === inline.inline);
  // The restriction is what keeps "no network calls" true BY CONSTRUCTION rather
  // than by trusting that nothing on chain can set the field. A data: URI cannot
  // name a host; anything else can, so anything else is ignored.
  ok("a non-data inline is refused and cannot smuggle in a host",
     M.mediaSrc({kind: "img", inline: "https://evil.example/x.png"}, "", true) === "");
  ok("a purged exhibit shows nothing even carrying bytes",
     M.mediaSrc({...inline, purged: true}, "", false) === "");

  // A DECLARED RATIO IS ATTACKER INPUT. w and h are numbers the filer put in the
  // transaction and nothing verifies them against the image; the realm bounds
  // each to maxMediaDim and says nothing about the ratio between them. Declaring
  // 1x20000 reserved a box measured in a browser at 40,000px tall and 2px wide,
  // and media is fixed at creation — so the claim page stayed that way until a
  // global-DAO purge, a takedown built for illegal content spent on a layout
  // attack.
  ok("an ordinary document reserves its own box", M.mediaBoxRatio(240, 160) === "240/160");
  ok("a portrait exhibit reserves its own box", M.mediaBoxRatio(600, 900) === "600/900");
  // THE CASE THE CAP MUST NOT BREAK. A screenshot of a long chat log genuinely is
  // many times taller than it is wide; refusing it would trade a rare attack for
  // a jumping page on ordinary evidence.
  ok("a long screenshot is still ordinary evidence", M.mediaBoxRatio(800, 6000) === "800/6000");
  ok("a ratio past the limit reserves nothing", M.mediaBoxRatio(1, 20000) === "");
  ok("...in either direction", M.mediaBoxRatio(20000, 1) === "");
  ok("...and the limit itself is allowed",
     M.mediaBoxRatio(100, 100 * M.MEDIA_BOX_LIMIT) !== "");
  ok("...while one step past it is not",
     M.mediaBoxRatio(100, 100 * M.MEDIA_BOX_LIMIT + 1) === "");
  // Zero and absent were already refused; pinned so the guard above cannot be
  // rewritten into one that divides by zero.
  ok("an undeclared size reserves nothing", M.mediaBoxRatio(0, 0) === "");
  ok("...and a half-declared one does not either", M.mediaBoxRatio(800, 0) === "");

  // A card is one image the reader asked for, so a mirror is worth it there.
  const card = M.mediaCardItems([img, {purged: true, kind: "img"},
                                 {kind: "vid", caption: "hearing", mirrors: ["https://i.imgur.com/v.webp"]}], "");
  ok("a card falls back to a mirror", card[0].src === "https://i.imgur.com/a.webp");
  ok("every card exhibit is numbered", card.map(c => c.label).join("|") === "1 of 3|2 of 3|3 of 3");
  ok("a purged exhibit keeps its place and says so", card[1].note === "taken down" && !card[1].src);
  ok("a video says it is not verified", /not verified/.test(card[2].note));

  // ---- verification ------------------------------------------------------
  const bytes = new TextEncoder().encode("kourt-bytes");
  const real = await M.mediaDigest(bytes);
  const item = {kind: "img", sha256: real, bytes: bytes.length};
  const serve = b => async () => ({ok: true, arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)});

  ok("matching bytes verify", await M.mediaVerify(item, "/m/x", {fetch: serve(bytes)}) === "matches");
  const other = new TextEncoder().encode("swapped-bytes!");
  ok("swapped bytes are reported as altered",
     await M.mediaVerify(item, "/m/x", {fetch: serve(other)}) === "altered");
  ok("a host that will not answer is unavailable",
     await M.mediaVerify(item, "/m/x", {fetch: async () => { throw new Error("no"); }}) === "unavailable");
  ok("a video cannot be verified and says so",
     await M.mediaVerify({kind: "vid"}, "https://x", {fetch: serve(bytes)}) === "unverifiable");
  // A HOSTILE MIRROR IS REFUSED BEFORE ITS BODY IS READ. The hash would catch
  // the bytes anyway, so this cannot change a verdict — it exists so reaching
  // that verdict does not mean pulling a hundred megabytes into memory. Pinned
  // by counting whether the body was ever touched.
  let read = false;
  const huge = {
    ok: true,
    headers: {get: h => (h === "content-length" ? "99999999" : null)},
    arrayBuffer: async () => { read = true; return new ArrayBuffer(8); },
  };
  ok("a mirror declaring more than it filed is refused",
     await M.mediaVerify(item, "/m/x", {fetch: async () => huge}) === "altered");
  ok("...without reading its body", !read);
  // A SAMPLE MUST NOT PASS A CHECK NOBODY PERFORMED. fetch() resolves a data:
  // URI perfectly well, so the offline demo's exhibit would otherwise hash its
  // own embedded bytes, agree with its own digest, and print "matches what was
  // filed" — a verdict about an ARCHIVE, for an exhibit no archive has seen and
  // no chain has recorded. Served the MATCHING bytes on purpose: without the
  // guard this assertion reads "matches", so it fails when the guard is removed
  // rather than passing for the wrong reason.
  ok("bytes carried in the page are never reported as verified",
     await M.mediaVerify({...item, inline: "data:image/png;base64,AAAA"}, "/m/x",
                         {fetch: serve(bytes)}) === "sample");
  ok("...and the verdict says there was nothing to check it against",
     /nothing to check it against/.test(M.MEDIA_VERDICTS.sample));
  // The altered verdict is the whole feature: it must be a sentence, not a mark.
  ok("the altered verdict is impossible to miss",
     M.MEDIA_VERDICTS.altered.length > 20 && /NO LONGER MATCHES/.test(M.MEDIA_VERDICTS.altered));

  // ---- drafts ------------------------------------------------------------
  // The work being protected is somebody writing out what they believe and why.
  // Losing it is the kind of thing people do not come back from.
  function fakeStore() {
    const m = new Map();
    return {getItem: k => (m.has(k) ? m.get(k) : null),
            setItem: (k, v) => m.set(k, String(v)),
            removeItem: k => m.delete(k), size: () => m.size};
  }

  const live = [
    {id: 1, kind: "img", sha256: "a".repeat(64), mime: "image/webp", w: 8, h: 6,
     bytes: 12, caption: "the memo", mirrors: ["https://kourt.xyz/m/" + "a".repeat(64)],
     preview: "blob:gone-on-reload", state: "ready"},
    {id: 2, kind: "img", sha256: "b".repeat(64), mime: "image/webp", w: 8, h: 6,
     bytes: 12, caption: "", mirrors: [], preview: "blob:also-gone", state: "failed"},
    {id: 3, kind: "img", state: "uploading"},   // not fileable yet
  ];

  let store = fakeStore();
  M.mediaSaveDraft(store, "covid", "a title", "a body", live);
  const back = M.mediaLoadDraft(store, "covid");
  ok("a draft comes back", !!back && back.title === "a title" && back.body === "a body");
  // An exhibit still uploading has nothing worth remembering: its bytes may
  // never have reached the archive.
  ok("only fileable exhibits are kept", back.items.length === 2);

  // A blob: URL is DEAD after a reload. Storing one would restore an exhibit
  // whose thumbnail is a broken image; the archive copy survived and is what
  // can actually be shown.
  ok("the preview is the archive copy, not the dead blob URL",
     back.items[0].preview === "https://kourt.xyz/m/" + "a".repeat(64));
  ok("an exhibit with nowhere to be found has no preview", back.items[1].preview === "");
  // State is re-derived, because after a reload the only honest source is what
  // the item actually has.
  ok("an exhibit with a copy is ready", back.items[0].state === "ready");
  // AND ONE WITH NOWHERE TO BE FOUND CANNOT BE FILED, so it must not come back
  // in a state that says it can. This restored as "failed", which is fileable,
  // so a draft written while a mirrorless exhibit still counted as fileable
  // restored into a claim that could not be signed — "this exhibit has no link
  // yet" — and drafts sit in localStorage indefinitely, so that is not a window
  // that closes on its own.
  ok("...and one without comes back broken, not filed", back.items[1].state === "broken");
  ok("...saying how to get it back",
     /try adding it again/.test(back.items[1].error || ""), JSON.stringify(back.items[1].error));
  ok("restored ids cannot collide with live ones", back.items.every(i => i.id < 0));
  ok("the exhibit that has a copy is fileable", M.mediaFileable(back.items[0]));
  // The property that matters about a restore, rather than the state it picked:
  // whatever comes back, the claim can still be signed.
  const restored = M.mediaNewComposer({siteDomain: "kourt.xyz"});
  restored.seed(back.items);
  ok("...and a restored draft never blocks the claim", restored.fault() === "",
     JSON.stringify(restored.fault()));

  // Drafts are per court: writing one must not overwrite another court's.
  M.mediaSaveDraft(store, "other", "elsewhere", "", []);
  ok("drafts are kept per court", M.mediaLoadDraft(store, "covid").title === "a title");

  // AN EMPTY DRAFT IS A DELETION. Leaving one behind greets the next person
  // with a blank form they have to dismiss.
  M.mediaSaveDraft(store, "covid", "", "", []);
  ok("emptying the composer clears the draft", M.mediaLoadDraft(store, "covid") === null);
  M.mediaClearDraft(store, "other");
  ok("clearing removes it", M.mediaLoadDraft(store, "other") === null);

  // A draft is a convenience and must never be load-bearing.
  const broken = {getItem: () => { throw new Error("blocked"); },
                  setItem: () => { throw new Error("full"); }, removeItem: () => {}};
  ok("a storage that refuses to write does not throw",
     M.mediaSaveDraft(broken, "covid", "t", "b", live) === false);
  ok("a storage that refuses to read yields no draft",
     M.mediaLoadDraft(broken, "covid") === null);
  ok("no storage at all is fine", M.mediaLoadDraft(null, "covid") === null);
  store = fakeStore();
  store.setItem(M.mediaDraftKey("covid"), "{not json");
  ok("a corrupt draft is ignored rather than thrown", M.mediaLoadDraft(store, "covid") === null);
  store.setItem(M.mediaDraftKey("covid"), JSON.stringify({v: 99, items: []}));
  ok("a draft from a future version is ignored", M.mediaLoadDraft(store, "covid") === null);

}

/* SEQUENTIAL, AND THIS IS NOT A STYLE CHOICE. These sections used to be three
   concurrent IIFEs, and the last one called process.exit when it finished —
   killing the process while the others still had awaits pending. 39 of 132
   assertions never ran, and the harness printed ALL PASS because `fails` was
   still zero when it died. A suite that reports success for tests it did not
   run is worse than one that does not run them.

   The count below is the guard against it happening again: if a section stops
   being awaited, or exits early, the number drops and this says so. */

/* A composer with the browser bits faked. mediaNewComposer takes prepare/upload
   as options precisely so this is possible without a DOM. */
function mediaNewComposerFor(opts) {
  return M.mediaNewComposer(Object.assign({siteDomain: "kourt.xyz"}, opts));
}

/* ---- a pasted link that the host lets us read ---------------------------
 *
 * §2.1's fourth intake path. The difference to a reader is the whole point: a
 * link-only exhibit is one the court keeps no copy of and can never check
 * again, and a fetched one has a fingerprint, an archive copy and a verdict in
 * the lightbox. Plenty of allowed hosts do send the header that permits this
 * (i.imgur.com, raw.githubusercontent.com) and plenty do not, so all three
 * outcomes are pinned — including the one where nothing improves.
 */
async function section4() {
  const png = new Uint8Array([1, 2, 3, 4, 5]);
  const fakePrepare = async () => ({mime: "image/webp", w: 800, h: 600, bytes: png});
  const settle = async c => {
    for (let i = 0; i < 50; i++) {
      if (c.items.every(x => x.state === "ready" || x.state === "failed")) return c.items;
      await new Promise(r => setTimeout(r, 5));
    }
    return c.items;
  };

  // 1. the host allows it: the link becomes a real exhibit
  const good = mediaNewComposerFor({
    fetch: async () => ({ok: true, blob: async () => png}),
    prepare: fakePrepare,
    upload: async () => ({sha256: "x", url: "https://kourt.xyz/m/" + "a".repeat(64)}),
  });
  good.addLink("https://i.imgur.com/a.webp", "img");
  let it = (await settle(good))[0];
  ok("a readable link becomes a fingerprinted exhibit", /^[0-9a-f]{64}$/.test(it.sha256 || ""),
     JSON.stringify(it.sha256));
  ok("...no longer marked link-only", it.linkOnly === false);
  ok("...with the archive first and the original kept behind it",
     it.mirrors.length === 2 && it.mirrors[0].includes("/m/") &&
     it.mirrors[1] === "https://i.imgur.com/a.webp", JSON.stringify(it.mirrors));
  ok("...and it is fileable", M.mediaItemFault(it, "kourt.xyz") === "",
     M.mediaItemFault(it, "kourt.xyz"));

  // 2. the host refuses: exactly what happened before, plus a sentence with a fix
  const refused = mediaNewComposerFor({
    fetch: async () => { throw new TypeError("Failed to fetch"); },
    prepare: fakePrepare,
    upload: async () => ({sha256: "x", url: "u"}),
  });
  refused.addLink("https://i.imgur.com/b.webp", "img");
  it = (await settle(refused))[0];
  // AND THIS IS WHY THE FETCH IS LOAD-BEARING RATHER THAN AN IMPROVEMENT. A
  // pasted image link used to be kept the way a video link is, marked "the
  // court keeps no copy" — but the realm requires 64 hex characters of sha256
  // for every image and lets only a video go without one. So the row sat there
  // looking filed while composer.fault() said "this image has no fingerprint
  // yet" and the claim could not be signed at all: a message about a
  // fingerprint, to somebody with no way to make one, about an exhibit they had
  // been shown as accepted.
  ok("a host that refuses ends the exhibit rather than filing an unfilable one",
     it.state === "broken", it.state);
  ok("...with no invented fingerprint", !it.sha256);
  ok("...and the one action that works", /drop it in/.test(it.error || ""),
     JSON.stringify(it.error));
  ok("...and it is not a link exhibit, which only a video can be", !it.linkOnly);
  ok("...and it blocks nothing: a broken row is not fileable", !M.mediaFileable(it));

  // 3. read but not copied — a fingerprint with no archive copy still beats a link
  const nocopy = mediaNewComposerFor({
    fetch: async () => ({ok: true, blob: async () => png}),
    prepare: fakePrepare,
    upload: async () => { throw new Error("archive down"); },
  });
  nocopy.addLink("https://i.imgur.com/c.webp", "img");
  it = (await settle(nocopy))[0];
  ok("a failed copy keeps the fingerprint", /^[0-9a-f]{64}$/.test(it.sha256 || ""));
  ok("...and the original link to check it against",
     it.mirrors[0] === "https://i.imgur.com/c.webp", JSON.stringify(it.mirrors));
  ok("...and says the copy is what is missing", it.state === "failed");

  // 5. THE ARCHIVE IS DOWN AND A FILE WAS DROPPED IN.
  //
  // A dropped file's only mirror is the archive copy, so a failed upload leaves
  // it with a fingerprint and no link. That used to stay "failed", which is
  // fileable, so it went into the argument and mediaItemFault refused it with
  // "this exhibit has no link yet" — while the composer displayed
  // MEDIA_STATES.failed, "no copy yet — it will still be filed". Promised, then
  // blocked, by a message about a link nobody had been asked for. The chain
  // requires a mirror per exhibit and the bytes exist only in the tab, so there
  // is genuinely nothing to file: it is broken, it blocks nothing, and it says
  // the two things that work.
  const noCopy = mediaNewComposerFor({
    prepare: fakePrepare,
    upload: async () => { throw new Error("archive down"); },
  });
  noCopy.add({name: "photo.png"});
  it = (await settle(noCopy))[0];
  ok("a dropped file whose copy fails does not block the claim",
     noCopy.fault() === "", JSON.stringify(noCopy.fault()));
  ok("...it is broken rather than filed without a link", it.state === "broken");
  ok("...and is left out of the argument", noCopy.argument() === "");
  ok("...saying both things that would work",
     /try adding it again/.test(it.error || "") && /paste the image's own link/.test(it.error || ""),
     JSON.stringify(it.error));

  // AND THE STATE THAT PROMISES FILING IS NOW ONLY REACHED WHEN THAT IS TRUE.
  // An adopted link keeps the pasted address, so a failed copy there really can
  // still be filed — which is the case "no copy yet — it will still be filed"
  // was written for, and the only one that now reaches it.
  const linkNoCopy = mediaNewComposerFor({
    fetch: async () => ({ok: true, blob: async () => png}),
    prepare: fakePrepare,
    upload: async () => { throw new Error("archive down"); },
  });
  linkNoCopy.addLink("https://i.imgur.com/d.webp", "img");
  it = (await settle(linkNoCopy))[0];
  ok("a link exhibit whose copy fails IS still filed", it.state === "failed" &&
     M.mediaFileable(it) && linkNoCopy.fault() === "", JSON.stringify(linkNoCopy.fault()));
  ok("...which is what its state text promises",
     /it will still be filed/.test(M.MEDIA_STATES[it.state]));

  // Each failure writes its own whole sentence. The renderer used to prefix
  // every one with "could not read that file", which made a refused link read
  // "could not read that file — that host will not let us read it — ...".
  const unreadable = mediaNewComposerFor({
    prepare: async () => { throw new Error("not an image"); },
    upload: async () => ({sha256: "x", url: "u"}),
  });
  unreadable.add({name: "notes.txt"});
  it = (await settle(unreadable))[0];
  ok("a file that will not decode still says so", /could not read that file/.test(it.error || ""),
     JSON.stringify(it.error));
  ok("...and no other failure repeats that phrase",
     !/could not read that file/.test(
       (await settle(refused))[0].error || ""));

  // 4. A VIDEO IS NEVER FETCHED. There are no stable bytes behind a streaming
  // URL, so a fingerprint of one moment would prove nothing about the next.
  let asked = false;
  const vid = mediaNewComposerFor({
    fetch: async () => { asked = true; return {ok: true, blob: async () => png}; },
    prepare: fakePrepare,
    upload: async () => ({sha256: "x", url: "u"}),
  });
  vid.addLink("https://i.imgur.com/v.mp4", "vid");
  it = (await settle(vid))[0];
  ok("a video link is not fetched", asked === false);
  ok("...and stays a link", it.linkOnly === true && !it.sha256);
}


/* ---- THE INVARIANT THE LAST THREE BUGS ALL BROKE ------------------------
 *
 * Three separate defects had one shape: the composer put an exhibit in the list,
 * showed it as accepted, and then composer.fault() refused the whole set — so
 * the sign button was withheld for a reason about the machine, phrased as
 * something the person had failed to provide.
 *
 *   - an uploaded image whose mirror came back relative — "a link starts with
 *     https://"
 *   - a pasted image link that could not be read — "this image has no
 *     fingerprint yet"
 *   - a dropped file whose copy failed — "this exhibit has no link yet"
 *
 * Each was found and fixed one at a time. The general rule underneath them is
 * simple and worth holding directly: A FAULT MAY ONLY EVER DESCRIBE SOMETHING
 * THE PERSON DID. Too many exhibits, a caption too long, a host nobody can load
 * — those are theirs to fix and must be said. Anything the composer produced by
 * itself, including every way its own network calls can fail, must leave a set
 * that can be signed.
 *
 * So: every intake path crossed with every way it can go wrong, asserting only
 * that. It would have caught all three.
 */
async function section5() {
  const png = new Uint8Array([1, 2, 3, 4, 5]);
  const okPrepare = async () => ({mime: "image/webp", w: 800, h: 600, bytes: png});
  const okUpload = async (b, m, sum) => ({sha256: sum, url: "https://kourt.xyz/m/" + sum});
  const okFetch = async () => ({ok: true, blob: async () => png});
  const boom = async () => { throw new Error("no"); };

  /* THE ARCHIVE IS STUBBED AT THE NETWORK, not at the function. mountCompose
     builds its upload out of mediaUpload, so stubbing `upload` here would test
     an input production cannot produce — and it did, until this was rewritten:
     two rows failed against a value only the test could create. What varies
     below is what the SERVICE answers, which is what really varies. */
  const archive = answer => async (bytes, mime, sum) =>
    M.mediaUpload(bytes, mime, {
      // The same host mediaNewComposerFor is configured for. A mirror on any
      // other host is refused, correctly — an earlier draft of this used a
      // different one and every row failed with "browsers will not load images
      // from k here", which is the composer being right about the wrong thing.
      base: "https://kourt.xyz", sha256: sum,
      fetch: async () => answer(sum),
    });

  const outcomes = [
    ["everything works", {}],
    ["the file will not decode", {prepare: boom}],
    ["the host refuses the read", {fetch: boom}],
    ["the archive is down", {upload: archive(() => ({ok: false, status: 503, json: async () => ({})}))}],
    ["the archive answers rubbish",
     {upload: archive(sum => ({ok: true, json: async () => ({sha256: sum, url: "not a url"})}))}],
    ["the archive answers a relative url",
     {upload: archive(sum => ({ok: true, json: async () => ({sha256: sum, url: "/m/" + sum})}))}],
    ["the archive names a different digest",
     {upload: archive(() => ({ok: true, json: async () => ({sha256: "f".repeat(64)})}))}],
  ];
  const intakes = [
    ["a dropped file", c => c.add({name: "shot.png"})],
    ["a pasted image link", c => c.addLink("https://i.imgur.com/a.webp", "img")],
    ["a pasted video link", c => c.addLink("https://i.imgur.com/v.mp4", "vid")],
  ];

  for (const [what, over] of outcomes) {
    for (const [how, act] of intakes) {
      const c = mediaNewComposerFor(Object.assign(
        {fetch: okFetch, prepare: okPrepare, upload: okUpload}, over));
      act(c);
      for (let i = 0; i < 60; i++) {
        if (c.items.every(x => x.state === "ready" || x.state === "failed" || x.state === "broken")) break;
        await new Promise(r => setTimeout(r, 5));
      }
      ok(`${how}, ${what}: the claim can still be signed`, c.fault() === "",
         `${JSON.stringify(c.fault())} state=${c.items.map(x => x.state).join(",")}`);
    }
  }

  // AND THE OTHER HALF, so the rule above cannot be satisfied by refusing
  // everything: a fault the PERSON can act on must still be raised.
  const mine = mediaNewComposerFor({fetch: okFetch, prepare: okPrepare, upload: okUpload});
  mine.addLink("https://i.imgur.com/a.webp", "img");
  await new Promise(r => setTimeout(r, 40));
  ok("a caption too long is still the person's to fix",
     mine.setCaption(mine.items[0].id, "x".repeat(M.MEDIA_MAX_CAPTION + 1)) !== "");
  const many = mediaNewComposerFor({fetch: okFetch, prepare: okPrepare, upload: okUpload});
  let refusedAt = 0;
  for (let i = 0; i < M.MEDIA_MAX_ITEMS + 1; i++) {
    const r = many.addLink("https://i.imgur.com/" + i + ".webp", "vid");
    if (r.error) refusedAt = i;
  }
  ok("...and an eighth exhibit is refused when it is added, not at signing",
     refusedAt === M.MEDIA_MAX_ITEMS, `refused at ${refusedAt}`);
}

(async () => {
  await section1();
  await section2();
  await section3();
  await section4();
  await section5();
  const EXPECTED = 224;
  if (EXPECTED && ran !== EXPECTED) {
    fails++;
    console.log(`FAIL only ${ran} of ${EXPECTED} assertions ran`);
  }
  console.log(fails ? `\n${fails} FAILURES` : "\nALL PASS");
  process.exit(fails ? 1 : 0);
})();
