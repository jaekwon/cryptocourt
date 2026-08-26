// PKGPATH: gno.land/r/kourt/evtkourt
package evtkourt

// THE MOD-LOG EVENTS, held for the first time.
//
// KNOWN-GAPS carried a row saying so and standing for a class: "NOTHING in this suite
// asserts an emitted event: emitModAct calls chain.Emit, and the only facility that can
// observe those is a filetest's `Events:` directive, which no filetest here uses. So all
// ten of folders.gno's emitModAct calls are unheld — this row is the one that says so out
// loud, rather than ten rows saying it ten times." It also said what would close it: "IF
// THIS COMES BACK CAUGHT, somebody has written a filetest that asserts events."
//
// This is that filetest. The directive exists — gnovm/pkg/test/filetest.go marshals the
// EventLogger's events to JSON and matches them against the block below — so the gap was
// closable all along and only needed somebody to use it.
//
// WHY IT MATTERS BEYOND THE ROW. The mod-log stream is how a moderator's curation becomes
// visible after the fact: a reader who wants to know what was hidden, retired or reordered
// has nothing else. An event nobody asserts is an audit trail nobody has checked exists.
//
// THREE VERBS, one folder, in the order a curator actually uses them — create, retire,
// restore — because the interesting failure is not "no event" but "the wrong act name",
// and a single verb cannot show that.

import (
	"gno.land/r/kourt/kourtv2"
)

func main(cur realm) {
	kourtv2.StartCourt(cross(cur), "evt", "Event Court")
	id := kourtv2.CreateFolder(cross(cur), "evt", "Highlights", "")
	kourtv2.RetireFolder(cross(cur), "evt", id)
	kourtv2.RestoreFolder(cross(cur), "evt", id)
	println("folder:", id)
	println("retired:", kourtv2.FolderRetired("evt", id))
	// THE TWO REALM-WIDE DEFAULT SETTERS, which emitted nothing at all until the
	// authority-matrix audit (D14). They move the floor under EVERY court at once,
	// so they are the widest acts in the board lane — and there is no single court
	// to log them against, which makes the event the only record there can be. An
	// event nobody asserts is an audit trail nobody has checked exists, which is
	// the sentence this filetest was written for.
	kourtv2.SetLadderDefault(cross(cur), 5, 25, 100, 3, 10)
	kourtv2.SetCreditRatesDefault(cross(cur), 10000, 10000, 2000, 1000, 5000)
}

// Output:
// folder: 1
// retired: false

// Events:
// [
//   {
//     "type": "ModAct",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "evt"
//       },
//       {
//         "key": "claim",
//         "value": "0"
//       },
//       {
//         "key": "act",
//         "value": "folder-create"
//       },
//       {
//         "key": "by",
//         "value": "g1cg7y89t6k2sry4ga32qe7j782wsyq8vdycwach"
//       },
//       {
//         "key": "height",
//         "value": "123"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/kourtv2"
//   },
//   {
//     "type": "ModAct",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "evt"
//       },
//       {
//         "key": "claim",
//         "value": "0"
//       },
//       {
//         "key": "act",
//         "value": "folder-retire"
//       },
//       {
//         "key": "by",
//         "value": "g1cg7y89t6k2sry4ga32qe7j782wsyq8vdycwach"
//       },
//       {
//         "key": "height",
//         "value": "123"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/kourtv2"
//   },
//   {
//     "type": "ModAct",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "evt"
//       },
//       {
//         "key": "claim",
//         "value": "0"
//       },
//       {
//         "key": "act",
//         "value": "folder-restore"
//       },
//       {
//         "key": "by",
//         "value": "g1cg7y89t6k2sry4ga32qe7j782wsyq8vdycwach"
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
//         "value": "set-ladder-default:5:25:100:3:10"
//       },
//       {
//         "key": "by",
//         "value": "g1cg7y89t6k2sry4ga32qe7j782wsyq8vdycwach"
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
//         "value": "set-rates-default:10000:10000:2000:1000:5000"
//       },
//       {
//         "key": "by",
//         "value": "g1cg7y89t6k2sry4ga32qe7j782wsyq8vdycwach"
//       },
//       {
//         "key": "height",
//         "value": "123"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/kourtv2"
//   }
// ]
