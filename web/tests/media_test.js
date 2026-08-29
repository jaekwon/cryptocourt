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

})();

// ---- the composer --------------------------------------------------------
(async () => {
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

  // A FLAKY UPLOAD MUST NOT COST SOMEBODY THEIR CLAIM.
  c = newComposer({upload: async () => { throw new Error("archive down"); }});
  c.add({name: "shot.png"});
  await settle(); await settle(); await settle();
  ok("a failed copy leaves the exhibit filed as failed", c.items[0].state === "failed");
  ok("...and it is still fileable", M.mediaFileable(c.items[0]));

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
  c = newComposer({upload: async () => { throw new Error("down"); }});
  c.add({name: "a"});
  c.addLink("https://i.imgur.com/v.webp", "vid");
  await settle(); await settle(); await settle();
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

  console.log(fails ? `\n${fails} FAILURES` : "\nALL PASS");
  process.exit(fails ? 1 : 0);
})();
