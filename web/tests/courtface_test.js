// A court's face: the drawn cover, and the real picture when one is set.
//
// WHY THIS HARNESS. The cover is generated, so the thing that can break is not
// "does it render" but "is it the SAME cover every time" — a court whose colour
// changed between reloads would be worse than no cover at all, and a screenshot
// of one page can never show it. The fill is the other half: one read for a
// whole directory page, parsed on a tab, where a court with no picture is absent
// from the reply rather than present-and-empty.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
const { slice } = require("./srcslice");
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.esc = s => String(s).replace(/[&<>"']/g, c =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
global.unesc = s => String(s);
global.gstr = s => JSON.stringify(String(s));
global.isLive = () => true;
global.siteHost = () => "kourt.xyz";
global.mediaParse = line => [{line}];
global.mediaNodeThumb = (items) => items && items.length ? `<img src="X">` : "";
let ONE = async () => { throw new Error("name CourtImages not declared"); };
let asked = [];
global.one = async e => { asked.push(e); return ONE(e); };
const DOM = new Map();
global.document = { getElementById: id => DOM.get(id) || null };

// the glyph table the cover now draws from — sliced with it, so the two cannot
// be tested against different vocabularies
eval(slice("const SUBJECT_WORDS", "function fnv1a("));
eval(slice("function fnv1a(", "function mulberry32("));

(async () => {
  // ---- the cover is a function of the slug and nothing else -----------------
  const a1 = courtCover("covid"), a2 = courtCover("covid");
  ok("the same court draws the same cover, every time", a1 === a2);
  ok("a different court draws a different one", courtCover("orem") !== a1);
  // A cover that changed between reloads is worse than none, so the only inputs
  // allowed are the slug — no time, no randomness.
  const body = slice("function courtCover(", "\n}");
  ok("nothing in the cover depends on the clock or on chance",
     !/Date|Math\.random|performance\./.test(body));
  // "covid" names a subject, so it gets the virus rather than the letters; a
  // slug that names nothing still falls back to initials.
  ok("a court whose name says its subject gets the subject",
     !courtCover("covid").includes(">CO<") && courtCover("covid").includes("<circle"));
  ok("and one that does not gets its initials", courtCover("zzqq").includes(">ZZ<"));
  ok("and survives a slug with nothing to initial", /<text/.test(courtCover("-")));
  ok("the slug is escaped where it reaches the markup",
     !courtCover('"><script>').includes("<script"));

  // ---- the face slot --------------------------------------------------------
  const slot = courtFaceHtml("covid");
  ok("the slot is addressable, so the fill can find it", slot.includes('id="cf-covid"'));
  ok("and holds the drawn cover until a picture arrives", slot.includes("<svg"));

  // ---- one read for a page of courts ----------------------------------------
  const cells = ["covid","orem","meta"].map(s => { const e = {innerHTML:""}; DOM.set("cf-"+s, e); return e; });
  ONE = async () => "orem\tIMGLINE\n";
  asked = [];
  await fillCourtFaces(["covid","orem","meta"]);
  ok("one read for the whole page, not one per court", asked.length === 1);
  ok("it asks CourtImages with every slug",
     /^CourtImages\(/.test(asked[0]) && asked[0].includes("covid,orem,meta"));
  ok("the court with a picture gets it", cells[1].innerHTML.includes("<img"));
  // THE ABSENT ONES KEEP THEIR COVER. CourtImages sends nothing for a court with
  // no image, and "nothing" must not be read as "blank it".
  ok("the courts with none keep their drawn cover",
     cells[0].innerHTML === "" && cells[2].innerHTML === "");

  // ---- what the wire may throw at it ----------------------------------------
  cells.forEach(c => { c.innerHTML = ""; });
  ONE = async () => { throw new Error("name CourtImages not declared"); };
  await fillCourtFaces(["covid"]);
  ok("a chain without the entrypoint leaves every cover alone", cells[0].innerHTML === "");
  ONE = async () => "orem-no-tab-here\n";
  await fillCourtFaces(["orem"]);
  ok("a record with no tab is skipped, not mis-parsed", cells[1].innerHTML === "");
  // a caption may contain anything a person can type, including a pipe or a
  // comma — which is why the outer separator is a tab. Prove the split is on the
  // FIRST tab only, so a caption cannot steal the media line.
  cells[1].innerHTML = "";
  ONE = async () => "orem\tkind|sha|mime|1|2|3|a caption, with a pipe |\n";
  await fillCourtFaces(["orem"]);
  ok("a caption carrying separators still lands on the right court",
     cells[1].innerHTML.includes("<img"));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
