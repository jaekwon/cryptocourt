// The board: a claim's comments (docs/CLAIM_BOARDS.md §6). posting.gno owns who
// may write and how fast; this file owns what they wrote.
//
// DEPTH ONE. A flat list of top-level comments, each carrying its direct
// replies, and no deeper. Two reasons, and the first is not aesthetic:
// pagination stops being definable on a tree — you cannot say "25 per page" when
// one subtree is 200 rows — and a flooder can push things around by replying
// deep rather than by posting more. The second is that an evidence record wants
// to be readable in order.
//
// ROWS ARE IMMUTABLE. No edit, because a text mutation outside purge breaks I4
// and because a revisable comment lets its author answer a reply and then rewrite
// what the reply was answering. No author delete, because that is
// delete-the-evidence-after-the-quote. An author may HIDE their own row, which is
// a discovery bit and leaves the row and its id in place.
//
// FOUR INDEXES PER CLAIM, and each earns its place:
//
//	board     be(rowID)           -> *boardRow   every row, addressable by id
//	boardTop  be(rowID)           -> *boardRow   top-level only, for pagination
//	boardKids be(parent)|be(rowID)-> *boardRow   one prefix scan per parent
//	boardWrote string(addr)       -> int64       rows per author, for the cap
//
// THE INDEXES HOLD THE ROW, NOT A PLACEHOLDER. They used to store `true` and
// every reader then did a second descent into `board` to fetch what the index
// had just walked past — six redundant tree descents on a page render. A pointer
// is the same width as the bool it replaces and there is one object either way,
// so the second lookup bought nothing. `board` remains the addressable-by-id
// store, which is what mustBoardRow and the deep link need.
//
// boardTop exists because bptree's offset iteration takes no start or end bound
// (tree.gno: IterateByOffset/ReverseIterateByOffset walk the WHOLE tree), so a
// prefix of a shared tree cannot be offset-paged. Newest-first over a tree that
// holds exactly the top-level rows is one reverse walk; the same query against a
// prefix of `board` would be O(everything before it).
//
// boardWrote is a counter rather than a scan for the reason stakeindex.gno gives
// about its own index: the alternative is O(rows) on every write, and "measured,
// that tax is ~57 bytes on a write that already costs ~604k gas" is the trade
// this realm has already made once and found worth making.

package kourtv2

import (
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// A couple of paragraphs. The cap is a legal surface as much as a render
	// budget: a short-post board is a materially smaller defamation surface than
	// a long-form one, and it bounds what one row can cost a page.
	maxBoardTextLen = 2000

	// Per claim, across everyone. The ceiling on what one claim's board can cost
	// to serve, whatever anybody is willing to pay to write.
	maxBoardRowsPerClaim = 512

	// Per claim, per author — a PAGE-COMPOSITION rule and not a rate limit, which
	// posting.gno's throttle already is. Flat across levels on purpose: the grief
	// is concentration on one claim, and a top-rung poster has no more right to
	// fill a single page than an entry-rung one.
	maxBoardRowsPerAuthor = 8

	// How many direct replies a top-level row renders. Depth one means a reply
	// cannot itself be replied to, so this bounds the whole subtree.
	maxBoardRepliesShown = 8
)

// boardRow is one comment. `hidden` is a DISCOVERY bit — the row keeps its id,
// its author and its place in the ordering, and its own route still serves it
// (I3). Only purge removes text.
type boardRow struct {
	id     uint64
	parent uint64 // 0 = top-level; otherwise the top-level row this answers
	author address
	text   string
	// score is the sum of its upvoters' standing, and scoreKey is the index key
	// that CURRENTLY holds it. Storing the key is what lets a re-key remove the
	// old entry rather than a recomputed one that may no longer match.
	score    int64
	scoreKey string
	// at is the height the comment landed, and it is RENDERED on the row's own
	// page — a deep link is a citation handle, and a citation without a date is
	// half a citation on a claim whose market moves under it. Nothing gates on
	// it. A parallel atTime in unix seconds was carried here too and read by
	// nothing; height is what every other record in this realm cites by, so the
	// second clock was a duplicate with no consumer.
	at int64
	// TWO HIDE BITS, TWO AUTHORITIES. They were one field, and that made
	// HideOwnComment a one-call reversal of a speechM-of-n moderator act: the
	// sanctioned author called it with hide=false and the row re-entered the
	// ranked index. Symmetrically, UnhideBoardRow exposed a row its author had
	// withdrawn. This is the same argument the legal bits below already carry —
	// different acts by different authorities, so clearing one must not clear the
	// other — applied one step further than it was.
	//
	// Both are discovery-only: the deep link serves either way. boardMark reads
	// their disjunction, so the wire and the index see one "hidden" state and only
	// the render says WHICH, because "withdrawn by its author" is false of a row
	// a moderator removed and is an assertion about a person either way.
	hiddenByAuthor bool
	hiddenByMod    bool

	// The legal bits (boardlegal.gno). ON THE ROW rather than in a side tree,
	// because the two text gates below are the whole withholding guarantee and a
	// rule they cannot see is not a chokepoint. Distinct from `hidden` because
	// they are different acts by different authorities: clearing one must not
	// clear the other.
	global          bool   // all-surface redaction; the deep link withholds too
	purged          bool   // text destroyed; the stub remains
	globalClearedAt int64 // height a global act last cleared, for the re-set window
	// No legalCode here. One was carried and read by nothing: boardActCode
	// already writes the category into the moderation log, and that copy is the
	// durable one — PurgeModLogRow destroys reasons, not codes. A second home on
	// the row for a fact that already has a durable one is a divergence risk with
	// no reader, and I3 argues against putting a legal code on the row's own page
	// in any case.
}

// boardMark is the one-character state a wire row carries, and the ONE place the
// four states are distinguished. Three wire paths read it: a client that showed
// "withdrawn by its author" over a statutory redaction would be stating something
// false about a person, so the distinction is not cosmetic.
//
//	.  readable      h  hidden by its author or a court mod
//	g  withheld      x  purged: the bytes are gone
func boardMark(r *boardRow) string {
	switch {
	case r.purged:
		return "x"
	case r.global:
		return "g"
	case r.hiddenByAuthor || r.hiddenByMod:
		return "h"
	}
	return "."
}

// ensureBoard allocates the four indexes. WRITE PATHS ONLY — named in
// check-read-purity.py's ALLOCATORS for that reason: a read that reached for it
// would let the first caller change what the second one sees, and a query
// carries no storage deposit, so it would be unpaid state growth.
func ensureBoard(cs *claimState) {
	if cs.board == nil {
		cs.board = bptree.NewBPTree32()
		cs.boardTop = bptree.NewBPTree32()
		cs.boardWrote = bptree.NewBPTree32()
	}
}

// THREE OF THE SIX ARE ALLOCATED WHEN FIRST WRITTEN, not with the others.
//
// A claim whose board has one top-level comment and no replies and no upvotes —
// which is most of them — used to carry three permanently empty trees forever.
// The argument against lazy allocation elsewhere in this realm is that it gives
// a reader a second branch which has to agree with the write path; here every
// reader ALREADY nil-checks, because these three were always nil until the first
// comment anyway. So the branch exists either way and the allocation is the only
// thing being deferred.
//
// Kept as separate trees rather than merged into one tagged keyspace: see
// boardKeyMine, whose note explains that be(N) becomes a prefix of row N's own
// key the moment the two share a keyspace, and that the failure mode is a prefix
// scan quietly returning a row it does not own.
func ensureKids(cs *claimState) *bptree.BPTree {
	if cs.boardKids == nil {
		cs.boardKids = bptree.NewBPTree32()
	}
	return cs.boardKids
}

func ensureScoreIdx(cs *claimState) *bptree.BPTree {
	if cs.boardScore == nil {
		cs.boardScore = bptree.NewBPTree32()
	}
	return cs.boardScore
}

func ensureVoted(cs *claimState) *bptree.BPTree {
	if cs.boardVoted == nil {
		cs.boardVoted = bptree.NewBPTree32()
	}
	return cs.boardVoted
}

// boardOpen reports whether a claim still takes comments.
//
// THE TERMINAL PREDICATE THE REALM ALREADY USES, not `crystallized`: a claim can
// end without ever crystallizing — CloseDeadClaim sets `closed`, and provClose
// sets `verdictAt` — so gating on crystallization would leave two terminal states
// accepting comments forever. votelock.gno gates on this same pair.
func boardOpen(cs *claimState) bool { return cs.verdictAt == 0 && !cs.closed }

func boardWroteBy(cs *claimState, who address) int64 {
	if cs.boardWrote == nil {
		return 0
	}
	if v := cs.boardWrote.Get(string(who)); v != nil {
		return v.(int64)
	}
	return 0
}

// PostComment writes a comment, or a reply to one, and returns its row id.
//
// parentRow 0 is a top-level comment; anything else must name an existing
// TOP-LEVEL row — depth one, enforced here rather than by convention.
func PostComment(cur realm, courtSlug string, claimID uint64, parentRow uint64, text string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	// A purged court accretes no new content, alongside the OpenClaim gate that
	// carve-out already covers. Tombstoning the render would not stop the rows
	// arriving.
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; it takes no new content")
	}
	cs := mustClaim(c, claimID)
	if !boardOpen(cs) {
		panic("kourtv2: this claim is settled; its board is closed to new comments")
	}
	// The two moderator freezes (boardmod.gno), read on every board WRITE and
	// nowhere else. A frozen address still stakes, votes, answers, disputes,
	// flags, opens claims, withdraws, draws emission and takes every election
	// action — the election is the remedy for a capturing set, so a freeze that
	// reached any of those could silence the vote that removes it.
	mustBoardWritable(c, cs, who)
	text = strings.TrimSpace(text)
	if text == "" {
		panic("kourtv2: a comment needs text")
	}
	if len(text) > maxBoardTextLen {
		panic("kourtv2: a comment is at most " + strconv.Itoa(maxBoardTextLen) + " characters")
	}

	// EVERY REFUSAL BEFORE THE THROTTLE, so a rejected call costs no allowance.
	// The reverse order would let a mistyped parent id or an over-long body burn
	// a post the poster never made — and the allowance refills slowly enough that
	// this is a real cost rather than an inconvenience.
	if parentRow != 0 {
		p := mustBoardRow(cs, parentRow)
		if p.parent != 0 {
			panic("kourtv2: replies are one level deep; reply to the comment, not to a reply")
		}
	}
	if boardWroteBy(cs, who) >= maxBoardRowsPerAuthor {
		panic("kourtv2: you already have " + strconv.Itoa(maxBoardRowsPerAuthor) +
			" comments on this claim")
	}
	if cs.board != nil && cs.board.Size() >= maxBoardRowsPerClaim {
		panic("kourtv2: this claim's board is full")
	}

	mustSpendPost(c, who)

	ensureBoard(cs)
	cs.boardNextID++
	r := &boardRow{
		id: cs.boardNextID, parent: parentRow, author: who, text: text,
		at: heightNow(),
	}
	k := beClaimKey(r.id)
	cs.board.Set(k, r)
	if parentRow == 0 {
		cs.boardTop.Set(k, r)
		scoreIndexPut(cs, r)
	} else {
		ensureKids(cs).Set(beClaimKey(parentRow)+k, r)
	}
	cs.boardWrote.Set(string(who), boardWroteBy(cs, who)+1)
	return r.id
}

func mustBoardRow(cs *claimState, rowID uint64) *boardRow {
	if cs.board == nil {
		panic("kourtv2: no such comment")
	}
	v := cs.board.Get(beClaimKey(rowID))
	if v == nil {
		panic("kourtv2: no such comment")
	}
	return v.(*boardRow)
}

// HideOwnComment lets an author withdraw their own row from the listings.
//
// A DISCOVERY BIT AND NOT A DELETE: the row, its id and its author stay, its own
// route still serves it, and it still counts against its author's per-claim cap.
// Otherwise self-hide would be a way to post nine comments by hiding one — and
// deleting would be delete-the-evidence-after-the-quote.
func HideOwnComment(cur realm, courtSlug string, claimID uint64, rowID uint64, hide bool) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	cs := mustClaim(mustCourt(courtSlug), claimID)
	r := mustBoardRow(cs, rowID)
	if r.author != who {
		panic("kourtv2: only a comment's author may hide their own comment")
	}
	r.hiddenByAuthor = hide
	// Top holds only visible rows, so hiding leaves the index and unhiding
	// rejoins it at whatever score it had. Newest keeps the row either way —
	// that is the ordering nothing can be pushed off.
	//
	// scoreIndexPut refuses a row that is still hidden by the OTHER authority
	// (it gates on boardMark), so an author who un-withdraws a row a moderator
	// removed does not republish it. That refusal is the whole fix.
	if hide {
		scoreIndexDrop(cs, r)
	} else {
		scoreIndexPut(cs, r)
	}
}

// ------------------------------------------------------------------ reads --

// BoardSize is the row count, top-level and replies together.
func BoardSize(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.board == nil {
		return 0
	}
	return cs.board.Size()
}

// BoardHiddenCount is how many TOP-LEVEL rows this claim's list is not
// showing — hidden, legally withheld or purged.
//
// TOP-LEVEL ONLY, and that is the whole reason it is not cs.board.Size() minus
// something. A withheld REPLY is not missing from the list: it sits inside a
// thread a reader may never open, and counting it would make the number
// disagree with what the page is actually withholding from view. The list shows
// parents, so the count is about parents.
//
// A SCAN AND NOT A COUNTER, which is the trade boardPartyRows already made and
// for the same reason one level up. A counter would have to be maintained at
// every site that changes a mark — HideOwnComment, HideBoardRow, UnhideBoardRow,
// GlobalHideRow, PurgeBoardRow, PurgeBoardRange, GlobalClearBoardBits — and one
// missed site drifts silently, forever, with nothing to notice. The walk is
// bounded by the per-claim row cap and CANNOT disagree with the board it is
// counting.
//
// It costs no gas either way: this is a read, and a read is a query rather than
// a transaction. A counter would add gas to every hide and purge in order to
// speed up something nobody pays for.
func BoardHiddenCount(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardTop == nil {
		return 0
	}
	n := 0
	cs.boardTop.Iterate("", "", func(_ string, v any) bool {
		if boardMark(v.(*boardRow)) != "." {
			n++
		}
		return false
	})
	return n
}

// BoardOpen reports whether the claim still takes comments.
func BoardOpen(courtSlug string, claimID uint64) bool {
	return boardOpen(mustClaim(mustCourt(courtSlug), claimID))
}

// CommentsWrittenBy is what an address has already spent of its per-claim cap.
func CommentsWrittenBy(courtSlug string, claimID uint64, who address) int64 {
	return boardWroteBy(mustClaim(mustCourt(courtSlug), claimID), who)
}

// BoardNewest is one page of top-level comments, newest first, packed one row
// per line:
//
//	<id>|<author>|<replies>|<mark>|<at>|<text>
//
// `at` is the block height the comment landed. It is rendered on the row's own
// page and was carried by NO exported read, so a client could offer "newest
// first" and be unable to date a single row — half a citation, on a claim whose
// market moves under it.
//
// NEWEST-FIRST IS THE ORDERING THAT CARRIES THE GUARANTEE. It is append-only, so
// a prefix of it is stable across reads and an offset a client held from an
// earlier page still points at the same row — the property stakeindex.gno makes
// a contract of for its own index. The ranked ordering cannot promise that,
// because one upvote between page one and page two moves a row across the
// boundary; that is why there are two orderings and why this is the one nothing
// can be pushed off.
//
// Hidden rows are returned with an empty text and an `h` marker rather than
// dropped: dropping them would make the page cost O(offset + hidden), with the
// hidden count chosen by whoever is hiding. The row stays, the text does not.
//
// THAT IS THE WIRE'S BARGAIN, NOT THE PAGE'S. A client is handed the marked rows
// so its paging stays cheap and stable; what it DRAWS is its own choice, and
// both renderers here drop them from the listing and collect them behind one
// link. A moderator clearing twenty griefer comments should not leave twenty
// stubs down the page — the stubs are more prominent than the comments were.
func BoardNewest(courtSlug string, claimID uint64, offset, count int) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardTop == nil || count <= 0 {
		return ""
	}
	if count > maxBoardRepliesShown*8 {
		count = maxBoardRepliesShown * 8
	}
	var b strings.Builder
	cs.boardTop.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" +
			strconv.Itoa(boardReplyCount(cs, r.id)) + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
			return false
		}
		b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
		return false
	})
	return b.String()
}

// boardReplyCount counts one parent's direct replies. Bounded by the per-claim
// row cap, and depth one means there is no recursion to bound.
func boardReplyCount(cs *claimState, parent uint64) int {
	if cs.boardKids == nil {
		return 0
	}
	pre := beClaimKey(parent)
	n := 0
	cs.boardKids.Iterate(pre, "", func(k string, _ any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		n++
		return false
	})
	return n
}

// boardKeyMine is the length guard on every prefix scan here, and it is
// REDUNDANT TODAY — recorded rather than papered over, because a guard nobody
// can kill is a guard nobody should trust without knowing why.
//
// Why it cannot be killed: boardKids holds only 16-byte `be(parent)|be(rowID)`
// keys, and the first eight bytes ARE the parent, so HasPrefix alone already
// admits exactly that parent's children. There is no key in this tree that a
// correct prefix matches and this test rejects.
//
// Why it stays: the redundancy is a property of the trees being SEPARATE. Merge
// rows and children into one tree — the obvious economy, and the one
// p/gnoland/boards invites with its flat AllReplies index — and `be(N)` becomes
// a prefix of row N's own eight-byte key, so a scan for N's children would
// return N itself. votelock.gno's pruneVoteLocks learned that lesson worse: it
// read an unparseable prefix match as permission to DELETE. One definition, used
// by every scan here, so the merge cannot half-happen.
func boardKeyMine(pre, k string) bool { return len(k) == len(pre)+8 }

// BoardReplies is one parent's direct replies, oldest first — a reply thread
// reads in order, unlike the top-level list. Packed:
//
//	<id>|<author>|<mark>|<at>|<text>
//
// FOUR FIELDS BEFORE THE TEXT, not five: a reply carries no reply count of its
// own, because depth stops at one. A client that reuses BoardNewest's arity here
// reads this row's MARK as a reply count.
func BoardReplies(courtSlug string, claimID uint64, parent uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardKids == nil {
		return ""
	}
	pre := beClaimKey(parent)
	var b strings.Builder
	n := 0
	cs.boardKids.Iterate(pre, "", func(k string, v any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
		} else {
			b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
		}
		n++
		return n >= maxBoardRepliesShown
	})
	return b.String()
}

// BoardPartyRows is the claim's author and its answerer, each with their newest
// top-level comment — the same two rows the realm's own board page pins above
// both orderings, served to clients that render their own. Packed:
//
//	<id>|<author>|<role>|<mark>|<at>|<text>
//
// ROLE STANDS WHERE BoardNewest CARRIES A REPLY COUNT and BoardTop carries a
// score: field 3 is always what THIS ordering knows about the row. It is spelled
// out — `author` or `answerer` — and it is packed rather than left to the client
// to derive, because the two rows are order-dependent only while both exist. An
// author who has not commented yields a single row that is the ANSWERER'S, and a
// client that assumed "the first row is the author" would put the wrong name on
// somebody's argument. That is the mistake a client already makes reading
// BoardReplies at BoardNewest's arity, and the fix is the same one: say it on
// the wire rather than leaving it to be inferred.
//
// IT SHARES boardPartyRows WITH THE RENDER, so this read and the realm's own
// page cannot come to disagree about who the parties are.
//
// WHY IT EXISTS AT ALL, when a client could scan BoardNewest for the two
// addresses it already holds: BoardNewest clamps count to 64 and a claim holds
// up to maxBoardRowsPerClaim rows, so a party who commented FIRST and was buried
// under later volume is off page one and silently omitted. That is precisely the
// burial the reserved slot exists to prevent, so the client-side scan fails on
// the one case the block is for.
//
// TOP-LEVEL ONLY, because boardTop holds parents: a party who has only ever
// REPLIED gets no row here. That is the render's semantics too and deliberately
// so — a reply pinned away from the thread it answers is an argument with its
// question removed.
//
// THE PINNED ROW IS NOT FILTERED ON ITS MARK. A party's newest comment may be
// hidden, withheld or purged, and it arrives with the mark set and EMPTY TEXT
// like every other packing here. A client that renders the badge and then trusts
// the text prints a name over nothing; the mark is how it knows to print the
// tombstone instead.
//
// The answerer's gate is frozenAt != 0 — what HasAnswer reports, not the mere
// presence of an address, because an unfrozen answer is not one the realm names
// as an answer anywhere else either.
func BoardPartyRows(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	// REQUIRED, not defensive: boardPartyRows iterates boardTop unguarded, and a
	// claim nobody has commented on has no tree to iterate. The render reaches it
	// only past its own `boardTop == nil` early return; an exported read has no
	// such shelter.
	if cs.boardTop == nil {
		return ""
	}
	var b strings.Builder
	for _, r := range boardPartyRows(cs) {
		// Derived from the ROW rather than from its position, which is what makes
		// the single-row case unambiguous. boardPartyRows skips an answerer who is
		// also the author, so no row can answer to both names.
		role := "answerer"
		if r.author == cs.author {
			role = "author"
		}
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" + role + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
			continue
		}
		b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
	}
	return b.String()
}

// boardTextFor is THE single place a comment's text becomes output, and it is
// named in check-render-text.py's census for that reason. A comment is
// attacker-controlled multi-line text on a page people stake money on; every
// consumer sanitises for its own context, and this is where the choice is made
// once rather than at each caller.
func boardTextFor(r *boardRow) string {
	if boardMark(r) != "." {
		return ""
	}
	// ESCAPE THE ROW DELIMITER. A comment is multi-line BY DESIGN — that is why
	// the display gate below uses sanitize.Block rather than InlineText — and
	// every wire read here packs rows as "…|…|text\n" with the text last. So a
	// comment whose text contained a newline did not merely wrap: it CLOSED its
	// own row and opened another, with an attacker-chosen id and author. Text
	// like "x\n999|g1attacker|0|.|forged" forged a row in BoardNewest, BoardTop
	// and BoardReplies alike.
	//
	// Escaped here rather than refused at PostComment, because refusing newlines
	// would delete multi-line comments, and escaped at the SINGLE wire gate rather
	// than at each of the three packers, for the reason this function exists.
	// Pipes need no escape: text is the terminal field on every row, so a bounded
	// split recovers it whole.
	return escapeWireText(r.text)
}

// escapeWireText makes a comment safe to be the last field of a newline-
// terminated wire row. Backslash first, or the escape is itself forgeable:
// "\\" + "n" would otherwise arrive indistinguishable from an escaped newline.
func escapeWireText(s string) string {
	if !strings.ContainsAny(s, "\\\n\r") {
		return s // the common case allocates nothing
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			b.WriteString("\\\\")
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// ------------------------------------------------------------------ render --

// renderBoardPage is a claim's comments, newest first.
//
// EVERY PIECE OF USER TEXT GOES THROUGH boardTextVisible, which is the single
// gate named in check-render-text.py's census. A comment is attacker-controlled
// multi-line text on a page people stake money on, and gnoweb runs no HTML
// sanitiser after the realm, so the choice of helper is made once here rather
// than at each caller.
func renderBoardPage(slug string, claimID uint64) string {
	return renderBoardIn(slug, claimID, false)
}

// renderBoardTop is the same board, ranked. A SEPARATE PAGE rather than a second
// section, and that is the fix for a real defect: the page used to print the
// parties, then Top, then Newest, with no dedup — so a two-comment board rendered
// five comment blocks, and because cold-start puts every un-upvoted row in the
// score index at score 0, on any board with no upvotes Top and Newest were
// byte-identical lists printed back to back.
//
// Two orderings survive intact, one click apart, which is what the ruling asks
// for: Top is a VIEW, and being outranked on it is never being hidden, because
// nothing can be pushed off Newest.
func renderBoardTop(slug string, claimID uint64) string {
	return renderBoardIn(slug, claimID, true)
}

// renderBoardHidden is the page the count links to: the rows this claim's
// list is not showing, and what happened to each.
//
// IT SAYS WHICH AUTHORITY ACTED, which no client can. boardMark collapses
// hiddenByAuthor and hiddenByMod into one `h` on the wire on purpose, so an
// overlay reading that wire may not attribute the act — "withdrawn by its
// author" over a moderator's hide is an assertion about a person that would be
// false half the time. This page reads the two bits directly, so it can.
//
// THE TEXT IS HERE FOR A HIDE, AND ONLY FOR A HIDE. A hide is a DISCOVERY bit:
// the bytes were never destroyed and the row's own deep link already serves them
// to anyone who asks, so withholding them on this page would hide nothing and
// only make the record harder to read than the chain already makes it. A PURGE
// destroyed the bytes and a GLOBAL withholding is pending a legal
// determination — reprinting either would be the realm undoing its own act in a
// tidier format, so those get the reason alone.
func renderBoardHidden(slug string, claimID uint64) string {
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	var b strings.Builder
	b.WriteString("# Hidden comments on claim " + strconv.FormatUint(claimID, 10) + "\n\n")
	b.WriteString("[← the comments](" + base + "/board)\n\n")
	if cs.boardTop == nil {
		b.WriteString("_Nothing has been hidden here._\n")
		return b.String()
	}
	n := 0
	cs.boardTop.Iterate("", "", func(_ string, v any) bool {
		r := v.(*boardRow)
		m := boardMark(r)
		if m == "." {
			return false
		}
		n++
		b.WriteString("---\n\n**" + sanitize.InlineText(r.author.String()) + "**")
		b.WriteString(" · block " + strconv.FormatInt(r.at, 10))
		// A purged row has no text to reach, so it gets no link to reach it.
		if m != "x" {
			b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](" + base +
				"/board/" + strconv.FormatUint(r.id, 10) + ")")
		} else {
			b.WriteString(" · #" + strconv.FormatUint(r.id, 10))
		}
		b.WriteString("\n\n")
		// WHY, AND THEN WHAT WAS SAID — but only where there is something to
		// say and saying it undoes nothing.
		//
		// A PURGE destroyed the bytes; there is no text to show and never will
		// be. A GLOBAL withholding is pending a legal determination, and this
		// page reprinting it would be the realm undoing its own act in a tidier
		// format. Those two get the reason alone.
		//
		// A HIDE is different in kind: it is a DISCOVERY bit, the text was never
		// destroyed, and the row's own deep link serves it to anyone who asks.
		// Withholding it here would hide nothing and only make the record harder
		// to read than the chain already makes it.
		//
		// THROUGH boardTextVisible, not sanitize.Block, even though the switch
		// has already established the row is neither purged nor global. That
		// function is the one place a comment's text becomes output and the one
		// place the withholding states are decided; reimplementing the decision
		// here would make this the second place, free to drift. check-render-text
		// enforces exactly that, and caught this line reading the raw field.
		switch {
		case r.purged:
			b.WriteString("> _Removed on legal grounds. The text is gone from the record; " +
				"the row remains._\n\n")
		case r.global:
			b.WriteString("> _Withheld pending a legal determination._\n\n")
		case r.hiddenByMod:
			b.WriteString("> _Removed from the listing by this court's moderators._\n\n")
			b.WriteString(boardTextVisible(r) + "\n\n")
		default:
			b.WriteString("> _Withdrawn from the listing by its author._\n\n")
			b.WriteString(boardTextVisible(r) + "\n\n")
		}
		return false
	})
	if n == 0 {
		b.WriteString("_Nothing has been hidden here._\n")
	}
	return b.String()
}

func renderBoardIn(slug string, claimID uint64, ranked bool) string {
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("# Comments on claim " + strconv.FormatUint(claimID, 10) + "\n\n")
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	b.WriteString("[← the claim](" + base + ")")
	// The ordering switch, with the current one named rather than linked.
	if ranked {
		b.WriteString(" · **Top** · [Newest](" + base + "/board)")
	} else {
		b.WriteString(" · [Top](" + base + "/board/top) · **Newest**")
	}
	b.WriteString("\n\n")

	// WHO MAY WRITE HERE, first, because it is what a reader wants to know and
	// nothing on any surface said it. Then the reasons they might not be able to.
	// A COMMENT IS A DEEP LINK, so this page is a first page as often as it is
	// a second one: somebody arrives at an argument without having seen the
	// front page, the court, or the claim. "Standing" and "entry pass" are this
	// realm's words, and the sentence explaining who may write here uses both.
	b.WriteString("Anyone with standing in this court — or a one-off entry pass — " +
		"may comment. Replies go one level deep. " +
		"[Where you stand](" + "/r/kourt/kourtv2:" + slug + "/me) · " +
		helpLink + "\n\n")
	if !boardOpen(cs) {
		b.WriteString("> This claim is settled. Its board is closed to new comments;\n" +
			"> what is here stays.\n\n")
	}
	// THE MODERATOR FREEZE, WHICH NOTHING RENDERED. ClaimBoardFrozenUntil existed
	// with no caller at all, so a frozen board was a silent wall that announced
	// itself only as a panic on somebody's write.
	// THE CLAIM'S OWN LEGAL STATE, said out loud. A claim redaction or purge does
	// NOT reach its board — the lanes are per-row on purpose, so that answering a
	// notice about one comment does not force the whole claim to be redacted
	// (§7.6). The converse is that the discussion of a redacted claim stays fully
	// readable, and neither a reader nor an operator answering a notice could tell
	// from this page. Now they can.
	if TextRedacted(c.id, claimID) {
		b.WriteString("> **The claim itself is withheld or removed on legal grounds.**\n" +
			"> These comments are a separate record and are not covered by that act.\n\n")
	}
	if until := claimBoardFrozenAt(c, claimID); until != 0 {
		b.WriteString("> **Comments are paused on this claim by this court's moderators**\n" +
			"> until block " + strconv.FormatInt(until, 10) + ". The claim itself is\n" +
			"> unaffected: answers, stakes and the verdict continue as normal.\n\n")
	}
	if cs.boardTop == nil || cs.boardTop.Size() == 0 {
		b.WriteString("_No comments yet._\n")
		return b.String()
	}

	// THE PARTIES FIRST, ON BOTH ORDERINGS. The claim's author and its answerer
	// hold a reserved place because the need behind the reserved slot is being
	// able to answer a question about your own claim and have the answer seen.
	//
	// It belongs on Newest too, and an earlier version of this render moved it to
	// the ranked page only, reasoning that recency already surfaces a party. That
	// is false the moment the party commented FIRST and volume arrived after —
	// which is the burial case the slot exists for, and the one the test asserts.
	//
	// What was actually wrong was the absence of `seen`: the page printed the
	// parties, then Top, then Newest, with no dedup, so a two-comment board
	// rendered five comment blocks and — because cold start puts every un-upvoted
	// row in the score index at score 0 — Top and Newest were byte-identical
	// lists printed back to back on any board with no upvotes.
	// HIDDEN ROWS LEAVE THE LISTING, collected behind one link instead of left
	// as a stub apiece. A moderator clearing twenty griefer comments used to
	// leave twenty notices down the page, each louder than the comment it
	// replaced — the griefing survived its own removal, in the realm's voice.
	// The count and the page are the record; this list is for what was said.
	if k := BoardHiddenCount(slug, claimID); k > 0 {
		b.WriteString("[" + strconv.Itoa(k) + " hidden comment" + plural2(k) +
			"](" + base + "/board/hidden)\n\n")
	}

	seen := map[uint64]bool{}
	if parties := boardPartyRows(cs); len(parties) > 0 {
		b.WriteString("## The parties\n\n")
		for _, r := range parties {
			seen[r.id] = true
			// A party's newest comment may itself be hidden, and a reserved slot
			// filled with a stub is the same clutter one line higher up.
			if boardMark(r) != "." {
				continue
			}
			b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
		}
		if ranked {
			b.WriteString("\n## Ranked\n\n")
		} else {
			b.WriteString("\n## Newest\n\n")
		}
	}

	shown := 0
	if ranked {
		if cs.boardScore != nil {
			cs.boardScore.IterateByOffset(0, maxBoardRepliesShown*3, func(_ string, v any) bool {
				r := v.(*boardRow)
				if seen[r.id] {
					return false // reserved above; a slot is not a second copy
				}
				b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
				shown++
				return false
			})
		}
		if shown == 0 {
			b.WriteString("_Nothing else upvoted yet — [Newest](" + base +
				"/board) is the fuller view._\n")
		}
		return b.String()
	}

	cs.boardTop.ReverseIterateByOffset(0, maxBoardRepliesShown*3, func(_ string, v any) bool {
		r := v.(*boardRow)
		if seen[r.id] || boardMark(r) != "." {
			return false // hidden rows are counted and linked above, not stubbed here
		}
		b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
		shown++
		return false
	})
	if rest := cs.boardTop.Size() - shown - len(seen); rest > 0 {
		b.WriteString("\n_" + strconv.Itoa(rest) + " older comments._\n")
	}
	return b.String()
}

// boardPartyRows is the newest top-level comment by the claim's author and by
// its answerer, in that order, skipping either who has not commented.
//
// A SCAN AND NOT AN INDEX, because it is bounded by the per-claim row cap and
// runs once per page: an index keyed by author would be a fifth tree maintained
// on every write to save a walk of at most maxBoardRowsPerClaim rows on a read.
// stakeindex.gno's note is about the opposite trade and measured it; this one
// falls the other way.
func boardPartyRows(cs *claimState) []*boardRow {
	want := []address{cs.author}
	if cs.frozenAt != 0 && cs.answerer != "" && cs.answerer != cs.author {
		want = append(want, cs.answerer)
	}
	var out []*boardRow
	for _, who := range want {
		var newest *boardRow
		cs.boardTop.ReverseIterate("", "", func(_ string, v any) bool {
			r := v.(*boardRow)
			if r.author == who {
				newest = r
				return true
			}
			return false
		})
		if newest != nil {
			out = append(out, newest)
		}
	}
	return out
}

// renderBoardRow is the per-row deep link, and it is MANDATORY rather than a
// convenience: a courtMod hide is a discovery bit, and I3 forbids a discovery
// bit removing text from a deep link. A hidden row is listed as hidden and still
// reads here.
func renderBoardRow(slug string, claimID uint64, rowArg string) string {
	id, err := strconv.ParseUint(rowArg, 10, 64)
	if err != nil {
		return "## Not found\nA comment id must be a number."
	}
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	if cs.board == nil || cs.board.Get(beClaimKey(id)) == nil {
		return "## Not found\nNo comment by that id on this claim."
	}
	r := mustBoardRow(cs, id)
	var b strings.Builder
	// WHAT THIS COMMENT IS ABOUT. A single row is the most-shared unit here —
	// somebody quotes an argument and sends the link — and this page opened
	// "# Comment 1" over "← the board" and said nothing else. A reader arriving
	// cold got an opinion with no proposition attached: not which claim, not
	// which court, and no way to find out but to click a link labelled with a
	// word that tells them nothing either.
	//
	// The claim's TITLE is the heading, because that is the thing being argued
	// about; the comment number is demoted to a subtitle, where an ordinal
	// belongs. claimTitleFor gates the title the same way the claim's own page
	// does, so a redacted or purged claim does not leak its text here.
	b.WriteString("# " + claimTitleFor(c, cs) + "\n\n")
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	b.WriteString("Comment " + strconv.FormatUint(id, 10) + " on this claim in " +
		"[" + courtNameFor(c) + "](/r/kourt/kourtv2:" + slug + ")\n\n")
	b.WriteString("[← the claim](" + base + ") · [all " +
		strconv.Itoa(cs.board.Size()) + " comments](" + base + "/board)\n\n")
	b.WriteString(renderBoardOne(slug, claimID, cs, r, false))
	return b.String()
}

// renderBoardOne is one row. `listing` distinguishes the two surfaces: a hidden
// row is withheld from a LISTING and served on its own route, which is the whole
// content of the hide bit.
func renderBoardOne(slug string, claimID uint64, cs *claimState, r *boardRow, listing bool) string {
	var b strings.Builder
	b.WriteString("---\n\n**" + sanitize.InlineText(r.author.String()) + "**")
	for _, badge := range boardBadges(cs, r.author) {
		b.WriteString(" · " + badge)
	}
	b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](/r/kourt/kourtv2:" + slug + "/" +
		strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(r.id, 10) + ")" +
		" · block " + strconv.FormatInt(r.at, 10) + "\n\n")
	if (r.hiddenByAuthor || r.hiddenByMod) && !r.global && !r.purged && listing {
		// WHICH AUTHORITY, because the two are different facts about a person.
		// A moderator act reported as "withdrawn by its author" is an assertion
		// this realm has no business making, and MODERATION §6's mod-copy rule
		// is exactly about not making it.
		if r.hiddenByMod {
			b.WriteString("> _Removed from this listing by this court's moderators. " +
				"It still reads at its own link._\n\n")
		} else {
			b.WriteString("> _Withdrawn from this listing. It still reads at its own link._\n\n")
		}
		return b.String()
	}
	b.WriteString(boardTextVisible(r) + "\n\n")
	if r.parent == 0 {
		writeBoardReplies(&b, slug, claimID, cs, r.id)
	}
	return b.String()
}

// writeBoardReplies renders a top-level comment's direct replies, indented.
//
// THE SECOND LEVEL OF THE TREE WAS WRITE-ONLY. The page printed "_1 reply._" and
// stopped — the count was not even a link, and BoardReplies, the one function
// that reads them, had no caller on any render path. Replies could be posted and
// never read on the site, which is not a discussion board.
//
// Bounded by maxBoardRepliesShown, and depth one means there is no recursion to
// bound. Each reply goes through boardTextVisible like every other piece of user
// text, and carries its own deep link, because a reply is quotable evidence too.
func writeBoardReplies(b *strings.Builder, slug string, claimID uint64, cs *claimState, parent uint64) {
	// NO nil check on boardKids here, and that is deliberate rather than an
	// oversight: boardReplyCount nil-guards already, so a claim with no replies
	// index answers 0 and the next line returns before anything is dereferenced.
	// A third guard would be one the corpus cannot catch, because it cannot
	// change an answer — the count IS the guard.
	pre := beClaimKey(parent)
	n, total := 0, boardReplyCount(cs, parent)
	if total == 0 {
		return
	}
	cs.boardKids.Iterate(pre, "", func(k string, v any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		r := v.(*boardRow)
		// A hidden reply leaves the thread for the same reason a hidden
		// top-level row leaves the list: the stub is louder than what it
		// replaced. BoardHiddenCount does not count these — a reply is not
		// missing from a list it was never in — so the link above does not
		// promise them either.
		if boardMark(r) != "." {
			return false
		}
		b.WriteString("> **" + sanitize.InlineText(r.author.String()) + "**")
		for _, badge := range boardBadges(cs, r.author) {
			b.WriteString(" · " + badge)
		}
		b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](/r/kourt/kourtv2:" + slug +
			"/" + strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(r.id, 10) + ")\n>\n")
		{
			// The reply's own text, quoted one level. Block-sanitised like every
			// other comment; the "> " prefix is ours, not the author's.
			for _, line := range strings.Split(boardTextVisible(r), "\n") {
				b.WriteString("> " + line + "\n")
			}
			b.WriteString("\n")
		}
		n++
		return n >= maxBoardRepliesShown
	})
	if total > n {
		b.WriteString("_" + strconv.Itoa(total-n) + " more repl" + plural(total-n) +
			" at [#" + strconv.FormatUint(parent, 10) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(parent, 10) + ")._\n\n")
	}
}

func plural(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}

// boardBadges says what a commenter has at stake on THIS claim — author,
// answerer, or a position and its side.
//
// COMPOSITION MADE LEGIBLE RATHER THAN CURATED. The ordering does not rank by
// this; the reader is told who has money on the question and decides for
// themselves. All four facts are already stored, so the badge costs a lookup.
func boardBadges(cs *claimState, who address) []string {
	var out []string
	if who == cs.author {
		out = append(out, "author")
	}
	if cs.frozenAt != 0 && who == cs.answerer {
		out = append(out, "answerer")
	}
	for _, side := range []int{sideYES, sideNO} {
		if v := cs.stakers.Get(posKey(who, side)); v != nil {
			if p := v.(*stakePos); p.stake > 0 {
				name := "YES"
				if side == sideNO {
					name = "NO"
				}
				out = append(out, name+" "+strconv.FormatInt(p.stake, 10))
			}
		}
	}
	return out
}

// boardTextVisible is THE single place a comment becomes display text.
//
// sanitize.Block, the STRICT variant, for the reason claimBodyVisible's note
// gives about a claim body: a comment is multi-line by design so InlineText is
// wrong, and Block escapes the doc-spoof markers that BlockRich deliberately
// preserves. A comment is lower-trust than a claim body, not higher.
func boardTextVisible(r *boardRow) string {
	// The legal states first, and they say WHICH one: "removed" over a purge and
	// "withheld" over a redaction are different facts, and the second is
	// reversible by a counter-notice while the first is not.
	if r.purged {
		return "> _Removed. The text is gone from the record; the row remains._"
	}
	if r.global {
		return "> _Withheld pending a legal determination._"
	}
	if r.text == "" {
		return "_(empty)_"
	}
	return sanitize.Block(r.text)
}

// ---- Top: the ranked ordering ---------------------------------------------
//
// TWO ORDERINGS, AND NEITHER IS THE ONLY PAGE ONE. That is the whole design.
// MODERATION.md §3.2 refuses an auto-ranking on any address- or vote-keyed
// signal for the directory, calling it a capture surface, and gives two
// paginated orderings from two monotone indexes instead. This is the same
// arrangement one level down: Top ranks by who upvoted, Newest cannot be pushed
// off, and capturing Top buys a VIEW rather than the surface.
//
// WHY STANDING IS A DEFENSIBLE KEY WHERE STAKE WAS NOT. Stake is rentable — this
// is a no-loss realm, principal returns 1x either way, so holding the top of a
// claim costs only carry and the rank collapses for everyone at settlement.
// Standing cannot be rented, cannot be transferred, and does not survive
// splitting: twenty addresses sharing one holder's standing cast twenty votes
// worth a twentieth each.
//
// COLD START NEEDS NO CONSTANT. Every un-voted row scores zero and ties break on
// the row id, so descending iteration over a court with no standing is EXACTLY
// newest-first. Top degenerates into Newest rather than into noise, which is why
// there is no rankColdStartN here despite the plan naming one.

// boardScoreKey sorts high score first, and newest first within a score. Both
// halves are inverted because bptree iterates ascending, and beInv is the
// realm's one descending-key idiom (modrender.gno) rather than a second spelling
// of it.
func boardScoreKey(score int64, rowID uint64) string {
	return beInv(score) + beInv(int64(rowID))
}

// scoreIndexPut and scoreIndexDrop are the ONLY writers of the score index.
//
// THE STORED KEY IS REMOVED, NEVER A RECOMPUTED ONE. reindexBurn does the same
// and for the same reason: a key rebuilt from a score that has since changed
// misses, and the tree keeps a second entry for one row — which then renders
// twice, at two different ranks.
//
// THE INDEX HOLDS ONLY VISIBLE ROWS. Filtering at read time is not an option
// here: bptree's IterateByOffset counts every row it VISITS, not every row the
// callback keeps (tree.gno increments `visited` whatever the callback returns),
// so a page that skipped hidden rows would short-page by an amount whoever is
// hiding gets to choose. Keeping them out of the index also stops a tombstone
// holding a rank it can no longer justify.
func scoreIndexPut(cs *claimState, r *boardRow) {
	// Any withholding state keeps the row out: Top must not carry a rank for text
	// nobody may read, and a clear must not re-index a row the OTHER authority
	// still has hidden.
	if r.parent != 0 || boardMark(r) != "." {
		return
	}
	r.scoreKey = boardScoreKey(r.score, r.id)
	ensureScoreIdx(cs).Set(r.scoreKey, r)
}

func scoreIndexDrop(cs *claimState, r *boardRow) {
	if cs.boardScore == nil || r.scoreKey == "" {
		return
	}
	cs.boardScore.Remove(r.scoreKey)
	r.scoreKey = ""
}

// UpvoteComment adds the caller's standing to a top-level comment's score.
//
// UPVOTE ONLY. A downvote is burial handed to anyone with standing, and burial
// already belongs to moderators behind a threshold.
//
// The weight is SNAPSHOTTED. A later slash does not re-sort every board in the
// court — which is a real cost, honestly: a cast vote is an effect a sanction
// cannot reach, so §4's "no banked balance a sanction fails to reach" is true of
// throughput and false of rank. Bounded, not fixed, by Top not being the only
// view.
func UpvoteComment(cur realm, courtSlug string, claimID uint64, rowID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; it takes no new content")
	}
	cs := mustClaim(c, claimID)
	if !boardOpen(cs) {
		panic("kourtv2: this claim is settled; its board is closed")
	}
	// The two moderator freezes (boardmod.gno), read on every board WRITE and
	// nowhere else. A frozen address still stakes, votes, answers, disputes,
	// flags, opens claims, withdraws, draws emission and takes every election
	// action — the election is the remedy for a capturing set, so a freeze that
	// reached any of those could silence the vote that removes it.
	mustBoardWritable(c, cs, who)
	r := mustBoardRow(cs, rowID)
	if r.parent != 0 {
		panic("kourtv2: only top-level comments are ranked; a reply is read under its parent")
	}
	if r.author == who {
		panic("kourtv2: you cannot upvote your own comment")
	}
	// A PURGED ROW TAKES NO VOTES. Hidden and redacted rows do, deliberately —
	// both are reversible, and scoreIndexPut re-ranks them correctly when they
	// come back. A purge is the one state that never comes back: the bytes are
	// gone and the row is out of the ranked index for ever, so the vote's effect
	// is unreachable by construction and the allowance it costs buys nothing.
	// The realm refuses charges for nothing everywhere else; this is that rule.
	if r.purged {
		panic("kourtv2: that comment was destroyed on legal grounds; it takes no votes")
	}
	vk := beClaimKey(rowID) + string(who)
	if cs.boardVoted != nil && cs.boardVoted.Has(vk) {
		panic("kourtv2: you have already upvoted that comment")
	}
	var w int64
	if sr := lookupStanding(c, who); sr != nil {
		w = sr.score
	}
	if w <= 0 {
		panic("kourtv2: an upvote is weighted by standing, and you have none here yet")
	}
	// A vote is a state write, so it is its own flood surface and draws on the
	// same allowance a comment does.
	mustSpendPost(c, who)

	ensureBoard(cs)
	ensureVoted(cs).Set(vk, true)
	scoreIndexDrop(cs, r)
	r.score = satAdd(r.score, w)
	scoreIndexPut(cs, r)
	return r.score
}

// HasUpvoted reports whether an address has already spent its vote on a row.
func HasUpvoted(courtSlug string, claimID uint64, rowID uint64, who address) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardVoted == nil {
		return false
	}
	return cs.boardVoted.Has(beClaimKey(rowID) + string(who))
}

// CommentScore is one row's accumulated weight.
func CommentScore(courtSlug string, claimID uint64, rowID uint64) int64 {
	return mustBoardRow(mustClaim(mustCourt(courtSlug), claimID), rowID).score
}

// BoardTop is one page of top-level comments, best first:
//
//	<id>|<author>|<score>|<mark>|<at>|<text>
//
// The SCORE stands where BoardNewest carries a reply count, and the mark is
// always "." — so the two orderings are the same arity and NOT the same fields.
//
// No hidden rows appear, because none are in the index — see scoreIndexPut.
func BoardTop(courtSlug string, claimID uint64, offset, count int) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardScore == nil || count <= 0 {
		return ""
	}
	if count > maxBoardRepliesShown*8 {
		count = maxBoardRepliesShown * 8
	}
	var b strings.Builder
	cs.boardScore.IterateByOffset(offset, count, func(_ string, v any) bool {
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" +
			strconv.FormatInt(r.score, 10) + "|.|" + strconv.FormatInt(r.at, 10) +
			"|" + boardTextFor(r) + "\n")
		return false
	})
	return b.String()
}

// writeBoardLink is the claim page's one line about its board: how many
// comments, and where they are.
//
// It says the COUNT, because "Comments" alone cannot distinguish an empty board
// from a busy one, and the difference is the whole reason to click. It appears
// even at zero, because a board nobody has written on is exactly the one worth
// inviting somebody to.
func writeBoardLink(b *strings.Builder, c *Court, cs *claimState, claimID uint64) {
	// EVERY ROW, not the top-level ones. This counted cs.boardTop, which is the
	// pagination index and holds only rows with no parent — so a board with
	// three threads and two replies advertised "3 comments" and then showed
	// five things to read. The number under a link is a promise about what is
	// behind it, and a reply is a comment: it is written by a person, it is
	// counted against their daily allowance, it can be hidden, upvoted and
	// purged like any other row, and a reader scanning the page counts it.
	//
	// cs.board is the tree of all rows, so this also counts the ones that
	// render as tombstones — hidden, legally withheld, purged. That is right for
	// the same reason: they occupy a line on the page the reader is about to
	// open, and a count that skipped them would undershoot again.
	//
	// IT ALSO AGREES WITH BoardSize NOW, which has always returned
	// cs.board.Size(). A client reading the realm and a reader looking at the
	// realm's own page were being told different numbers for the same board.
	n := 0
	if cs.board != nil {
		n = cs.board.Size()
	}
	link := "/r/kourt/kourtv2:" + c.id + "/" + strconv.FormatUint(claimID, 10) + "/board"
	switch {
	case n == 0 && !boardOpen(cs):
		return // a settled claim with no comments has nothing to offer
	case n == 0:
		b.WriteString("[Discuss this claim](" + link + ") — no comments yet.\n\n")
	default:
		b.WriteString("[" + strconv.Itoa(n) + " comment" + plural2(n) + "](" + link +
			") · [Top](" + link + "/top)\n\n")
	}
}

func plural2(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
