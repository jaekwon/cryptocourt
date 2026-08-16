package courtv2

// The directory: curation-only tiers, exactly V1's model — a hidden court still
// works for anyone holding its address; moderation, not custody.

const (
	tierHidden   uint8 = 0
	tierListed   uint8 = 1
	tierFeatured uint8 = 2
)

// directoryAdmin is the first court's creator; only the tier setter reads it.
var directoryAdmin address

// SetTier promotes or hides a court, admin-only, among the three tiers.
func SetTier(cur realm, courtSlug string, tier int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if cur.Previous().Address() != directoryAdmin {
		panic("courtv2: only the directory admin may set a court's tier")
	}
	if tier < int(tierHidden) || tier > int(tierFeatured) {
		panic("courtv2: tier is 0 (hidden), 1 (listed), or 2 (featured)")
	}
	mustCourt(courtSlug).tier = uint8(tier)
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
