package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE FRONT PAGE'S PAGINATION, which render_test.gno says in as many words was never
// tested: "TestDirectoryRanksByBurn tests the INDEX (ListedCourtsBy) and never the
// PAGE". Both existing calls pass offset 0, so listedPage's offset arm and its
// zero-limit contract were free, and an operator inventory of modrender.gno found three
// boundaries there with no corpus row at all:
//
//	`if limit <= 0 { return out }`   narrowed to `< 0` — a limit of ZERO stops
//	                                 returning nothing and returns one court, because
//	                                 the take() appends before testing len(out) >= 0.
//	`if skipped < offset`            widened to `<=` — the page skips offset+1 and
//	                                 silently drops a court from every page after the
//	                                 first.
//	`return len(out) >= limit`       narrowed to `>` — the page runs one court long.
//
// None is a money path; all three are the kind of defect a reader never reports as a
// bug, because a directory that quietly omits one court still looks like a directory.
//
// ASSERTED AS PAGING CONSISTENCY, not as absolute positions. Suites here share one
// realm, so by the time this runs the directory holds courts from every other test and
// no fixed slug sits at a fixed index. What IS stable is the relationship between a full
// listing and its pages: page(k) must be the full list from k onward, and page(0, n)
// must be its first n. That relationship is what the three mutations break, and it does
// not care how many courts exist.
func TestTheListedCourtPageIsConsistentAtItsOffsetAndLimit(cur realm, t *testing.T) {
	a := testutils.TestAddress("lpg-a")
	testCourt(cur, "lpgone", a, 1_000_000)
	testCourt(cur, "lpgtwo", a, 1_000_000)
	testCourt(cur, "lpgthree", a, 1_000_000)
	reindexBurn(mustCourt("lpgone"), 7_000)
	reindexBurn(mustCourt("lpgtwo"), 5_000)
	reindexBurn(mustCourt("lpgthree"), 3_000)

	for _, order := range []string{"burn", "new"} {
		all := ListedCourtsBy(order, 0, 10_000)
		// The fixture has to hold enough courts for an offset and a limit to mean
		// anything: with fewer than three, page(1) and page(0,2) are the whole list
		// and every assertion below passes on a listing nobody paged.
		if len(all) < 3 {
			t.Fatalf("setup: %q must list at least three courts to page, lists %d",
				order, len(all))
		}

		// A LIMIT OF ZERO IS EMPTY. This is the contract `limit <= 0` states, and the
		// arm that makes `< 0` observable at all.
		if got := ListedCourtsBy(order, 0, 0); len(got) != 0 {
			t.Fatalf("%q with limit 0 must list nothing, listed %d: %v",
				order, len(got), got)
		}

		// EVERY OFFSET IS THE TAIL FROM THAT POINT. Walked across the first few, so a
		// skip that is off by one shows up as a missing first element rather than as a
		// length that happens to match.
		for k := 1; k <= 3; k++ {
			page := ListedCourtsBy(order, k, 10_000)
			want := all[k:]
			if len(page) != len(want) {
				t.Fatalf("%q offset %d must list %d courts, listed %d",
					order, k, len(want), len(page))
			}
			for i := range want {
				if page[i] != want[i] {
					t.Fatalf("%q offset %d position %d is %q, want %q — the page "+
						"skipped the wrong number of courts",
						order, k, i, page[i], want[i])
				}
			}
		}

		// AND EVERY LIMIT IS THE HEAD. The pair to the offset walk: one catches a page
		// that starts late, this one catches a page that ends late.
		for n := 1; n <= 3; n++ {
			page := ListedCourtsBy(order, 0, n)
			if len(page) != n {
				t.Fatalf("%q with limit %d must list exactly %d, listed %d",
					order, n, n, len(page))
			}
			for i := 0; i < n; i++ {
				if page[i] != all[i] {
					t.Fatalf("%q limit %d position %d is %q, want %q",
						order, n, i, page[i], all[i])
				}
			}
		}
	}
}
