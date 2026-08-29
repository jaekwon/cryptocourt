package kourtv2

import "strconv"

// The directory: curation-only tiers, exactly V1's model — a hidden court still
// works for anyone holding its address; moderation, not custody.

const (
	tierHidden   uint8 = 0
	tierListed   uint8 = 1
	tierFeatured uint8 = 2
)

// directoryAdmin is the first court's creator. It still bootstraps the global
// DAO (ensureGlobalDAO makes it the sole founding member), but it is no longer
// an authority in its own right — see SetTier.
var directoryAdmin address

// SetTier moves a court between the three directory tiers: 0 hidden, 1 listed,
// 2 featured. Hidden courts are kept off the front page; featured ones are
// promoted on it.
//
// Any member of the global DAO, single key — a tier change moves no money,
// removes no text, and is undone by one call in the other direction. Setting a
// court to the tier it already holds writes nothing and records nothing.
//
// Emits a court-level event carrying the tier CODE only, never any court text,
// because events cannot be purged. There is no moderation-log row: the log is
// per-claim and this is court-level.
//
// Refused when the court does not exist, the caller is not a global DAO member,
// or `tier` is outside 0..2.
func SetTier(cur realm, courtSlug string, tier int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may set a court's tier")
	}
	if tier < int(tierHidden) || tier > int(tierFeatured) {
		panic("kourtv2: tier is 0 (hidden), 1 (listed), or 2 (featured)")
	}
	c := mustCourt(courtSlug)
	if c.tier == uint8(tier) {
		return // a no-op writes nothing and stamps no history
	}
	c.tier = uint8(tier)
	emitGlobalAct(c.id, 0, "tier:"+strconv.Itoa(tier), who)
}

// DirectoryAdmin is who curates tiers; CourtTier is a court's tier.
func DirectoryAdmin() address        { return directoryAdmin }
func CourtTier(courtSlug string) int { return int(mustCourt(courtSlug).tier) }

// ListCourts returns every court's slug in slug order (lexicographic — the key
// the tree holds them under, not age).
func ListCourts() []string {
	out := []string{}
	courts.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

// ListByTier returns the slugs at exactly one tier.
func ListByTier(tier int) []string {
	out := []string{}
	courts.Iterate("", "", func(key string, v any) bool {
		if int(v.(*Court).tier) == tier {
			out = append(out, key)
		}
		return false
	})
	return out
}
