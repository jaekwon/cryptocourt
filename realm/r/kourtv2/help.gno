// The page that explains the thing, for somebody who has never seen it.
//
// WHY IT IS A REALM PAGE AND NOT A WEBSITE. Read the front page as a stranger:
// a one-line lede, then a list of court names and coin symbols. Nothing says
// what a court is, what a claim is, what staking does, or why the strangest and
// most important property here — that you cannot lose your stake — is true.
// Every one of those answers lived in docs/ or in the overlay, which is to say
// nowhere a gnoweb reader could reach. A realm whose explanation is off-chain is
// a realm you have to be told about before you can use it.
//
// THE ROUTE CANNOT COLLIDE WITH A COURT, structurally rather than by
// reservation. A slug is 1..11 characters (mustSlug), and "how-it-works" is 12,
// so no court can ever be registered at this path and no reserved-word list has
// to be maintained to keep it that way. reservedSlugs exists for symbols that
// could impersonate an asset in a wallet; a route that is simply too long to be
// a slug needs no entry there and cannot be shadowed by an older court that
// registered the name first.

package kourtv2

import "strings"

// helpPath is the one place the route is spelled, so the carve in render() and
// every link to it cannot drift apart.
const helpPath = "how-it-works"

// helpLink is the phrase the rest of the realm points at this page with. One
// wording everywhere: a reader who has already dismissed it once should be able
// to recognise it and skip it, which they cannot do if every page invents its
// own words for the same page.
const helpLink = "[New here? How Kourt works](/r/kourt/kourtv2:" + helpPath + ")"

// renderHelp answers, in order, the questions a stranger actually has: what is
// this, what happens to my money, what is a court, what is a claim, where is the
// argument, what does it cost, who is in charge.
//
// PLAIN WORDS, AND SHORT. The realm's own vocabulary — principal, standing,
// epoch, reservoir, emission — is precise and means nothing to somebody who has
// not been told what it means. Each term is either explained here on first use
// or not used at all. A page that needs the glossary it was written to replace
// is not a help page.
func renderHelp() string {
	var b strings.Builder
	b.WriteString("# How Kourt works\n\n")
	b.WriteString("Kourt is a place to put money behind whether a factual claim is " +
		"true — without being able to lose the money.\n\n")
	// THE ORDER OF OPERATIONS, before anything else, because every sentence
	// below depends on knowing which of the two currencies is in play. An
	// earlier draft of this page said "stake GNOT", which is wrong —
	// stake.gno's Stake, "Stake backs one side of a claim with CC" — and it is the
	// worst possible sentence to get wrong, since a reader who believes they are
	// staking GNOT has the whole model upside down before they reach paragraph
	// two.
	b.WriteString("It works in two steps. **GNOT buys a court's coin**, one way; " +
		"**that coin is what you stake** on the court's claims.\n\n")

	// THE 1× GUARANTEE FIRST, because it is the load-bearing surprise. Every
	// reader arrives with a mental model built from prediction markets, where
	// the losing side funds the winning one. Leave that model in place and
	// nothing below reads correctly: "stake NO" sounds like a bet they can lose.
	b.WriteString("## You cannot lose your stake\n\n")
	b.WriteString("Stake the court's coin on YES or NO and the stake stays yours. " +
		"It is locked where it is, not handed to anybody: when the claim is " +
		"answered you withdraw exactly what you put in — 1×, always, whichever " +
		"side you took and whichever side turned out to be right. No one's stake " +
		"pays anyone else's winnings.\n\n")
	// TWO DIFFERENT THINGS BEING RIGHT EARNS, and the page used to run them
	// together as "the court's coin … is what gives you a voice". Coin is a
	// balance and standing is a score; the pass is the only place they touch,
	// and a reader who thinks a big balance buys a voice has been told the one
	// thing the design is built to prevent.
	b.WriteString("Then what is at stake? Being right pays you more of the court's " +
		"coin, out of the reserve it set aside for exactly that — and being wrong " +
		"pays you none. Nothing of yours is taken either way.\n\n")
	b.WriteString("Being right also earns **standing**, which is a separate thing " +
		"from a balance: a score you cannot buy, and what actually gives you a " +
		"voice here.\n\n")

	b.WriteString("## A court is a subject\n\n")
	b.WriteString("A court covers one subject — an epidemic, an election, a company. " +
		"Each court has its own coin, and coins never cross between courts. Being " +
		"right about virology earns you nothing in a court about monetary policy. " +
		"That is the point: standing is earned subject by subject, by the people who " +
		"follow that subject.\n\n")

	b.WriteString("## A claim is a statement that can be settled\n\n")
	b.WriteString("A claim is a sentence that is either true or false, written so it " +
		"can actually be answered. You stake YES or NO, and you can move your stake " +
		"freely until an answer posts.\n\n")
	// The three endings verbatim as the claim list prints them, so a reader who
	// saw "disputed" on a court page finds the same word here rather than a
	// synonym they have to guess is the same thing.
	b.WriteString("Every claim ends one of three ways:\n\n")
	b.WriteString("- **settled YES** or **settled NO** — answered, and the page " +
		"says which way; every stake withdraws 1×\n")
	b.WriteString("- **disputed** — a sealed vote is deciding; principal is never withheld\n")
	b.WriteString("- **closed** — never answered; every stake exited 1×, the deposit refunded\n\n")

	b.WriteString("## Comments are where the argument is\n\n")
	b.WriteString("Every claim has a comment board. A YES/NO number cannot carry a " +
		"reason, a source, or an objection; the board is where those go.\n\n")
	b.WriteString("Writing takes standing — the score you earned by being right in " +
		"this court, not the coin you hold. If you have none yet, you can buy a " +
		"one-off entry pass by burning a little of the court's coin, which is the " +
		"single place money substitutes for it. Standing sets how many comments a " +
		"day you get, not how loudly they land: nothing is hidden for being new, " +
		"and nothing is ranked by wealth.\n\n")
	// THE BADGE, EXPLAINED WHERE IT IS NOT SHOWN. It appears on the board with
	// no gloss, and "YES 12000000" beside a stranger's name is either a
	// disclosure or a scoreboard depending on what the reader assumes it is.
	b.WriteString("If you have money on the claim you are commenting on, your comment " +
		"says so — which side, and how much. The board deliberately does *not* order " +
		"by it. You are told, and you decide what it is worth.\n\n")

	b.WriteString("## Two things you can actually lose\n\n")
	b.WriteString("Everything above is about a stake that always comes back. " +
		"There are exactly two actions here that risk money, and both are " +
		"challenges — you are putting up a **bond** to say the court got " +
		"something wrong.\n\n")
	b.WriteString("- **Challenging an answer.** If you think a claim was answered " +
		"the wrong way, you can dispute it by posting a bond. Win and the " +
		"answerer's bond is burned and you are compensated; lose and yours is " +
		"burned instead. Nothing passes between you — a forfeit is destroyed, a " +
		"compensation is newly issued.\n")
	b.WriteString("- **Challenging a rating.** Every answered claim gets rated " +
		"low, mid or high, and that rating decides what it pays. Anyone may " +
		"challenge the rating once, also by posting a bond, which calls a vote " +
		"on it.\n\n")
	b.WriteString("**Your stake is never at risk in either.** A bond is separate " +
		"money you choose to put up; the coin you staked on the claim still " +
		"comes back 1×, whatever the challenge decides.\n\n")
	b.WriteString("## What things cost\n\n")
	b.WriteString("- **Staking** costs only the stake, which you get back.\n")
	b.WriteString("- **Opening a claim** takes a deposit, refunded when the claim is " +
		"answered or closed.\n")
	b.WriteString("- **Buying a court's coin** burns GNOT one way. There is no sell " +
		"side and no redemption; the price only rises as more is bought.\n\n")

	b.WriteString("## Who is in charge\n\n")
	b.WriteString("Each court elects its own moderators. They answer claims, organise " +
		"them into folders, and can hide comments. What they do to a claim or a " +
		"comment is written to that court's moderation log, which anyone can read " +
		"without asking. The serious powers need several moderators to agree — one " +
		"moderator acting alone cannot use them.\n\n")

	b.WriteString("[← all courts](/r/kourt/kourtv2:)\n")
	return b.String()
}
