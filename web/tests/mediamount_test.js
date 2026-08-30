// The composer's PANEL, exercised against a real element tree.
//
// WHY THIS IS SEPARATE from media_test.js, and it is an admission in the same
// shape as mapclick_test.js's. Every rule in the composer's core is testable as
// arithmetic, and all of it is. None of that proves a person can reach it: that
// the paste handler is bound, that the remove button offers an undo instead of
// a confirm, that the caption input carries the fault back to somebody's eyes.
// A core that works behind a panel nobody can operate is a feature that does
// not exist.
//
// The shim is deliberately tiny — enough tree, listeners, classList and value
// for the handlers under test and nothing else. jsdom would be a dependency,
// and this repo's harnesses are standalone node scripts with none.
const path = require("path");
const M = require(path.join(__dirname, "..", "media.js"));

let fails = 0, ran = 0;
function ok(name, cond, extra) {
  ran++;
  if (cond) { console.log("ok: " + name); return; }
  fails++; console.log("FAIL " + name + (extra ? "  " + extra : ""));
}

class El {
  constructor(tag) {
    this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {};
    this.textContent = ""; this.value = ""; this.files = [];
    const cls = new Set();
    this.classList = {
      add: c => cls.add(c), remove: c => cls.delete(c), contains: c => cls.has(c),
    };
  }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(c => c !== this); }
  focus() { this.focused = true; }
  getAttribute(k) { return this.attrs[k]; }
  appendChild(c) { this.children.push(c); c.parent = this; return c; }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  fire(t, ev) { for (const fn of this.listeners[t] || []) fn(ev || {preventDefault(){}}); }
  set innerHTML(v) { if (v === "") this.children = []; }
  get innerHTML() { return ""; }
  find(pred) {
    if (pred(this)) return this;
    for (const c of this.children) { const r = c.find(pred); if (r) return r; }
    return null;
  }
  all(pred, out) {
    out = out || [];
    if (pred(this)) out.push(this);
    for (const c of this.children) c.all(pred, out);
    return out;
  }
  get text() {
    return this.textContent + this.children.map(c => c.text).join("");
  }
}
const doc = {createElement: t => new El(t)};
const byClass = (root, c) => root.all(e => (e.attrs.class || "").split(" ").includes(c));

function mount(over) {
  const root = new El("div");
  const prepared = new TextEncoder().encode("bytes");
  const composer = M.mediaNewComposer(Object.assign({
    siteDomain: "kourt.xyz",
    previewURL: () => "blob:p",
    prepare: async () => ({mime: "image/webp", w: 8, h: 6, bytes: prepared}),
    upload: async (b, m, sum) => ({sha256: sum, url: "https://kourt.xyz/m/" + sum}),
  }, over || {}));
  const panel = M.mediaMount(root, composer, {doc});
  composer.onChange = () => panel.draw();
  return {root, composer, panel};
}

const settle = () => new Promise(r => setTimeout(r, 0));

async function section1() {
  // The empty panel must already say what to do. An empty box that explains
  // nothing is the commonest way a feature goes unused.
  let {root, composer, panel} = mount();
  ok("the empty panel says how to add evidence", /Drop images|paste/i.test(root.text));
  ok("...and that order matters", /first one is what the map shows/i.test(root.text));
  ok("there is a file input", !!root.find(e => e.tag === "input" && e.attrs.type === "file"));

  // PASTE IS THE PATH THAT MATTERS. A screenshot on the clipboard is the
  // commonest evidence there is.
  let pasted = false;
  panel.el.fire("paste", {
    preventDefault: () => { pasted = true; },
    clipboardData: {files: [{name: "shot.png"}], getData: () => ""},
  });
  ok("pasting an image adds an exhibit", composer.count() === 1 && pasted);

  // Pasting a LINK is adopted too, and refused with a reason when it is one the
  // chain would not store.
  panel.el.fire("paste", {
    preventDefault(){}, clipboardData: {files: [], getData: () => "http://i.imgur.com/a.webp"},
  });
  ok("a bad pasted link is refused out loud",
     /https/.test(byClass(root, "medianote")[0].text), byClass(root, "medianote")[0].text);
  panel.el.fire("paste", {
    preventDefault(){}, clipboardData: {files: [], getData: () => "https://i.imgur.com/a.webp"},
  });
  ok("a good pasted link is adopted", composer.count() === 2);

  // A PASTED VIDEO IS FILED AS A VIDEO. It has no hash either way, but the
  // reader is told which kind of thing it is, and only a <video> will play it.
  panel.el.fire("paste", {
    preventDefault(){}, clipboardData: {files: [], getData: () => "https://i.imgur.com/a.mp4"},
  });
  ok("a pasted video is filed as one", composer.items[composer.count()-1].kind === "vid");
  ok("...and the panel says it cannot be checked later",
     /cannot check it later/.test(byClass(root, "medianote")[0].text),
     byClass(root, "medianote")[0].text);
  composer.remove(composer.items[composer.count()-1].id);

  // A drop is the same path, and the panel shows it is a target.
  panel.el.fire("dragover", {preventDefault(){}});
  ok("a drag over the panel is visible", panel.el.classList.contains("over"));
  panel.el.fire("drop", {preventDefault(){}, dataTransfer: {files: [{name: "b.png"}]}});
  ok("dropping adds an exhibit", composer.count() === 3);
  ok("...and the panel stops looking like a target", !panel.el.classList.contains("over"));

  await settle(); await settle(); await settle();

  // Every exhibit is numbered, and the first says why it is first.
  panel.draw();
  const nums = byClass(root, "medianum").map(e => e.text);
  ok("every exhibit is numbered", nums.length === 3 && /1 of 3/.test(nums[0]), JSON.stringify(nums));
  ok("the first says why it is first", /shown on the map/.test(nums[0]));
  ok("the others do not repeat it", !/shown on the map/.test(nums[1]));

  // A caption's fault reaches somebody's eyes, not just a return value.
  const capInput = byClass(root, "mediacaption")[0];
  capInput.value = "a|b";
  capInput.fire("input");
  ok("a bad caption is reported in the panel",
     /vertical bar/.test(byClass(root, "medianote")[0].text));

  // REMOVE OFFERS AN UNDO, NOT A CONFIRM. A confirm taxes every correct removal
  // to prevent a rare wrong one; an undo charges only the mistake.
  const before = composer.count();
  byClass(root, "mediadel")[0].fire("click");
  ok("removing takes the exhibit out", composer.count() === before - 1);
  const undo = byClass(root, "mediaundo")[0];
  ok("...and offers an undo", !!undo);
  undo.fire("click");
  ok("undo puts it back", composer.count() === before);

  // A link-added exhibit must SAY it cannot be checked, or the badge means
  // nothing anywhere.
  panel.draw();
  ok("a linked exhibit says it cannot be checked",
     /cannot check it later/.test(root.text));

  // A file that cannot be read says so, and says which one.
  ({root, composer, panel} = mount({prepare: async () => { throw new Error("not an image"); }}));
  composer.add({name: "weird.tiff"});
  await settle(); await settle();
  panel.draw();
  ok("an unreadable file explains itself", /could not read that file/.test(root.text));
  ok("...naming the reason", /not an image/.test(root.text));

}

// ---- the lightbox --------------------------------------------------------
async function section2() {
  const bytes = new TextEncoder().encode("real bytes");
  // The hash must be the DIGEST OF THESE BYTES. Writing a placeholder made the
  // "matches" arm report altered — and had the assertion been the other way
  // round it would have passed for entirely the wrong reason.
  const hash = await M.mediaDigest(bytes);

  function open(over) {
    const host = new El("div");
    const keys = [];
    const d = {
      createElement: t => new El(t),
      body: host,
      activeElement: null,
      addEventListener: (t, fn) => keys.push(fn),
      removeEventListener: () => keys.length = 0,
    };
    const items = over && over.items || [
      {kind: "img", sha256: hash, bytes: bytes.length, caption: "the memo",
       mirrors: ["https://i.imgur.com/a.webp"]},
      {kind: "img", sha256: "b".repeat(64), bytes: 4, caption: "", mirrors: ["https://i.imgur.com/b.webp"]},
      {kind: "vid", caption: "hearing", mirrors: ["https://i.imgur.com/v.webp"]},
    ];
    const lb = M.mediaLightbox(items, (over && over.start) || 0, Object.assign({
      doc: d, host, siteDomain: "",
      fetch: async () => ({ok: true, headers: {get: () => null},
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)}),
    }, over || {}));
    return {host, lb, keys, items};
  }
  const settle = () => new Promise(r => setTimeout(r, 0));

  let {host, lb, keys} = open();
  ok("the lightbox opens on the exhibit that was clicked", lb.at() === 0);
  ok("...and says which of how many", /1 of 3/.test(host.text));
  ok("the caption is the alt text, not a number",
     byClass(host, "lbox-img")[0].attrs.alt === "the memo");
  ok("it is a modal dialog to a screen reader",
     byClass(host, "lbox")[0].attrs["aria-modal"] === "true");

  await settle(); await settle();
  ok("a matching exhibit is reported as matching",
     /matches what was filed/.test(byClass(host, "lbox-v")[0].text),
     byClass(host, "lbox-v")[0].text);

  // Arrow keys and buttons walk the gallery, and it does not run off either end.
  keys[0]({key: "ArrowRight", preventDefault(){}});
  ok("the right arrow advances", lb.at() === 1);
  keys[0]({key: "ArrowLeft", preventDefault(){}});
  keys[0]({key: "ArrowLeft", preventDefault(){}});
  ok("...and the first exhibit is the first", lb.at() === 0);
  ok("the previous button is disabled there", byClass(host, "lbox-prev")[0].disabled === true);

  // A VIDEO CANNOT BE CHECKED AND MUST SAY SO, or the verdict on the exhibits
  // that CAN be checked stops meaning anything.
  ({host, lb, keys} = open({start: 2}));
  await settle(); await settle();
  ok("a video says it cannot be checked",
     /cannot check it/.test(byClass(host, "lbox-v")[0].text), byClass(host, "lbox-v")[0].text);

  // ALTERED IS THE WHOLE FEATURE and must be impossible to miss.
  ({host, lb, keys} = open({
    fetch: async () => ({ok: true, headers: {get: () => null},
      arrayBuffer: async () => new TextEncoder().encode("swapped!").buffer}),
  }));
  await settle(); await settle();
  ok("swapped bytes are announced loudly",
     /NO LONGER MATCHES/.test(byClass(host, "lbox-v")[0].text));
  ok("...and the verdict is on the element for styling",
     byClass(host, "lbox-v")[0].attrs.class.includes("lbox-altered"));

  // A SLOW VERDICT MUST NOT LAND ON THE WRONG EXHIBIT. This is the worst thing
  // this feature could do: label an untouched image as altered because a check
  // for the previous one arrived late.
  const held = [];
  ({host, lb, keys} = open({
    fetch: () => new Promise(r => held.push(() => r({ok: true, headers: {get: () => null},
      arrayBuffer: async () => new TextEncoder().encode("swapped!").buffer}))),
  }));
  keys[0]({key: "ArrowRight", preventDefault(){}});   // move on before it lands
  held[0]();                                          // the FIRST exhibit's check returns late
  await settle(); await settle();
  ok("a stale verdict is dropped rather than shown on the next exhibit",
     !/NO LONGER MATCHES/.test(byClass(host, "lbox-v")[0].text),
     byClass(host, "lbox-v")[0].text);

  // ONLY THE BACKDROP CLOSES. A click on the picture is how somebody looks at
  // the picture; closing on it would make the thing they came for the thing
  // that dismisses it. Ablating this changed no test until now.
  ({host, lb, keys} = open());
  const lbox = byClass(host, "lbox")[0];
  lbox.fire("click", {target: byClass(host, "lbox-img")[0]});
  ok("clicking the picture does not close it", host.children.length === 1);
  lbox.fire("click", {target: lbox});
  ok("clicking the backdrop does", host.children.length === 0);

  // Escape closes, and focus goes back where it came from.
  let focused = false;
  const opener = {focus: () => { focused = true; }};
  ({host, lb, keys} = open({activeElement: opener}));
  keys[0]({key: "Escape", preventDefault(){}});
  ok("escape closes it", host.children.length === 0);
  ok("...and focus returns to whatever opened it", focused);

}

/* Sequential, and counted, for the reason media_test.js records: concurrent
   IIFEs with one process.exit between them silently skip whatever has not
   finished, and report success for it. */
/* WHERE THE PAGE THINKS THE ARCHIVE IS. Not testable through media.js, which
   takes the site domain as an argument and is right either way — the bug was
   entirely in what index.html passed it.

   Four call sites asked for `CFG.site`, and nothing has ever set one: there is
   no `site` in CFG_DEFAULTS, cleanCfg does not copy one, and no deploy stamps
   it. Every one of them silently got undefined, which turned the archive-first
   rule off in the overlay — map nodes drew no thumbnail at all, cards and the
   lightbox fell through to the filer's own host, and the composer refused its
   own upload because the archive is an allowed mirror only once the site is
   known. Found by internal/archive/browser_test.go, which is skipped wherever
   puppeteer is absent; hence this cheap pin, which is not.

   Both halves matter. archiveBase() returning "" made the uploaded mirror the
   relative "/m/<sha256>", which mediaMirrorFault refuses for not being https —
   so an uploaded image could not be filed at all. */
function section3() {
  const page = require("fs").readFileSync(
    path.join(__dirname, "..", "index.html"), "utf8");
  ok("the site domain is derived from the origin, not configured",
     /function siteHost\(\)\{[\s\S]{0,400}location\.host/.test(page));
  ok("nothing reads a CFG.site that nothing writes", !page.includes("CFG.site"));
  ok("all four media call sites take the derived host",
     (page.match(/siteHost\(\)/g) || []).length >= 5);
  ok("the archive's address is absolute, so its mirror is a valid https link",
     /return siteHost\(\) \? location\.origin : "";/.test(page));

  /* AN HTTP DEPLOYMENT CANNOT FILE AN UPLOAD AT ALL, and it should hear that
     before the seventh photo rather than after each one breaks. A mirror must be
     https — here and in the realm — so on a page served over http no copy this
     composer makes is filable. A local overlay is http, so this is a developer's
     first encounter with the feature, and the failure they used to meet named
     the symptom ("the copy has no address a claim could point at") rather than
     anything they could act on. */
  ok("an http page warns before every exhibit breaks in turn",
     /served over http, and the court only takes https links/.test(page));
  ok("...gated on the protocol and on there being something to lose",
     /composer\.count\(\) && siteHost\(\) && location\.protocol !== "https:"/.test(page));
  /* THE CALL NOBODY MADE. mediaClaimed has four assertions of its own in
     media_test.js and /m/claimed has its own in Go, and nothing invoked it: the
     composer uploaded bytes and let them sit until a backfill pass noticed.
     Both halves tested, the call between them missing, every suite green — and
     once the archive stopped serving unclaimed bytes, that gap became a 404 on a
     claim somebody had just filed. */
  ok("a broadcast claim tells the archive about its bytes",
     /mediaClaimed\(court, Number\(n\)/.test(page));
  ok("...only when the claim actually carried some",
     /args && args\.media && typeof mediaClaimed=="?="?"function"/.test(page)
     || /args && args\.media && typeof mediaClaimed===\"function\"/.test(page));
  ok("...and only where there is an archive to tell",
     /args\.media && typeof mediaClaimed==="function" && siteHost\(\)/.test(page));
  ok("...with the id read from the chain, since a broadcast returns none",
     /ClaimCount\(\$\{gstr\(court\)\}\)/.test(page));

  ok("...and the upload's own error names http as the cause",
     /a claim only takes https links/.test(
       require("fs").readFileSync(path.join(__dirname, "..", "media.js"), "utf8")));
}

(async () => {
  await section1();
  await section2();
  section3();
  const EXPECTED = 48;
  if (ran !== EXPECTED) {
    fails++;
    console.log(`FAIL only ${ran} of ${EXPECTED} assertions ran`);
  }
  console.log(fails ? `\n${fails} FAILURES` : "\nALL PASS");
  process.exit(fails ? 1 : 0);
})();
