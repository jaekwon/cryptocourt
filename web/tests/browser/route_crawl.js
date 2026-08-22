// Follow every internal link the overlay draws, and check the page it lands on
// exists.
//
// WHY THIS EXISTS, and it is a specific bug rather than a category. Nesting
// landed for chain folders; the folder route still resolved a path against the
// ROOT array; every chain subfolder answered "No such folder on this court" —
// and the court page went on linking to them. It shipped, and nothing in the
// tree could have caught it:
//
//   * the source harnesses test functions, and this was two functions AGREEING
//     to disagree — chainFolders produced a tree, the route read a list;
//   * the layout checks measure geometry on routes they are handed, and the
//     broken route was one nobody had listed;
//   * my own live check read the subfolder row's LABEL. "The record · 1
//     subfolder" renders identically whether or not the thing it names opens.
//
// A rendered link is a promise the page makes. This is the only check that
// collects the promises and calls them in.
//
// DEMO MODE, deliberately: the sample docket is a fixed graph, so this is
// deterministic and needs no chain. It covers curation folders (dotted index
// paths), claims, the map, curate, raw and positions. The chain half — id paths,
// subfolders, retired folders — is covered by folders_test.js calling
// resolveFolderPath directly, because a crawl cannot conjure a seeded node.
const puppeteer = require('puppeteer');
const PAGE = 'file://' + require('path').join(__dirname, '..', '..', 'index.html');

// Bounded on purpose. The demo graph is finite, but a bug that generated links
// in a loop should fail this check rather than hang it.
const MAX_PAGES = 90;

// `notFound()` is one shape: an .empty block whose first line is a .page-h. The
// other empty states ("No courts yet", "No open claims") are legitimate pages
// and carry no .page-h, which is what separates "nothing here" from "no such
// thing".
const NOT_FOUND = () => {
  const box = document.querySelector('.main .empty .page-h');
  if (box) return box.textContent.trim();
  const err = document.querySelector('.main h2.page-h');
  if (err && /Could not read/.test(err.textContent)) return err.textContent.trim();
  return null;
};

(async () => {
  const browser = await puppeteer.launch();
  const page = await browser.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 140)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 900});
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 700));

  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  const seen = new Set(['#/']);
  const queue = [{route: '#/', from: 'the start'}];
  const broken = [];
  const mismatched = [];
  let visited = 0;

  while (queue.length && visited < MAX_PAGES) {
    const {route, from, promised} = queue.shift();
    visited++;
    await page.evaluate(r => { location.hash = r.slice(1); }, route);
    await new Promise(r => setTimeout(r, 220));

    const bad = await page.evaluate(NOT_FOUND);
    if (bad) broken.push({route, from, saw: bad});

    // A LINK THAT LANDS SOMEWHERE ELSE IS STILL BROKEN, and it is the harder
    // half: resolution that walks the wrong array finds A folder, so the page
    // renders and every existence check passes. The first version of this crawl
    // missed exactly that — armed with resolution that never descends, it went
    // green, because "0.1" quietly resolved to root folder 1.
    if (!bad && promised) {
      const landed = await page.evaluate(() => {
        const h = document.querySelector('.main .page-h');
        if (!h) return null;
        const seal = h.querySelector('.seal');
        if (seal) seal.remove();
        return h.textContent.replace(/\s+/g, ' ').trim();
      });
      if (landed && !landed.includes(promised)) {
        mismatched.push({route, from, promised, landed});
      }
    }

    // Collect what THIS page promises. Embeds are a different chrome with their
    // own checks, and a ?from= query only changes an analytics crumb.
    const links = await page.evaluate(() => [...document.querySelectorAll('.main a[href^="#/"], .rail a[href^="#/"]')]
      .map(a => ({
        href: a.getAttribute('href'),
        // A FOLDER ROW NAMES THE FOLDER IT OPENS. Captured so the destination can
        // be held to it — see `mismatched` below.
        folderName: a.classList.contains('folderrow') && a.querySelector('.t')
          ? a.querySelector('.t').textContent.trim() : null,
      })));
    for (const {href, folderName} of links) {
      const r = String(href).split('?')[0];
      if (!r.startsWith('#/') || r.startsWith('#/embed/')) continue;
      if (seen.has(r)) continue;
      seen.add(r);
      queue.push({route: r, from: route, promised: folderName});
    }
  }

  console.log(`\ncrawled ${visited} route(s) from ${seen.size} link(s)`);
  ok(`every link the overlay draws lands on a page that exists`, broken.length === 0,
     broken.slice(0, 4).map(b => `${b.route} (linked from ${b.from}) -> "${b.saw}"`).join(" | "));
  // A crawl that visited three pages proves nothing; this is the tripwire that
  // stops it passing vacuously if the link collector ever stops collecting.
  ok(`the crawl actually went somewhere`, visited >= 12, `visited ${visited}`);
  ok(`a folder link opens the folder it named`, mismatched.length === 0,
     mismatched.slice(0, 3).map(m => `${m.route} promised "${m.promised}" showed "${m.landed}"`).join(" | "));
  ok(`it reached a folder`, [...seen].some(r => /\/f\//.test(r)), [...seen].join(" ").slice(0, 80));
  ok(`it reached a claim`, [...seen].some(r => /^#\/c\/[^/]+\/\d+$/.test(r)));
  ok(`no page errors on any route reached`, errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
