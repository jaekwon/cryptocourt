package govern

import (
	"strings"

	ufmt "gno.land/p/nt/ufmt/v0"
)

// batchKind runs several adopted kinds as one decision.
//
//	govern:batch   "treasury/spend 100\nfee 250"
//
// One member per line, the kind first and the rest its payload. Members must
// already be adopted: a batch decides several things at once and smuggles in
// nothing.
//
// All or nothing, because there is no halfway. A member's Do returning an error
// makes this panic, aborting the transaction and unwinding what earlier members
// did — the only atomicity gno offers.
//
// So a failed batch leaves the proposal Succeeded rather than Failed: the
// transaction wrote nothing, including the failure. It can be run again and
// will fail identically until the world changes or the grace period ends it.
//
// Single-member kinds keep the other behaviour — record the failure and finish
// — since there is nothing to be atomic with respect to.
type batchKind struct{}

// maxBatch bounds a batch, because Describe and Check both walk it and a
// proposal nobody can render is a proposal nobody can vote on.
const maxBatch = 16

func (batchKind) Name() string { return reserved + "batch" }

func (batchKind) Describe(payload string) string {
	members, err := parseBatch(payload)
	if err != nil {
		return "malformed batch: " + err.Error()
	}
	out := ufmt.Sprintf("do all %d of these, or none of them:\n", len(members))
	for i, m := range members {
		// Each member described by its own kind, from its own payload — the
		// same strings their Do will be handed. A batch that summarised its
		// members in its own words would be the description gap this design
		// exists to avoid, reintroduced one level up.
		out += ufmt.Sprintf("\n%d. **%s** — %s", i+1, m.kind, describeMember(m))
	}
	return out
}

func describeMember(m member) string {
	k := anyKind(m.kind)
	if k == nil {
		return "_no kind by that name_"
	}
	return k.Describe(m.payload)
}

func (batchKind) Check(payload string) error {
	members, err := parseBatch(payload)
	if err != nil {
		return err
	}
	for _, m := range members {
		e := entryOf(m.kind)
		if e == nil {
			return govErr("no kind called " + m.kind)
		}
		if !e.live {
			// A batch cannot reach a power the holders have not granted.
			return govErr(m.kind + " is not adopted")
		}
		if m.kind == (batchKind{}).Name() {
			// No batches of batches. Nesting makes the rendered description a
			// tree of unbounded depth, and the point of the description is
			// that somebody reads it.
			return govErr("a batch cannot contain a batch")
		}
		if err := e.kind.Check(m.payload); err != nil {
			return govErr(m.kind + ": " + err.Error())
		}
	}
	return nil
}

func (batchKind) Do(_ int, rlm realm, payload string) error {
	members, err := parseBatch(payload)
	if err != nil {
		return err
	}
	for i, m := range members {
		e := entryOf(m.kind)
		if e == nil || !e.live {
			panic("govern: batch member " + m.kind + " is no longer adopted")
		}
		if err := e.kind.Do(0, rlm, m.payload); err != nil {
			// Panic, not return. Returning would record a failure and keep
			// whatever the earlier members already did, which is the one
			// outcome a batch promises cannot happen.
			panic(ufmt.Sprintf("govern: batch member %d (%s) failed: %s",
				i+1, m.kind, err.Error()))
		}
	}
	return nil
}

type member struct {
	kind    string
	payload string
}

func parseBatch(payload string) ([]member, error) {
	var out []member
	for _, line := range strings.Split(payload, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		sp := strings.Index(line, " ")
		if sp <= 0 {
			// A member with no payload is almost always a typo, and a batch is
			// the wrong place to find out.
			return nil, govErr("expected `<kind> <payload>`, got: " + line)
		}
		out = append(out, member{kind: line[:sp], payload: strings.TrimSpace(line[sp+1:])})
	}
	if len(out) < 2 {
		return nil, govErr("a batch needs at least two members; propose the kind directly")
	}
	if len(out) > maxBatch {
		return nil, govErr("too many members in one batch")
	}
	return out, nil
}
