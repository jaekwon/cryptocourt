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
function chatStatusLine(you, nowSec) {
  const st = you && you.state ? String(you.state) : "ok";
  if (st === "ok") return "";
  // Not a punishment and must not read like one: the court was withdrawn, which says
  // nothing about the person reading it.
  if (st === "closed") return "This court's chat has been closed.";
  const until = you && you.until ? Number(you.until) : 0;
  const ref = you && you.ref ? Number(you.ref) : 0;
  let when = "";
  if (until > nowSec) {
    const left = until - nowSec;
    when = left < 3600 ? " for another " + Math.max(1, Math.round(left / 60)) + " minutes"
         : left < 86400 ? " for another " + Math.round(left / 3600) + " hours"
         : " for another " + Math.round(left / 86400) + " days";
  }
  const what = st === "ban"
    ? "Posting from your connection is blocked"
    : "Posting from your connection is paused" + when;
  // The reference exists so an appeal can quote something specific. Saying so is the
  // difference between a dead end and a process.
  return ref
    ? what + ". You can appeal — quote reference " + ref + "."
    : what + ".";
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
  if ([...m].length > 24) return "that name is too long (24 characters)";
  if (!b) return "type something";
  if ([...b].length > 400) return "that message is too long (400 characters)";
  // Matches MaxInputBytes on the server. Reachable with 400 astral characters.
  if (new TextEncoder().encode(b).length > 4096) return "that message is too long";
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
    + "</div>"
    + '<ol class="chatlog" aria-live="polite"></ol>'
    + '<div class="chatdry" hidden></div>'
    + '<div class="chatstate"></div>'
    + '<form class="chatform" autocomplete="off">'
    +   '<input class="chatmoniker" maxlength="24" placeholder="name"'
    +     ' aria-label="your name" value="' + chatEsc(moniker) + '">'
    +   '<input class="chatinput" maxlength="400" placeholder="say something"'
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

// chatBase resolves the service URL, and returns "" for "do not use the network".
//
// Absent config means off, not a default host: a page that quietly starts posting to
// a guessed origin because nobody configured one is worse than a page with no chat.
function chatBase(cfg) {
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
  };
}

// chatHealth asks whether moderation is actually applying timeouts.
//
// §6 says the panel must not claim moderation that is not happening, and until now nothing
// implemented that — no client in the repo fetched this endpoint at all, while CHAT.md said
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

// chatDryRunNotice is the wording, kept apart from the fetch so it can be tested directly.
//
// Deliberately factual rather than either reassuring or inviting. It does not say "you will
// not be punished", which reads as an invitation, and it does not stay silent, which would
// let the panel imply a protection nobody is providing.
function chatDryRunNotice(health) {
  if (!health || health.enforcing !== false) return "";
  return "Automatic moderation is not applying timeouts on this server right now.";
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
.chatlog{list-style:none;margin:0;padding:0;max-height:15rem;overflow-y:auto}
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
.chatdry{margin:.4rem 0;font-size:.9em;opacity:.75}
.chatform{display:flex;gap:.4rem;margin-top:.5rem}
.chatmoniker{flex:0 0 8rem;min-width:0}
.chatinput{flex:1 1 auto;min-width:0}
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
  const base = chatBase(o.cfg);
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

  const nowSec = () => Math.floor((o.now ? o.now() : Date.now()) / 1000);
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
  function paintState(you) {
    if (!live()) return;
    const line = chatStatusLine(you, nowSec());
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
    formEl.addEventListener("submit", ev => {
      ev.preventDefault();
      note("This is a demo — nothing is sent anywhere.");
    });
    return () => { if (gen === CHATGEN) CHATGEN++; };
  }

  // One health request per mount, in live mode only — demo mode makes no network calls.
  chatHealth(base).then(h => {
    if (!live()) return;
    const notice = chatDryRunNotice(h);
    if (!notice) return;
    const el2 = el.querySelector(".chatdry");
    if (el2) {
      el2.textContent = notice;
      el2.hidden = false;
    }
  });

  let timer = null;
  async function tick() {
    if (!live()) return;
    try {
      const d = await chatFetch(base, chain, court, o.limit || 50);
      if (!live()) return;
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

  tick();
  return () => {
    if (gen === CHATGEN) CHATGEN++;
    if (timer) clearTimeout(timer);
  };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {chatEsc, chatFlag, chatWhen, chatStatusLine, chatValidate,
    chatLineHtml, chatLogHtml, chatPanelHtml, chatDemoThread, chatBase,
    chatFetch, chatPost, chatStyles, chatHealth, chatDryRunNotice, mountChat, CHATCSS};
}
