package kourtv2

/* GOVERNED SETS — §6's deferred half, un-deferred.
 *
 * A claim whose title begins with the wedjat, U+13080 𓂀, is asking to become a
 * set. It is a claim in every other respect: it is staked on, answered under
 * bond, disputable for 72 hours, and it settles YES or NO like any other. What
 * the mark buys is what happens AFTER a YES — the court has agreed that this
 * heading should exist, so a set is created and bound to the claim that carried
 * it.
 *
 * THE CLAIM DOES NOT BECOME THE CONTAINER, and that is not a compromise, it is
 * what §6 actually specified: "the heading is itself a claim, affirmed by vote,
 * its slug bound on affirmation". §5's guard — "only sections may be containment
 * parents ... claim→claim containment stays forbidden" — is why association.gno
 * implements the argument edge and not that one, and it still holds here: the
 * container is a folder, exactly as it was before, and the claim owns it.
 * Reading it as "a set IS a claim" is right at the level a reader cares about
 * and wrong at the level the storage cares about, and only one of those has to
 * be true for the feature to be worth having.
 *
 * WHY THIS IS NOT mod:newset AGAIN. That verb asks the META court to overrule
 * a court's moderators, and its proposal carries the name because a claim title
 * could not. This asks the court ITSELF, in its own venue, and the title IS the
 * name — which is the whole appeal of the mark. The two do not overlap: one is
 * an appeal against moderators who will not file, the other is a court filing
 * for itself. A court with no moderators at all can use this and cannot use
 * that.
 *
 * EXECUTION IS A SEPARATE TRANSACTION, following ExecuteMetaVerdict rather than
 * inventing a second convention: settling a claim must not do unbounded work,
 * and every rule has to be re-checked at the moment of execution anyway, because
 * weeks pass between opening a claim and carrying it and a court can fill up or
 * take the name in between.
 */

import (
	"strconv"
	"strings"

	"chain"
)

/* THE MARK IS ONE EXACT CODEPOINT, U+13080 EGYPTIAN HIEROGLYPH D010.
 *
 * SPELLED AS AN ESCAPE, NOT AS THE GLYPH, so that what this constant is cannot
 * depend on an editor, a terminal font or a copy-paste. The Egyptian block holds
 * several eyes that are indistinguishable at title size — D004 𓁹, D006, D007,
 * D010 𓂀 — and a source file that shows the reader a picture instead of a
 * number is a file where the wrong one can be pasted in and nobody will see it.
 *
 * AND THE MATCH IS EXACT. parseModTitle's comment makes the same promise for
 * "mod:" — "a near-miss cannot masquerade as binding" — and the promise is worth
 * more here, because the near-misses are invisible rather than merely similar.
 * A claim opening with D004 is an ordinary claim with an unusual first
 * character; it is NOT a set, and it must not become one by looking like it.
 */
const (
	setMark   = "\U00013080" // 𓂀 U+13080, and nothing else
	setPrefix = setMark + " "
)

/* parseSetTitle reads a governed-set title. The mark, one space, then the name.
 *
 * THE SPACE IS REQUIRED, so that the mark is a prefix and not merely a first
 * character: without it "𓂀Lab leak" and "𓂀 Lab leak" would be two spellings of
 * one thing, and a court would eventually hold both.
 *
 * THE NAME IS THE REST, VERBATIM — no trimming beyond the single delimiter
 * space. A title with trailing whitespace is a different title, and folderTextOK
 * is what decides whether the result is a legal name; silently repairing the
 * caller's string here would mean the set's name and the claim's title no longer
 * match, which is the one invariant this feature sells.
 */
func parseSetTitle(title string) (string, bool) {
	if !strings.HasPrefix(title, setPrefix) {
		return "", false
	}
	name := title[len(setPrefix):]
	if !folderTextOK(name, "") {
		return "", false
	}
	return name, true
}

// IsSetClaim reports whether this claim's title asks to be a set. It says
// nothing about whether the court agreed — see ClaimSet for that.
func IsSetClaim(courtSlug string, claimID uint64) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	_, ok := parseSetTitle(cs.title)
	return ok
}

/* ClaimSet is the binding, read forwards: which set did this claim create, or 0.
 *
 * A SCAN, AND DELIBERATELY SO. The reverse direction is a field on the folder,
 * so this walks folders looking for it. That is bounded by maxFolders, which is
 * the same bound folderNameTaken already walks on every single AddToFolder, so
 * this is not a new cost class — and a second index would be a second thing to
 * keep true.
 */
func ClaimSet(courtSlug string, claimID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil || c.mod.folders == nil {
		return 0
	}
	var out uint64
	c.mod.folders.Iterate("", "", func(_ string, v any) bool {
		f := v.(*folder)
		if f.bornOf == claimID {
			out = f.id
			return true
		}
		return false
	})
	return out
}

// SetBornOf is the binding read backwards: which claim carried this set into
// existence, or 0 for one a moderator simply created.
func SetBornOf(courtSlug string, folderID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.mustFolder(folderID).bornOf
}

/* AffirmSet carries a settled 𓂀 claim into the set it asked to be.
 *
 * PERMISSIONLESS, like ExecuteMetaVerdict: the verdict is the authority, and
 * making execution a privilege would let whoever holds it sit on a decision the
 * court already took.
 *
 * NO DESCRIPTION. A moderator's folder has a one-line desc because nothing else
 * says what belongs in it; this set has a whole claim — with a body, a stake
 * history and a verdict — sitting behind it, and that is a better description
 * than a line anybody could have written. Leaving it empty also means there is
 * exactly one place the text lives, so the two can never disagree.
 *
 * AT THE ROOT. Nesting a governed set under another would need the parent named
 * somewhere, and the title is spent on the name. That is a real limit and it is
 * stated rather than hidden: a moderator can MoveFolder it afterwards, which is
 * the same authority that could have retired it anyway.
 */
func AffirmSet(cur realm, courtSlug string, claimID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)

	// 1. The title still has to parse. It cannot change under a claim, but
	//    reading it here rather than trusting a flag set at open means there is
	//    one definition of what a set title is, in one function.
	name, ok := parseSetTitle(cs.title)
	if !ok {
		panic("kourtv2: this claim's title is not a set heading")
	}

	// 2. A FINAL YES. provClose is the three-failed-rounds close, which is not a
	//    verdict at all — meta.gno refuses on exactly the same pair, and for the
	//    same reason: `provisional` alone would read a closed-without-decision
	//    claim as a YES.
	if cs.verdictAt == 0 || cs.provClose {
		panic("kourtv2: no final verdict")
	}
	if cs.provisional != 0 {
		panic("kourtv2: the verdict was not YES")
	}

	// 3. Exactly once. Without this anyone could re-call a settled claim and
	//    mint a set per call until the court hit its folder cap.
	if prior := ClaimSet(courtSlug, claimID); prior != 0 {
		panic("kourtv2: this claim already carries set " + strconv.FormatUint(prior, 10))
	}

	// 4. RE-CHECKED NOW, not at open. Weeks pass between opening a claim and
	//    carrying it: an ordinary CreateFolder can take the name in between, and
	//    the court can fill up. A name that has since been taken is a REFUSAL —
	//    the same call mod:newset makes, and for the same reason: two live
	//    folders sharing a name is worse than a claim that has to be re-filed.
	cm := ensureMod(c)
	if folderNameTaken(cm, name) {
		panic("kourtv2: a folder by that name already exists")
	}

	/* 5. THE PARENT IS WHERE THE CLAIM ITSELF IS FILED, which is what makes a
	   SUBSET expressible at all. The title is spent on the name and carries no
	   room for a path, so the alternative was to birth every set at the root and
	   have a moderator move it — which put a moderator back in the middle of the
	   one act this feature exists to take out of their hands.
	   Filed in one set, born inside it. Filed in none, born at the root.
	   AND FILED IN SEVERAL IS A REFUSAL, not a guess. A claim may belong to any
	   number of sets — ClaimSets returns a slice precisely because of that — so
	   "the parent" is only well defined when there is exactly one. Picking the
	   first would make the tree depend on iteration order, which is the kind of
	   thing that is stable until the day it is not.
   newFolderCore re-checks the depth cap for us: a parent already four deep
	   refuses there, with the message that names the cap.
	   TWO READS, ONE LETTER APART, and they answer opposite questions:
	     ClaimFolders(claim) — the sets this claim is FILED IN  (the parent)
	     ClaimSet(claim)     — the set this claim BORE          (guard 3, above)
	   Reading the wrong one here would silently nest every set under itself. */
	var parent uint64
	if in := ClaimFolders(courtSlug, claimID); len(in) == 1 {
		parent = in[0]
	} else if len(in) > 1 {
		panic("kourtv2: this claim is filed in more than one set; a born set needs exactly one parent")
	}

	fid := newFolderCore(cm, name, "", parent)
	cm.mustFolder(fid).bornOf = claimID
	emitModAct(c.id, claimID, "folder-create", cs.author)
	chain.Emit("SetAffirmed",
		"court", c.id,
		"claim", strconv.FormatUint(claimID, 10),
		"folder", strconv.FormatUint(fid, 10),
		"parent", strconv.FormatUint(parent, 10),
		"name", name,
		"height", eventHeight(),
	)
	return fid
}
