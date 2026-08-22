// Harness for web/chat.js — the court chat panel.
//
// Unlike its neighbours this one does not slice index.html. chat.js is a whole file
// of its own, so it is evaluated whole, which means these tests exercise the shipped
// code rather than a fragment of it and they keep working while the page is being
// edited by somebody else.
//
// WHAT THIS FILE IS FOR. The panel renders text written by anonymous strangers, and
// the server deliberately does not strip markup from it (SanitizeBody preserves what
// a reader sees so that the classifier reads the same thing). Escaping here is
// therefore the only thing between a message body and script execution. Most of what
// follows is that one property, approached from several directions, plus the two
// regressions found while writing it: a status repaint that erased the transcript,
// and a poller that outlived the DOM it was writing to.
const fs = require("fs");
const path = require("path");
const SRC = path.join(__dirname, "..", "chat.js");

// Stubs, before the eval: chat.js touches document.hidden, localStorage and fetch.
let FETCHES = [];
let FETCH = async () => { throw new Error("no fetch stub installed"); };
global.fetch = (...a) => { FETCHES.push(a); return FETCH(...a); };
// A document fake with real listener bookkeeping, because mountChat now registers a
// visibilitychange handler and a fake without addEventListener would make that line
// unreachable from a test — the guard would hold and a mutation deleting it would survive.
global.document = {
  hidden: false,
  _l: {},
  addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); },
  removeEventListener(t, f) {
    this._l[t] = (this._l[t] || []).filter(g => g !== f);
  },
  dispatchEvent(e) { for (const f of (this._l[e.type] || []).slice()) f(e); },
  listeners(t) { return this._l[t] || []; },
};
const STORE = {};
global.window = {localStorage: {
  getItem: k => (k in STORE ? STORE[k] : null),
  setItem: (k, v) => { STORE[k] = String(v); },
}};

eval(fs.readFileSync(SRC, "utf8"));

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

// ---------------------------------------------------------------- escaping
// The single property everything else rests on. Both directions every time: the
// dangerous form must be ABSENT and the escaped form PRESENT, because a function that
// returned "" would pass an absence check on its own.
const XSS = '<img src=x onerror=alert(1)>';
{
  const h = chatLineHtml({moniker: "alice", body: XSS, country: "DE",
                          suffix: "a1b2c3", created_at: 1000}, 1000);
  ok("a script payload in a body is not emitted as a tag", !/<img/.test(h));
  ok("...and it is still shown to the reader, escaped",
     h.includes("&lt;img src=x onerror=alert(1)&gt;"));

  // A moniker lands inside an attribute in some renderings and inside text in
  // others, so it is checked against both kinds of breakout.
  const q = chatLineHtml({moniker: '" onmouseover="alert(1)', body: "hi",
                          country: "DE", suffix: "a1b2c3", created_at: 1000}, 1000);
  ok("a quote in a moniker cannot close an attribute", !/onmouseover="/.test(q));
  ok("...and the quote is escaped", q.includes("&quot;"));

  ok("single quotes are escaped", chatEsc("it's") === "it&#39;s");
  ok("backticks are escaped", chatEsc("a`b") === "a&#96;b");
  ok("ampersand first, so escapes are not double-decoded",
     chatEsc("&lt;") === "&amp;lt;");
  ok("null and undefined render as empty, not as the word null",
     chatEsc(null) === "" && chatEsc(undefined) === "");
}

// A scam is only dangerous when its link is clickable. This is a design rule, not an
// oversight, so it is pinned: nothing in a rendered line may be an anchor.
{
  const h = chatLineHtml({moniker: "crook", country: "", suffix: "",
    body: "claim your airdrop at http://gnot-claim.xyz now", created_at: 1000}, 1000);
  ok("a URL in a body is never linkified", !/<a\b/i.test(h) && !/href/i.test(h));
  ok("...and is still legible as text", h.includes("http://gnot-claim.xyz"));
}

// ---------------------------------------------------------------- flags
{
  ok("DE is the German flag", chatFlag("DE") === "\u{1F1E9}\u{1F1EA}");
  ok("lowercase is accepted", chatFlag("de") === chatFlag("DE"));
  // Every rejection separately, because each is a different way for a bad value to
  // arrive: short, long, non-letter, empty, absent, and markup.
  for (const bad of ["D", "DEU", "d3", "", null, undefined, "<>", "  ", "ZZZ"]) {
    ok("no flag for " + JSON.stringify(bad), chatFlag(bad) === "");
  }
  // ZZ is not a country but IS two letters; it yields an unassigned pair rather than
  // markup, which is the acceptable failure. Recorded so nobody "fixes" it with a
  // list of 249 codes that goes stale.
  ok("an unassigned two-letter code is inert", !/[<>&]/.test(chatFlag("ZZ")));
}

// ---------------------------------------------------------------- the suffix
// The anti-impersonation property. Nobody owns a moniker, so the suffix is the only
// thing that distinguishes two people using the same name. It must be rendered.
{
  const a = chatLineHtml({moniker: "alice", suffix: "a1b2c3", country: "GB",
                          body: "hello", created_at: 1000}, 1000);
  const b = chatLineHtml({moniker: "alice", suffix: "ff0099", country: "GB",
                          body: "I am the real alice", created_at: 1000}, 1000);
  ok("the suffix is rendered", a.includes("a1b2c3"));
  ok("two people using one name are distinguishable", a !== b && b.includes("ff0099"));
  // A suffix is 6 hex from the server. Anything else did not come from HashPair and
  // is dropped rather than displayed as though it had.
  const junk = chatLineHtml({moniker: "alice", suffix: "<b>staff</b>", country: "",
                             body: "hi", created_at: 1000}, 1000);
  ok("a non-hex suffix is dropped", !junk.includes("staff") && !/<b>/.test(junk));
  const none = chatLineHtml({moniker: "alice", body: "hi", created_at: 1000}, 1000);
  ok("a message with no suffix or country still renders",
     none.includes("alice") && !/undefined/.test(none));
}

// ---------------------------------------------------------------- ages
{
  ok("fresh reads as just now", chatWhen(1000, 1000) === "just now");
  ok("under 45s reads as just now", chatWhen(1044, 1000) === "just now");
  ok("a minute reads in minutes", chatWhen(1000 + 60, 1000) === "1m");
  ok("an hour reads in minutes below 90m", chatWhen(1000 + 3600, 1000) === "60m");
  ok("two hours reads in hours", chatWhen(1000 + 7200, 1000) === "2h");
  ok("three days reads in days", chatWhen(1000 + 3 * 86400, 1000) === "3d");
  // A viewer whose clock is behind the server's is common; "in 4 minutes" is not a
  // useful thing to show them.
  ok("a clock behind the server does not read as the future",
     chatWhen(1000, 1240) === "just now");
}

// ---------------------------------------------------------------- your own status
{
  ok("ok says nothing at all", chatStatusLine({state: "ok"}, 1000) === "");
  ok("a missing status says nothing", chatStatusLine(null, 1000) === "");

  const k = chatStatusLine({state: "kick", until: 1000 + 1800, ref: 42}, 1000);
  ok("a kick says paused", /paused/i.test(k));

  // THE COUNTDOWN MUST NOT COME FROM THIS CLOCK, because this clock did not set it.
  //
  // Measured on a five-minute kick before `seconds` existed: a client ten minutes SLOW read
  // "paused for another 15 minutes", wrong by three times over, and one ten minutes FAST lost the
  // duration entirely and was told only "paused" — nothing to say when to come back. Browsers take
  // their time from the OS and a machine minutes out is ordinary.
  //
  // The state was never affected, so nobody was wrongly let through; it was the one number the
  // reader needs that was wrong.
  {
    const now = 1700000000;
    const you = {state: "kick", until: now + 300, seconds: 300, ref: 7};
    const at = skew => chatStatusLine(you, now + skew, "mods@example.org");
    ok("a correct clock reads the server's five minutes", /another 5 minutes/.test(at(0)));
    ok("...and so does a clock ten minutes fast", /another 5 minutes/.test(at(600)));
    ok("...and one ten minutes slow", /another 5 minutes/.test(at(-600)));
    ok("...and one two hours out", /another 5 minutes/.test(at(7200)));

    // The fallback is kept deliberately: a server that does not send `seconds` must still produce
    // a line, and `until` remains for an appeal to quote.
    const older = {state: "kick", until: now + 300, ref: 7};
    ok("without seconds it still says how long", /another 5 minutes/.test(chatStatusLine(older, now)));

    // And the paired case that keeps this from passing for a line that always says five minutes:
    // a different remaining time reads differently.
    const longer = {state: "kick", until: now + 7200, seconds: 7200, ref: 7};
    ok("a two-hour kick reads as hours", /another 2 hours/.test(chatStatusLine(longer, now)));
    ok("...regardless of the local clock",
       /another 2 hours/.test(chatStatusLine(longer, now - 99999)));
  }
  ok("...says how long", /30 minutes/.test(k));
  // With NO contact configured it gives the reference and promises nothing. The line used to
  // say "You can appeal" unconditionally, while no channel existed anywhere in the service.
  ok("...gives the reference", /42/.test(k));
  ok("...and does not promise an appeal with nowhere to send it", !/appeal/i.test(k));
  const withContact = chatStatusLine({state: "kick", until: 1000 + 1800, ref: 42}, 1000,
    "mods@example.org");
  ok("...but names the route when the operator configured one",
     /appeal/i.test(withContact) && /mods@example\.org/.test(withContact) &&
       /42/.test(withContact));

  // Singular where it should be singular. "paused for another 1 hours" is what a punished
  // person reads while forming a view of whether this service is careless.
  ok("one hour is singular", /1 hour\b/.test(
     chatStatusLine({state: "kick", until: 1000 + 3600}, 1000)) &&
     !/1 hours/.test(chatStatusLine({state: "kick", until: 1000 + 3600}, 1000)));
  ok("one day is singular", /1 day\b/.test(
     chatStatusLine({state: "kick", until: 1000 + 86400}, 1000)));
  ok("one minute is singular", /1 minute\b/.test(
     chatStatusLine({state: "kick", until: 1000 + 30}, 1000)));
  ok("a long kick reads in hours", /3 hours/.test(
     chatStatusLine({state: "kick", until: 1000 + 3 * 3600}, 1000)));
  ok("a week reads in days", /7 days/.test(
     chatStatusLine({state: "kick", until: 1000 + 7 * 86400}, 1000)));
  ok("a ban says blocked", /blocked/i.test(chatStatusLine({state: "ban"}, 1000)));

  // THE ORACLE PROPERTY. The server withholds the category and the model's reasoning
  // so the endpoint cannot be used to tune an evasion. The panel must not undo that
  // by naming a reason it does not have.
  for (const st of ["kick", "ban"]) {
    const line = chatStatusLine({state: st, until: 9999, ref: 7}, 1000);
    ok("a " + st + " never names a category",
       !/spam|scam|hack|phish/i.test(line));
  }
  // An expiry already in the past must not render as a negative duration.
  ok("a stale expiry does not read as negative time",
     !/-/.test(chatStatusLine({state: "kick", until: 500}, 1000)));
}

// ---------------------------------------------------------------- input limits
{
  ok("no name is refused", chatValidate("", "hi") === "pick a name first");
  ok("no body is refused", chatValidate("al", "") === "type something");
  ok("whitespace only is refused", chatValidate("al", "   ") === "type something");
  ok("an ordinary message passes", chatValidate("al", "hello there") === "");
  ok("400 characters passes", chatValidate("al", "a".repeat(400)) === "");
  ok("401 is refused", chatValidate("al", "a".repeat(401)) !== "");
  ok("24 characters of name passes", chatValidate("a".repeat(24), "hi") === "");
  ok("25 is refused", chatValidate("a".repeat(25), "hi") !== "");
  // Runes, not UTF-16 units. 24 astral characters is .length 48, and counting units
  // would refuse a name the server accepts.
  ok("astral characters count as one each",
     chatValidate("\u{1D552}".repeat(24), "hi") === "");
  ok("...and 25 of them is still refused",
     chatValidate("\u{1D552}".repeat(25), "hi") !== "");
}

// ---------------------------------------------------------------- config
{
  ok("no config means no network", chatEndpoint(null) === "");
  ok("demo mode means no network", chatEndpoint({mode: "demo", chat: "http://x"}) === "");
  ok("an unset endpoint means no network", chatEndpoint({mode: "live"}) === "");
  ok("a trailing slash is trimmed",
     chatEndpoint({mode: "live", chat: "http://x:8791/"}) === "http://x:8791");
}

// ---------------------------------------------------------------- empty room
{
  const h = chatLogHtml([], 1000);
  ok("an empty room says so rather than rendering nothing", /Nobody has said/.test(h));
  ok("a null transcript does not throw", typeof chatLogHtml(null, 1000) === "string");
}

// ---------------------------------------------------------------- mounted panel
// A DOM stub, because the interesting failures are in the wiring rather than in the
// pure functions: which element gets written, and whether a stale poller writes at all.
function mkEl() {
  return {innerHTML: "", textContent: "", hidden: false, disabled: false, value: "",
    scrollHeight: 100, scrollTop: 100, clientHeight: 100, isConnected: true,
    handlers: {},
    // A classList, because without one mountChat's tagging line is simply unreachable
    // from a test and a mutation deleting it survives.
    classList: {names: new Set(), add(n) { this.names.add(n); },
                contains(n) { return this.names.has(n); }},
    addEventListener(t, f) { (this.handlers[t] = this.handlers[t] || []).push(f); },
    fire(t, ev) { for (const f of (this.handlers[t] || [])) f(ev || {preventDefault(){}}); }};
}
function mkRoot() {
  const kids = {};
  for (const c of [".chatlog", ".chatstate", ".chatnote", ".chatdry", ".chatform",
                   ".chatmoniker", ".chatinput", ".chatsend"]) kids[c] = mkEl();
  // Modelling the shell's own markup: chatPanelHtml emits `<div class="chatdry" hidden>`, so
  // the stub must start hidden or a test of "says nothing" passes on a stub default instead of
  // on the code. The real attribute is checked in web/tests/browser/chat_page.js.
  kids[".chatdry"].hidden = true;
  const root = mkEl();
  root.querySelector = s => kids[s] || null;
  root.k = kids;
  return root;
}
const tickMicro = () => new Promise(r => setImmediate(r));

// A document stub for the stylesheet injection. chat.js ships its own CSS so that
// installing the panel does not mean another edit to a page three workstreams share.
//
// The stylesheet is read back off the injected node rather than from the CHATCSS
// binding: a `const` at the top level of a direct eval does not leak into this scope,
// and reading what was actually appended is the more honest check anyway.
function mkDoc() {
  const byId = {};
  return {
    head: {children: [], appendChild(n) { this.children.push(n); byId[n.id] = n; }},
    getElementById: id => byId[id] || null,
    createElement: () => ({id: "", textContent: ""}),
  };
}
{
  const doc = mkDoc();
  chatStyles(doc);
  ok("the stylesheet is injected", doc.head.children.length === 1);
  const css = doc.head.children[0].textContent;
  ok("...carrying the classes the panel actually uses",
     /\.chatmsg/.test(css) && /\.chatlog/.test(css) && /\.chatsuf/.test(css));
  ok("...under an id, so it can be found again", doc.head.children[0].id === "chatcss");
  chatStyles(doc);
  chatStyles(doc);
  ok("...exactly once, however many panels mount", doc.head.children.length === 1);
  // A stylesheet is as good a place to smuggle markup as any, so it must stay static.
  ok("nothing is interpolated into the stylesheet",
     !/[$]\{/.test(css) && !/</.test(css) && !/>/.test(css));
  ok("chatStyles without a document does not throw",
     (() => { try { chatStyles(null); return true; } catch (e) { return false; } })());
}

(async () => {
  // DEMO MODE MAKES NO NETWORK CALLS. web/README.md promises this of the whole page,
  // and a chat panel is the easiest way to break it by accident.
  {
    FETCHES = [];
    const el = mkRoot();
    const doc = mkDoc();
    const stop = mountChat(el, {cfg: {mode: "demo"}, court: "orem", doc: doc});
    await tickMicro();
    ok("demo mode calls nothing over the network", FETCHES.length === 0);
    // Mounting must install the stylesheet and tag the container, or the panel ships
    // unstyled unless whoever integrates it also remembers to do both by hand.
    ok("mounting installs the stylesheet", doc.head.children.length === 1);
    ok("mounting tags the container", el.classList.contains("chatpanel"));
    ok("demo mode still shows a sample thread", /ellery/.test(el.k[".chatlog"].innerHTML));
    ok("the demo sample is escaped like anything else",
       !/<b>|<script/i.test(el.k[".chatlog"].innerHTML));
    el.k[".chatform"].fire("submit");
    ok("submitting in demo mode says so instead of posting",
       /demo/i.test(el.k[".chatnote"].textContent) && FETCHES.length === 0);
    stop();
  }

  // THE REGRESSION: a refused post carries a status and no messages, and the first
  // version of paint() took both at once — so telling somebody they were paused also
  // erased the transcript they were reading.
  {
    FETCHES = [];
    FETCH = async () => ({ok: true, json: async () => ({
      messages: [{id: 1, moniker: "ellery", body: "still here", country: "GB",
                  suffix: "a1b2c3", created_at: Math.floor(Date.now() / 1000)}],
      you: {state: "ok"}, next: 1})});
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"},
                                court: "orem", chain: "dev"});
    await tickMicro(); await tickMicro();
    ok("a live mount paints the transcript", /still here/.test(el.k[".chatlog"].innerHTML));
    const before = el.k[".chatlog"].innerHTML;

    // Now a refused POST.
    FETCH = async (url, init) => (init && init.method === "POST")
      ? {ok: false, status: 403, json: async () => ({
          error: "posting is blocked for this address",
          you: {state: "kick", until: Math.floor(Date.now() / 1000) + 1800, ref: 9}})}
      : {ok: true, json: async () => ({messages: [], you: {state: "ok"}, next: 0})};
    el.k[".chatmoniker"].value = "alice";
    el.k[".chatinput"].value = "let me back in";
    el.k[".chatform"].fire("submit");
    await tickMicro(); await tickMicro(); await tickMicro();

    ok("a refusal is shown to the sender", /blocked/i.test(el.k[".chatnote"].textContent));
    ok("a refusal explains the pause", /paused/i.test(el.k[".chatstate"].textContent));
    ok("a refusal does NOT erase the transcript", el.k[".chatlog"].innerHTML === before);
    ok("a paused sender's composer is disabled", el.k[".chatinput"].disabled === true);
    stop();
  }

  // A POST must send application/json. text/plain is CORS-safelisted, so a form-style
  // post would skip the preflight the server relies on; see chat.csrfOK.
  {
    FETCHES = [];
    let sent = null;
    FETCH = async (url, init) => {
      if (init && init.method === "POST") { sent = init; return {ok: true, json: async () => ({id: 5})}; }
      return {ok: true, json: async () => ({messages: [], you: {state: "ok"}, next: 0})};
    };
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem"});
    await tickMicro(); await tickMicro();
    el.k[".chatmoniker"].value = "alice";
    el.k[".chatinput"].value = "hello";
    el.k[".chatform"].fire("submit");
    await tickMicro(); await tickMicro();
    ok("a post declares application/json",
       sent && sent.headers["Content-Type"] === "application/json");
    ok("a successful post clears the box", el.k[".chatinput"].value === "");
    ok("the moniker is remembered", STORE["kourt.chat.moniker"] === "alice");
    stop();
  }

  // A STALE POLLER MUST NOT WRITE. render() is async and re-entrant, so a tick from a
  // previous mount can resolve after its DOM has been replaced. Without the
  // generation check this writes a transcript into a discarded panel — or, worse,
  // paints one court's messages into another court's page.
  {
    let release;
    FETCH = () => new Promise(r => { release = () => r({ok: true, json: async () => ({
      messages: [{id: 1, moniker: "stale", body: "from the old mount", country: "",
                  suffix: "", created_at: 1000}], you: {state: "ok"}, next: 1})}); });
    const oldEl = mkRoot();
    mountChat(oldEl, {cfg: {mode: "live", chat: "http://x"}, court: "orem"});
    await tickMicro();               // the first tick is now waiting on fetch

    const newEl = mkRoot();          // a re-render replaces the panel
    FETCH = async () => ({ok: true, json: async () => ({
      messages: [], you: {state: "ok"}, next: 0})});
    const stop = mountChat(newEl, {cfg: {mode: "live", chat: "http://x"}, court: "logan"});
    await tickMicro();

    release();                       // the OLD fetch finally answers
    await tickMicro(); await tickMicro(); await tickMicro();
    ok("a stale poller does not paint into its discarded panel",
       !/from the old mount/.test(oldEl.k[".chatlog"].innerHTML));
    ok("...and does not paint into the live one either",
       !/from the old mount/.test(newEl.k[".chatlog"].innerHTML));
    stop();
  }

  // The service being down must not blank a transcript that is already on screen, and
  // must not be mistaken for an empty room.
  {
    const now = Math.floor(Date.now() / 1000);
    FETCH = async () => ({ok: true, json: async () => ({
      messages: [{id: 1, moniker: "tosh", body: "readable", country: "JP",
                  suffix: "40de71", created_at: now}], you: {state: "ok"}, next: 1})});
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                interval: 5});
    await tickMicro(); await tickMicro();
    ok("the transcript is on screen", /readable/.test(el.k[".chatlog"].innerHTML));
    FETCH = async () => { throw new Error("connection refused"); };
    await new Promise(r => setTimeout(r, 40));
    ok("an outage says so", /unreachable/i.test(el.k[".chatnote"].textContent));
    ok("an outage does not blank what is already readable",
       /readable/.test(el.k[".chatlog"].innerHTML));
    stop();
  }

  // COMING BACK TO THE TAB MUST REFRESH AT ONCE.
  //
  // The poller backs off to 60s while the tab is hidden, which is right: a court page left open
  // overnight in a background tab is a poller nobody is reading. But the interval is chosen when
  // the timer is SET, and nothing listened for coming back — so a reader who switched away for two
  // seconds and returned waited out the rest of that minute in front of a transcript that was not
  // moving, and a `you` block that is how somebody learns their own timeout has expired.
  //
  // Four arms, because the obvious fix breaks the thing it is helping: a listener that fires
  // regardless of document.hidden would defeat the backoff entirely, and one that is not removed
  // would leak per mount on a panel that remounts on navigation.
  {
    let fetches = 0;
    FETCH = async () => { fetches++; return {ok: true, json: async () => ({
      messages: [], you: {state: "ok"}, next: 1})}; };
    const el = mkRoot();
    // Measured as a DELTA, not an absolute: an earlier case above mounts a panel and discards
    // its stop function, so the global listener list is not empty here and asserting that it is
    // would fail on somebody else's leak.
    const before = document.listeners("visibilitychange").length;
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                interval: 5});
    // The fixture's own precondition. If the guard in mountChat decides this document cannot
    // listen, every arm below passes without exercising anything.
    ok("mounting registers a visibility listener",
       document.listeners("visibilitychange").length === before + 1);
    await new Promise(r => setTimeout(r, 30));
    ok("the poller is running while visible", fetches > 0);

    document.hidden = true;
    await new Promise(r => setTimeout(r, 30));   // one more tick lands, then parks at 60s
    const parked = fetches;
    await new Promise(r => setTimeout(r, 40));
    ok("a hidden tab stops polling", fetches === parked);

    // THE PAIRED NEGATIVE, first: an event while still hidden must change nothing, or the
    // listener would have undone the backoff it exists to compensate for.
    document.dispatchEvent({type: "visibilitychange"});
    await new Promise(r => setTimeout(r, 20));
    ok("...and an event while STILL hidden does not wake it", fetches === parked);

    document.hidden = false;
    document.dispatchEvent({type: "visibilitychange"});
    await new Promise(r => setTimeout(r, 20));
    ok("returning to the tab refreshes without waiting out the minute", fetches > parked);

    // And the listener is gone on unmount. Asserted on the registration itself rather than on
    // the fetch count, because live() would also stop a leaked listener from fetching — so
    // counting fetches would pass with the leak still there.
    stop();
    ok("unmounting removes the listener rather than leaving one per visit",
       document.listeners("visibilitychange").length === before);
    document.hidden = false;
  }

  // THE PANEL NO LONGER TELLS READERS ABOUT MODERATION MODE, and this replaced the
  // assertions that it must.
  //
  // It printed "Automatic moderation is not applying timeouts on this server right now"
  // whenever health.enforcing was false. The reasoning was sound in the abstract —
  // silence could let the panel imply a protection nobody is providing — but a scanner
  // that has not been started is the NORMAL state of a fresh deployment, so the line sat
  // permanently on the live site telling ordinary readers something only an operator can
  // act on. The panel makes no positive claim about moderation anywhere else, so dropping
  // it withdraws no promise. Owner's call, 2026-08-19.
  //
  // What is asserted instead: that it is GONE, all of it, rather than merely hidden
  // behind a flag somebody can flip back on by accident.
  {
    const SRCTEXT = require("fs").readFileSync(SRC, "utf8");   // SRC is a path
    ok("no reader-facing dry-run wording is exported",
       typeof chatDryRunNotice === "undefined");
    ok("the wording is not in the file at all",
       !/return "Automatic moderation is not applying/.test(SRCTEXT));
    ok("and there is no slot in the markup for it", !/class="chatdry"/.test(SRCTEXT));
    ok("nor a style for one", !/\.chatdry\{/.test(SRCTEXT));
    // `enforcing` stays PUBLIC on the endpoint — CHAT.md keeps it public on an asymmetry
    // rather than on comfort, and an operator has to be able to see it. The fetch also
    // still carries appeal_to, which the panel DOES show.
    ok("health is still fetched", typeof chatHealth === "function");
    ok("...and appeal_to still reaches the panel", /appeal_to/.test(SRCTEXT));
  }

  // Demo mode must not reach the network for this either.
  {
    FETCHES = [];
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "demo"}, court: "orem", doc: mkDoc()});
    await tickMicro(); await tickMicro();
    ok("the health check does not fire in demo mode", FETCHES.length === 0);
    stop();
  }

  // A CLOSED COURT IS NOT A BROKEN ONE. 410 means an operator withdrew the court from
  // service, and reporting that as "unreachable" sends a reader to reload and an operator
  // to check the network for something working exactly as intended. It must also stop
  // polling — asking again is a request nobody will ever answer.
  {
    const now = Math.floor(Date.now() / 1000);
    let calls = 0;
    FETCH = async () => {
      calls++;
      return {ok: true, json: async () => ({
        messages: [{id: 1, moniker: "tosh", body: "said before the freeze", country: "JP",
                    suffix: "40de71", created_at: now}], you: {state: "ok"}, next: 1})};
    };
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                interval: 5});
    await tickMicro(); await tickMicro();
    ok("the transcript is on screen before the freeze",
       /said before the freeze/.test(el.k[".chatlog"].innerHTML));

    FETCH = async () => ({ok: false, status: 410, json: async () => ({
      error: "this court is no longer served"})});
    await new Promise(r => setTimeout(r, 40));

    ok("a closed court says closed, not unreachable",
       /closed/i.test(el.k[".chatnote"].textContent));
    ok("...and does NOT say unreachable",
       !/unreachable/i.test(el.k[".chatnote"].textContent));
    ok("...the state line explains it without blaming the reader",
       /closed/i.test(el.k[".chatstate"].textContent) &&
       !/paused|blocked/i.test(el.k[".chatstate"].textContent));
    ok("...the composer is disabled", el.k[".chatinput"].disabled === true);
    const after = calls;
    await new Promise(r => setTimeout(r, 60));
    ok("...and it stops polling a court that will never answer", calls === after);
    stop();
  }

  // stop() must actually stop, or every re-render leaves another poller behind.
  //
  // The obvious version of this test counted fetches after stop() and passed even with
  // clearTimeout deleted — the generation check alone makes a stale tick do nothing, so
  // counting work measures the guard and never the cleanup. The timer itself is what
  // clearTimeout is for, so the timer is what is counted: a pending callback holds its
  // closure, and through it the whole detached panel, until it fires.
  {
    // Counts TRANSCRIPT fetches only. A mount also asks /api/chat/health once, for the
    // dry-run notice, and counting every request made this assertion fail for a reason that
    // had nothing to do with the poller.
    let calls = 0;
    FETCH = async url => {
      if (String(url).includes("/health")) {
        return {ok: true, json: async () => ({ok: true, enforcing: true})};
      }
      calls++;
      return {ok: true, json: async () => ({messages: [], you: {state: "ok"}, next: 0})};
    };
    const pending = new Set();
    const realSet = global.setTimeout, realClear = global.clearTimeout;
    global.setTimeout = (f, d) => { const id = realSet(f, d); pending.add(id); return id; };
    global.clearTimeout = id => { pending.delete(id); return realClear(id); };
    try {
      // A LONG INTERVAL FOR THE COUNTING HALF, and this is not a detail.
      // It used to be 5ms, so the poller's own timer could fire in the gap
      // between mounting and counting — two microtask ticks take no time at all
      // on an idle machine and comfortably more than 5ms on a busy one. The
      // result was a gate that passed alone and failed about one run in twenty
      // inside `make check`, which is the worst kind: it blocked a good commit
      // and taught whoever hit it to re-run rather than to look.
      // Nothing here waits for the timer to FIRE — it asserts that exactly one
      // exists and that one fetch happened — so a 30s interval measures the
      // same thing and cannot race.
      const el = mkRoot();
      const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                  interval: 30000});
      // Only setImmediate is used to yield here, so nothing but the poller can be
      // holding a setTimeout at the point it is counted.
      await tickMicro(); await tickMicro();
      ok("the poller reschedules itself after a tick", pending.size === 1);
      ok("...having actually fetched", calls === 1);
      stop();
      ok("stop() clears the pending timer", pending.size === 0);
      // The other half, on its own mount and deliberately still short: HERE the
      // timer firing is the whole point. If stop() failed to clear it, a 5ms
      // poller fires many times inside 60ms — and a slow machine only makes
      // this stricter, never flakier.
      calls = 0;
      const el2 = mkRoot();
      const stop2 = mountChat(el2, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                    interval: 5});
      await tickMicro(); await tickMicro();
      stop2();
      const after = calls;
      await new Promise(r => realSet(r, 60));
      ok("stop() ends the poller", calls === after);
    } finally {
      global.setTimeout = realSet;
      global.clearTimeout = realClear;
    }
  }

  // A READER WHOSE CLOCK IS WRONG MUST STILL SEE THE RIGHT AGES.
  //
  // Every message carries an absolute created_at and the panel renders it by subtracting. Measured
  // through the shipped chatWhen before the server sent its own clock: a client ten minutes FAST
  // read a message posted one second ago as "10m", and one two hours SLOW read a two-hour-old
  // message as "just now" — which in a court misrepresents the order things were said in.
  //
  // This drives the WHOLE path — chatFetch, the offset it learns, and the render — because that is
  // where the bug actually was. The first fix looked correct and did nothing: chatFetch returns an
  // explicit allowlist and dropped `now` on the floor, so the panel had nothing to learn from. A
  // hand-simulation of the arithmetic passed while the code was still broken, because the
  // simulation never went through chatFetch.
  {
    const serverNow = Math.floor(Date.now() / 1000);
    const reply = withNow => ({ok: true, json: async () => Object.assign({
      messages: [{id: 1, moniker: "ellery", body: "posted just this second", country: "GB",
                  suffix: "a1b2c3", created_at: serverNow}],
      you: {state: "ok"}, next: 1}, withNow ? {now: serverNow} : {})});

    // Ten minutes fast, so an uncorrected answer is "10m" and unmistakable.
    FETCH = async () => reply(true);
    const el = mkRoot();
    const stop = mountChat(el, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                chain: "dev", now: () => (serverNow + 600) * 1000});
    await tickMicro(); await tickMicro();
    const age = (el.k[".chatlog"].innerHTML.match(/chatage">([^<]*)</) || [])[1] || "";
    ok("a reader ten minutes fast sees a fresh message as recent: " + JSON.stringify(age),
       age === "just now");
    stop();

    // THE DISCRIMINATING CASE: with no `now` in the reply there is nothing to learn from, so the
    // same panel falls back to the local clock and reads 10m. Without this, the assertion above
    // would pass for a panel that ignored the clock entirely.
    FETCH = async () => reply(false);
    const el2 = mkRoot();
    const stop2 = mountChat(el2, {cfg: {mode: "live", chat: "http://x"}, court: "orem",
                                  chain: "dev", now: () => (serverNow + 600) * 1000});
    await tickMicro(); await tickMicro();
    const age2 = (el2.k[".chatlog"].innerHTML.match(/chatage">([^<]*)</) || [])[1] || "";
    ok("...and without the server's clock it falls back, which is what makes that meaningful: "
       + JSON.stringify(age2), age2 === "10m");
    stop2();
  }

  // A 413 IS A STATUS THE PANEL HAD NEVER SEEN, and the server started sending one this commit:
  // an oversize request used to be reported as malformed JSON, and now says "the request is too
  // large; a message may be up to 4096 bytes" with 413 instead of 400.
  //
  // chatPost maps 429 and 410 by hand and falls back to "could not send (N)" for anything else, so
  // the question is whether the server's own sentence survives a status the panel does not know. It
  // does, because d.error wins — but that is worth an assertion rather than a reading of the code,
  // since the fallback would show a bare number to somebody who only needs to send less.
  {
    FETCH = async (url, init) => (init && init.method === "POST")
      ? {ok: false, status: 413, json: async () => ({
          error: "the request is too large; a message may be up to 4096 bytes"})}
      : {ok: true, json: async () => ({messages: [], you: {state: "ok"}, next: 0})};
    const r = await chatPost("http://x", "dev", "orem", "alice", "x".repeat(50));
    ok("a 413 shows the server's sentence", /request is too large/.test(r.error));
    ok("...and names the limit rather than a status code", /4096/.test(r.error));
    ok("...and does not fall back to \"could not send\"", !/could not send/.test(r.error));
    ok("...and reports failure", r.ok === false);

    // The paired case: with no error field the fallback is used, so the assertions above are about
    // d.error winning and not about 413 being special-cased.
    FETCH = async (url, init) => (init && init.method === "POST")
      ? {ok: false, status: 413, json: async () => ({})}
      : {ok: true, json: async () => ({messages: [], you: {state: "ok"}, next: 0})};
    const bare = await chatPost("http://x", "dev", "orem", "alice", "x");
    ok("without a server sentence it still says something", typeof bare.error === "string" &&
       bare.error.length > 0);
  }


  /* ---- how the page decides there is a chat service at all -----------------
     This file evaluates chat.js whole and does not otherwise read index.html;
     it reads it here because the decision that the panel exists is made there.

     Chat used to be off until CFG.chat named a service, under a deliberate
     rule: a page opened out of somebody's Downloads folder must never start
     posting to a host nobody named. Right for file://, and fatal once the page
     is DEPLOYED — kourt.xyz served a court page with no chat box, because every
     visitor would first have had to paste a URL into a settings panel. Nobody
     does that. A SERVED origin is not a guess: the operator named it by
     deploying there. */
  {
    const page = require("fs").readFileSync(
      require("path").join(__dirname, "..", "index.html"), "utf8");
    ok("a served page defaults to its own origin",
      page.includes('return /^https?:$/.test(location.protocol) ? location.origin : "";'));
    ok("file:// still gets nothing, which is the case the rule was written for",
      /defaultChatBase[\s\S]{0,200}location\.origin : ""/.test(page));
    // THREE states, not two. Without the empty string surviving cleanCfg,
    // clearing the field would hand the default straight back on reload.
    ok("an explicit blank survives cleanCfg", page.includes('else if(c.chat==="") out.chat="";'));
    ok("chatBase prefers an explicit value over the default",
      page.includes("return (CFG.chat === undefined) ? defaultChatBase() : CFG.chat;"));
    ok("clearing the field records the decision rather than deleting the key",
      page.includes('CFG.chat = v || "";') && !page.includes("delete CFG.chat"));
    // Resolved at mount, never stored: persisting it would pin the page to
    // whichever host it was first opened from.
    ok("the origin is never persisted", page.includes("{cfg: {...CFG, chat: chatBase()}"));
    ok("the settings field says what it will use",
      page.includes('chatin.placeholder = dflt ? dflt + "  (this site)"'));
    // index.html loads exactly one local file, and the deploy must ship it.
    const loads = [...page.matchAll(/<script src="([^"]+)"/g)].map(m => m[1]);
    ok("index.html loads only chat.js", loads.length === 1 && loads[0] === "chat.js",
      JSON.stringify(loads));
  }

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
