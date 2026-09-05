# `mod:newfolder` — a folder the court decides on

A folder is the one piece of a court's structure created by fiat: `CreateFolder`
gates on `requireFolderMod` and nothing else writes `cm.folders`. This spec adds
a route where the court itself decides, using machinery that already exists.

**It is a verb, not a system.** `meta.gno` already turns a claim into a binding
proposal: a reserved `mod:` title names a verb and a target, the claim is decided
by the ordinary bonded path (answer bond → 72h → optional dispute → sealed vote),
and on a final YES `ExecuteAppeal` runs a `switch` on the verb. Everything below
is one new case in that switch plus the registration call its payload needs.

---

## 1. The payload does not fit in a title, so it is registered first

The existing schema parses its target as a `uint64`:

    mod:hide:<court>/<claimID>        mod:setmods:<court>/<candidateID>

A folder needs a name and a description — up to 200 runes each, arbitrary text.
Putting that in the title would make the title do double duty as data, and the
title is the one field `sanitize.InlineText` guards hardest.

**The realm has already answered this exact problem.** `setmods` installs a
moderator SET, which is also data, and it does it in two steps:
`RegisterModCandidate` records the set and returns an id; the appeal then names
that id. Folders take the same shape:

```gno
// Records a proposed folder and returns its id. Any holder may call it; it
// creates nothing and costs gas only.
func RegisterFolderProposal(cur realm, courtSlug, name, desc string, parentID uint64) uint64
```

Then the appeal is:

    mod:newfolder:<court>/<proposalID>

This buys three things beyond tidiness:

* **Validation happens at registration**, where the caller can be told what is
  wrong — name length, charset, `parentID` nesting depth — instead of failing
  weeks later inside an execution nobody is watching.
* **The predate guard works unchanged.** `ExecuteAppeal` already requires the
  target to strictly predate the appeal (`cand.at >= cs.openedAt` panics for
  `setmods`). A proposal id gets that for free; a name embedded in a title
  could not have it at all.
* **The title stays a number**, so no free text crosses the parser.

### Parser change

One case in `parseModTitle`, alongside the other target verbs:

```gno
case verbUnhide, verbClear, verbHide, verbSetmods, verbNewfolder:
```

No other change: the `<court>/<id>` shape, the slug charset loop, and the
`id == 0` rejection all apply as written.

---

## 2. Restorative, not aggressive — and this reverses my first answer

I said "make it aggressive" before reading what aggressive *does*. It is not a
severity label; it is a specific requirement:

```gno
if verbIsAggressive(p.verb) {
    if cs.route != "vote" || cs.decidedRounds == 0 {
        panic("kourtv2: this verb needs a decided contested vote, not silence")
    }
    if p.verb != verbHide && !cs.credEligible {
        panic("kourtv2: a manufactured contest cannot seize authority — ...")
    }
}
```

An aggressive verb can only execute if the claim was **disputed and voted on,
with real weight against it**. For hiding a claim or reseating moderators that is
right: those seize authority, so silence must never carry them.

Applied to a folder it is perverse. An uncontested, obviously-good proposal could
never execute — the folder would exist only if somebody had fought it. The verb
would be unusable in exactly the case it is for.

So `newfolder` is **restorative**: it may execute from the undisputed route.
That is not a free pass. The undisputed route still requires:

* someone to **answer YES with a bond**, which is money at risk, and
* **72h of silence**, in which any holder may dispute for a bond.

A folder is additive, carries zero economic weight, and one moderator can undo it
with `RetireFolder` — the same reasoning `folders.gno:298` already uses to
justify one-moderator folder ops without an m-of-n ceremony. The bar should match
the consequence, and this one does.

---

## 3. Guards

Everything in `ExecuteAppeal` applies unchanged: the court must exist and
predate the appeal, the verdict must be final and YES, the claim must not have
executed already, and the verdict must not have expired. On top of those:

| Guard | Where | Why |
|---|---|---|
| proposal exists and predates the appeal | execute | same shape as the `setmods` candidate check |
| court is not at `maxFolders` | execute | the cap is a storage bound; a passed claim cannot be allowed to breach it |
| no live folder with that name | execute | two proposals can pass; the second is a no-op, not a duplicate |
| `parentID` still exists and is not retired | execute | weeks pass between proposal and execution |
| nesting depth still legal | execute | `cm.mustNestable` — the tree may have deepened meanwhile |
| latch key `"fold:" + court` | `latchKey` | per COURT, not per proposal — `setmods`' comment explains why: a per-target key lets an attacker bank unlimited parallel installs and discharge them one after another |

**Failure is a refusal, not a panic that strands the claim.** A verdict that
cannot execute — cap reached, name taken, parent retired — should emit an event
and mark the appeal spent, so the claim reads as decided-but-not-applied rather
than as an execution anyone can retry forever. Mirror whatever `setmods` does
when its candidate has become uninstallable.

---

## 4. Execution

```gno
case verbNewfolder:
    prop := ensureMod(tc).mustFolderProposal(p.target)
    id := createFolderFromProposal(tc, prop)      // shares CreateFolderIn's body
    chain.Emit("FolderCreated",
        "court", tc.id, "by", "meta",
        "folder", strconv.FormatUint(id, 10),
        "proposal", strconv.FormatUint(p.target, 10),
        "height", eventHeight())
```

`CreateFolder`/`CreateFolderIn` keep their moderator gate. The shared body they
and this case both call must not: authority is checked by the caller, which is
the pattern `installModSet` already follows.

The moderation log gains a row whose actor is the meta court rather than an
address — `emitModAct(c.id, 0, "folder-create", who)` already takes a `who`, so
this is a value, not a schema change.

---

## 5. What this does not settle

**Paying the proposer is the easy half, and it already exists.** "You should be
rewarded for making a good folder" is the AUTHOR BONUS — `cs.drawAuthor`, the
8-point one-shot slice a claim's author draws when it resolves. It is not an
accuracy payment and never was; it pays for having written something worth
deciding. A folder proposal that carries is exactly that, so the proposer being
paid needs no new idea and no new lane.

**The accuracy slice is the half that strains.** `cs.drawWinners` pays STAKERS
in proportion to conviction — stake × time — for having backed the right side.
On "was this claim wrongly hidden?" that is a payment for judgement. On "should
this court have a folder called Fauci" it risks being a payment for agreeing,
and conviction weighting makes it profitable to squat early on a proposal that
looks popular.

**Unless the question is read as a prediction, which it can be.** "Is this a
category this court actually needs?" is not a preference — it is falsifiable, by
whether anything ever gets filed there. A folder nobody uses was a bad call. Read
that way the accuracy slice is defensible, and the honest version of the verb
would settle against USE rather than against a show of hands: carry the proposal,
then judge it on whether the folder filled. That is a much longer horizon than
72h and a different mechanism, so it is a direction rather than a change to this
spec.

**Three ways to resolve it, cheapest first:**

1. **Author bonus only.** Set `drawWinners` to zero for `newfolder` appeals; the
   proposer is paid, stakers are not. Smallest change, keeps *stakes, never
   ballots* intact, and still answers "reward me for a good folder".
2. **Full split, as any other claim.** Simplest code — no special case — and the
   defence is the prediction reading above. Costs the cleanliness of the rule.
3. **A ballot instead of a claim.** `modvote.gno` already does propose → holders
   vote → install. Truest to the separation, but it pays nobody, which is the
   thing being asked for.

(1) is what I would build. It grants the request exactly and gives up nothing.

**Venue.** Appeals are heard by the meta court, deliberately neutral, because
moderation acts need a venue that is not the court being acted on. Folder
curation is local and weightless, and covid's own holders are the interested
party. Hearing folder proposals in the meta court is consistent; hearing them in
the target court is arguably more correct. Not a detail — it decides who pays the
bond and whose stake is at risk.

---

## 6. Tests this needs

* the title parses, and a near-miss (`mod:newfolder:covid/0`, missing slash,
  bad slug charset) does not
* a proposal that does not predate its appeal is refused
* the undisputed route executes it; a NO verdict does not
* executing twice is refused by the latch
* cap reached / name taken / parent retired each refuse cleanly and mark spent
* the latch is per court: two live folder appeals on one court cannot both bank
* `RegisterFolderProposal` creates no folder by itself — the read-purity and
  membership checks in `make realm-test` will notice if it does
