// How a file gets into the composer at all — paste, drop, pick.
//
// docs/CLAIM_MEDIA.md §2.1 calls paste "the single most important path", because
// a screenshot is the commonest evidence a claim of fact has and every competing
// product makes people save-then-upload first. It also says, twice, that it must
// work "anywhere in the composer, not only in a drop zone".
//
// None of that is checkable without a browser. mediamount_test.js can prove the
// listener is BOUND — it does — but not which element it is bound to, and
// therefore not whether a paste from where a person's cursor actually is ever
// reaches it. That distinction is the whole subject of this file.
//
// Run by internal/archive/browser_test.go against a live archive, so a pasted
// file travels the same road as a picked one.
const puppeteer = require('puppeteer');
const BASE = process.argv[2];
if (!BASE) { console.log("usage: compose_intake.js <base-url>"); process.exit(2); }

(async () => {
  const browser = await puppeteer.launch({
    headless: 'new', acceptInsecureCerts: true, ignoreHTTPSErrors: true,
    args: ['--ignore-certificate-errors'],
  });
  const page = await browser.newPage();
  let fail = 0;
  const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra !== undefined ? extra : ""); } else console.log("ok:", n, extra !== undefined ? extra : ""); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 200)));

  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
    // Drafts persist per court, and a draft restored from an earlier case would
    // seed exhibits this one never added.
    localStorage.removeItem("cc.mediadraft.orem");
  });
  await page.goto(BASE + "/index.html", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 600));

  // Everything below drives one freshly mounted composer per case, so a failure
  // in one cannot look like a pass in the next.
  await page.evaluate(() => {
    window.__mount = function () {
      for (const old of document.querySelectorAll(".__probe")) old.remove();
      // CLEAR THE DRAFT FIRST. §2.5 is working — the composer saves every
      // keystroke and every exhibit per court, and restores them on mount — so
      // without this each case inherits the one before it and the counts creep.
      // Observed as 1, then 2, then 3 items across three independent cases.
      localStorage.removeItem(mediaDraftKey("orem"));
      const real = window.mediaNewComposer;
      window.mediaNewComposer = function (o) { const c = real(o); window.__c = c; return c; };
      const div = document.createElement("div");
      div.className = "__probe";
      document.body.appendChild(div);
      mountCompose(div, "orem");
      div.querySelector(".composeopen").click();
      window.mediaNewComposer = real;
      return div;
    };
    // A small real PNG, built once. The bytes matter only in that they are a
    // decodable image; compose_upload.js is where the resize is measured.
    window.__file = async function (name) {
      const c = document.createElement("canvas");
      c.width = 120; c.height = 80;
      const g = c.getContext("2d");
      g.fillStyle = "#3a6ea5"; g.fillRect(0, 0, 120, 80);
      g.fillStyle = "#c2683a"; g.fillRect(10, 30, 90, 12);
      const blob = await new Promise(r => c.toBlob(r, "image/png"));
      return new File([blob], name || "shot.png", {type: "image/png"});
    };
    window.__settle = async function (want) {
      for (let i = 0; i < 60; i++) {
        const n = window.__c ? window.__c.items.length : 0;
        if (n >= want && window.__c.items.every(x => x.state === "ready" || x.state === "broken")) break;
        await new Promise(r => setTimeout(r, 100));
      }
      return window.__c ? window.__c.items.map(x => ({state: x.state, kind: x.kind,
        mirrors: x.mirrors, sha256: x.sha256, linkOnly: !!x.linkOnly})) : [];
    };
  });

  // --- 1. the path the doc calls the most important one --------------------
  // Cursor in the title, which is where it IS: a person types the claim and then
  // pastes the screenshot that proves it. Nobody clicks a drop zone first to
  // make a paste land.
  const inTitle = await page.evaluate(async () => {
    const div = window.__mount();
    const title = div.querySelector(".composetitle");
    title.focus();
    title.value = "The memo said that";
    const dt = new DataTransfer();
    dt.items.add(await window.__file());
    title.dispatchEvent(new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true}));
    const items = await window.__settle(1);
    return {items, title: title.value};
  });
  ok("a screenshot pasted with the cursor in the title becomes an exhibit",
     inTitle.items.length === 1 && inTitle.items[0].state === "ready",
     JSON.stringify(inTitle.items));
  ok("...and the title is left alone", inTitle.title === "The memo said that",
     JSON.stringify(inTitle.title));

  // Same, from the body — the other place a cursor sits.
  const inBody = await page.evaluate(async () => {
    const div = window.__mount();
    const body = div.querySelector(".composebody");
    body.focus();
    const dt = new DataTransfer();
    dt.items.add(await window.__file());
    body.dispatchEvent(new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true}));
    return await window.__settle(1);
  });
  ok("a screenshot pasted from the body becomes an exhibit",
     inBody.length === 1 && inBody[0].state === "ready", JSON.stringify(inBody));

  // --- 2. the drop zone still works ----------------------------------------
  const onZone = await page.evaluate(async () => {
    const div = window.__mount();
    const zone = div.querySelector(".mediadrop");
    const dt = new DataTransfer();
    dt.items.add(await window.__file());
    zone.dispatchEvent(new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true}));
    return await window.__settle(1);
  });
  ok("a screenshot pasted on the drop zone becomes an exhibit",
     onZone.length === 1 && onZone[0].state === "ready", JSON.stringify(onZone));

  const dropped = await page.evaluate(async () => {
    const div = window.__mount();
    const zone = div.querySelector(".mediadrop");
    const dt = new DataTransfer();
    dt.items.add(await window.__file());
    zone.dispatchEvent(new DragEvent("drop", {dataTransfer: dt, bubbles: true, cancelable: true}));
    return await window.__settle(1);
  });
  ok("a dropped file becomes an exhibit",
     dropped.length === 1 && dropped[0].state === "ready", JSON.stringify(dropped));

  // The uploaded ones really reached the archive on this origin.
  ok("a pasted exhibit was copied to the archive, like a picked one",
     /^https:\/\/[^/]+\/m\/[0-9a-f]{64}$/.test((inTitle.items[0] || {}).mirrors && inTitle.items[0].mirrors[0] || ""),
     JSON.stringify((inTitle.items[0] || {}).mirrors));

  // --- 3. a URL pasted into a text field is TEXT ---------------------------
  // The handler adopts a pasted link as an exhibit, which is right on the drop
  // zone and wrong in a box someone is typing in: a claim whose title or body
  // mentions a URL must be able to contain one. Files are different — a
  // screenshot cannot be meaningfully pasted into a text input, so those are
  // taken anywhere.
  const urlInBody = await page.evaluate(async () => {
    const div = window.__mount();
    const body = div.querySelector(".composebody");
    body.focus();
    const dt = new DataTransfer();
    dt.setData("text", "https://i.imgur.com/abc.webp");
    const ev = new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true});
    body.dispatchEvent(ev);
    await new Promise(r => setTimeout(r, 250));
    return {items: window.__c.items.length, prevented: ev.defaultPrevented};
  });
  ok("a link pasted into the body stays text, and is not seized as an exhibit",
     urlInBody.items === 0 && !urlInBody.prevented, JSON.stringify(urlInBody));

  const urlOnZone = await page.evaluate(async () => {
    const div = window.__mount();
    const zone = div.querySelector(".mediadrop");
    const dt = new DataTransfer();
    dt.setData("text", "https://i.imgur.com/abc.webp");
    zone.dispatchEvent(new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true}));
    // The composer tries to READ the link so it can fingerprint and copy it.
    // i.imgur.com is not reachable from this test, so this exercises the
    // refusal path — which is the one with the history.
    for (let i = 0; i < 60; i++) {
      await new Promise(r => setTimeout(r, 100));
      const x = window.__c.items[0];
      if (x && (x.state === "ready" || x.state === "broken" || x.state === "failed")) break;
    }
    return {items: window.__c.items.map(x => ({kind: x.kind, state: x.state,
              linkOnly: !!x.linkOnly, sha256: x.sha256, error: x.error})),
            fault: window.__c.fault(), argument: window.__c.argument()};
  });
  ok("a link the page cannot read ends as a broken row, not a filed exhibit",
     urlOnZone.items.length === 1 && urlOnZone.items[0].state === "broken",
     JSON.stringify(urlOnZone.items));
  // THE POINT OF THE WHOLE CHANGE. This used to leave an image exhibit with no
  // sha256 in the list, which the realm refuses and mediaItemFault reports as
  // "this image has no fingerprint yet" — so pasting a link nobody could read
  // silently made the claim unsignable.
  ok("...and the claim can still be signed", urlOnZone.fault === "",
     JSON.stringify(urlOnZone.fault));
  ok("...carrying no exhibit it could not stand behind", urlOnZone.argument === "",
     JSON.stringify(urlOnZone.argument));

  ok("no page errors throughout", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
