# Sibling order for folders

**Status: designed, audited, implementing.**

## The gap, stated as a thing the chain cannot say

`MoveItemInFolder` orders the *claims inside* a folder — `items []uint64` is
documented "in curation order" and a curator can put an item anywhere in it.
Nothing orders the *folders themselves*. `FolderTree` walks `c.mod.folders` in
key order, the key is `beClaimKey(id)`, so siblings come out in **creation
order**, permanently.

The local curation format can already say more than that. `scenarios/covid-curation.json`
nests folders as arrays, and array order is authored order — "Origins" is first
because a curator put it first. Seeding preserves it only by accident: the
seeder creates folders in array order, so creation order happens to equal
authored order on a freshly seeded court. It stops being true the moment
anybody edits:

- a folder created later always lands **last**, so a curator cannot file a
  "Prologue" ahead of what already exists;
- `MoveFolder` re-parents into the **end** of the new sibling list, so moving a
  folder and moving it back is not a no-op in what the reader sees.

That is the same class as the other four items in this programme: the overlay
draws something the chain cannot store.

## Shape: one int, and a rule about zero

`ord int` on `folder`. Siblings sort by `(placed, ord, id)` where a row with
`ord == 0` is **unplaced** and unplaced rows sort **after** placed ones, by id.

**Within a sibling group only, and the group keeps its slots.** The first
implementation sorted the whole tree by `(parent, placed, ord, id)`, which reads
as tidier and quietly broke the promise this design is built on: a nested court
that nobody had ordered emitted `1:0:-,2:1:-,3:0:-` before and
`1:0:-,3:0:-,2:1:-` after, so every deployed nested court's read changed shape on
a feature none of them had used. `TestFolderTree` caught it. Permuting each group
inside the positions it already occupied keeps an unordered court byte-identical
whatever its shape — which is what "no migration" actually has to mean — and
keeps a parent ahead of its own children instead of letting ordered children
overtake it.

Zero is doing real work here, and choosing it over `ord = index` is the whole
design:

| situation | with "unplaced sorts last" | with plain `ord = index`, 0 default |
|---|---|---|
| court that never ordered | every row `ord==0`, sorts by id — **byte-identical output to today** | same |
| new folder after an ordering | `ord==0` → **last**, where a new folder belongs | `0` → **first**, jumping ahead of the curated list |
| ordering a subset | refused (below), so it cannot arise | silently reshuffles the unlisted |

So there is no migration: an already-deployed court reads `ord` as the zero
value, sorts exactly as it does today, and the first `OrderFolders` call is what
changes anything. No version field, no backfill — the same posture `c.mod` and
the argument trees already take.

## The entrypoint takes the whole sibling list, not one folder

`OrderFolders(cur realm, courtSlug string, parentID uint64, ids string)` — a
comma-separated list of folder ids, assigned `ord = 1..n` in the order given.

A per-folder setter (`SetFolderOrder(id, n)`) was the first design and is worse
in a specific way: reordering a list of eight folders becomes eight
transactions, each leaving the tree in an intermediate state a reader can see,
and "insert between" needs renumbering the moment two neighbours are adjacent
integers. The list form is one transaction, atomic, and idempotent.

**The list must be exactly the sibling set** — every folder whose `parent ==
parentID`, no more, no fewer, no duplicates. Two alternatives were rejected:

- *allow a subset*: the unlisted keep `ord==0` and sort last, so ordering three
  of five silently demotes the other two. Surprising, and it makes the call's
  effect depend on state the caller may not have read.
- *ignore unknown ids*: a typo becomes a silent no-op on the folder the curator
  meant, which is the failure mode this repo keeps writing guards against.

Retired and purged siblings are **in** the set. Their rows survive, they still
appear in `FolderTree` behind their flags, and a restored folder that had been
excluded would come back at an arbitrary position.

The refusal has to say which id, or a curator with a 40-folder court is left
diffing two lists by hand.

## Reads: sorted rows, no format change — and one client that had to change

`FolderTree` emits the same `id:parent:flags` rows, in sorted order. No new
field to parse, no second read; a client that wants to *edit* an order reads
positions, which are already there.

The first draft of this section said the overlay needed no change at all,
because `nestChainFolders` appends children in the order it meets them. That was
checking the wrong function. `chainFolders` parses the tree into a `Map` keyed by
id and then builds its fetch list with `for(let i=1;i<=F;i++)` — so it read the
order out of the tree and immediately threw it away, and every court would have
kept rendering in id order with the realm insisting otherwise.

It walks `shape.keys()` now (a `Map` preserves insertion order), falling back to
the 1..F walk when the tree read is absent — a realm deployed before `FolderTree`
existed — and still appending any id the tree did not name, so a malformed row is
last rather than invisible.

The general lesson, which this repo keeps relearning: **"the client already does
the right thing" is a claim about a specific function, and the function that
matters is usually the one upstream of the one you checked.**

## Audit

**Unbounded read cost.** No. `maxFolders` is 100, so the sort is over ≤100 rows
and `FolderTree` stays the ~1.2KB it is today. The sort is a local slice; it
allocates nothing persistent, which is what `check-read-purity.py` is about.

**Storage growth.** One `int32` per folder row, on a struct that already carries
a name, a description and an item slice. Nothing per-call accumulates.

**Gas.** One write touches at most `maxFolders` rows — bounded by the same
constant that bounds the read, and the caller pays for it once rather than n
times, which is strictly cheaper than the per-folder setter it replaces.

**Spam without a price.** Moderator-gated, single-signer, like `CreateFolder`
and `RenameFolder`: additive and reversible acts are 1-of-n here, and a wrong
order is fixed by sending the right one. No new public surface — a stranger
cannot call it at all, so there is nothing to flood.

**Moderation gaps.** An order carries no text: no new escaping surface, no new
thing to purge. It cannot reveal a purged folder's name because it moves rows,
not names, and the name gate is in the reads that return names. The one honest
note: order is *editorial*, so a moderator can bury a folder at the bottom —
which is true of the filing system as a whole and is why moderators are a
per-court elected set.

**Migration for already-deployed courts.** None, by the zero rule above.
