// A real image, through the real composer, into a real archive, and back.
//
// This is the one path docs/CLAIM_MEDIA.md has carried as untested since the
// feature was built: "mountCompose needs a real canvas and createImageBitmap, so
// the resize path is the one piece no harness covers and it has never run
// against a real image." It is also the first thing a person does.
//
// Started by internal/archive/browser_test.go, which owns the server and passes
// its URL in argv[2]. That server is the archive AND the page, on one origin
// over TLS — which is what production looks like behind nginx, and what
// crypto.subtle needs to exist at all.
//
// What no other harness can reach, and this one crosses in order:
//   createImageBitmap -> mediaFitWithin -> canvas -> toBlob("image/webp")
//   -> mediaEncodeUnder -> mediaDigest -> POST /m -> the archive stores it
//   -> GET /m/<sha256> -> mediaVerify says the bytes are the ones filed
//
// The composer is captured by wrapping the mediaNewComposer factory before
// mountCompose calls it. That is a real seam rather than a reimplementation: the
// object under test is the one the page built for itself.
const puppeteer = require('puppeteer');
const BASE = process.argv[2];
if (!BASE) { console.log("usage: compose_upload.js <base-url>"); process.exit(2); }

(async () => {
  // The server's certificate is self-signed by httptest. Three spellings on
  // purpose: `acceptInsecureCerts` is the current option, `ignoreHTTPSErrors`
  // the one older puppeteer knew, and the flag is what actually reaches Chrome
  // if a version honours neither.
  const browser = await puppeteer.launch({
    headless: 'new', acceptInsecureCerts: true, ignoreHTTPSErrors: true,
    args: ['--ignore-certificate-errors'],
  });
  const page = await browser.newPage();
  let fail = 0;
  const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra !== undefined ? extra : ""); } else console.log("ok:", n, extra !== undefined ? extra : ""); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 200)));

  const host = new URL(BASE).host;
  await page.evaluateOnNewDocument((h) => {
    // Demo mode only so the page renders without a chain; the composer is
    // mounted directly below. Nothing here configures where the archive is —
    // siteHost() derives that from the origin, which is the point.
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  }, host);
  await page.goto(BASE + "/index.html", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 600));

  ok("the page can hash (crypto.subtle is available on this origin)",
     await page.evaluate(async () => {
       const d = await mediaDigest(new Uint8Array([1, 2, 3]));
       return /^[0-9a-f]{64}$/.test(d);
     }));

  // --- mount the real composer and hand it a real photograph ----------------
  const SRC_W = 3000, SRC_H = 2000;
  const mounted = await page.evaluate(async (w, h) => {
    const real = window.mediaNewComposer;
    window.__c = null;
    window.mediaNewComposer = function (o) { const c = real(o); window.__c = c; return c; };
    const div = document.createElement("div");
    document.body.appendChild(div);
    window.__host = div;
    mountCompose(div, "orem");
    // The panel is behind "Open a claim with evidence", which is the first
    // thing a person clicks — so the harness clicks it too rather than
    // reaching past it.
    const opener = div.querySelector(".composeopen");
    if (!opener) return {error: "no compose opener"};
    opener.click();

    // A photograph the size a phone actually produces, drawn rather than
    // fetched so the harness needs no fixture on disk.
    //
    // IT HAS TO COMPRESS LIKE A PHOTOGRAPH. The first version filled every
    // pixel with independent random noise, which is incompressible by
    // construction: the encode ladder ran all the way down and reported "that
    // image will not compress small enough" — correctly, about a picture no
    // camera can produce. Gradients and shapes with a little grain over them
    // are what a real exhibit looks like to an encoder, and they exercise the
    // ladder without being a trick question.
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const g = c.getContext("2d");
    const sky = g.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, "#2b4f74"); sky.addColorStop(0.6, "#c8b79a");
    sky.addColorStop(1, "#3a2f26");
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    let s = 12345;
    const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
    for (let i = 0; i < 240; i++) {
      g.fillStyle = `rgba(${(rnd() * 255) | 0},${(rnd() * 255) | 0},${(rnd() * 255) | 0},0.55)`;
      g.fillRect(rnd() * w, rnd() * h, 40 + rnd() * 300, 30 + rnd() * 220);
    }
    for (let i = 0; i < 60; i++) {
      g.beginPath();
      g.arc(rnd() * w, rnd() * h, 20 + rnd() * 160, 0, Math.PI * 2);
      g.fillStyle = `rgba(${(rnd() * 255) | 0},${(rnd() * 255) | 0},${(rnd() * 255) | 0},0.35)`;
      g.fill();
    }
    // A little grain, so it is not a poster of flat shapes either.
    const grain = g.getImageData(0, 0, w, h);
    for (let i = 0; i < grain.data.length; i += 4) {
      const n = (rnd() * 24 - 12) | 0;
      grain.data[i] += n; grain.data[i + 1] += n; grain.data[i + 2] += n;
    }
    g.putImageData(grain, 0, 0);
    const blob = await new Promise(r => c.toBlob(r, "image/png"));
    const file = new File([blob], "photo.png", {type: "image/png"});

    const input = div.querySelector('input[type="file"]');
    if (!input) return {error: "no file input in the mounted composer"};
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event("change", {bubbles: true}));
    return {sourceBytes: blob.size};
  }, SRC_W, SRC_H);
  ok("the composer mounted and took the file", !mounted.error, mounted.error || `source png ${mounted.sourceBytes} bytes`);

  // The resize, the encode ladder and the upload are all async and all real.
  const item = await page.evaluate(async () => {
    for (let i = 0; i < 200; i++) {
      const it = window.__c && window.__c.items && window.__c.items[0];
      if (it && (it.state === "ready" || it.state === "broken")) {
        return {...it, preview: undefined,
                fault: window.__c.fault(), argument: window.__c.argument()};
      }
      await new Promise(r => setTimeout(r, 100));
    }
    return {state: "timed out"};
  });

  ok("the exhibit came out ready", item.state === "ready",
     item.state + (item.error ? " — " + item.error : ""));

  // --- the resize itself, which is what had never run -----------------------
  const maxEdge = await page.evaluate(() => MEDIA_MAX_EDGE);
  const maxBytes = await page.evaluate(() => MEDIA_MAX_BYTES);
  ok("the long edge came down to the cap", item.w <= maxEdge && item.h <= maxEdge,
     `${item.w}x${item.h} cap=${maxEdge}`);
  ok("it was actually resized, not passed through", item.w < SRC_W, `${item.w} < ${SRC_W}`);
  // A resize that quietly changes the shape of a document makes it a different
  // exhibit. Half a pixel of rounding is the tolerance.
  ok("the aspect ratio survived", Math.abs(item.w / item.h - SRC_W / SRC_H) < 0.01,
     `${(item.w / item.h).toFixed(4)} vs ${(SRC_W / SRC_H).toFixed(4)}`);
  ok("it is under the byte cap the realm enforces", item.bytes > 0 && item.bytes <= maxBytes,
     `${item.bytes} <= ${maxBytes}`);
  ok("re-encoded to webp", item.mime === "image/webp", item.mime);
  ok("and fingerprinted", /^[0-9a-f]{64}$/.test(item.sha256 || ""), item.sha256);

  // --- the archive really has the bytes, and the page can prove it ----------
  ok("the exhibit carries the archive's address", (item.mirrors || []).length === 1,
     JSON.stringify(item.mirrors));
  const verdict = await page.evaluate(async (it) => {
    // siteHost(), not CFG.site — the latter is the field that was never set,
    // which is the bug this harness found.
    const src = mediaSrc(it, siteHost(), true);
    return {src, verdict: await mediaVerify(it, src)};
  }, item);
  ok("the archive serves back what was filed", verdict.verdict === "matches",
     `${verdict.verdict} from ${verdict.src}`);

  // --- and the claim can actually be filed ---------------------------------
  // THE POINT OF THE WHOLE HARNESS. Everything above can be right while this is
  // wrong, and then nobody can file an image at all.
  ok("the composer raises no fault, so the claim can be signed",
     item.fault === "", JSON.stringify(item.fault));
  ok("the argument is one line the realm will parse",
     typeof item.argument === "string" && item.argument.split("|").length === 8
       && !item.argument.includes("\n"),
     JSON.stringify((item.argument || "").slice(0, 120)));

  ok("no page errors throughout", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
