package kourtv1

// The directory curates the courts anyone can create. A court opens at the default
// tier; the directory admin (the first court's creator, in V1) can promote it to
// featured or hide it — the three tiers the front page groups by. Curation only
// changes VISIBILITY: a hidden court still works for anyone holding its address, and
// its funds and votes are untouched. This is moderation, not custody.

const (
	tierHidden   uint8 = 0 // not listed on the front page
	tierListed   uint8 = 1 // the default: listed
	tierFeatured uint8 = 2 // promoted to the top
)

// directoryAdmin curates tiers. Set to the first court's creator (see StartCourt).
// A package var because a realm is stateful; unexported, and only the tier setter
// reads it, so it grants nothing but the curation power.
var directoryAdmin address

// SetTier promotes or hides a court. Only the directory admin, and only among the
// three tiers. A no-op on the value already set.
func SetTier(cur realm, courtSlug string, tier int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if cur.Previous().Address() != directoryAdmin {
		panic("court: only the directory admin may set a court's tier")
	}
	if tier < int(tierHidden) || tier > int(tierFeatured) {
		panic("court: tier is 0 (hidden), 1 (listed), or 2 (featured)")
	}
	mustCourt(courtSlug).tier = uint8(tier)
}

// ------------------------------------------------------------------ reads --

// DirectoryAdmin is who curates tiers. CourtTier is a court's tier.
func DirectoryAdmin() address        { return directoryAdmin }
func CourtTier(courtSlug string) int { return int(mustCourt(courtSlug).tier) }

// ListCourts returns every court's slug in slug order — lexicographic by the
// user-chosen slug, which is the key the tree holds them under, NOT age of
// creation. A value slice; nothing internal escapes. A page filters by
// CourtTier. Paged callers can slice the result.
func ListCourts() []string {
	out := []string{}
	courts.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

// ListByTier returns the slugs at exactly one tier, for a front page that groups
// featured, listed, and (for the admin) hidden separately.
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
