#!/usr/bin/env python3
"""Re-apply this session's two web/index.html changes, idempotently.

WHY THIS EXISTS. Three Claude Code sessions were editing this one working tree at
the same time on 2026-09-03, and web/index.html got written wholesale twice
(20:11 and 20:15), losing surgical edits both times. These are string
replacements against stable anchors, so running this after a clobber costs one
command instead of a redo. Each one is skipped if it is already in place.

  1. the court page's map link wears ICN_CONSTEL, like the claim and folder pages
  2. /raw grows a source/set toggle and the small renderer behind it

Run from the repo root:  python3 scratchpad/apply-rawmd.py
"""
import sys, pathlib

F = pathlib.Path("web/index.html")
src = F.read_text()
applied, already = [], []


def sub(name, old, new, done_marker):
    global src
    if done_marker in src:
        already.append(name)
        return
    if old not in src:
        print(f"ANCHOR MISSING for {name!r} — the file moved under this patch", file=sys.stderr)
        sys.exit(2)
    if src.count(old) != 1:
        print(f"ANCHOR AMBIGUOUS for {name!r} ({src.count(old)} matches)", file=sys.stderr)
        sys.exit(2)
    src = src.replace(old, new, 1)
    applied.append(name)


# ---- 1. the court page's map mark -----------------------------------------
sub(
    "court page map icon",
    '''          <span class="tacts"><a class="tlink" href="#/c/${esc(slug)}/map">map<span aria-hidden="true">→</span></a><a class="tlink" href="#/c/${esc(slug)}/holders">holders''',
    '''          <!-- THE MAP WEARS ITS OWN MARK HERE TOO. The claim page and the folder
               page both write ICN_CONSTEL before the word, so the constellation
               says WHICH view rather than that there is one to go to. The court
               page — the likeliest place to go looking for the map at all — said
               only "map→", so one destination was announced two different ways
               depending on which page you left from. -->
          <span class="tacts"><a class="tlink" href="#/c/${esc(slug)}/map">${ICN_CONSTEL}map<span aria-hidden="true">→</span></a><a class="tlink" href="#/c/${esc(slug)}/holders">holders''',
    '''/map">${ICN_CONSTEL}map<span aria-hidden="true">→</span></a><a class="tlink" href="#/c/${esc(slug)}/holders"''',
)

# ---- 1b. the curate page's, same convention -------------------------------
sub(
    "curate page map icon",
    '''<a class="tlink" href="#/c/${esc(slug)}/map">map<span aria-hidden="true">→</span></a><a class="tlink" href="#/raw/${esc(slug)}/mod">moderation log<span aria-hidden="true">→</span></a></span></div>''',
    '''<a class="tlink" href="#/c/${esc(slug)}/map">${ICN_CONSTEL}map<span aria-hidden="true">→</span></a><a class="tlink" href="#/raw/${esc(slug)}/mod">moderation log<span aria-hidden="true">→</span></a></span></div>''',
    '''/map">${ICN_CONSTEL}map<span aria-hidden="true">→</span></a><a class="tlink" href="#/raw/''',
)

# ---- 2a. a pressed chip outside a pager ----------------------------------
sub(
    "schips pressed state",
    '''.pager .pill[aria-pressed="true"]{background:var(--accent-wash); color:var(--accent-2); border-color:var(--accent)}
.pager.hidenav .pnav{display:none}''',
    '''/* .schips is named here too, because a chip group is not always inside a pager.
   Every one of them was until the /raw route grew a source/set toggle, which
   sits under the page's own copy — and a two-state control that draws both
   states identically is not a toggle, it is two buttons. */
.pager .pill[aria-pressed="true"],.schips .pill[aria-pressed="true"]{background:var(--accent-wash); color:var(--accent-2); border-color:var(--accent)}
.pager.hidenav .pnav{display:none}''',
    '''.schips .pill[aria-pressed="true"]''',
)

# ---- 2b. the rendered half's styles --------------------------------------
sub(
    "rawmd styles",
    '''.rawblock{background:var(--inset); border:1px solid var(--line); border-radius:var(--r); padding:18px; font-family:var(--mono); font-size:12.5px; white-space:pre-wrap; line-height:1.5; color:var(--ink-2); overflow-x:auto}''',
    '''.rawblock{background:var(--inset); border:1px solid var(--line); border-radius:var(--r); padding:18px; font-family:var(--mono); font-size:12.5px; white-space:pre-wrap; line-height:1.5; color:var(--ink-2); overflow-x:auto}
/* The /raw route's other half — the same bytes, set. It sits in the SAME frame
   as .rawblock so the toggle swaps the contents of one panel rather than
   replacing one shape with another; .prose already sets p, h2 and ul, and these
   are the elements the realm's markdown adds to that set. max-width is dropped
   because the frame is the measure here, not the 70ch a body of prose wants. */
.rawmd{background:var(--inset); border:1px solid var(--line); border-radius:var(--r); padding:18px 20px; max-width:none}
.rawmd>:first-child{margin-top:0} .rawmd>:last-child{margin-bottom:0}
.rawmd h3,.rawmd h4,.rawmd h5,.rawmd h6{font-family:var(--serif); font-size:16px; margin:18px 0 8px}
.rawmd blockquote{margin:0 0 12px; padding:8px 14px; border-left:3px solid var(--line-2); background:var(--surface); color:var(--ink-2)}
.rawmd code{font-family:var(--mono); font-size:.9em; background:var(--surface); border:1px solid var(--line); border-radius:var(--r-sm); padding:1px 4px}
.rawmd hr{border:0; border-top:1px solid var(--line); margin:18px 0}
.rawmd li{margin:0 0 4px} .rawmd ul ul{margin:4px 0 0}''',
    '''.rawmd{background:var(--inset)''',
)

# ---- 2c. the renderer and the route --------------------------------------
OLD_ROUTE = '''/* --- the chain render: the same page as the realm alone serves it. --- */
on(/^\\/raw\\/([a-z0-9-]+)(?:\\/(\\d+|mod))?$/, async (slug,id)=>{
  loading();
  const path = id!=null? slug+"/"+id : slug;
  const md = await rawRender(path);
  main.innerHTML = crumbs([{label:"Directory",href:"#/"},{label:courtCrumb(slug),href:"#/c/"+slug},{label:id==="mod"? "Moderation log":"Chain render"}])
    + `<h1 class="page-h">As the chain serves it</h1>
       <p class="page-sub">Plain markdown for <code>${esc(path)}</code>, with nothing added and nothing left out. The ordinary pages show these same facts in a friendlier layout — this view is here so you can check them against the source.</p>
       <div class="rawblock">${esc(md||"(empty)")}</div>`;
});'''

NEW_ROUTE = '''/* --- the chain render: the same page as the realm alone serves it. --- */
/* AND SET, NOT ONLY QUOTED. This route showed the markdown as characters and
   stopped there, which is right for checking a fact against its source and wrong
   for reading a page — the moderation log opens on a wall of `#`, `**` and
   `[…](…)` that says the log is unreadable when the log is fine. So the same
   bytes get a second view, and the source stays the one you land on.

   A SUBSET, DELIBERATELY, and only the elements the realm actually emits:
   headings, paragraphs, bullets (nested one level, which modrender.gno and
   electionrender.gno both write), blockquotes, rules, bold, em, inline code,
   links and image destinations. No tables — the one pipe-delimited string in
   board.gno is a machine format for a query, not a table for a reader — and no
   code fences, which the realm never writes. A wider renderer would be more
   surface for no page that exists to use it.

   THIS IS NOT GNOWEB, and the copy on the page does not claim the set half is
   what the chain serves. gnoweb runs goldmark plus its own extensions; this is a
   reading aid for the text beside it. The source view remains the ground truth
   and is still what the route opens on. */
function mdInline(t){
  /* Escaped as each fragment is EMITTED, never escaped first and pattern-matched
     after: esc() turns a backtick into `&#96;` and `>` into `&gt;`, so a pass
     over already-escaped text has to match entities, and the one that gets
     forgotten is the injection. Here the patterns run on the raw string and
     every piece between them goes through esc() on its way out.
     Bold, em and link labels recurse — "**[a](b)**" is one link inside one
     strong — and the recursion terminates because each match hands on a strictly
     shorter string.
     `_em_` must not fire INSIDE a word: an address or an identifier with an
     underscore in it is not emphasis. Expressed as a leading non-word character
     that is captured and re-emitted rather than as a lookbehind, which Safari
     did not have until 16.4.

     THE BACKSLASH ESCAPE COMES FIRST, and it is not optional here. Every string
     the realm interpolates has been through sanitize.InlineText, which
     backslash-escapes markdown punctuation — so a court called "COVID-19 Origins
     & Response Court" reaches this function as `COVID\\-19 Origins \\& Response`.
     goldmark consumes those, this did not, and the deployed page read
     "COVID\\-19 Origins \\& Response Court" with the backslashes showing. Matching
     the escape first also does the other half of the job: the character it
     protects is consumed with it, so a `\\-` at the head of a line is text rather
     than a bullet, exactly as sanitize intended. CM §2.4 — a backslash before
     ASCII punctuation is an escape, before anything else it is a backslash. */
  const re = /\\\\([!-\\/:-@\\[-`{-~])|(!?)\\[([^\\]\\n]*)\\]\\(([^()\\s]*)\\)|\\*\\*([^\\n]+?)\\*\\*|`([^`\\n]+)`|(^|[^A-Za-z0-9_])_([^_\\n]+)_(?![A-Za-z0-9_])/g;
  let out = "", at = 0, m;
  while((m = re.exec(t)) !== null){
    out += esc(t.slice(at, m.index));
    at = re.lastIndex;
    if(m[1] !== undefined) out += esc(m[1]);
    else if(m[4] !== undefined) out += mdLink(m[2] === "!", m[3], m[4]);
    else if(m[5] !== undefined) out += `<strong>${mdInline(m[5])}</strong>`;
    else if(m[6] !== undefined) out += `<code>${esc(m[6])}</code>`;
    else out += esc(m[7]) + `<em>${mdInline(m[8])}</em>`;
  }
  return out + esc(t.slice(at));
}
/* WHERE A LINK IS ALLOWED TO GO. The realm writes its own gnoweb paths —
   /r/kourt/kourtv2:meta/mod — and those are rewritten to THIS view's route, so
   walking the chain's pages keeps showing you the chain's pages. Anything else
   is a link only if it is plainly http(s); every other scheme renders as its own
   text, because a page whose whole job is to show what the chain said must not
   invent a destination the chain did not write.

   AN IMAGE DESTINATION BECOMES A LINK, not an <img>. media.js draws the same
   evidence URLs on the claim page and only after checking them against a host
   allowlist (see scripts/check-media-hosts.py); fetching them from here would be
   a second, unvetted way for a stranger's URL to reach the reader's browser, on
   the one page that promises to add nothing. The alt text is the label, which is
   what the realm put there for a reader who cannot see the picture anyway. */
const PKG_GWPATH = "/" + PKG.replace(/^[^/]*\\//, "");
function mdLink(isImg, text, dest){
  const local = dest.startsWith(PKG_GWPATH + ":")
    ? "#/raw/" + dest.slice(PKG_GWPATH.length + 1) : null;
  const href = local || (/^https?:\\/\\//i.test(dest)? dest : null);
  const label = (text.trim()? mdInline(text) : esc(dest)) + (isImg? ` <span class="small muted">(image)</span>` : "");
  if(!href) return label;
  return local
    ? `<a href="${esc(href)}">${label}</a>`
    : `<a href="${esc(href)}" target="_blank" rel="noopener">${label}<span aria-hidden="true">↗</span></a>`;
}
function mdLite(md){
  const out = []; let para = [], quote = [], depth = 0;
  /* Paragraph lines are JOINED, the way a markdown reader joins them: the realm
     hard-wraps its prose, and one <p> per source line would set every sentence
     as its own paragraph. */
  const flushP = ()=>{ if(para.length){ out.push(`<p>${mdInline(para.join(" "))}</p>`); para=[]; } };
  const flushQ = ()=>{ if(quote.length){ out.push(`<blockquote>${mdInline(quote.join(" "))}</blockquote>`); quote=[]; } };
  /* A SUBLIST CLOSES THE ITEM IT LIVES IN. `<ul>` is not a legal child of `<ul>`
     — it belongs inside the `<li>` above it — and browsers indent the invalid
     shape anyway, which is how it would have shipped looking correct. */
  const flushL = ()=>{ while(depth>0){ depth--; out.push(depth>0? "</ul></li>" : "</ul>"); } };
  const flush = ()=>{ flushP(); flushQ(); flushL(); };
  for(const raw of String(md||"").replace(/\\r/g,"").split("\\n")){
    const line = raw.replace(/\\s+$/,"");
    let m;
    if(!line){ flush(); continue; }
    if(/^ {0,3}(-{3,}|\\*{3,}|_{3,})$/.test(line)){ flush(); out.push("<hr>"); continue; }
    if((m = line.match(/^ {0,3}(#{1,6})\\s+(.*)$/))){
      /* DEMOTED BY ONE. The page already carries its own <h1>, so the realm's
         `# Moderation log` would be a second one and the outline a screen reader
         walks would have two documents in it. Capped at h6. */
      flush(); const h = Math.min(6, m[1].length + 1);
      out.push(`<h${h}>${mdInline(m[2])}</h${h}>`); continue; }
    if((m = line.match(/^ {0,3}>\\s?(.*)$/))){ flushP(); flushL(); quote.push(m[1]); continue; }
    if((m = line.match(/^(\\s*)[-*+]\\s+(.*)$/))){
      flushP(); flushQ();
      // two spaces is one level, which is what the realm indents by
      const want = Math.min(4, Math.floor(m[1].replace(/\\t/g,"  ").length / 2) + 1);
      while(depth < want){
        // reopen the item above so the sublist nests inside it, not beside it
        if(depth>0 && out.length && out[out.length-1].endsWith("</li>"))
          out[out.length-1] = out[out.length-1].slice(0, -5);
        out.push("<ul>"); depth++; }
      while(depth > want){ depth--; out.push(depth>0? "</ul></li>" : "</ul>"); }
      out.push(`<li>${mdInline(m[2])}</li>`); continue; }
    flushQ(); flushL(); para.push(line.trim());
  }
  flush();
  return out.join("");
}
on(/^\\/raw\\/([a-z0-9-]+)(?:\\/(\\d+|mod))?$/, async (slug,id)=>{
  loading();
  const path = id!=null? slug+"/"+id : slug;
  const md = await rawRender(path);
  main.innerHTML = crumbs([{label:"Directory",href:"#/"},{label:courtCrumb(slug),href:"#/c/"+slug},{label:id==="mod"? "Moderation log":"Chain render"}])
    + `<h1 class="page-h">As the chain serves it</h1>
       <p class="page-sub">Plain markdown for <code>${esc(path)}</code>, with nothing added and nothing left out. The ordinary pages show these same facts in a friendlier layout — this view is here so you can check them against the source. <b>Set it</b> to read the same bytes as a page rather than as characters; the source is what this route opens on, and neither view asks the chain twice.</p>
       <span class="schips" role="group" aria-label="how to show it"><button class="pill void" data-rawview="src" aria-pressed="true">markdown source</button><button class="pill void" data-rawview="md" aria-pressed="false">set it</button></span>
       <div class="rawblock" id="rawsrc" style="margin-top:10px">${esc(md||"(empty)")}</div>
       <div class="prose rawmd" id="rawmd" style="margin-top:10px" hidden>${mdLite(md) || `<p class="muted">(empty)</p>`}</div>`;
  /* BOTH VIEWS ARE IN THE DOM AND ONE IS HIDDEN, rather than one being rendered
     on demand: the toggle is then a property flip with no reflow of the page
     around it, and — the reason that matters here — no second read. rawRender is
     one qrender and the markdown is already in hand; re-entering the route to
     change how it is drawn would spend a round trip to show text the reader is
     already looking at. */
  const views = {src:document.getElementById("rawsrc"), md:document.getElementById("rawmd")};
  main.querySelectorAll("[data-rawview]").forEach(b=>b.addEventListener("click", ()=>{
    const want = b.getAttribute("data-rawview");
    views.src.hidden = want!=="src"; views.md.hidden = want!=="md";
    main.querySelectorAll("[data-rawview]").forEach(x=>
      x.setAttribute("aria-pressed", String(x.getAttribute("data-rawview")===want)));
  }));
});'''

sub("raw route renderer + toggle", OLD_ROUTE, NEW_ROUTE, "data-rawview")

if applied:
    F.write_text(src)
print("applied: " + (", ".join(applied) or "nothing"))
print("already in place: " + (", ".join(already) or "nothing"))
