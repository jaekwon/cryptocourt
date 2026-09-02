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
// heading=false drops the panel's own "Chat <court>" line. The host supplies it
// when it already has one: in the rail the section is titled Chat and the court
// is the page you are looking at, so the panel repeating both read as
// "Chat / Chat covid".
function chatPanelHtml(slug, moniker, note, heading) {
  return ""
    + '<div class="chathead">'
    +   (heading === false ? ""
        : "<b>Chat</b> <span class=\"chatslug\">" + chatEsc(slug) + "</span>")
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
.chatmoniker{flex:0 1 4rem;min-width:3rem}
.chatinput{flex:9 1 8rem;min-width:0}
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
/* SEND IS A BUTTON AND SHOULD LOOK LIKE ONE. It carried no styling at all, so
   a browser drew its own — flat and grey beside two inputs that had just been
   given borders and a radius, which made the one control that DOES something
   the least visible thing in the row.
   Neutral rather than accent-coloured: this file cannot see the page's colour
   tokens, and a hardcoded brand colour would be wrong on one theme or the
   other. A translucent grey reads as raised on both. */
.chatsend{flex:0 0 auto;font:inherit;font-weight:600;cursor:pointer;
  padding:.32rem .8rem;border-radius:4px;line-height:1.35;color:inherit;
  border:1px solid rgba(128,128,128,.45);background:rgba(128,128,128,.18)}
.chatsend:hover{background:rgba(128,128,128,.32);border-color:rgba(128,128,128,.7)}
.chatsend:active{transform:translateY(1px)}
.chatsend:disabled{opacity:.4;cursor:default;transform:none}
.chatnote{min-height:1.2em;opacity:.7;font-size:.85em;margin-top:.25rem}
/* THE SKY OVER LEO ON 23 SEPTEMBER 2017, with the planets where they actually
   were. Not a texture and not a generated scatter: every star and every planet
   in the plate behind this panel is a real position for that date.

   WHAT IS IN IT, and where each number came from:

     277 stars  Hipparcos (VizieR I/239/hip_main), everything brighter than
                V 6.3 in the frame RA 141-180 deg, Dec -20 to +50. Radius and
                opacity fall together over six magnitude bins, 3.0px at .95
                alpha for the brightest down to .55px at .30 for the faintest.
     Leo's figure  the eleven standard lines over its ten named stars -- the
                Sickle from Ras Elased through Adhafera and Algieba down to
                Regulus, then the body out to Denebola and back by Chertan.
     3 planets  JPL Horizons, geocentric astrometric, 2017-09-23 00:00 UT:
                Venus 10h22m40.4s +11d14'07", Mars 10h51m24.3s +08d33'14",
                Mercury 11h15m13.3s +06d46'26". Warm for Venus, orange for
                Mars, pale for Mercury, each with a faint halo.

   THE OTHER BODIES ARE ABSENT BECAUSE THEY WERE ELSEWHERE, not because they
   were forgotten. At that instant Jupiter sat at 13h38m and the Sun at 11h59m,
   both in Virgo, with the Moon at 14h10m below them -- all outside this frame.
   Drawing them would have meant moving them.

   CHECKED RATHER THAN TRUSTED, twice. The named-star coordinates were entered
   by hand and then confirmed against the catalogue that filled the field:
   Hipparcos gives Regulus as 152.0930 deg +11.9672 deg at V 1.36, which is the
   value the figure uses, to four decimals. And the ephemeris reproduces the
   configuration this date is known for without being asked to -- Venus 3.58
   deg from Regulus, all three planets inside Leo, Jupiter and the Sun over in
   Virgo. Two independent sources agreeing is what makes the plate worth
   calling real.

   EAST IS LEFT, which is why Denebola sits at the left edge and the Sickle at
   the right: right ascension increases eastward, and this is drawn the way a
   star map is, not the way a graph is.

   THE FRAME IS PORTRAIT ON PURPOSE (0.538 wide to tall). Leo is a wide
   constellation and this panel is a tall column, so the declination window is
   deliberately much taller than Leo -- it runs from Hydra up past Leo Minor.
   That is what lets one plate fill the panel with real sky instead of leaving
   two thirds of it bare, and the neighbours it pulls in are real stars, not
   filler.

   AN SVG DATA URI, base64, and both halves of that matter. The overlay's one
   promise is that it is self-contained and deploy.sh refuses any src or href
   pointing at a remote host, so the plate has to travel inside this file
   rather than be fetched. base64 rather than percent-encoding because the
   latter inflates an SVG full of quotes and angle brackets by about 60%.

   NO BACKTICK AND NO DOLLAR-BRACE ANYWHERE IN HERE. The whole block is one
   template literal; a stray pair closes it early and takes every page with it,
   not just the chat. */
.chatpanel{color:#e9e5f8;background-color:#06020e;
  background-image:url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NDAgMTE5MCI+PGcgc3Ryb2tlPSIjYjNhMmZmIiBzdHJva2Utb3BhY2l0eT0iLjIyIiBzdHJva2Utd2lkdGg9IjEiIGZpbGw9Im5vbmUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PGxpbmUgeDE9IjU1MSIgeTE9IjQ0NiIgeDI9IjUyMiIgeTI9IjQwOCIvPjxsaW5lIHgxPSI1MjIiIHkxPSI0MDgiIHgyPSI0MjQiIHkyPSI0NTIiLz48bGluZSB4MT0iNDI0IiB5MT0iNDUyIiB4Mj0iNDExIiB5Mj0iNTEzIi8+PGxpbmUgeDE9IjQxMSIgeTE9IjUxMyIgeDI9IjQ2MyIgeTI9IjU2NSIvPjxsaW5lIHgxPSI0NjMiIHkxPSI1NjUiIHgyPSI0NTgiIHkyPSI2NDciLz48bGluZSB4MT0iNDExIiB5MT0iNTEzIiB4Mj0iMTg4IiB5Mj0iNTAxIi8+PGxpbmUgeDE9IjE4OCIgeTE9IjUwMSIgeDI9IjQ1IiB5Mj0iNjAyIi8+PGxpbmUgeDE9IjQ1IiB5MT0iNjAyIiB4Mj0iMTg4IiB5Mj0iNTg4Ii8+PGxpbmUgeDE9IjE4OCIgeTE9IjU4OCIgeDI9IjQ1OCIgeTI9IjY0NyIvPjxsaW5lIHgxPSIxODgiIHkxPSI1MDEiIHgyPSIxODgiIHkyPSI1ODgiLz48bGluZSB4MT0iNjA5IiB5MT0iNDYwIiB4Mj0iNTUxIiB5Mj0iNDQ2Ii8+PC9nPjxnIGZpbGw9IiNmZmYiIG9wYWNpdHk9IjAuOTUiPjxjaXJjbGUgY3g9IjQ1OCIgY3k9IjY0NyIgcj0iMy4wIi8+PGNpcmNsZSBjeD0iNjI2IiBjeT0iOTk3IiByPSIzLjAiLz48Y2lyY2xlIGN4PSI0MTEiIGN5PSI1MTMiIHI9IjMuMCIvPjxjaXJjbGUgY3g9IjQ1IiBjeT0iNjAyIiByPSIzLjAiLz48L2c+PGcgZmlsbD0iI2ZmZiIgb3BhY2l0eT0iMC44OCI+PGNpcmNsZSBjeD0iMTg4IiBjeT0iNTAxIiByPSIyLjIiLz48Y2lyY2xlIGN4PSI1NTEiIGN5PSI0NDYiIHI9IjIuMiIvPjxjaXJjbGUgY3g9IjIwNyIgY3k9Ijk0IiByPSIyLjIiLz48Y2lyY2xlIGN4PSI0MDEiIGN5PSIxNDUiIHI9IjIuMiIvPjxjaXJjbGUgY3g9IjI4OSIgY3k9IjExMjUiIHI9IjIuMiIvPjxjaXJjbGUgY3g9IjE4OCIgY3k9IjU4OCIgcj0iMi4yIi8+PGNpcmNsZSBjeD0iNDI0IiBjeT0iNDUyIiByPSIyLjIiLz48Y2lyY2xlIGN4PSI0MjIiIGN5PSIxMjAiIHI9IjIuMiIvPjxjaXJjbGUgY3g9IjQ2MyIgY3k9IjU2NSIgcj0iMi4yIi8+PGNpcmNsZSBjeD0iMTcwIiBjeT0iMjg3IiByPSIyLjIiLz48L2c+PGcgZmlsbD0iI2ZmZiIgb3BhY2l0eT0iMC43NCI+PGNpcmNsZSBjeD0iNTcwIiBjeT0iNjgyIiByPSIxLjYiLz48Y2lyY2xlIGN4PSIxNjciIGN5PSIxMTAxIiByPSIxLjYiLz48Y2lyY2xlIGN4PSIzOCIgY3k9IjgyMCIgcj0iMS42Ii8+PGNpcmNsZSBjeD0iNDQ5IiBjeT0iMTA2MCIgcj0iMS42Ii8+PGNpcmNsZSBjeD0iNTciIGN5PSIzOCIgcj0iMS42Ii8+PGNpcmNsZSBjeD0iMjc0IiBjeT0iMjY4IiByPSIxLjYiLz48Y2lyY2xlIGN4PSIzODYiIGN5PSIxMTM2IiByPSIxLjYiLz48Y2lyY2xlIGN4PSIzNTgiIGN5PSI2OTIiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjUyMiIgY3k9IjQwOCIgcj0iMS42Ii8+PGNpcmNsZSBjeD0iNTc1IiBjeT0iODY5IiByPSIxLjYiLz48Y2lyY2xlIGN4PSIxNDgiIGN5PSI2NzEiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjU4IiBjeT0iNzM5IiByPSIxLjYiLz48Y2lyY2xlIGN4PSIxNjAiIGN5PSI3NDgiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjE0NCIgY3k9IjExNTEiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjI0NyIgY3k9IjExNjEiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjUyOCIgY3k9IjExMDIiIHI9IjEuNiIvPjxjaXJjbGUgY3g9IjM3OCIgY3k9IjIyNiIgcj0iMS42Ii8+PC9nPjxnIGZpbGw9IiNmZmYiIG9wYWNpdHk9IjAuNTgiPjxjaXJjbGUgY3g9IjI2NCIgY3k9IjQyOSIgcj0iMS4xNSIvPjxjaXJjbGUgY3g9Ijk1IiBjeT0iODY0IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNjA5IiBjeT0iNDYwIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDYwIiBjeT0iNjgwIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMjM3IiBjeT0iNTA3IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTc4IiBjeT0iOTEyIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNjM4IiBjeT0iNDA1IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDYwIiBjeT0iODU2IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDYyIiBjeT0iMjUxIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDkiIGN5PSI1MDYiIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSI2MDgiIGN5PSI4NzAiIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSI1OTgiIGN5PSIyMzEiIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSIxODQiIGN5PSI0NTciIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSI2MTkiIGN5PSI4OTciIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSI0NzIiIGN5PSIxMDcyIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMjI2IiBjeT0iNzI1IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMjcxIiBjeT0iMTE2IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNTgxIiBjeT0iNzcxIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDkyIiBjeT0iNzEzIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMzM0IiBjeT0iMzA2IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iOTYiIGN5PSIxMDE3IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNjMiIGN5PSIxMTYyIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMzg2IiBjeT0iMjc1IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMzU2IiBjeT0iMTYzIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMjM5IiBjeT0iODkyIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTY4IiBjeT0iMjAxIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTIyIiBjeT0iOTAxIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNDEyIiBjeT0iNTE5IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNTk1IiBjeT0iMTc2IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTQ1IiBjeT0iMTAzNSIgcj0iMS4xNSIvPjxjaXJjbGUgY3g9IjI0NCIgY3k9Ijc4OSIgcj0iMS4xNSIvPjxjaXJjbGUgY3g9IjYwIiBjeT0iNzEwIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMzM4IiBjeT0iMTA3OCIgcj0iMS4xNSIvPjxjaXJjbGUgY3g9IjMzNCIgY3k9IjExMzciIHI9IjEuMTUiLz48Y2lyY2xlIGN4PSI1MTQiIGN5PSIxMTczIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTMyIiBjeT0iODAxIiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMjQzIiBjeT0iNzQ2IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iNjA4IiBjeT0iNjU4IiByPSIxLjE1Ii8+PGNpcmNsZSBjeD0iMTUzIiBjeT0iMTExIiByPSIxLjE1Ii8+PC9nPjxnIGZpbGw9IiNmZmYiIG9wYWNpdHk9IjAuNDQiPjxjaXJjbGUgY3g9IjU4NiIgY3k9IjczNCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMjY0IiBjeT0iMjgwIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIyNDkiIGN5PSIxNjMiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjI0MyIgY3k9IjE4MyIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNjA4IiBjeT0iNjg1IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1NzMiIGN5PSIxMDk0IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1MjMiIGN5PSI5ODgiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjM1MCIgY3k9IjczMiIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNTM5IiBjeT0iNjgiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjM2OCIgY3k9Ijg2MSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzE0IiBjeT0iNDU2IiByPSIwLjgiLz48Y2lyY2xlIGN4PSIxNTAiIGN5PSIxMTY5IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1MDIiIGN5PSIxNTIiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjE2IiBjeT0iMTE0MiIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzE0IiBjeT0iNjUiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjE3NSIgY3k9IjgxNiIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzcyIiBjeT0iODk3IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI4OCIgY3k9IjcxMiIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDIwIiBjeT0iOTg3IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1MDAiIGN5PSI2MzgiIHI9IjAuOCIvPjxjaXJjbGUgY3g9Ijc5IiBjeT0iNDg3IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1MTAiIGN5PSIzIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1ODEiIGN5PSIxNjYiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjUyNiIgY3k9IjQzNSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDUxIiBjeT0iMTA2OCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMTI3IiBjeT0iMTgxIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIxODEiIGN5PSI2MjQiIHI9IjAuOCIvPjxjaXJjbGUgY3g9Ijc4IiBjeT0iMjY5IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1MCIgY3k9IjcxMCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMjkwIiBjeT0iNjcxIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1NTkiIGN5PSI2MTIiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjMwNCIgY3k9IjMyOCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMCIgY3k9Ijc4OCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDg4IiBjeT0iMzA3IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI2MjUiIGN5PSI5NTMiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjYwOSIgY3k9IjI1MyIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMTQ4IiBjeT0iODI2IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI2MjIiIGN5PSI2OTYiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjYyMSIgY3k9Ijc1IiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1OTMiIGN5PSIyNDEiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjE5MCIgY3k9Ijg1MSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDI0IiBjeT0iNjE3IiByPSIwLjgiLz48Y2lyY2xlIGN4PSIzNjAiIGN5PSI2MTAiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjMwMCIgY3k9IjExNDQiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjI3MiIgY3k9Ijg4NiIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMjQ1IiBjeT0iNzYiIHI9IjAuOCIvPjxjaXJjbGUgY3g9Ijg4IiBjeT0iMTA3NCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDI2IiBjeT0iMzUyIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIzMDIiIGN5PSI2MDkiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjMwMiIgY3k9IjUyOSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzE2IiBjeT0iNDAyIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIyMzMiIGN5PSIxMDQyIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIzOTQiIGN5PSIyNzciIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjIxOCIgY3k9IjgxNyIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMTgiIGN5PSI1ODQiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjEyMSIgY3k9IjUzNyIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNTk3IiBjeT0iOTUxIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI4OSIgY3k9IjEwOCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNTg4IiBjeT0iMzIwIiByPSIwLjgiLz48Y2lyY2xlIGN4PSIzNTUiIGN5PSIyNTUiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjE0MSIgY3k9IjU3MCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMjAiIGN5PSI3MDYiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjQ2MyIgY3k9IjExNDEiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjM2NSIgY3k9IjEwODEiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjYzNSIgY3k9IjkzNyIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzg3IiBjeT0iOTcwIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1NjYiIGN5PSIxNzQiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjM4OSIgY3k9IjcwMSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzciIGN5PSI5NDEiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjU2MCIgY3k9IjM0MCIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iNDQ4IiBjeT0iOTkzIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI1NDgiIGN5PSI4MjAiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjI3MCIgY3k9IjEwODQiIHI9IjAuOCIvPjxjaXJjbGUgY3g9IjU0OCIgY3k9IjY0OSIgcj0iMC44Ii8+PGNpcmNsZSBjeD0iMzQ5IiBjeT0iNzAzIiByPSIwLjgiLz48Y2lyY2xlIGN4PSI0ODEiIGN5PSI0NzciIHI9IjAuOCIvPjwvZz48ZyBmaWxsPSIjZmZmIiBvcGFjaXR5PSIwLjMiPjxjaXJjbGUgY3g9IjIxMCIgY3k9IjQzMSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjM0MyIgY3k9IjEwNTgiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyMDgiIGN5PSIyMzMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MjIiIGN5PSI3MTEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI1ODciIGN5PSI1NzEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0MDIiIGN5PSIxNDkiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNjciIGN5PSIyNzEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI3NiIgY3k9IjMxMCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQyIiBjeT0iMjU2IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNjA2IiBjeT0iMTE4MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjEyNCIgY3k9IjU4OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQ5NCIgY3k9IjM0NiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjEwNSIgY3k9Ijc5OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQ0MCIgY3k9Ijc3MiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjMxNSIgY3k9Ijc2OSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjM2OSIgY3k9IjE4OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjE4OSIgY3k9IjcxMyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjU0OSIgY3k9IjczNiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI4NiIgY3k9IjEwMDEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIxNDQiIGN5PSI2NTYiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI5NyIgY3k9IjM3OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQyMiIgY3k9IjQ1NyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQyNCIgY3k9IjQxOSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjMzMiIgY3k9IjIwNiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjUwNyIgY3k9IjY5OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI4OCIgY3k9IjEwMTciIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MTQiIGN5PSIxMTE1IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDQ3IiBjeT0iMjE0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMjQ2IiBjeT0iMTA4OSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjYxMyIgY3k9IjI3OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI0OCIgY3k9IjExMjgiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIxNzgiIGN5PSI5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzk4IiBjeT0iMjc0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMjA3IiBjeT0iMTE1IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTY4IiBjeT0iMzE4IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTE4IiBjeT0iNzQ5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzYyIiBjeT0iMzAwIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTY5IiBjeT0iODIyIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDciIGN5PSI2MDciIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0NTEiIGN5PSI5OTMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNjQiIGN5PSI4MzciIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNjMiIGN5PSI3NDUiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyOTMiIGN5PSI4ODMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzOTYiIGN5PSI5MTkiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIxMzUiIGN5PSIxMDYwIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTIxIiBjeT0iMTE2IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTEyIiBjeT0iOTgzIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNjA0IiBjeT0iMTA4MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQyNSIgY3k9IjQ1MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI4MyIgY3k9IjkwMyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjIzMSIgY3k9Ijg1MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjEwNCIgY3k9IjU2NCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjMiIGN5PSIyODYiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNDgiIGN5PSIyMzYiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0MTMiIGN5PSIyNyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjM4MCIgY3k9IjE0MyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjYzMSIgY3k9Ijg3NSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjUyOSIgY3k9IjkyMiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQxMyIgY3k9IjEwNjMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzNzkiIGN5PSI2ODQiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzNDQiIGN5PSIxMTI4IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMjI4IiBjeT0iMjAwIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTI1IiBjeT0iODA4IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDMzIiBjeT0iNDkwIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzE5IiBjeT0iMzExIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNjUiIGN5PSI0MjEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNjIiIGN5PSIxMzYiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyNDUiIGN5PSIxMjEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzMzMiIGN5PSIxMDYyIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTAwIiBjeT0iNzA5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDM2IiBjeT0iMzg5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzc1IiBjeT0iOTE0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMjg4IiBjeT0iMzc0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTUxIiBjeT0iODQ4IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTEwIiBjeT0iMTEyNyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjY2IiBjeT0iOTY0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDQiIGN5PSI1NzQiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzOTgiIGN5PSI3MzkiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI1MjUiIGN5PSIxMTMxIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDI2IiBjeT0iMTA0MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQ3OCIgY3k9IjEwMTMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyMjMiIGN5PSIxMDM5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iODgiIGN5PSI1NCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjUzNCIgY3k9IjQ5MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjYwNSIgY3k9IjgxOCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjE5NSIgY3k9IjExNjQiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIxNzciIGN5PSI5NzEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MDgiIGN5PSIxMDI2IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNjAzIiBjeT0iOTk1IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTY0IiBjeT0iMjUzIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDAxIiBjeT0iMTE4OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI3MyIgY3k9Ijg4OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjIzMyIgY3k9Ijg2MyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjYwOSIgY3k9IjEwMjkiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0MCIgY3k9IjExMjAiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MTgiIGN5PSI4ODciIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzODIiIGN5PSI1MjEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIyOTIiIGN5PSIzNTAiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0NSIgY3k9Ijg1NSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQwMyIgY3k9IjU5NSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI2MiIgY3k9IjQ3MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjgzIiBjeT0iMTEzMyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjkwIiBjeT0iNjk5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNCIgY3k9Ijg0MSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjYwMSIgY3k9IjIzMCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjI2OCIgY3k9IjQxNyIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjQ2NSIgY3k9Ijc1NSIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjM2NSIgY3k9Ijk4MCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjgzIiBjeT0iMTA5NiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9Ijg5IiBjeT0iODkxIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDU5IiBjeT0iMzEzIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDQ2IiBjeT0iOTc0IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMTMyIiBjeT0iODc5IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNTMyIiBjeT0iNzc2IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iNDUyIiBjeT0iMTA1NiIgcj0iMC41NSIvPjxjaXJjbGUgY3g9IjMxOCIgY3k9IjEwODgiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0OCIgY3k9IjEwMjUiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MTgiIGN5PSI5MjIiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MDIiIGN5PSI5NzIiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI0NTciIGN5PSIxMTE1IiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzIzIiBjeT0iODgwIiByPSIwLjU1Ii8+PGNpcmNsZSBjeD0iMzYiIGN5PSIyODMiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI1OTkiIGN5PSI0NTEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI1NjgiIGN5PSI0MDkiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI2MjAiIGN5PSI4NzEiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzMTEiIGN5PSI1MTQiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzMDciIGN5PSI4MDgiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIxMTYiIGN5PSI2MDYiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSIzNDMiIGN5PSIyMzIiIHI9IjAuNTUiLz48Y2lyY2xlIGN4PSI4OCIgY3k9IjI3OCIgcj0iMC41NSIvPjxjaXJjbGUgY3g9Ijg3IiBjeT0iODMiIHI9IjAuNTUiLz48L2c+PGNpcmNsZSBjeD0iNDAwIiBjeT0iNjU5IiByPSIxMSIgZmlsbD0iI2ZmZTZhZCIgb3BhY2l0eT0iLjEzIi8+PGNpcmNsZSBjeD0iNDAwIiBjeT0iNjU5IiByPSIzLjQiIGZpbGw9IiNmZmU2YWQiIG9wYWNpdHk9Ii45NyIvPjxjaXJjbGUgY3g9IjI4MiIgY3k9IjcwNSIgcj0iMTEiIGZpbGw9IiNmZjkxNjYiIG9wYWNpdHk9Ii4xMyIvPjxjaXJjbGUgY3g9IjI4MiIgY3k9IjcwNSIgcj0iMy40IiBmaWxsPSIjZmY5MTY2IiBvcGFjaXR5PSIuOTciLz48Y2lyY2xlIGN4PSIxODQiIGN5PSI3MzUiIHI9IjExIiBmaWxsPSIjZTJlNmZmIiBvcGFjaXR5PSIuMTMiLz48Y2lyY2xlIGN4PSIxODQiIGN5PSI3MzUiIHI9IjMuNCIgZmlsbD0iI2UyZTZmZiIgb3BhY2l0eT0iLjk3Ii8+PC9zdmc+"),
    linear-gradient(to bottom, #06020e 0, #0b041a 30%, #14092c 65%, #1d1042 100%);
  background-size:100% auto,100% 100%;
  background-position:center -34px,0 0;
  background-repeat:no-repeat,no-repeat}
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
    base ? "" : "Chat is not configured for this page.", o.heading);
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
