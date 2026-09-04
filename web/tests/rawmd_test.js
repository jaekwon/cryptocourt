#!/usr/bin/env node
// The /raw route's second view: the chain's markdown SET, beside the source.
//
// WHY THIS HARNESS EXISTS. /raw showed the markdown as characters and nothing
// else, so /raw/covid/mod opened on a wall of `#`, `**` and `[…](…)` — the log
// reads as unreadable when the log is fine. The route grew a toggle and a small
// renderer, and a renderer is exactly the shape of thing this suite is for:
// string in, HTML out, no browser needed.
//
// AND IT IS A TRUST BOUNDARY, which is the real reason. Everything this thing
// is handed came off a chain: claim titles, folder names, moderator addresses,
// evidence URLs, all written by strangers. index.html's claimBody deliberately
// does NOT interpret its field as markdown for that exact reason, so the one
// place that DOES interpret chain text as markup has to be pinned: escaped
// before anything else, one closed set of inline forms, and a link that may only
// go to this view's own route or to plainly http(s).
//
// THE VOCABULARY IS THE REALM'S, not CommonMark's. Assertions cover what
// modrender.gno, electionrender.gno, courtrender and media.gno actually emit —
// headings, joined paragraphs, bullets nested one level, blockquotes, rules,
// bold, em, inline code, links, image destinations — and no more. A form the
// realm never writes is not a gap here; adding one would be surface for no page.
const { slice, src, fn } = require("./srcslice");
let fail = 0;
const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra === undefined ? "" : extra); } else console.log("ok:", n); };

global.esc = s => String(s).replace(/[&<>"'`]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;", "`": "&#96;"}[c]));
// The same derivation the overlay makes, from the same constant — evaluated as
// an expression rather than eval'd as a declaration, because `const` inside a
// direct eval is scoped to the eval and never reaches the harness.
global.PKG = slice('const PKG = "', '";').replace('const PKG = "', "");
// slice() is inclusive of its start anchor, so the `const` keyword comes with
// it — eval'ing that returns undefined, and every link assertion below then
// fails for a reason that has nothing to do with the renderer.
const GWDECL = slice("const PKG_GWPATH = ", "\nfunction mdLink")
  .replace("const PKG_GWPATH = ", "").trim().replace(/;$/, "");
global.PKG_GWPATH = eval(GWDECL);
/* DERIVED, NOT RETYPED. index.html hardcodes "/r/kourt/kourtv2:" in two older
   places already; a third copy is the one that would be left behind by a rename.
   Asserted as "the declaration reads PKG", because a hardcoded literal would
   satisfy the value check below and fail only later, somewhere else. */
ok("the gnoweb path is derived from PKG", /\bPKG\b/.test(GWDECL), GWDECL);
eval(fn("mdInline"));
eval(fn("mdLink"));
eval(fn("mdLite"));

ok("PKG_GWPATH is the realm's gnoweb path, derived not retyped",
   PKG_GWPATH === "/r/kourt/kourtv2", PKG_GWPATH);

// ---- blocks ---------------------------------------------------------------
/* HEADINGS DEMOTE BY ONE. The page carries its own <h1> ("As the chain serves
   it"), so the realm's `# Moderation log` must not be a second one — a document
   with two h1s is two documents to anything walking the outline. */
ok("`#` becomes h2, not a second h1", mdLite("# Moderation log") === "<h2>Moderation log</h2>", mdLite("# Moderation log"));
ok("`##` becomes h3", mdLite("## Moderators") === "<h3>Moderators</h3>");
ok("the demotion is capped at h6", mdLite("###### deep") === "<h6>deep</h6>", mdLite("###### deep"));
/* PARAGRAPH LINES JOIN. The realm hard-wraps its prose; one <p> per source line
   would set every clause as its own paragraph. */
ok("wrapped lines are one paragraph", mdLite("one line\nand its wrap") === "<p>one line and its wrap</p>");
ok("a blank line starts a new paragraph", mdLite("a\n\nb") === "<p>a</p><p>b</p>");
ok("a rule is a rule", mdLite("---\n\nafter") === "<hr><p>after</p>");
/* CONSECUTIVE QUOTE LINES ARE ONE QUOTE — the alternative is a stack of
   single-line blockquotes with a border between each. */
ok("blockquote lines merge into one quote",
   mdLite("> withheld\n> pending review") === "<blockquote>withheld pending review</blockquote>", mdLite("> withheld\n> pending review"));

// ---- lists ----------------------------------------------------------------
ok("bullets are a list", mdLite("- a\n- b") === "<ul><li>a</li><li>b</li></ul>");
/* THE SUBLIST LIVES INSIDE ITS ITEM. `<ul>` is not a legal child of `<ul>`, and
   a browser indents the invalid shape anyway — so this would have shipped
   looking exactly right. modrender.gno writes this nesting (the candidate set
   under "installs candidate set #N") and so does electionrender.gno. */
{
  const got = mdLite("- installs candidate set #7:\n  - g1abc\n  - threshold: 1 of 1\n- next");
  ok("a nested bullet nests inside the item above it",
     got === "<ul><li>installs candidate set #7:<ul><li>g1abc</li><li>threshold: 1 of 1</li></ul></li><li>next</li></ul>", got);
  ok("...so no <ul> is parked beside its item", !/<ul><ul>|<\/li><ul>/.test(got), got);
}
ok("a list closes at a blank line", mdLite("- a\n\nprose") === "<ul><li>a</li></ul><p>prose</p>");

// ---- inline ---------------------------------------------------------------
ok("**bold**", mdInline("**this ballot**") === "<strong>this ballot</strong>");
ok("_em_", mdInline("_No claims yet._") === "<em>No claims yet.</em>");
ok("`code`", mdInline("`OpenElection`") === "<code>OpenElection</code>");
ok("a link inside bold is both", mdInline("**[a](/r/kourt/kourtv2:x)**") === '<strong><a href="#/raw/x">a</a></strong>',
   mdInline("**[a](/r/kourt/kourtv2:x)**"));
/* `_` MUST NOT FIRE INSIDE A WORD. An identifier or an address with an
   underscore in it is not emphasis, and the realm prints both. */
ok("an underscore inside a word is not emphasis",
   mdInline("snake_case_name and g1abc_def") === "snake_case_name and g1abc_def", mdInline("snake_case_name and g1abc_def"));

// ---- links: where they may go --------------------------------------------
/* THE REALM'S OWN PATHS COME BACK HERE. A walk through the chain's pages should
   keep showing the chain's pages, not jump to the friendly route halfway. */
ok("a realm path becomes this view's route",
   mdInline("[moderation log](/r/kourt/kourtv2:meta/mod)") === '<a href="#/raw/meta/mod">moderation log</a>',
   mdInline("[moderation log](/r/kourt/kourtv2:meta/mod)"));
ok("...and stays in this tab", !/target=/.test(mdInline("[x](/r/kourt/kourtv2:meta)")));
{
  const got = mdInline("[gno.land](https://gno.land/r/x)");
  ok("an http destination is a link, in a new tab, with noopener",
     /^<a href="https:\/\/gno\.land\/r\/x" target="_blank" rel="noopener">/.test(got), got);
}
/* EVERY OTHER SCHEME RENDERS AS ITS OWN TEXT. A page whose whole promise is
   "nothing added" must not invent a destination the chain did not write, and the
   destination a stranger would most like to write is a script. */
for(const bad of ["javascript:alert%281%29", "data:text/html;base64,x", "vbscript:x", "//evil.example", "file:///etc/passwd"]){
  const got = mdInline(`[click](${bad})`);
  ok(`\`${bad.slice(0,24)}\` is text, not a link`, !/<a /.test(got) && !got.includes(bad), got);
}
ok("a link with no destination is just its label", mdInline("[label]()") === "label", mdInline("[label]()"));

// ---- the escaping floor ---------------------------------------------------
/* ESCAPED ON THE WAY OUT, not escaped first and pattern-matched after: esc()
   turns a backtick into &#96; and `>` into &gt;, so a second pass over escaped
   text has to match entities, and the entity that gets forgotten is the hole.
   These are the shapes a chain-supplied title would carry. */
/* ASSERTED AS "EVERY `<` OPENS A REVIEWED TAG", not as "these bad words are
   absent". The first draft grepped the output for `onerror` and `<img`, which
   the CORRECT output also contains — escaped, as `&lt;img … onerror=&quot;` —
   so the assertion failed on working code and would have been "fixed" by
   loosening it. What matters is not whether the payload appears; it is whether
   any of it appears as MARKUP. */
const REVIEWED = "p|h[2-6]|ul|li|a|em|strong|code|blockquote|hr|span";
const onlyReviewedTags = html => !new RegExp(`<(?!/?(?:${REVIEWED})[ >/])`).test(html);
for(const [what, mdIn] of [
  ["a script tag", "<script>alert(1)</script>"],
  ["an event handler", `<img src=x onerror="alert(1)">`],
  ["a broken-out attribute", `" onmouseover="alert(1)`],
  ["a bare angle bracket", "a < b > c"],
  ["an entity-looking string", "&lt;script&gt;"],
  ["a backtick", "a ` b"],
  ["one inside a heading", "# <script>alert(1)</script>"],
  ["one inside a bullet", "- <script>alert(1)</script>"],
  ["one inside a link label", "[<script>alert(1)</script>](/r/kourt/kourtv2:x)"],
  ["one inside a code span", "`<script>alert(1)</script>`"],
]){
  const got = mdLite(mdIn);
  ok(`${what} is text, never markup`, onlyReviewedTags(got), got);
  /* ESCAPED IS NOT THE SAME AS DELETED. A renderer that dropped the payload
     would satisfy the check above and lose text the chain served, on the page
     whose promise is that nothing is left out. `&lt;script&gt;` already arrives
     escaped and comes back as `&amp;lt;`, which is why this looks for any entity
     rather than for the angle bracket in particular. */
  ok(`...and is still SHOWN rather than dropped`, /&(amp|lt|gt|quot|#39|#96);/.test(got), got);
}
// the check itself has to be able to fail, or it is decoration
ok("...and that check would catch a real tag", !onlyReviewedTags("<p>ok</p><script>no</script>"));
ok("code spans escape their contents", mdInline("`a<b`") === "<code>a&lt;b</code>", mdInline("`a<b`"));
/* THE OUTPUT'S WHOLE TAG VOCABULARY, asserted as a closed set rather than as a
   list of things that happen to be absent. A renderer that grows a tag nobody
   reviewed is the failure this catches. */
{
  const rich = mdLite("# h\n\n## h2\n\npara **b** _e_ `c` [l](/r/kourt/kourtv2:x) [e](https://x.example)\n\n- a\n  - b\n\n> q\n\n---\n\n![alt](https://x.example/a.png)");
  const tags = [...new Set((rich.match(/<\/?([a-z0-9]+)/g) || []).map(t => t.replace(/[<\/]/g, "")))].sort();
  ok("the tags emitted are exactly the reviewed set",
     tags.join(",") === "a,blockquote,code,em,h2,h3,hr,li,p,span,strong,ul", tags.join(","));
}

// ---- images ---------------------------------------------------------------
/* AN IMAGE DESTINATION BECOMES A LINK. media.js draws these same evidence URLs
   on the claim page and only after checking the host against an allowlist (see
   scripts/check-media-hosts.py). Fetching them from here would be a second,
   unvetted route for a stranger's URL to reach the reader's browser — on the one
   page that promises to add nothing to what the chain said. */
{
  const got = mdInline("![Exhibit 1 of 3 — the memo](https://ex.example/a.png)");
  ok("an image is a link, never an <img>", !/<img/i.test(got) && /<a href="https:\/\/ex\.example\/a\.png"/.test(got), got);
  ok("...labelled by its alt text", got.includes("Exhibit 1 of 3 — the memo"), got);
  ok("...and says it is one", got.includes("(image)"), got);
}

// ---- the empty case -------------------------------------------------------
ok("nothing renders as nothing", mdLite("") === "" && mdLite(null) === "" && mdLite("   ") === "");

// ---- the whole page, as the realm writes it -------------------------------
/* A FIXTURE OFF A REAL NODE, not a hand-built string: this is the moderation log
   of a court with no acts yet, read from kourt-1 — the page that was reported as
   unreadable. Held as a fixture because the assertion is about the SHAPES the
   realm combines, and a hand-written sample is a sample of what the harness
   author remembers the realm doing. */
{
  const modlog = [
    "# Moderation log — Review Court",
    "",
    "Every moderation act on this court's CLAIMS and COMMENTS is recorded here: who acted,",
    "what they did, and when. Moderation controls what is listed; it never moves a coin or",
    "changes a verdict.",
    "",
    "[Who holds these seats, and how to challenge them](/r/kourt/kourtv2:meta/election)",
    "",
    "## Moderators",
    "",
    "1-of-1 — g1mkl9efaf5fz89wqp0cz9p2jhrt468zl8ct5j5c (the court's creator, until an election",
    "or an appointment changes it)",
    "",
    "_No moderation acts yet._",
  ].join("\n");
  const got = mdLite(modlog);
  ok("the mod log sets: one h2, one h3, four paragraphs",
     (got.match(/<h2>/g) || []).length === 1 && (got.match(/<h3>/g) || []).length === 1
     && (got.match(/<p>/g) || []).length === 4, got);
  ok("...its seats link lands on this route", got.includes('href="#/raw/meta/election"'), got);
  ok("...the 1-of-1 line is prose, not an ordered list", !/<ol|<li/.test(got), got);
  ok("...and no markdown punctuation is left as text",
     !/\]\(|##|\*\*/.test(got.replace(/<[^>]*>/g, "")), got);
}

// ---- the route: source is what you land on -------------------------------
/* THE SOURCE VIEW REMAINS THE GROUND TRUTH. This route exists so a reader can
   check a fact against what the realm served; a rendered default would make the
   check the thing you have to go looking for. Source assertions, because this
   harness has no browser — the toggle's behaviour is measured against a live
   node in the browser half. */
ok("the route ships both views, source visible and set hidden",
   src.includes('<div class="rawblock" id="rawsrc"') && src.includes('id="rawmd" style="margin-top:10px" hidden'));
ok("...with a two-state toggle, source pressed",
   src.includes('data-rawview="src" aria-pressed="true"') && src.includes('data-rawview="md" aria-pressed="false"'));
/* AND THE PRESSED STATE IS DRAWN. .schips chips were all inside a .pager, which
   is where the aria-pressed rule lived; this group is not, and a two-state
   control that draws both states identically is two buttons. */
ok("...and a pressed chip outside a pager is still styled",
   src.includes('.schips .pill[aria-pressed="true"]'));
/* ONE READ FOR BOTH VIEWS. rawRender is a qrender; re-entering the route to
   change how text already in hand is drawn would spend a round trip to show the
   reader what they are already looking at. */
ok("...and the toggle re-reads nothing",
   /views\.src\.hidden = want!=="src"/.test(src) && !/rawRender/.test(slice('const views = {src:', '\n});')));
/* THE COPY DOES NOT PROMISE GNOWEB. This is goldmark-shaped, not goldmark: a
   claim that the set half is "what the chain serves" would be the one sentence
   on the page that is not true. */
ok("the page says the source is what it opens on",
   src.includes("the source is what this route opens on"));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
