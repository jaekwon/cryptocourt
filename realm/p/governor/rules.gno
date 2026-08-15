package governor

import (
	"strconv"
	"strings"

	ufmt "gno.land/p/nt/ufmt/v0"
)

// rulesKind changes what it takes to pass a kind.
//
//	govern:rules   "<kind> quorum=2000 threshold=6600 voting=120960 delay=34560 grace=241920 propose=100"
//
// All six terms. ProposeBps was once missing, and it is where a bad value is
// worst: above a hundred percent nobody can open a question under that kind at
// all — adopted, unusable, and unfixable by the one kind that changes terms.
//
// Fields left out keep their value, so lengthening one delay is a short line.
//
// Space-separated key=value because a governance payload has to be readable
// where it is read — a URL, a wallet's confirmation screen, a forum post. JSON
// puts a parser between a voter and their intent.
type rulesKind struct{}

func (k rulesKind) Name() string { return reserved + "rules" }

// Describe renders the requested change and NOTHING about the world.
//
// Deliberately not "from 20% to 30%": that would read live state, so two
// voters at different heights would see different questions at the same URL,
// and a proposal that lands in between would silently rewrite what everyone
// else is voting on.
func (k rulesKind) describe(g *Governor, payload string) string {
	name, set, err := parseRules(payload)
	if err != nil {
		return "malformed rules change: " + err.Error()
	}
	out := "change the rules for `" + name + "`:"
	for _, f := range set {
		out += ufmt.Sprintf("\n- %s -> %s", f.key, f.human())
	}
	return out
}

func (k rulesKind) check(g *Governor, payload string) error {
	name, set, err := parseRules(payload)
	if err != nil {
		return err
	}
	e := g.entryOf(name)
	if e == nil {
		return errNoSuchKind
	}
	if !e.live {
		// Retuning something not yet adopted would be the same swap the
		// immutable-name rule closes, moved from the code to the terms: change
		// a kind's quorum while its adoption vote is open and holders approve
		// one set of terms and get another. What is not adopted is not the
		// governor's to tune.
		return errNotLive
	}
	// No check for an empty change set. parseRules refuses a payload with
	// fewer than two fields, and every field after the first either parses or
	// returns an error, so a nil error here guarantees at least one change. A
	// guard would be unreachable, and unreachable defence reads as a case
	// somebody thought could happen.
	next := e.rules
	applyRules(&next, set)
	// The same sanity the offering path enforces, and literally the same code:
	// one function, two callers. A second copy is how the two paths come to
	// disagree about what a proposer must hold.
	return saneRules(next)
}

func (k rulesKind) run(g *Governor, dispatch Dispatch, payload string) error {
	name, set, err := parseRules(payload)
	if err != nil {
		return err
	}
	e := g.entryOf(name)
	if e == nil {
		return errNoSuchKind
	}
	next := e.rules
	applyRules(&next, set)
	// Only the entry changes. Proposals already open kept a COPY of the rules
	// they were opened under, so this cannot move the bar under a vote that is
	// already being cast.
	e.rules = next
	return nil
}

type field struct {
	key string
	n   int64
}

func (f field) human() string {
	switch f.key {
	case "quorum", "threshold", "propose":
		// A percentage as well as the raw figure: basis points are exact and
		// nobody reads them. Padded by hand because ufmt has no zero-padding
		// and its width digits apply to %s alone, so %02d prints 1 rather than
		// 01 and one basis point renders as 0.1% — ten times the truth.
		return ufmt.Sprintf("%d bps (%s)", f.n, pct(f.n))
	default:
		// The same rendering the adoption page uses. It printed a bare "%d
		// blocks" while adoptKind printed a duration, so the same field read
		// two different ways depending on which page you arrived at.
		return span(f.n)
	}
}

func parseRules(payload string) (string, []field, error) {
	parts := strings.Fields(payload)
	if len(parts) < 2 {
		return "", nil, govErr("expected a kind name and at least one key=value")
	}
	name := parts[0]
	var set []field
	for _, p := range parts[1:] {
		eq := strings.Index(p, "=")
		if eq <= 0 || eq == len(p)-1 {
			return "", nil, govErr("expected key=value, got " + p)
		}
		key, raw := p[:eq], p[eq+1:]
		switch key {
		case "quorum", "threshold", "voting", "delay", "grace", "propose":
		default:
			return "", nil, govErr("unknown field " + key)
		}
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n < 0 {
			return "", nil, govErr("expected a non-negative number for " + key)
		}
		set = append(set, field{key: key, n: n})
	}
	return name, set, nil
}

// applyRules applies an already-validated change set to r. It cannot fail:
// parseRules has validated every key and value, so a default/error path here would
// be unreachable (unreachable defence reads as a case somebody thought could happen).
func applyRules(r *Rules, set []field) {
	for _, f := range set {
		switch f.key {
		case "quorum":
			r.QuorumBps = f.n
		case "threshold":
			r.ThresholdBps = f.n
		case "voting":
			r.VotingBlocks = f.n
		case "delay":
			r.DelayBlocks = f.n
		case "grace":
			r.GraceBlocks = f.n
		case "propose":
			r.ProposeBps = f.n
		}
	}
}

// pct renders basis points as a percentage.
//
// Padded by hand because ufmt has no zero-padding and its width digits apply
// to %s alone, so %02d prints 1 rather than 01 and one basis point reads as
// 0.1% — ten times the truth, on the line a voter actually reads.
func pct(n int64) string {
	// n/(bps/100) is the percentage; bps/100 is 100, so the split is n/100 and
	// n%100. Derived from the constant rather than written as 100, so a change
	// to the scale cannot leave this rendering the old one.
	per := bps / 100
	frac := strconv.FormatInt(n%per, 10)
	for int64(len(frac)) < 2 {
		frac = "0" + frac
	}
	return ufmt.Sprintf("%d.%s%%", n/per, frac)
}
