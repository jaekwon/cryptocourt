#!/usr/bin/env node
// A court's or a set's picture, filed from the curate page.
//
// WHY THIS EXISTS. check-curation-reachable had SetCourtImage and SetFolderImage
// exempted for sixteen iterations with the note "needs an UPLOAD, which btn()
// cannot express" — the `media` argument is not a URL anybody can type, it is
// the pipe-delimited line media.js builds from bytes it has hashed. The clear
// half shipped as plain buttons; this is the set half, and the exemptions are
// gone.
//
// The guard covers the ARGUMENT ORDER now that both calls are spelled out with
// literals. What it cannot see is everything below.
const fs = require("fs");
const path = require("path");
const { src, fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

const control = fn("pictureControl");
const mount = fn("mountPicture");

// THE REALM TAKES EXACTLY ONE IMAGE — court.gno panics "a court carries exactly
// one image" and folders.gno "a folder carries exactly one image". So the file
// input must NOT be multiple; the claim composer's tray sets multiple="multiple"
// and holds seven, which is the affordance this control must not borrow.
ok("the picker takes one file, because the realm takes exactly one image",
   /pick\.type = "file"/.test(control) && !/multiple/.test(control));

// AN IMAGE, NEVER A LINK. Both verbs refuse mediaKindVideo — "a video is a link
// the court cannot vouch for … an unreasonable thing to make the face of a
// venue". The composer has addLink; this must not.
ok("there is no paste-a-link path, which the realm would refuse anyway",
   !/addLink/.test(control));
ok("the item is built as an image", /kind:\s*"img"/.test(control));

// THE BUTTON ONLY EXISTS ONCE THERE IS AN ARGUMENT TO SIGN. A media line with no
// mirror is one the realm refuses, so a button rendered before the upload
// finishes is a control that fails AFTER the work instead of before it.
ok("the action area is cleared before the upload starts",
   /say\("Shrinking…"\)/.test(control) && /act\.innerHTML = ""/.test(control));
ok("the button is only built after a mirror exists",
   control.indexOf("mirrors:[up.url]") < control.indexOf("refresh()", control.indexOf("mirrors:[up.url]")));

// A FAULT STOPS IT. mediaItemFault is what the realm's own parser will apply;
// asking it first is how this says no before the chain does.
ok("a faulty item is refused here rather than by the chain",
   /mediaItemFault\(item/.test(control) && /if\(fault\)\{ say\(fault\); return; \}/.test(control));

// THE NOTE IS textContent. It carries a caption somebody typed and a fault
// naming it back to them — both attacker-influenced on a shared moderator page.
ok("the status line is set as text, never as markup",
   /note\.textContent|say = t => \{ note\.textContent/.test(control)
   && !/note\.innerHTML/.test(control));

// BOTH VERBS, AND THE FOLDER ONE CARRIES AN ID. SetFolderImage's signature is
// (cur realm, courtSlug string, folderID uint64, media string); without the id
// input the control could only ever address folder 1.
ok("both entrypoints are offered", /"SetCourtImage"/.test(control) && /"SetFolderImage"/.test(control));
ok("the folder control asks which set", /spec\.folder/.test(control) && /aria-label", "Set id"/.test(control));

// MOUNTED, AND GUARDED. mountCompose is wrapped in a typeof check so a missing
// media.js leaves the page whole; this is on the same page and needs the same.
ok("the curate page has a host for it", /id="curatepic"/.test(src));
ok("it is mounted", /mountPicture\(document\.getElementById\("curatepic"\), slug\)/.test(src));
ok("...behind a typeof guard, so a missing media.js does not take the page down",
   /typeof mediaArgLine === "function"\)\s*\{\s*\n\s*mountPicture/.test(src));

// AND THE EXEMPTIONS ARE GONE. The guard's own note says the shape this list
// should have: "an entry, then a button, then no entry."
const guard = fs.readFileSync(path.join(__dirname, "..", "..", "scripts",
  "check-curation-reachable.py"), "utf8");
const exempt = guard.slice(guard.indexOf("EXEMPT = {"), guard.indexOf("ENTRY = re.compile"));
ok("SetCourtImage is no longer exempted from reachability", !/SetCourtImage/.test(exempt));
ok("SetFolderImage is no longer exempted either", !/SetFolderImage/.test(exempt));

// The clear buttons' help text pointed at a set half that did not exist. It does
// now, and saying "not here yet" on a page that has it is worse than saying
// nothing.
ok("the clear buttons no longer say the set half is missing",
   !/putting one on does, so it is not here yet/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
