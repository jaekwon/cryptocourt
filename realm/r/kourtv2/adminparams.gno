// One place to see every knob an administrator can turn, and what it is set to.
//
// WHY THIS EXISTS. The realm-wide settings were readable one at a time and
// nowhere together: AssociationBondDefault here, SiteDomain there, MediaHosts
// somewhere else, the ladder and the standing rates only through a per-court
// read that resolves an override first, and the purge threshold not at all. So
// the question "what is this realm configured to right now" had no answer short
// of nine queries and knowing which nine — which means in practice nobody asked
// it, and a setting left at a value nobody intended could sit there unnoticed.
//
// SEVEN PARAMETERS, and the boundary is exactly "the global DAO admin can set
// it". Per-court knobs are deliberately not here: SetCourtAssociationBond,
// SetCourtLadder and SetCourtCreditRates are a court moderator's business, they
// belong on that court's own page, and mixing the two would misrepresent who
// can change what. SetTier is also left out — it is gated on isGlobalMod, a
// wider set than the admin, and listing it under "admin params" would be wrong
// about its authority.
//
// ONE LINE, and that is a constraint rather than a preference: the overlay's
// parseTyped splits raw output on newlines before it matches a typed value, so
// a multi-line answer parses as garbage (media.gno's MediaHosts says the same,
// for the same reason). Hence a flat `key:value;key:value` string, with the
// ladder and rates FLATTENED rather than nested — their own packed forms use
// `;` internally, and nesting one inside the other would make the separator
// ambiguous for anything reading this.
//
// VALUES ARE READ, NEVER RESTATED. Every field below resolves through the same
// global the setter writes, so this page cannot drift from the realm: a listing
// that keeps its own copy of a default is a listing that is wrong the first
// time somebody changes one.
package kourtv2

import (
	"strconv"
	"strings"
)

/* PURE READS OF THE DAO, because the ensure* builder ALLOCATES. It builds the
   DAO on first call, and check-read-purity refuses that inside an exported read
   for a good reason: a query carries no storage deposit and must be safe to
   serve at any height, so a read that allocates makes the first caller change
   what the second one sees. AdminParams was written with the builder and the
   gate caught it.
   Before the DAO is built these report what it WOULD be built with — admin from
   directoryAdmin, which is exactly what the builder copies, and the named
   bootstrap size from moderation.gno — so the listing is correct rather than
   empty on a realm whose DAO nobody has touched yet. */
func adminAddr() address {
	if globalDAO != nil {
		return globalDAO.admin
	}
	return directoryAdmin
}

func purgeThreshold() int {
	if globalDAO != nil {
		return globalDAO.purgeM
	}
	return daoBootstrapM
}

func daoSeats() int {
	if globalDAO != nil {
		return globalDAO.n
	}
	return daoBootstrapN
}

// AdminParams packs every realm-wide, admin-settable parameter and its live
// value, one line, `key:value` pairs separated by semicolons:
//
//	admin:<address>;creationBurn:<ugnot>;assocBond:<ugnot>;purgeM:<n>;
//	t1:<bps>;t2:<bps>;t3:<bps>;entry:<n>;l2:<n>;l3:<n>;
//	flag:<bps>;dispute:<bps>;authorHigh:<bps>;conviction:<bps>;unadjudicated:<bps>;
//	domain:<host>;mediaExact:<csv>;mediaSuffix:<csv>
//
// (written across lines here for reading; the value is a single line.)
//
// A reader splitting this must split each pair on the FIRST colon only: the
// media lists are comma-separated and a future host could contain one, and
// SplitN costs nothing today against a parse that silently truncates later.
func AdminParams() string {
	l := ladderDefault
	r := creditRatesDefault
	hosts := MediaHosts()
	exact, suffix := hosts, ""
	if i := strings.Index(hosts, "|"); i >= 0 {
		exact, suffix = hosts[:i], hosts[i+1:]
	}
	n := func(v int64) string { return strconv.FormatInt(v, 10) }
	return "admin:" + adminAddr().String() +
		";creationBurn:" + n(courtCreationBurn) +
		";assocBond:" + n(assocBondDefault) +
		";purgeM:" + strconv.Itoa(purgeThreshold()) +
		";t1:" + n(l.t1Bps) +
		";t2:" + n(l.t2Bps) +
		";t3:" + n(l.t3Bps) +
		";entry:" + n(l.postsEntry) +
		";l2:" + n(l.postsT2) +
		";l3:" + n(l.postsT3()) +
		";flag:" + n(r.flag) +
		";dispute:" + n(r.dispute) +
		";authorHigh:" + n(r.authorHigh) +
		";conviction:" + n(r.conviction) +
		";unadjudicated:" + n(r.unadjudicated) +
		";domain:" + siteDomain +
		";mediaExact:" + exact +
		";mediaSuffix:" + suffix
}

// adminParamsPath is the render route. TWELVE CHARACTERS, and that is load
// bearing: a slug is at most maxSlugLen (11), so this path cannot collide with
// any court that exists or could ever be created. help.gno reserves its own
// route the same way and for the same reason — by construction rather than by a
// reserved word somebody has to remember to keep reserved.
const adminParamsPath = "admin-params"

// renderAdminParams draws the same seven parameters for a human.
//
// It reads the SAME globals AdminParams packs rather than parsing that string,
// so the page and the machine read cannot disagree; what differs is only the
// presentation. Each row says what the setting DOES, because a name and a
// number together still do not tell an administrator what turning it would
// change, and the verb that sets it, because the next question after "what is
// it" is always "how do I change it".
func renderAdminParams() string {
	l := ladderDefault
	r := creditRatesDefault
	n := func(v int64) string { return strconv.FormatInt(v, 10) }

	var b strings.Builder
	b.WriteString("# Realm parameters\n\n")
	b.WriteString("Everything the global DAO admin can set, and what it is set " +
		"to now. A court's moderators set their own court's bond, ladder and " +
		"standing rates; those are on the court's page, not here.\n\n")
	b.WriteString("Admin: `" + adminAddr().String() + "`\n\n")

	b.WriteString("| Setting | Now | What it does | Set with |\n")
	b.WriteString("|---|---|---|---|\n")
	b.WriteString("| Court creation burn | " + ugnotAmt(courtCreationBurn) +
		" GNOT | The minimum a new court costs to open. The whole payment is " +
		"burned. 0 turns it off, and off is the shipped default. | " +
		"`SetCourtCreationBurn` |\n")
	b.WriteString("| Association bond | " + ccAmt(assocBondDefault) +
		" CC | What a stranger posts to attach an edge, in courts that set no " +
		"override. | `SetAssociationBondDefault` |\n")
	b.WriteString("| Purge threshold | " + strconv.Itoa(purgeThreshold()) + " of " +
		strconv.Itoa(daoSeats()) + " | How many global moderators must agree to purge. | " +
		"`SetPurgeThreshold` |\n")
	b.WriteString("| Posting ladder | " + n(l.t1Bps) + "/" + n(l.t2Bps) + "/" +
		n(l.t3Bps) + " bps at " + n(l.postsEntry) + "/" + n(l.postsT2) + "/" +
		n(l.postsT3()) + " posts | The default rungs a court inherits: the share " +
		"earned at each tier and the post counts that reach them. | " +
		"`SetLadderDefault` |\n")
	b.WriteString("| Standing rates | flag " + n(r.flag) + ", dispute " +
		n(r.dispute) + ", author " + n(r.authorHigh) + ", conviction " +
		n(r.conviction) + ", unadjudicated " + n(r.unadjudicated) +
		" bps | The default credit each act earns toward standing. Policing " +
		"ranks above authorship, which ranks above staking. | " +
		"`SetCreditRatesDefault` |\n")
	dom := siteDomain
	if dom == "" {
		dom = "_none_"
	}
	b.WriteString("| Site domain | " + dom + " | The website this realm belongs " +
		"to. Also allow-lists that domain for images without listing it below. | " +
		"`SetSiteDomain` |\n")
	hosts := MediaHosts()
	if hosts == "|" {
		hosts = "_none_"
	}
	b.WriteString("| Media hosts | " + hosts + " | Where images may be loaded " +
		"from: exact hosts before the bar, suffixes after it. | " +
		"`SetMediaHosts` |\n")
	return b.String()
}
