// Court chat, client side.
//
// A standalone file rather than another block inside index.html, for two reasons.
// The page is one 20k-line document that several workstreams edit at once, and this
// is the one feature whose input is entirely attacker-controlled — it is worth being
// able to read all of it at once. Everything here is a plain function on `window`,
// same as the rest of the page; there is no bundler and no module system.
//
// THE THREAT MODEL, because it is not the usual one. Every string this file renders
// was typed by an anonymous stranger with no account, and the server deliberately
// does NOT strip markup: internal/chat.SanitizeBody erases invisible characters and
// normalises width, and otherwise preserves exactly what the author wrote, so that
// what the moderator's model reads is what a human reads. That decision puts the
// entire burden of not executing it here. Three rules follow, and none of them may
// be relaxed for a nicer-looking panel:
//
//   1. Every interpolated value goes through chatEsc. No exceptions, including
//      monikers, country codes and numbers.
//   2. Nothing is ever linkified. A scam works when its link is clickable; the whole
//      point of the moderator is defeated if the panel upgrades "gnot-claim.xyz"
//      into an anchor while the classifier is still deciding. URLs render as text.
//   3. The log is REPLACED from a full fetch, never appended to incrementally. See
//      chatFetch: moderation has to be able to take a message away.
//
// WHAT A MONIKER IS WORTH: nothing. Nobody owns "alice" and there is no login. What
// makes the room legible is `suffix` — six hex characters derived from the author's
// address, salted per court and per day. Two people typing the same name have
// different suffixes, so impersonation is visible. The suffix is therefore rendered
// inseparably from the name and must never be dropped as visual clutter; without it
// the panel actively invites impersonation. It rotates daily on purpose, so it is
// recognition within a conversation and never an identity to trust across days.

// CHATLIMITS mirrors the server's limits, and it is one object because it was five values.
//
// internal/chat/sanitize.go enforces these; the panel repeats them so a user hears "too long"
// before a round trip rather than after one. That makes them two definitions of one thing in
// two languages, which is the shape that has produced most of the bugs in this service — so
// they are declared once here and internal/chat/paneldrift_test.go reads this file and fails if
// the numbers stop matching the constants.
//
// Drift is bad in both directions and neither is loud: too small refuses text the server would
// happily take, too large accepts text the server then rejects with a 400 the user cannot act
// on. `maxlength` is included because it physically stops typing, so a stale value there is a
// capability quietly removed rather than a message shown.
const CHATLIMITS = {body: 400, moniker: 24, bytes: 4096};

// CHATMONIKERUNITS is the `maxlength` attribute's crude keystroke stop, in UTF-16
// units, and it is deliberately LOOSER than the real check below. The moniker's
// limit counts LETTERS, not code points, because in Hebrew, Arabic, Thai and
// Devanagari a letter costs two or three code points: an eighteen-letter voweled
// Arabic name is 34 of them, and a maxlength of 24 would stop it being TYPED with
// no message at all. chatValidate gives the reason; this only bounds a paste.
const CHATMONIKERUNITS = CHATLIMITS.moniker * 4;

// chatLetters counts what a reader sees, mirroring countAgainstLimit(_, countMarks)
// in internal/chat/sanitize.go. The predicate must match the server's EXACTLY —
// \p{Mn} and \p{Me} but NOT \p{Mc}, which is what Go's unicode.Mn/Me tests, plus
// the three joiners — or the panel and the server disagree about one name and the
// composer either refuses text the server takes or accepts text it will reject.
const CHATSKIP = /[\p{Mn}\p{Me}\u200C\u200D\uFE0F]/u;
function chatLetters(s) {
  let n = 0;
  for (const ch of String(s)) if (!CHATSKIP.test(ch)) n++;
  return n;
}

// chatEsc escapes into HTML text or a double-quoted attribute.
//
// Single quote and backtick are in here beyond the usual four on purpose: the page's
// own esc() covers only &<>" , which is correct for its own inputs and not for
// these, and a later edit that switches an attribute to single quotes would silently
// open the hole back up.
function chatEsc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
    .replace(/`/g, "&#96;");
}

// chatFlag turns "DE" into a flag. Anything that is not exactly two ASCII letters
// returns "" — an unknown country renders as no flag rather than as a guess, and the
// strict test is also what stops an arbitrary code point being assembled out of a
// field that arrived over the network.
function chatFlag(cc) {
  const s = String(cc == null ? "" : cc).toUpperCase();
  if (!/^[A-Z]{2}$/.test(s)) return "";
  return String.fromCodePoint(0x1f1e6 + s.charCodeAt(0) - 65,
                              0x1f1e6 + s.charCodeAt(1) - 65);
}

// chatWhen renders an age, coarsely and without a locale.
//
// Coarse is the point: a per-second timestamp on an anonymous message is a traffic
// analysis aid, and "3m" is everything a reader needs. A negative difference means
// the viewer's clock is behind the server's, which is common and not worth reporting
// as "in 4 minutes".
function chatWhen(nowSec, thenSec) {
  const d = Math.floor(nowSec - thenSec);
  if (!isFinite(d) || d < 45) return "just now";
  if (d < 90 * 60) return Math.round(d / 60) + "m";
  if (d < 36 * 3600) return Math.round(d / 3600) + "h";
  return Math.round(d / 86400) + "d";
}

// chatStatusLine turns the server's `you` into a sentence.
//
// The server sends state, an expiry and an opaque reference, and deliberately NOT the
// category or the classifier's reasoning — those would make the endpoint an oracle
// for tuning an evasion. So this cannot say what someone did, only that they are
// paused and until when, and it must not invent a reason.
function chatStatusLine(you, nowSec, appealTo) {
  const st = you && you.state ? String(you.state) : "ok";
  if (st === "ok") return "";
  // Not a punishment and must not read like one: the court was withdrawn, which says
  // nothing about the person reading it.
  if (st === "closed") return "This court's chat has been closed.";
  const until = you && you.until ? Number(you.until) : 0;
  const ref = you && you.ref ? Number(you.ref) : 0;

  // PREFER THE SERVER'S OWN COUNTDOWN. `until` is an absolute time and this clock is not the
  // one that set it, so differencing them shows the reader their own skew.
  //
  // Measured against a five-minute kick: a client ten minutes SLOW read "paused for another 15
  // minutes", wrong by three times over, and one ten minutes FAST lost the duration entirely and
  // was told only "paused", with nothing to say when to come back. Browsers take their time from
  // the OS and a machine minutes out is ordinary.
  //
  // `seconds` is computed where `until` was, so it needs no clock here at all. `until` is kept as
  // the fallback for a server that does not send it, and because an appeal can quote a time.
  const fromServer = you && you.seconds ? Number(you.seconds) : 0;
  let when = "";
  if (fromServer > 0 || until > nowSec) {
    const left = fromServer > 0 ? fromServer : until - nowSec;
    // Pluralised, because "paused for another 1 hours" is what a punished person reads while
    // deciding whether this service is careless. Noticed in a live walk-through, not a test.
    const unit = (n, word) => n + " " + word + (n === 1 ? "" : "s");
    when = " for another " + (left < 3600 ? unit(Math.max(1, Math.round(left / 60)), "minute")
         : left < 86400 ? unit(Math.round(left / 3600), "hour")
         : unit(Math.round(left / 86400), "day"));
  }
  const what = st === "ban"
    ? "Posting from your connection is blocked"
    : "Posting from your connection is paused" + when;
  // The reference exists so an appeal can quote something specific — but only say "you can
  // appeal" when there is somewhere to send it. This line used to promise an appeal with no
  // channel anywhere in the service: not in this file, not in kourtchatctl, not in CHAT.md.
  // The whole operator surface exists to service appeals and the person invited to make one
  // had nowhere to go, which is a dead end wearing the word "process".
  //
  // With no contact configured it still gives the reference, because that is useful to somebody
  // who finds a channel another way, and it makes no claim about one that does not exist.
  if (!ref) return what + ".";
  if (appealTo) {
    return what + ". To appeal, quote reference " + ref + " to " + appealTo + ".";
  }
  return what + ". Reference " + ref + ".";
}

// chatValidate mirrors the server's limits so the answer arrives before the round
// trip. It is a courtesy and not a control: the server re-checks everything, because
// anything checked only here is not checked.
//
// Runes, not UTF-16 units: "𝕒".length is 2 and [..."𝕒"].length is 1, and the server
// counts the latter. Counting wrong here means refusing text the server accepts.
function chatValidate(moniker, body) {
  const m = String(moniker == null ? "" : moniker).trim();
  const b = String(body == null ? "" : body).trim();
  if (!m) return "pick a name first";
  if (chatLetters(m) > CHATLIMITS.moniker) {
    return "that name is too long (" + CHATLIMITS.moniker + " letters)";
  }
  if (!b) return "type something";
  if ([...b].length > CHATLIMITS.body) {
    return "that message is too long (" + CHATLIMITS.body + " characters)";
  }
  // Mirrors MaxInputBytes on the server, and it is NOT reachable today — this comment used to
  // claim it was, "reachable with astral characters at the rune cap", and the arithmetic says
  // otherwise. UTF-8 tops out at four bytes per rune, so a body at the rune cap cannot exceed
  // CHATLIMITS.body * 4 bytes, which is comfortably under CHATLIMITS.bytes; and the rune check
  // above fires first for anything longer. Measured through this function: a body of astral
  // characters exactly at the rune cap validates clean, and one character more is refused by the
  // RUNE check rather than by this one.
  //
  // (Spelled with the constants rather than their values on purpose. TestThePanelsLimitsMatch-
  // TheServers forbids a bare limit literal anywhere in this function, comments included, because
  // a number written here today is a number copied into the code tomorrow — and it caught this
  // comment when it was first written with the digits in.)
  //
  // Kept rather than deleted, because it stops mirroring the server the moment somebody raises the
  // rune cap above a quarter of the byte cap — and deleting a guard that becomes necessary exactly
  // when a constant changes is how the panel drifts from the server. The relationship is pinned in
  // TestThePanelsByteCapIsUnreachableUntilTheRuneCapMoves, which fails loudly if it goes live.
  //
  // It names its limit for that day. Left as a bare "too long" it was the one refusal here that
  // did not say what would be accepted, and it disagreed with the server's sentence for the same
  // rule — neither noticed, because the branch never ran.
  if (new TextEncoder().encode(b).length > CHATLIMITS.bytes) {
    return "that message is far too long to process (" + CHATLIMITS.bytes + " bytes)";
  }
  return "";
}

// chatLineHtml renders one message.
function chatLineHtml(m, nowSec) {
  const flag = chatFlag(m.country);
  const suffix = /^[0-9a-f]{1,16}$/.test(String(m.suffix || "")) ? m.suffix : "";
  return '<li class="chatmsg">'
    + '<span class="chatwho">'
    + (flag ? '<span class="chatflag" title="' + chatEsc(String(m.country).toUpperCase())
              + '">' + flag + "</span>" : "")
    + '<span class="chatname">' + chatEsc(m.moniker) + "</span>"
    + (suffix ? '<span class="chatsuf" title="derived from the sender&#39;s connection,'
                + ' rotates daily">&middot;' + chatEsc(suffix) + "</span>" : "")
    + "</span>"
    + '<span class="chatbody">' + chatEsc(m.body) + "</span>"
    + '<span class="chatage">' + chatEsc(chatWhen(nowSec, m.created_at)) + "</span>"
    + "</li>";
}

// chatLogHtml renders the whole transcript.
function chatLogHtml(msgs, nowSec) {
  const list = Array.isArray(msgs) ? msgs : [];
  if (!list.length) {
    return '<li class="chatempty">Nobody has said anything about this court yet.</li>';
  }
  return list.map(m => chatLineHtml(m, nowSec)).join("");
}

// chatPanelHtml renders the SHELL only — never the transcript.
//
// The obvious implementation re-renders the whole panel on every poll, which deletes
// whatever the user was halfway through typing every few seconds. The shell is built
// once and only .chatlog and .chatstate are written afterwards.
function chatPanelHtml(slug, moniker, note) {
  return ""
    + '<div class="chathead">'
    +   "<b>Chat</b> <span class=\"chatslug\">" + chatEsc(slug) + "</span>"
    +   '<span class="chatwarn">names are unverified &mdash; nobody here is staff,'
    +     " and nobody can move funds for you</span>"
    +   '<span class="chatdemo" hidden></span>'
    + "</div>"
    + '<ol class="chatlog" aria-live="polite"></ol>'
    + '<div class="chatstate"></div>'
    + '<form class="chatform" autocomplete="off">'
    +   '<input class="chatmoniker" maxlength="' + CHATMONIKERUNITS + '" placeholder="name"'
    +     ' aria-label="your name" value="' + chatEsc(moniker) + '">'
    +   '<input class="chatinput" maxlength="' + CHATLIMITS.body + '" placeholder="say something"'
    +     ' aria-label="message">'
    +   '<button class="chatsend" type="submit">send</button>'
    + "</form>"
    + '<div class="chatnote">' + chatEsc(note || "") + "</div>";
}

// A deterministic sample thread for demo mode.
//
// web/README.md promises the demo makes no network calls, so demo mode must not hit
// the chat service either — and an empty panel would misrepresent the feature. Fixed
// ages rather than a clock, so two loads of the demo look identical.
function chatDemoThread(slug) {
  const now = 1700000000;
  return {
    messages: [
      {id: 1, moniker: "ellery", country: "GB", suffix: "9c14ab",
       body: "is the settle window on this one still open?", created_at: now - 5400},
      {id: 2, moniker: "tosh", country: "JP", suffix: "40de71",
       body: "closed about an hour ago, the answer stood", created_at: now - 3300},
      {id: 3, moniker: "ellery", country: "GB", suffix: "9c14ab",
       body: "thanks. the wording of the claim was ambiguous imo",
       created_at: now - 2400},
      {id: 4, moniker: "rho", country: "BR", suffix: "77b0e2",
       body: "agreed, \"substantially complete\" is doing a lot of work there",
       created_at: now - 600},
    ],
    you: {state: "ok"},
    next: 4,
    now: now,
  };
}

// chatEndpoint resolves the service URL, and returns "" for "do not use the
// network".
//
// NAMED chatEndpoint, NOT chatBase, AND THAT RENAME IS A BUG FIX. index.html
// declares its own global `function chatBase()` — no argument, resolving the
// origin when nothing is configured — in an inline script that is evaluated
// AFTER this file loads. Same name, so the later declaration won and this
// function was unreachable in the page: measured, chatBase.length was 0 there.
//
// What that silently removed is the demo guard below. mountChat called
// chatBase(o.cfg) and got index.html's version, which ignores its argument and
// answers from the global CFG — so a page in DEMO mode with an endpoint
// configured issued real requests against sample data:
//
//     GET http://…/api/chat/health
//     GET http://…/api/chat/dev/orem?limit=50
//
// The four assertions that prove this guard works kept passing, because the
// harness slices this file alone and never sees the collision.
//
// Absent config means off, not a default host: a page that quietly starts posting to
// a guessed origin because nobody configured one is worse than a page with no chat.
function chatEndpoint(cfg) {
  if (!cfg || cfg.mode === "demo") return "";
  const b = String(cfg.chat || "").trim();
  if (!b) return "";
  return b.replace(/\/+$/, "");
}

// chatFetch reads a court's transcript.
//
// FULL FETCH, NO `since`. The endpoint supports incremental reads and this panel
// deliberately does not use them: internal/chat.Recent only returns messages that
// have not been hidden, so a client that appends by id would keep displaying a scam
// for the rest of the session after the moderator hid it. Re-reading the last 50 rows
// every few seconds is how hiding becomes visible at all. Cheap, and bounded by the
// server's own clamp.
async function chatFetch(base, chain, court, limit) {
  const url = base + "/api/chat/" + encodeURIComponent(chain) + "/"
    + encodeURIComponent(court) + "?limit=" + (limit || 50);
  const r = await fetch(url, {method: "GET", cache: "no-store"});
  // 410 is a decision, not a fault. A court withdrawn from service must not be reported
  // as "unreachable" — that sends a reader to reload, and an operator to check the
  // network, for something that is working exactly as intended.
  if (r.status === 410) {
    const gone = new Error("chat for this court is closed");
    gone.closed = true;
    throw gone;
  }
  if (!r.ok) throw new Error("chat unavailable (" + r.status + ")");
  const d = await r.json();
  return {
    messages: Array.isArray(d.messages) ? d.messages : [],
    you: d.you || {state: "ok"},
    next: Number(d.next || 0),
    // `now` is the server's clock and must survive this allowlist, or the skew correction in
    // mountChat has nothing to learn from. Omitting it failed SILENTLY: the panel fell back to
    // the local clock, and a browser test reading "10m" for a message posted a second ago is
    // what caught it — after a hand-simulation of the arithmetic had already "passed", because
    // the simulation never went through this function.
    now: Number(d.now || 0),
  };
}

// chatHealth asks whether moderation is actually applying timeouts.
//
// §6 says the panel must not claim moderation that is not happening, and until now nothing
// implemented that — no client in the repo fetched this endpoint at all, while CHAT.md said
// WHAT THIS NO LONGER DOES: tell readers when moderation is in dry run. The panel used to
// print "Automatic moderation is not applying timeouts on this server right now" whenever
// health.enforcing was false — a scanner that has not been started yet is the normal state
// of a fresh deployment, so the line sat on the site permanently, telling ordinary readers
// something only an operator can act on. It is not a protection the panel claims anywhere
// else, so dropping the line withdraws no promise; `enforcing` stays public on the health
// endpoint, which is where an operator looks.
// the panel derived its label from it. One request per mount, and a failure is silent: not
// knowing is not the same as knowing it is off, and a wrong warning is worse than none.
async function chatHealth(base) {
  try {
    const r = await fetch(base + "/api/chat/health", {cache: "no-store"});
    if (!r.ok) return null;
    const d = await r.json();
    return typeof d.enforcing === "boolean" ? d : null;
  } catch (e) {
    return null;
  }
}

// chatPost sends one message.
//
// Content-Type: application/json is REQUIRED by the server and is not decoration —
// it is what forces a cross-origin POST through a preflight, because text/plain is
// CORS-safelisted and would execute unseen. See chat.csrfOK. Do not "simplify" this
// to a form post.
async function chatPost(base, chain, court, moniker, body) {
  const r = await fetch(base + "/api/chat/" + encodeURIComponent(chain) + "/"
      + encodeURIComponent(court), {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({moniker: moniker, body: body}),
  });
  let d = null;
  try { d = await r.json(); } catch (e) { /* an error page is not JSON */ }
  if (r.ok) return {ok: true, id: d && d.id};
  const msg = (d && d.error) ? d.error
    : r.status === 429 ? "you are sending too fast — wait a moment"
    : r.status === 410 ? "this court is no longer served"
    : "could not send (" + r.status + ")";
  return {ok: false, status: r.status, error: msg, you: d && d.you};
}

// chatStyles injects the panel's stylesheet once.
//
// Carried here rather than added to index.html's stylesheet so that installing the
// panel is genuinely three lines — a script tag, a container, and a mountChat call —
// and so that everything the feature consists of stays in one readable file. It is
// deliberately theme-agnostic: no colours of its own beyond a grey that reads on both
// light and dark, and font and text colour inherited, so it does not fight the page.
//
// No value is interpolated into this string. If that ever changes it needs escaping
// like everything else — a stylesheet is as good a place to smuggle markup as any.
const CHATCSS = `
.chatpanel{margin:1.5rem 0 0;border-top:1px solid rgba(128,128,128,.3);padding-top:.6rem;
  font-size:.92em}
.chathead{display:flex;align-items:baseline;gap:.5rem;flex-wrap:wrap;margin-bottom:.4rem}
.chatslug{opacity:.6}
.chatwarn{opacity:.6;font-size:.85em}
/* max-height, not height: outside the rail this is still a panel on a page and
   must not grow without bound. Inside it, the rail's own flexing wins. */
.chatlog{list-style:none;margin:0;padding:0;max-height:15rem;overflow-y:auto;
  flex:1 1 auto;min-height:0}
.chatmsg{display:flex;gap:.5rem;align-items:baseline;padding:.15rem 0;
  border-bottom:1px solid rgba(128,128,128,.12)}
.chatwho{flex:0 0 auto;max-width:11rem;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap}
.chatname{font-weight:600}
.chatsuf{opacity:.45;font-size:.8em;font-family:ui-monospace,monospace}
.chatflag{margin-right:.25rem}
.chatbody{flex:1 1 auto;overflow-wrap:anywhere;white-space:pre-wrap}
.chatage{flex:0 0 auto;opacity:.45;font-size:.85em}
.chatempty{opacity:.55;padding:.3rem 0}
.chatstate{margin:.4rem 0;padding:.35rem .5rem;border-radius:4px;
  background:rgba(128,128,128,.15)}
.chatdemo{display:block;margin-top:.25rem;font-size:.85em;font-weight:600}
.chatform{display:flex;gap:.4rem;margin-top:.5rem;flex-wrap:wrap}
/* THE NAME IS A LABEL, NOT A MESSAGE. At 8rem it took a third of a 230px rail
   and left the message box too narrow to read what you were typing. It needs
   room for a moniker and no more; the message takes everything else and drops
   to its own line when the two cannot share one. */
.chatmoniker{flex:0 1 5.5rem;min-width:4rem}
.chatinput{flex:5 1 8rem;min-width:0}
/* THEME-FOLLOWING, NOT WHITE. These were unstyled inputs, so a browser painted
   them its default white and they glared out of a dark page. Inheriting is what
   makes one rule right in both themes: this file has no access to the page's
   colour tokens and must not grow a copy of them.
   NO BACKTICKS IN HERE -- the whole block is one template literal, and a stray
   pair closes it early. That is what broke every page, not just the chat. */
.chatmoniker,.chatinput{background:transparent;color:inherit;font:inherit;
  border:1px solid rgba(128,128,128,.35);border-radius:4px;padding:.3rem .4rem}
.chatmoniker:focus,.chatinput:focus{outline:none;border-color:rgba(128,128,128,.7)}
.chatmoniker::placeholder,.chatinput::placeholder{color:inherit;opacity:.4}
.chatnote{min-height:1.2em;opacity:.7;font-size:.85em;margin-top:.25rem}
`;
function chatStyles(doc) {
  const d = doc || (typeof document !== "undefined" ? document : null);
  if (!d || !d.head || d.getElementById && d.getElementById("chatcss")) return;
  const s = d.createElement("style");
  s.id = "chatcss";
  s.textContent = CHATCSS;
  d.head.appendChild(s);
}

// mountChat attaches a panel to `el` for one court.
//
// Returns a stop() that must be called before the element is discarded. The page's
// render() is async AND re-entrant, so a poller from a previous render can wake up
// after the DOM it was writing to has been replaced — the generation check below is
// what makes that harmless, and it is checked at the top of every tick, before every
// DOM write, and before rescheduling.
let CHATGEN = 0;
function mountChat(el, opts) {
  if (!el) return () => {};
  const o = opts || {};
  const base = chatEndpoint(o.cfg);
  const chain = o.chain || "dev";
  const court = o.court || "";
  const gen = ++CHATGEN;
  const live = () => gen === CHATGEN && el.isConnected !== false;
  chatStyles(o.doc);
  if (el.classList && el.classList.add) el.classList.add("chatpanel");

  let moniker = "";
  try { moniker = window.localStorage.getItem("kourt.chat.moniker") || ""; } catch (e) {}

  el.innerHTML = chatPanelHtml(court, moniker,
    base ? "" : "Chat is not configured for this page.");
  const logEl = el.querySelector(".chatlog");
  const stateEl = el.querySelector(".chatstate");
  const noteEl = el.querySelector(".chatnote");
  const formEl = el.querySelector(".chatform");
  const nameEl = el.querySelector(".chatmoniker");
  const bodyEl = el.querySelector(".chatinput");
  const sendEl = el.querySelector(".chatsend");

  // EVERY RENDERED TIME IS CORRECTED BY ONE OFFSET, because this clock is not the one that
  // stamped the messages.
  //
  // Measured through chatWhen before this existed: a client ten minutes FAST read a message
  // posted one second ago as "10m", and one two hours SLOW read a two-hour-old message as "just
  // now" — which in a court misrepresents the order things were said in. Browsers take their time
  // from the OS.
  //
  // The server sends its own clock with every read, so the offset is learned rather than assumed,
  // and re-learned on each poll. Zero until the first reply arrives, which is the honest default:
  // with nothing to compare against, the local clock is the only clock there is.
  let serverSkew = 0;
  const learnSkew = reply => {
    const n = reply && reply.now ? Number(reply.now) : 0;
    if (n > 0) serverSkew = n - Math.floor((o.now ? o.now() : Date.now()) / 1000);
  };
  const nowSec = () => Math.floor((o.now ? o.now() : Date.now()) / 1000) + serverSkew;
  const note = t => { if (live()) noteEl.textContent = t || ""; };

  // Writing the log has to preserve the reader's scroll position, or someone reading
  // back through a thread gets yanked to the bottom every few seconds.
  function paintLog(msgs) {
    if (!live()) return;
    const atBottom = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 24;
    logEl.innerHTML = chatLogHtml(msgs, nowSec());
    if (atBottom) logEl.scrollTop = logEl.scrollHeight;
  }

  // Separate from paintLog, and it has to stay separate: a refused POST carries a
  // `you` and NO messages, and the first version of this function took both at once,
  // so telling somebody they were paused also erased the transcript they were reading.
  // Declared before paintState uses it: the demo branch paints during the mount, before the
  // health request has even been made, and a `let` below that point is a temporal dead zone.
  let appealTo = "";
  // lastYou is remembered so the status line can be repainted when the appeal contact arrives
  // after it: the health request and the first transcript read race, and whichever loses would
  // otherwise leave a punished reader looking at the version with no channel in it.
  let lastYou = null;
  function paintState(you) {
    if (!live()) return;
    if (you) lastYou = you;
    const line = chatStatusLine(lastYou, nowSec(), appealTo);
    stateEl.textContent = line;
    stateEl.hidden = !line;
    // Disabled rather than hidden: someone who is paused should be able to see that
    // the box exists and will come back, not conclude the feature is broken.
    const blocked = !!line;
    bodyEl.disabled = blocked;
    sendEl.disabled = blocked;
  }

  const paint = (msgs, you) => { paintLog(msgs); paintState(you); };

  if (!base) {
    const demo = chatDemoThread(court);
    // The sample carries fixed timestamps so two loads look identical; shifting them
    // onto the viewer's clock is what keeps the ages the intended ones rather than
    // "9 months ago".
    const shift = nowSec() - demo.now;
    paint(demo.messages.map(m => ({...m, created_at: m.created_at + shift})), demo.you);

    // SAY THAT THE THREAD IS INVENTED — not merely that chat is unconfigured.
    //
    // This branch is reached when no API base is configured, which is at least as likely to
    // be a deployment that lost its base URL as a deliberate demo. It was never silent: the
    // panel already mounts with "Chat is not configured for this page." in .chatnote. But
    // that names the CAUSE and not the consequence, and the difference matters — a reader
    // who sees four plausible messages with names, flags and ages, plus a line saying chat
    // is not configured, can reasonably conclude they cannot POST, rather than that
    // everything above them is fabricated.
    //
    // Three things were wrong with relying on it, none of them the absence of any text:
    // .chatnote is the least prominent slot in the panel, it sits BELOW the composer and so
    // after the fiction rather than before it, and it is transient — the submit handler
    // below overwrites it, as does every validation message.
    //
    // chat-demo.html does say so in its own prose, which is part of why this went unnoticed.
    // The PANEL is the part that gets embedded in a court page, so it has to carry the
    // notice itself: in the head, beside the standing "names are unverified" warning, above
    // the log rather than below it, and never overwritten.
    const fiction = el.querySelector(".chatdemo");
    if (fiction) {
      fiction.textContent = "Sample conversation \u2014 this panel is not connected to a"
        + " server, and every message below is invented.";
      fiction.hidden = false;
    }

    formEl.addEventListener("submit", ev => {
      ev.preventDefault();
      note("This is a demo — nothing is sent anywhere.");
    });
    return () => { if (gen === CHATGEN) CHATGEN++; };
  }

  // One health request per mount, in live mode only — demo mode makes no network calls.
  // Health is fetched once per mount and carries two things the page needs: whether timeouts
  // are being applied, and where to appeal one. Held in a variable because the status line is
  // repainted on every poll while this is asked for once.
  chatHealth(base).then(h => {
    if (!live()) return;
    if (h && typeof h.appeal_to === "string") {
      appealTo = h.appeal_to;
      paintState(lastYou); // the line may already be on screen, saying less than it could
    }
    // health.enforcing is deliberately NOT surfaced to readers — see the note
    // on chatHealth. It stays public on the endpoint for an operator.
  });

  let timer = null;
  async function tick() {
    if (!live()) return;
    try {
      const d = await chatFetch(base, chain, court, o.limit || 50);
      if (!live()) return;
      // Before painting, so the ages in this very repaint are already corrected.
      learnSkew(d);
      paint(d.messages, d.you);
      note("");
    } catch (e) {
      if (!live()) return;
      // The service being down must not blank a transcript already on screen, and
      // must not look like an empty room.
      if (e && e.closed) {
        // Withdrawn, not broken. Say so, stop asking, and leave the composer disabled —
        // polling a court that has been closed is a request nobody will ever answer.
        note("Chat for this court is closed.");
        paintState({state: "closed"});
        return;
      }
      note("Chat is unreachable right now.");
    }
    if (!live()) return;
    // Backing off while the tab is hidden, because a court page left open in a
    // background tab overnight is otherwise a poller nobody is reading.
    const idle = typeof document !== "undefined" && document.hidden;
    timer = setTimeout(tick, idle ? 60000 : (o.interval || 6000));
  }

  formEl.addEventListener("submit", async ev => {
    ev.preventDefault();
    const m = nameEl.value, b = bodyEl.value;
    const bad = chatValidate(m, b);
    if (bad) { note(bad); return; }
    sendEl.disabled = true;
    try { window.localStorage.setItem("kourt.chat.moniker", m.trim()); } catch (e) {}
    const r = await chatPost(base, chain, court, m.trim(), b.trim());
    if (!live()) return;
    sendEl.disabled = false;
    if (r.ok) {
      bodyEl.value = "";
      note("");
      tick();
      return;
    }
    // A refusal carries the reason, and ONLY the state is repainted — see paintState.
    note(r.error);
    if (r.you) paintState(r.you);
  });

  // WAKE ON RETURN, so the backoff above is a saving rather than a stale room.
  //
  // The 60s idle interval is chosen when the timer is SET, so a reader who switches away for two
  // seconds and comes straight back waits out the rest of that minute in front of a transcript
  // that is not moving. Their own `you` block is stale for the same minute, and that block is how
  // somebody learns their timeout has expired — so the cost is not only missed messages.
  //
  // Nothing cancelled the timer, because there was no listener for coming back. There is one now,
  // and it makes the backoff strictly better: idling harder is only safe if returning is instant.
  //
  // It has to respect the same generation check as the poller. live() is asserted because an
  // unmounted panel must not fetch, and the listener is REMOVED on unmount because this panel
  // remounts on navigation and one leaked listener per visit would tick a discarded generation
  // forever. The removal is what the unmount arm of the test exists for.
  const onVisible = () => {
    if (!live() || document.hidden) return;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    tick();
  };
  const canListen = typeof document !== "undefined" &&
    typeof document.addEventListener === "function";
  if (canListen) document.addEventListener("visibilitychange", onVisible);

  tick();
  return () => {
    if (gen === CHATGEN) CHATGEN++;
    if (timer) clearTimeout(timer);
    if (canListen) document.removeEventListener("visibilitychange", onVisible);
  };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {chatEsc, chatFlag, chatWhen, chatStatusLine, chatValidate,
    chatLineHtml, chatLogHtml, chatPanelHtml, chatDemoThread, chatEndpoint,
    chatFetch, chatPost, chatStyles, chatHealth, mountChat, CHATCSS,
    CHATLIMITS};
}
