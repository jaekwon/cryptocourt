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

// SetTier promotes or hides a court among the three tiers. GLOBAL DAO, not the
// bare directoryAdmin (MODERATION.md §3.2, and the file-by-file plan's
// "directoryAdmin→global-DAO migration").
//
// Tier is moderation: hiding a court from the front page is the first power the
// global DAO was described as having. Leaving it on a single address meant the
// realm had two unrelated moderation authorities, one of them a lone key with
// no m-of-n, no membership management and no way to hand over — while the DAO
// beside it had all three. The DAO's founding member IS directoryAdmin, so this
// widens who may act without changing who can act today.
//
// Single-key like GlobalHide rather than m-of-n like purge: a tier change moves
// nothing, removes no text, and is reversible in one call, so speed is worth
// more than ceremony. Purge is m-of-n because it is irreversible.
//
// EVENTED, per I6 — every act emits, and the event carries the tier CODE only,
// never user text, because events are unpurgeable history. There is no log row:
// the moderation log is per-claim by construction and a tier change is
// court-level, exactly like suspension, which emits with claim id 0 for the
// same reason.
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
