#!/usr/bin/env node
// A set's picture on the map card, and the viewer behind it.
//
// THE NODE SHOWS A SLICE, NOT THE PICTURE. A map node is a box the layout sized,
// so its face is object-fit:cover — the image fills the rectangle and whatever
// does not fit is cropped away. That is right for a node and wrong for looking:
// the card is the surface with room to show the thing itself, and `contain` is
// the difference between a picture and a texture.
//
// AND A CARD IS STILL A COLUMN. Fitted to ~300px it is a larger thumbnail, so the
// click is what makes this a way to actually see the photograph.
const { src, fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

// The card is a pure function of a folder, so it is called rather than scanned.
const esc = s => String(s).replace(/[&<>"']/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const safeInline = esc, clipText = (t) => String(t || "");
const card = eval(fn("mapFolderCard") + "; mapFolderCard");

const data = {claims: {3:{title:"a"}, 4:{title:"b"}, 5:{title:"c"}}};
const fauci = {name:"Fauci", count:9, claims:[3,4,5], born:2, path:"2",
               img:"https://kourt.xyz/m/abc123"};
const withPic = card(fauci, data, "covid");

ok("a set with a picture shows it on the card", /class="mapsel-face"/.test(withPic));
ok("...as an img the reader can see, loaded lazily",
   /<img src="https:\/\/kourt\.xyz\/m\/abc123"[^>]*loading="lazy"/.test(withPic));
ok("...with no referrer, like every other archive image on this page",
   /referrerpolicy="no-referrer"/.test(withPic));
ok("...above the name, because it is the face of the thing being named",
   withPic.indexOf("mapsel-face") < withPic.indexOf("mapsel-t"));

/* AND NOTHING AT ALL WHEN THERE IS NO PICTURE. Most sets have none — the realm's
   "i" flag exists precisely so a client does not spend a read finding that out —
   so an empty frame would be the common case rather than the exception. */
ok("a set without one shows no frame",
   !/mapsel-face/.test(card({...fauci, img:""}, data, "covid")));

/* THE URL IS CARRIED ON THE BUTTON, not closed over. The card is built as a
   string and wired up afterwards by paint(), so the viewer has to read its
   subject from the DOM. */
ok("the button carries the url for the viewer",
   withPic.includes('data-full="https://kourt.xyz/m/abc123"'));
ok("...and paint() wires it to the viewer",
   /\.mapsel-face["'\]]?\)?\.forEach[\s\S]{0,140}openPictureFull\(b\.dataset\.full\)/.test(src));

/* A BUTTON, NOT AN ANCHOR. The map panel's rule is that nothing leaves the map
   until asked; a link here would navigate away from the selection the reader
   just made. */
ok("it is a button, so it does not navigate", /<button type="button" class="mapsel-face"/.test(withPic));
ok("...and says what it does, for a reader who cannot see it",
   /aria-label="Look at this set's picture full size"/.test(withPic));

/* THE VIEWER IS A NATIVE <dialog>, for the reason every other dialog in this file
   is one: Escape and the backdrop close it with no keydown handler of our own,
   and the browser supplies the focus trap. */
const viewer = fn("openPictureFull");
ok("the viewer is a native dialog", /document\.createElement\("dialog"\)/.test(viewer));
ok("...built once and reused, not one node per look",
   /if\(!PIC_FULL\)\{/.test(viewer) && /let PIC_FULL = null/.test(src));
ok("...opened modally, with a fallback for a browser without showModal",
   /showModal/.test(viewer) && /setAttribute\("open"/.test(viewer));
ok("...and a click anywhere dismisses it", /addEventListener\("click", *\(\)=>PIC_FULL\.close\(\)\)/.test(viewer));
ok("a missing url opens nothing", /if\(!url\) return;/.test(viewer));

/* CONTAIN ON BOTH SURFACES, which is the whole point of the feature: the node
   crops because it must, and neither of these two may. */
ok("the card's picture is contained, not cropped",
   /\.mapsel-face img\{[^}]*object-fit:contain/.test(src));
ok("...and so is the full view", /\.picfull img\{[^}]*object-fit:contain/.test(src));
ok("the node itself still covers, which is what a node needs",
   /\.mfimg\{[^}]*object-fit:cover/.test(src) || /preserveAspectRatio/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
