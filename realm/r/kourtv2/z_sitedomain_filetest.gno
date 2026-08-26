// PKGPATH: gno.land/r/kourt/sitekourt
package sitekourt

// THE SITE-DOMAIN EVENTS — the second events filetest, and why there is one.
//
// z_events_filetest.gno measured 58,874b against a 60,000b ceiling, and its own
// note in scripts/check-storage.py said what to do next: "the next act added
// here needs either a deliberate ceiling raise, with a reason, or a second
// events filetest. Do not raise it to make room without saying which." This is
// the second filetest. The ceiling over there stays where it is and keeps
// meaning what it said — a court plus a folder plus three verbs — rather than
// being widened each time somebody needs a few hundred bytes.
//
// WHAT IS HELD HERE. SetSiteDomain and ClearSiteDomain point every rendered page
// in the realm at an outside website, and take the pointer away again. There is
// no court to log them against — they are realm-wide by construction — so the
// event is the only record there can be that a domain was ever set, by whom, or
// when it changed. That is exactly the shape the first events filetest was
// written for, one lane further out.
//
// BOTH VERBS, in the order they happen. A single verb cannot show that the undo
// names a different act, and "the wrong act name" is the interesting failure.

import (
	"gno.land/r/kourt/kourtv2"
)

func main(cur realm) {
	// A court has to exist before the global DAO has an admin, and the first
	// court's creator is that admin — so this caller is the seat under test.
	kourtv2.StartCourt(cross(cur), "site", "Site Court")
	kourtv2.SetSiteDomain(cross(cur), "kourt.xyz")
	println("domain:", kourtv2.SiteDomain())
	kourtv2.ClearSiteDomain(cross(cur))
	println("cleared:", kourtv2.SiteDomain() == "")
}

// Output:
// domain: kourt.xyz
// cleared: true

// Events:
// [
//   {
//     "type": "GlobalAct",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "*"
//       },
//       {
//         "key": "claim",
//         "value": "0"
//       },
//       {
//         "key": "act",
//         "value": "set-site-domain:kourt.xyz"
//       },
//       {
//         "key": "by",
//         "value": "g1djper8qnalpftu5jag8sm3rg2fk77se4vyc4yr"
//       },
//       {
//         "key": "height",
//         "value": "123"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/kourtv2"
//   },
//   {
//     "type": "GlobalAct",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "*"
//       },
//       {
//         "key": "claim",
//         "value": "0"
//       },
//       {
//         "key": "act",
//         "value": "clear-site-domain"
//       },
//       {
//         "key": "by",
//         "value": "g1djper8qnalpftu5jag8sm3rg2fk77se4vyc4yr"
//       },
//       {
//         "key": "height",
//         "value": "123"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/kourtv2"
//   }
// ]
