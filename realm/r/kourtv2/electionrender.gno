// The election, which rendered nowhere.
//
// THE THIRD INSTANCE OF ONE PATTERN. The comment board had a working route and
// nothing linked to it; the filing tree had seven verbs and no page; and the
// ballot has fourteen entrypoints — five verbs and nine reads — and no page at
// all. In every case the writes were gated, tested and mutation-covered, the
// read side existed, and only the rendering was missing. The suite proved the
// machinery worked; nothing proved anybody could see it.
//
// WHY THIS ONE IS THE WORST OF THE THREE. A court's moderators can hide claims,
// hide comments, slash standing, freeze addresses out of the boards and answer
// claims. The election is the ONLY mechanism by which holders replace them. And
// an election that closes under its floor does not void — `install` requires
// `turnout >= floor`, and below it the CURRENT set stands. So an election nobody
// can see is not a missing feature, it is an incumbent-retention machine: the
// nomination window passes with no candidates, the vote window passes with no
// turnout, and the outcome is indistinguishable from a court that voted to keep
// the moderators it had.
//
// The reads exist because somebody expected this page: ElectionTally's own
// comment says it "exposes a line's approving weight and retain's, for render".

package kourtv2

import (
	"strconv"
	"strings"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// electionPath is the sub-route, spelled once. Not a slug collision risk: it
// sits at parts[1], where "mod" and "me" already live, and a claim id is
// numeric so a word can never be taken for one.
const electionPath = "election"

// renderElection is /<slug>/election.
//
// IT RENDERS WHETHER OR NOT ONE IS OPEN, because "no election is open" is the
// answer a holder most often needs and the state in which they can do something
// about it. A page that 404s when the ballot is closed would tell somebody
// looking for their remedy that the remedy does not exist.
func renderElection(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	base := "/r/kourt/kourtv2:" + slug
	var b strings.Builder
	b.WriteString("# Electing the moderators of " + courtNameFor(c) + "\n\n")
	b.WriteString("[← " + courtNameFor(c) + "](" + base + ") · [moderation log](" +
		base + "/mod)\n\n")
	// WHAT IS AT STAKE IN AN ELECTION, said before the mechanics. A reader who
	// does not already know what moderators can do cannot judge whether this
	// page is worth their attention, and the powers are not guessable from the
	// word "moderator".
	b.WriteString("A court's moderators answer claims, curate its folders, and can " +
		"hide a claim, hide a comment, slash somebody's standing, or freeze an " +
		"address out of the boards. **This ballot is the only way the court's " +
		"holders replace them.**\n\n")

	cm := c.mod
	if cm == nil || cm.election == nil || cm.election.resolved {
		writeNoElection(&b, c, cm)
		b.WriteString("\n" + helpLink + "\n")
		return b.String()
	}
	writeOpenElection(&b, c, cm, base)
	b.WriteString("\n" + helpLink + "\n")
	return b.String()
}

// writeNoElection is the closed state: who holds the seats now, and what it
// would take to challenge them.
func writeNoElection(b *strings.Builder, c *Court, cm *courtMod) {
	b.WriteString("## No election is open\n\n")
	if cm == nil || cm.n == 0 {
		b.WriteString("This court has no moderator set yet — its creator holds the " +
			"seat until an election or an appointment changes that.\n")
	} else {
		b.WriteString("- seats held now: **" + strconv.Itoa(cm.n) + "**, " +
			strconv.Itoa(cm.m) + " of whom must agree for a moderation act\n")
	}
	now := heightNow()
	// THE COOLDOWN, WITH ITS DEADLINE. A holder told only "you cannot open one"
	// has no way to learn when they can, and the number is already in state.
	if cm != nil && cm.electionCooldownUntil > now {
		b.WriteString("- this court is in its post-election cooldown until block **" +
			strconv.FormatInt(cm.electionCooldownUntil, 10) + "** (now " +
			strconv.FormatInt(now, 10) + "); no ballot can open before then\n\n")
		return
	}
	b.WriteString("- a ballot **can be opened now**\n\n")
	// The two steps, in order, because RegisterModCandidate must precede
	// OpenElection and the failure otherwise is a panic with no page to explain
	// it.
	b.WriteString("Opening one takes two calls: `RegisterModCandidate` records a " +
		"proposed set of moderators and returns its id, and `OpenElection` puts " +
		"that id on a ballot. Any holder may do both.\n\n")
}

// writeOpenElection is the live ballot.
func writeOpenElection(b *strings.Builder, c *Court, cm *courtMod, base string) {
	e := cm.election
	now := heightNow()
	b.WriteString("## A ballot is open\n\n")
	// WHICH PHASE, FIRST. The two windows govern different actions, and a reader
	// who nominates during the vote window or votes during nomination gets a
	// panic. The phase is derived rather than left for the reader to compare two
	// block numbers against a third — and derived through the SAME predicates the
	// gates use, so the banner cannot say "Nominating" while the chain refuses a
	// nomination. The block numbers printed below are still heights: they are the
	// reference beside the deadline, and converting what they SAY is the
	// projection pass, not this one.
	switch {
	case !nominationClosed(e):
		b.WriteString("**Nominating.** Candidate sets may be added until block **" +
			strconv.FormatInt(e.nominateEnd, 10) + "**; voting runs from then " +
			"until block **" + strconv.FormatInt(e.voteEnd, 10) + "**.\n\n")
	case !votingClosed(e):
		b.WriteString("**Voting.** Nominations closed at block " +
			strconv.FormatInt(e.nominateEnd, 10) + "; the ballot closes at block **" +
			strconv.FormatInt(e.voteEnd, 10) + "**.\n\n")
	default:
		b.WriteString("**Closed and awaiting resolution.** The ballot shut at block " +
			strconv.FormatInt(e.voteEnd, 10) + ". Anyone may call `ResolveElection` " +
			"to apply the result below.\n\n")
	}
	b.WriteString("- now: block " + strconv.FormatInt(now, 10) + "\n")
	b.WriteString("- a candidate set costs a bond of **" +
		strconv.FormatInt(e.bond, 10) + " " + qualifiedSymbol(c) + "**\n")
	b.WriteString("- weights are pinned at the epoch the ballot opened, so buying " +
		"coin now does not add voting weight to it\n\n")

	writeBallotLines(b, c, e)
	writeTurnoutBar(b, c, e)
}

// writeBallotLines is every candidate set on the ballot, with its members and
// its approving weight.
//
// RETAIN IS A LINE LIKE ANY OTHER, listed beside the challengers rather than
// buried under them: it is what wins if nobody clears the bar, so a reader
// comparing the field needs it in the same list they are comparing.
func writeBallotLines(b *strings.Builder, c *Court, e *election) {
	b.WriteString("## On the ballot\n\n")
	rows := 0
	e.lines.Iterate("", "", func(_ string, v any) bool {
		l, ok := v.(*ballotLine)
		if !ok {
			return false
		}
		rows++
		b.WriteString("- **set #" + strconv.FormatUint(l.candID, 10) + "** — " +
			strconv.FormatInt(l.weight, 10) + " " + qualifiedSymbol(c) + " approving\n")
		if cv := c.mod.candidates.Get(beClaimKey(l.candID)); cv != nil {
			cand := cv.(*modCandidate)
			b.WriteString("  - would seat " + strconv.Itoa(len(cand.members)) +
				", " + strconv.Itoa(cand.m) + " of whom must agree\n")
			for _, m := range cand.members {
				b.WriteString("  - `" + sanitize.InlineText(m.String()) + "`\n")
			}
		}
		return rows >= renderPageSize
	})
	if rows == 0 {
		b.WriteString("_No candidate sets yet._ Until one is nominated there is " +
			"nothing to elect, and the current moderators stay.\n\n")
	} else {
		b.WriteString("\n")
	}
	b.WriteString("- **keep the current moderators** — " +
		strconv.FormatInt(e.retainW, 10) + " " + qualifiedSymbol(c) + " approving\n\n")
}

// writeTurnoutBar is the floor, and the warning that goes with it.
//
// THE HAZARD THIS PAGE MOST HAD TO GET RIGHT. ElectionFloorOf's own comment says
// it: install requires turnout >= floor, and BELOW IT NOTHING INSTALLS AND THE
// CURRENT SET STANDS. So an over-read of achievable turnout — mobilising to what
// looks like the bar and falling short — hands the election to the incumbents.
// Falling short is not a null result; it is a win for one side.
//
// And the floor is 5% of `votable`, which nets out the court escrow and NOTHING
// ELSE: coin sitting at a wrapper's address is inside that pool and no key can
// vote it. A reader who reasons "we need 5% of the pool" is reasoning about a
// pool part of which cannot turn out, so the real share of votable-and-castable
// weight required is higher than the percentage suggests. Both facts are printed
// rather than left for a reader to derive, because deriving them wrong has a
// direction and the direction favours the incumbents.
func writeTurnoutBar(b *strings.Builder, c *Court, e *election) {
	b.WriteString("## Turnout\n\n")
	b.WriteString("- cast so far: **" + strconv.FormatInt(e.turnout, 10) + " " +
		qualifiedSymbol(c) + "**\n")
	b.WriteString("- the bar: **" + strconv.FormatInt(e.floor, 10) + " " +
		qualifiedSymbol(c) + "**, fixed when the ballot opened\n")
	if e.turnout < e.floor {
		b.WriteString("- still needed: **" + strconv.FormatInt(e.floor-e.turnout, 10) +
			" " + qualifiedSymbol(c) + "**\n\n")
	} else {
		b.WriteString("- the bar is cleared\n\n")
	}
	b.WriteString("> **Falling short is not a draw.** If the ballot closes with less " +
		"than the bar cast, nothing is installed and the current moderators keep " +
		"their seats — the same outcome as a vote to retain them.\n>\n" +
		"> And the bar is a share of this court's coin **including coin that " +
		"cannot vote**: it nets out only the court's own escrow, so coin held at " +
		"a wrapper's address counts toward the pool the bar was measured against " +
		"while no key can cast it. The share of actually-castable weight you need " +
		"is therefore larger than the bar looks.\n\n")
}
