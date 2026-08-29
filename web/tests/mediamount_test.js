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

let fails = 0;
function ok(name, cond, extra) {
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

(async () => {
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

  console.log(fails ? `\n${fails} FAILURES` : "\nALL PASS");
  process.exit(fails ? 1 : 0);
})();
