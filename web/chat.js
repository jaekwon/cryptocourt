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

// CHATDEFAULTNAME is who you are when you have not said. It is the server's
// DefaultMoniker and paneldrift_test.go pins the two together: a panel promising one
// default while the server stores another is exactly that test's subject.
//
// It is the name field's PLACEHOLDER rather than its value, so nothing is typed into
// the field on a reader's behalf and their first keystroke is not a deletion — a grey
// "anon" in an empty field says what you will be called if you leave it, which is the
// same fact with less furniture. The blank field is what the server defaults.
const CHATDEFAULTNAME = "anon";

// CHATHOLD is how long a read may hang waiting for something to happen, in
// seconds. It is the OLD POLL INTERVAL, and that is the whole argument: the hold
// is a floor on how stale this panel can be about anything the chat server does
// not itself do.
//
// A post wakes every held read in that court immediately, which is the point of
// the exercise — a message crosses a room in a round trip instead of in up to six
// seconds. But an operator's kick is applied by kourtchatctl against the DATABASE,
// in another process, so nothing in the server wakes: a kicked reader finds out
// when their hold expires. Fifteen seconds of holding made that fifteen seconds of
// typing into a box that was already refusing them — caught by chat_live, which
// waits twenty for the composer to disable and got there with nothing to spare.
//
// So the hold matches the interval it replaces. Delivery gets faster; nothing gets
// staler; the request rate is what it always was. A longer hold would buy fewer
// requests on an idle court and pay for it in exactly the case that matters most.
const CHATHOLD = 6;

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
  // NO REFUSAL FOR A BLANK NAME. It used to be "pick a name first", which demanded a
  // decision before a reader could say anything — on a panel whose own warning is that
  // names here prove nothing. Blank is a valid answer now and the server reads it as
  // CHATDEFAULTNAME; the caller substitutes it before posting so the message carries a
  // name rather than relying on the default twice.
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

/* THE TWO SET MARKS, and this file keeps its own copies for the reason chatEsc
   keeps its own escaper: chat.js is loaded beside the page but does not depend on
   it, and a constant reached across that line is a constant that breaks when the
   panel is rendered anywhere else.
   SPELLED AS ESCAPES, never as the glyph, for the realm's own reason: the Egyptian
   block holds several eyes that are one picture at this size, and a source file
   showing a picture instead of a number is a file where the wrong one gets pasted
   in and nobody sees it.
   TWO MARKS, ONE MEANING, AND ONE DIFFERENCE. Both make a set. Which one an author
   typed says what state the set is in when a reader arrives, and nothing else. The
   hover word is the whole of that difference, so it is said on hover rather than
   left to be learned.
   THE MAP IS THE SENTENCE. Key is the mark, value is what it opens as — so there is
   no `word` field to keep beside a `mark` field and no way for the pair to drift
   apart, because they are not a pair. Reading it is `CHATSETMARKS[mark]`, which is
   the same lookup a reader does in their head.
   AND THERE IS NO LENGTH CAP HERE, which is a deletion rather than an omission.
   This carried the realm's 1..200 folder-name limit, mirrored into CHATLIMITS and
   pinned to governedset.gno by check-web-constants — and it changed nothing. The
   only consumer is a lookup in the court's live set names, and that map can only
   HOLD names the realm accepted, so a longer one misses whether it is rejected
   here or not. Measured: a 250-rune name yields no link either way.
   THE DATA ALREADY CARRIES THE RULE, which is why the cap could go and the guard
   entry with it — a pin on a number nothing reads is one more thing to keep true
   for no benefit. */
const CHATSETMARKS = {
  "\u{13080}": "shown",      // 𓂀 D010
  "\u{1307C}": "concealed",  // 𓁼 D007
};

/* A CLAIM NUMBER IN A SENTENCE BECOMES A WAY TO READ IT, and only if the court
   really has that claim. Unlike a set heading — which IS the whole message — this
   is a reference inside prose, so it is a substitution rather than a replacement.
   RUN ON THE ESCAPED TEXT, which is what makes the exclusion below load-bearing.
   chatEsc turns an apostrophe into `&#39;` and a backtick into `&#96;` — both of
   which END IN A HASH FOLLOWED BY DIGITS. A pattern reading the escaped string
   without refusing a preceding `&` turns every apostrophe in the room into a link
   to claim 39, and every backtick into claim 96. Both are ordinary typing.
   NO LEADING ZERO, so `#019` and `#0` stay plain: the displayed text is what was
   typed and the href is the number, and those two must not disagree.
   AND THE COURT MUST SAY SO. claimIsReal lives in the page, not here — chat.js
   reads no chain by design, the same reason it carries its own escaper — so a
   panel loaded alone, or on a court whose count was never read, links nothing.
   That is the safe direction: a plain "#19" is a sentence, a wrong "#19" is a
   link to somebody else's claim. */
const CHATCLAIMREF = /(^|[^&\w])#([1-9]\d{0,8})(?![\w#])/g;

function chatClaimRefs(escaped, court, isReal) {
  if (!court || typeof isReal !== "function") return escaped;
  return String(escaped == null ? "" : escaped).replace(
    CHATCLAIMREF,
    (all, pre, digits) => isReal(court, Number(digits))
      ? pre + '<a class="chatclaim" href="#/c/' + chatEsc(court) + "/" + digits
            + '">#' + digits + "</a>"
      : all);
}

/* chatSetHeading reads a body as a set heading, or answers null.
   THE MARK, ONE SPACE, THEN THE NAME — the same shape parseSetTitle insists on,
   because a title this panel offers to file has to be one the realm will take. */
function chatSetHeading(body) {
  const b = String(body == null ? "" : body);
  for (const mark in CHATSETMARKS) {
    if (!b.startsWith(mark + " ")) continue;
    const name = b.slice(mark.length + 1);
    // The lower bound stays: "𓂀 " with nothing after it is a body somebody can
    // type, and an empty name is not a heading to the realm either. The UPPER
    // bound is gone — see the note on CHATSETMARKS: the map this name is looked
    // up in can only hold names the realm accepted, so a longer one misses
    // whether it is rejected here or not.
    if (!name) return null;
    // NO `word` BESIDE `mark`. It was CHATSETMARKS[mark] cached in a field one
    // line from the map it came out of — the gas-fee shape again, a derivation
    // stored next to its source. The caller reads the map.
    return {mark: mark, name: name};
  }
  return null;
}

// chatLineHtml renders one message.
function chatLineHtml(m, nowSec, court) {
  const flag = chatFlag(m.country);
  const suffix = /^[0-9a-f]{1,16}$/.test(String(m.suffix || "")) ? m.suffix : "";
  /* IS THIS A SET THIS COURT ACTUALLY HAS? The page knows and this file cannot —
     it reads no chain, for the reason it carries its own escaper — so the answer
     comes through the one function it reaches for, guarded because chat.js is also
     loaded on its own by the harness, which mounts the panel with no court at all.
     A NAME THAT IS NOT A SET IS LEFT ALONE — plain text, no mark span, no hover,
     nothing added. Somebody typing a heading in chat is TALKING, and a transcript
     is not a place to be sold a transaction. The only thing that changes is that a
     name the court ALREADY HAS becomes a way to go and look at it. */
  const hit = chatSetHeading(m.body);
  const fid = hit && court && typeof setFidByName === "function"
    ? setFidByName(court, hit.name) : null;
  /* ONE WRAPPER, WRITTEN ONCE. Both arms are a .chatbody; only what goes inside it
     differs, and spelling the span twice is two places for a class name to drift
     from the CSS that styles it. */
  const said = fid == null
    ? chatClaimRefs(chatEsc(m.body), court,
                    typeof claimIsReal === "function" ? claimIsReal : null)
    : '<a class="chatset" href="#/c/' + chatEsc(court) + "/f/" + chatEsc(String(fid))
      + '"><span class="chatmark wedjat" title="' + chatEsc(CHATSETMARKS[hit.mark]) + '">' + hit.mark
      + '</span><span class="chatsetname">' + chatEsc(hit.name) + "</span></a>";
  const body = '<span class="chatbody">' + said + "</span>";
  return '<li class="chatmsg">'
    + '<span class="chatsaid">'
    +   '<span class="chatwho">'
    +   (flag ? '<span class="chatflag" title="' + chatEsc(String(m.country).toUpperCase())
                + '">' + flag + "</span>" : "")
    +   '<span class="chatname">' + chatEsc(m.moniker) + "</span>"
    +   (suffix ? '<span class="chatsuf" title="derived from the sender&#39;s connection,'
                  + ' rotates daily">&middot;' + chatEsc(suffix) + "</span>" : "")
    +   "</span>"
    +   body
    + "</span>"
    + '<span class="chatage">' + chatEsc(chatWhen(nowSec, m.created_at)) + "</span>"
    + "</li>";
}

// chatLogHtml renders the whole transcript.
function chatLogHtml(msgs, nowSec, court) {
  const list = Array.isArray(msgs) ? msgs : [];
  if (!list.length) {
    return '<li class="chatempty">Nobody has said anything about this court yet.</li>';
  }
  return list.map(m => chatLineHtml(m, nowSec, court)).join("");
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
    +   '<button class="chatnamebtn" type="button" aria-label="your name — click to change">'
    +     '<span class="chatbtnface">' + chatEsc(moniker || CHATDEFAULTNAME)
    +     "</span></button>"
    +   '<input class="chatmoniker" hidden maxlength="' + CHATMONIKERUNITS
    +     '" placeholder="' + chatEsc(CHATDEFAULTNAME) + '"'
    +     ' aria-label="your name" value="' + chatEsc(moniker) + '">'
    +   '<input class="chatinput" maxlength="' + CHATLIMITS.body + '" placeholder="say something"'
    +     ' aria-label="message">'
    +   '<button class="chatsend" type="submit"><span class="chatbtnface">send</span></button>'
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
// The read's URL, as its own function so it can be asserted without a network and
// without waiting out a poll interval. Every parameter here is optional and the
// omissions matter: a request with no `wait` is the old behaviour exactly, which is
// what the first read wants and what an older server understands.
function chatFetchUrl(base, chain, court, limit, wait, seen) {
  return base + "/api/chat/" + encodeURIComponent(chain) + "/"
    + encodeURIComponent(court) + "?limit=" + (limit || 50)
    + (wait ? "&wait=" + wait : "") + (seen ? "&seen=" + seen : "");
}

async function chatFetch(base, chain, court, limit, wait, seen) {
  /* `wait` AND `seen` ARE THE LONG POLL, AND NEITHER CHANGES THE REPLY.
     The server holds this request until the court changes, the cap expires, or
     this page goes away — and then answers the same full transcript it always
     did. `seen` is the highest id already drawn, and the server uses it for one
     question: is there anything newer than what this reader has? It is NOT
     `since`, which filters the reply: asking with that one returns the rows AFTER
     it and empties the panel, which is how the first version of this failed.
     A SERVER THAT DOES NOT KNOW THE PARAMETERS ANSWERS AT ONCE, and the poller
     below carries on at its interval. That is what lets the panel and the service
     be deployed in either order. */
  const r = await fetch(chatFetchUrl(base, chain, court, limit, wait, seen),
                        {method: "GET", cache: "no-store"});
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
/* WHO SAID IT AND WHAT THEY SAID ARE ONE RUN OF PROSE, NOT TWO COLUMNS.
   The name was its own flex column, so a message that wrapped kept to the body
   column and every line after the first began under an indent as wide as the
   longest name in view — in a 230px rail a three-line message spent a third of
   itself on blank space beside a name that was only said once. Inline, the
   second line starts at the left edge, the way any wrapped sentence does.
   The age keeps a column of its own: it is the one thing here that is read
   down the page rather than across, and a float would let long messages run
   underneath it and break that column up. */
.chatsaid{flex:1 1 auto;min-width:0}
/* THE NAME NO LONGER NEEDS TRUNCATING, AND MUST STILL NOT WIDEN THE PAGE.
   max-width plus an ellipsis was protecting a column that has gone: inline, a
   long name cannot squeeze the message, it only delays it. What it can still do
   is overflow, since a 24-letter moniker and its suffix are one unbreakable
   word — hence the same anywhere-break the body has always carried. */
.chatwho{margin-right:.5rem;overflow-wrap:anywhere}
.chatname{font-weight:600}
.chatsuf{opacity:.45;font-size:.8em;font-family:ui-monospace,monospace}
.chatflag{margin-right:.25rem}
.chatbody{overflow-wrap:anywhere;white-space:pre-wrap}
/* THE SET LINK. Two declarations, and every one that used to sit here was
   resetting a BUTTON that this stopped being: font, background, border, padding
   and margin are user-agent button styling an anchor never had, and
   cursor:pointer, display:inline and text-align:left are an anchor's own
   defaults. overflow-wrap came free too — .chatbody sets it one level up and it
   inherits.
   NO ANGLE BRACKETS IN THIS COMMENT EITHER, for the reason below and one more:
   chat_test asserts the stylesheet carries no markup characters at all, because a
   style block is as good a place to smuggle markup as any. Naming the two tags
   the ordinary way is what turned this note red.
   WHAT IS LEFT IS WHAT AN ANCHOR ACTUALLY NEEDS: keep the body's colour, since
   the accent belongs on the name and not on the mark, and drop the underline it
   would otherwise wear at rest — hovering is what puts one on.
   MEASURED, NOT READ. Computed style comes out identical for every property this
   rule used to name except one: text-align resolves to "start" now instead of
   "left". That is inert here — the element is inline, so text-align aligns nothing
   of its own — and the rendered geometry is byte-identical in BOTH directions,
   checked with dir=rtl as well as ltr, which is the only case where those two
   words could differ. "start" is also the right default for a panel that renders
   whatever script somebody types.
   NO BACKTICKS IN THIS COMMENT, and that is not style: every line here lives
   inside the CHATCSS template literal, so one backtick ends the string and the
   file stops parsing. It cost a red suite writing this very note. */
.chatset{color:inherit;text-decoration:none}
/* A CLAIM REFERENCE, and it looks like the number it is rather than like a link
   in the middle of a sentence. Underlined on hover only: a transcript with three
   accented spans per line reads as a page of links, and what a reader is here to
   read is what people said. */
.chatclaim{color:var(--accent,inherit);text-decoration:none;font-weight:600}
.chatclaim:hover,.chatclaim:focus-visible{text-decoration:underline;text-underline-offset:2px}
/* HOVER THE EYE, UNDERLINE THE WORD — the sibling selector, because the mark is
   what a reader points at to ask "is that a real set?" and the NAME is the answer
   they want marked. Hovering the name underlines it too, since a link that does
   not respond to its own text reads as dead. */
.chatmark:hover + .chatsetname,
.chatset:hover .chatsetname,.chatset:focus-visible .chatsetname{
  text-decoration:underline;text-underline-offset:2px}
/* A SET READS AS A DESTINATION. The accent is on the NAME, not the mark: the mark
   is punctuation that says which kind, the name is the thing you are going to. */
.chatsetname{font-weight:600;color:var(--accent,inherit)}
/* THE MARK CARRIES THE ONE DIFFERENCE between the two eyes, so it gets the
   help cursor that says "there is something to read here" — the title is the
   whole of what distinguishes shown from concealed.
   AND IT WEARS .wedjat AS WELL, which is the page's own class for this glyph and
   already carries the subsetted font shipped for it. Measured on kourt.xyz before
   this line existed: the map drew its marks as text.mset.wedjat and computed
   wedjat-font, while a mark in this panel computed -apple-system — the system
   fallback, which is a hieroglyph font on this desk and a tofu box on most.
   NOT A FONT RULE OF ITS OWN, because there is nothing to add: the class exists,
   the font is loaded, and a second declaration here would be a second thing to
   keep true. This file styles the MARK'S PLACE IN THE LINE — the cursor and the
   gap before the name; the page styles the GLYPH.
   (It said "this file styles the CHIP", which is wrong twice over: the mark has
   not been a chip since the propose control went, and this file HAS a chip —
   .chatnamebtn, the name resting in the send button's clothes, forty lines down.
   One word for two things in one file is how the wrong one gets edited.)
   THE ONE COST IS STATED: chat.js is otherwise self-contained, and this is the
   single class it borrows. Rendered outside the overlay the mark falls back
   exactly as it does today, so nothing breaks that was working. */
.chatmark{cursor:help;margin-right:.35em}
.chatage{flex:0 0 auto;opacity:.45;font-size:.85em}
.chatempty{opacity:.55;padding:.3rem 0}
.chatstate{margin:.4rem 0;padding:.35rem .5rem;border-radius:4px;
  background:rgba(128,128,128,.15)}
.chatdemo{display:block;margin-top:.25rem;font-size:.85em;font-weight:600}
/* THE COMPOSER MUST NOT SHRINK, and this is the whole bug behind four failed
   fixes. In the rail the panel is a flex COLUMN (index.html's .railchat), and
   its rule for every direct child of .railchat sets min-height:0 there, which
   removes the automatic
   minimum size that normally stops a flex item shrinking below its content. All
   these rows still had flex-shrink:1, so a short window shrank them TOGETHER
   rather than letting the log absorb it alone: measured at a 700px viewport,
   .chatform collapsed to a 10px box while the 35px name button inside it
   overflowed 25px BELOW that box, and .chatnote — the panel's last child, so
   painted on top — covered the overflow.
   That is why the reported symptom was so strange. The button's top padding is
   still inside the form's own box and takes the pointer; its LETTERS sit in the
   overflow, where the note gets the hit instead, so the cursor stays auto and
   the click lands on a div. Nothing was wrong with the button, the cursor, or
   the browser, and none of it appears in a tall window — which is the only kind
   I had been measuring in.
   So the log is the one row that shrinks (it has flex:1 1 auto and its own
   max-height and scrollbar), and everything else is pinned. If the rail ever
   gets too short for the fixed rows it clips the NOTE, the least important
   thing in the panel, instead of swallowing the controls. */
.chathead,.chatstate,.chatform,.chatnote{flex:0 0 auto}
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
/* THE NAME IS WHO YOU ARE, UNTIL YOU GO TO CHANGE IT. At rest it wore the same
   empty box as the message beside it, which said "type here" about a field that
   already holds an answer — you are anon — and put two identical invitations in
   a row where only one of them is asking for anything.
   So it rests as a chip in the send button's own clothes and turns back into a
   field the moment it is focused. Asked for as "white like send"; send is not
   white, it is a translucent grey that READS light on a dark page and stays
   right on a light one, which is the same reason this file inherits its colours
   rather than naming them. Literal white is what these inputs looked like before
   anyone styled them, and the note above records how that went.
   :focus, NOT :focus-visible -- a tap focuses without matching focus-visible, so
   on a touch screen the chip would never become a field and the name could not
   be changed at all. The same lesson .sq learned in index.html. */
/* THE STONE. A real button element, so the pointer, the focus ring and the press
   are the browser's rather than a costume painted onto a text field. Same flex
   slot the field takes when it opens, so nothing moves in the row when they
   swap. (No angle brackets in here: chat_test scans this stylesheet for them,
   on the reasoning that a stylesheet is as good a place to smuggle markup as
   any, and it caught this comment saying so.) */
/* THE LABEL CANNOT BE HIT, SO THE BUTTON ALWAYS IS. Reported twice: over the
   padding of the name chip and of send you get a finger and a working click,
   and directly over the LETTERS you get neither. Something on the reporter's
   machine intercepts pointer events at the text — an extension that wraps text
   nodes is the usual cause, and Brave with Shields is a plausible one — and it
   is not reproducible here: in headless Chromium the button is topmost at every
   sampled point across its width, reports cursor:pointer, and has zero elements
   covering it.
   SO THIS FIXES IT WITHOUT KNOWING WHICH. pointer-events INHERITS, so declaring
   none on the label makes the label and anything a third party wraps around it
   transparent to hit testing; the event lands on the button underneath, which
   is the only thing that should ever have been receiving it. Cause-agnostic by
   construction, and inert where there is no problem.
   Two earlier attempts reasoned from the code instead of from the reporter's
   machine and were wrong. This one changes what is possible rather than what is
   likely. */
.chatbtnface{pointer-events:none}
/* user-select:none, and it is the fix for "the cursor is not a finger over the
   letters". Chrome and Safari set it on button elements in their UA stylesheets;
   FIREFOX DOES NOT. (Spelled without angle brackets on purpose: the harness
   forbids markup characters anywhere in this stylesheet, and it caught this very
   comment naming the element the proper way — the second comment in this file to
   be caught saying so.) So the label was selectable text, and the browser showed a
   text I-beam over the glyphs while the padding around them still showed the
   pointer — a control that looks dead exactly where a reader aims at it, since
   they aim at the word. Reported that way, and it is not reproducible in Chrome
   for the same reason it happens at all: the UA sheets disagree.
   The label is a name, not a passage. Nobody needs to select four characters out
   of a button they are about to click, so nothing is lost by declaring it. */
.chatnamebtn{flex:0 1 4rem;min-width:3rem;font:inherit;color:inherit;
  padding:.35rem .5rem;border-radius:6px;cursor:pointer;
  -webkit-user-select:none;user-select:none;
  border:1px solid rgba(128,128,128,.45);background:rgba(128,128,128,.18);
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chatnamebtn:hover{background:rgba(128,128,128,.34);border-color:rgba(128,128,128,.8)}
.chatnamebtn:active{transform:translateY(1px)}
/* The field it becomes: an ordinary text box, left-aligned, with a caret — no
   chip styling at all, because while it is open it is not a chip. */
.chatmoniker{text-align:left;cursor:text}
/* AND THE PLACEHOLDER STOPS WHISPERING. "anon" is not a prompt here, it is the
   name the message will carry, so it reads at the weight of a name and not at
   the .4 opacity of a hint. */
.chatmoniker::placeholder{color:inherit;opacity:.85}
.chatmoniker:focus::placeholder{opacity:.4}
/* SEND IS A BUTTON AND SHOULD LOOK LIKE ONE. It carried no styling at all, so
   a browser drew its own — flat and grey beside two inputs that had just been
   given borders and a radius, which made the one control that DOES something
   the least visible thing in the row.
   Neutral rather than accent-coloured: this file cannot see the page's colour
   tokens, and a hardcoded brand colour would be wrong on one theme or the
   other. A translucent grey reads as raised on both. */
/* Same on send: same element type, same UA disagreement, same symptom. */
.chatsend{flex:0 0 auto;font:inherit;font-weight:600;cursor:pointer;
  -webkit-user-select:none;user-select:none;
  padding:.32rem .8rem;border-radius:4px;line-height:1.35;color:inherit;
  border:1px solid rgba(128,128,128,.45);background:rgba(128,128,128,.18)}
.chatsend:hover{background:rgba(128,128,128,.32);border-color:rgba(128,128,128,.7)}
.chatsend:active{transform:translateY(1px)}
.chatsend:disabled{opacity:.4;cursor:default;transform:none}
.chatnote{min-height:1.2em;opacity:.7;font-size:.85em;margin-top:.25rem}
.chatpanel{color:#e9e5f8;background-color:#0a0a14;
  /* THE PLATE IS ONE COPY, AND IT LIVES IN index.html -- see --skyplate there for
     where every star in it came from. It was inline here until the whole rail
     became the sky: two consumers, one 11KB base64 blob, so the blob moved to a
     token and both read it. The none-fallback is not decoration -- chat.js is a
     separate file and can be mounted on a page that never defined the token, and
     a var() with no fallback would invalidate the whole declaration and take the
     gradient down with it.
     STILL A SKY OF ITS OWN, because outside the rail this is a panel on a page
     with nothing behind it. Inside the rail the reset in index.html turns all of
     this off and the rail's own sky shows through.
     NO BACKTICK AND NO DOLLAR-BRACE ANYWHERE IN HERE. The whole block is one
     template literal; a stray pair closes it early and takes every page with it,
     not just the chat. Two backticks in this very paragraph did exactly that
     while the note above was being moved out to index.html, which is the argument
     for keeping the warning wherever the literal is. */
  background-image:var(--skyplate, none),
    linear-gradient(to bottom, #0a0a14 0, #0d0c1b 30%, #130f26 65%, #181333 100%);
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
  /* THE NAME IS A BUTTON UNTIL YOU PRESS IT.
   *
   * It was an <input> dressed as a chip, and the costume was the whole problem:
   * a text field with cursor:pointer promises a button and then hands you a
   * caret, and on focus the chip lost its background — so the one visible result
   * of a successful click was the target disappearing.
   *
   * Worse, it was not the "anon" people were clicking. Every message in the log
   * carries the sender's name, so the panel shows six of them and only the last
   * is editable. A <button> is the one shape that says "this one does something"
   * without a legend, and the field now exists only while it is being typed in.
   *
   * PREFILLED WITH "anon", NOT PLACEHELD BY IT: you open it and the name is
   * already there to edit, which is what makes it a rename rather than a blank.
   * The submit path still treats a literal "anon" as no choice at all — see the
   * note there about storing a default the reader never made. */
  const nameBtn = el.querySelector(".chatnamebtn");
  const nameShown = () => (nameEl.value.trim() || CHATDEFAULTNAME);
  const closeName = () => {
    // THE FACE, NOT THE BUTTON. Writing textContent on the button would replace
    // its children and take the un-hittable wrapper with them — the bug would
    // come back the first time the field was closed, which is worse than never
    // having fixed it.
    const face = nameBtn.querySelector(".chatbtnface");
    if (face) face.textContent = nameShown(); else nameBtn.textContent = nameShown();
    nameEl.hidden = true; nameBtn.hidden = false;
  };
  const openName = () => {
    nameBtn.hidden = true; nameEl.hidden = false;
    if (!nameEl.value) nameEl.value = CHATDEFAULTNAME;
    nameEl.focus(); nameEl.select();
  };
  /* Guarded, as every other lookup in this file is: a panel rendered by an older
     shell has no button, and the name field must keep working rather than the
     whole mount throwing on line one. */
  if (nameBtn) {
    nameBtn.addEventListener("click", openName);
    nameEl.addEventListener("blur", closeName);
  } else { nameEl.hidden = false; }
  nameEl.addEventListener("keydown", ev => {
    /* Enter COMMITS THE NAME, it does not send. The field is inside the form, so
       without this a rename would post whatever half-written message was beside
       it. Escape puts back what was there and closes. */
    if (ev.key === "Enter") { ev.preventDefault(); closeName(); bodyEl.focus(); }
    else if (ev.key === "Escape") { ev.preventDefault(); nameEl.blur(); }
  });
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
    logEl.innerHTML = chatLogHtml(msgs, nowSec(), court);
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
  /* THE HIGHEST ID ALREADY ON SCREEN, which is the only thing the long poll needs
     from this side. It is not a cursor — every fetch is still the full transcript,
     because that is what makes a moderator's hide disappear from a panel that is
     already showing it. It is the watermark the server compares against to decide
     whether to answer now or hold. */
  let seen = 0;
  let first = true;
  async function tick() {
    if (!live()) return;
    try {
      /* HELD, NOT POLLED, WHEN THE SERVER OFFERS IT. The interval below is what
         made a message take up to six seconds to cross a room; this asks the
         server to hold the request until something happens instead, so the same
         message lands in about a round trip.
         THE INTERVAL STAYS as the floor under it. A server that ignores `wait`
         answers immediately and the loop is exactly what it was, and a hold that
         expires with nothing to report costs one round trip every CHATHOLD
         seconds rather than every six — fewer requests than before, not more.
         NOT WHILE HIDDEN. A backgrounded tab holding a connection open for twenty
         seconds at a time is a socket per idle tab; the 60s back-off below is the
         right behaviour there and a long poll would quietly undo it. */
      const idleNow = typeof document !== "undefined" && document.hidden;
      /* THE FIRST READ NEVER HOLDS. It is the paint, not a poll: a reader arriving
         at a court wants what is there now, and on an EMPTY court there is nothing
         newer than a watermark of zero — so a hold on the first read is fifteen
         seconds of blank panel on exactly the courts that look most broken when
         blank. Caught by chat_live, which waits fifteen seconds for a transcript
         and got one at the moment it gave up.
         Every read after it holds, because by then there is something on screen
         and the question has changed from "what is there" to "tell me when it
         changes". */
      const d = await chatFetch(base, chain, court, o.limit || 50,
                                (first || idleNow) ? 0 : (o.hold || CHATHOLD), seen);
      first = false;
      if (!live()) return;
      // AFTER the fetch resolves and before the paint, so a message that arrives
      // while this request was in flight cannot be counted as already seen.
      for (const m of (d.messages || [])) if (m && m.id > seen) seen = m.id;
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
    // A BLANK FIELD IS A CHOICE, and it is made here rather than left to the server so
    // the reader's own message reads back with the name that was posted. Nothing is
    // REMEMBERED for a blank field: storing "anon" would prefill it for ever and turn a
    // default into a decision the reader never made.
    const typed = nameEl.value.trim();
    const m = typed || CHATDEFAULTNAME, b = bodyEl.value;
    const bad = chatValidate(m, b);
    if (bad) { note(bad); return; }
    sendEl.disabled = true;
    // ...and neither is the prefilled default typed back at us: the button opens
    // the field already reading "anon", so a reader who opens it and changes
    // nothing must land exactly where a blank field lands.
    if (typed && typed !== CHATDEFAULTNAME) {
      try { window.localStorage.setItem("kourt.chat.moniker", typed); } catch (e) {}
    }
    const r = await chatPost(base, chain, court, m, b.trim());
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
