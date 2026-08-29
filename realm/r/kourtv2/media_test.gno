package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A well-formed image line, for tests that want one item and do not care what is
// in it. 64 hex characters, a host the browser will actually load from.
const okHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func imgLine(caption, mirrors string) string {
	return "img|" + okHash + "|image/webp|800|600|90210|" + caption + "|" + mirrors
}

const okMirror = "https://i.imgur.com/abc123.webp"

func TestAMirrorMustBeSomethingTheBrowserWillLoad(cur realm, t *testing.T) {
	// Every arm names a DIFFERENT reason, because a validator that refused
	// everything for one reason would pass a test that only checked for refusal.
	for _, tc := range []struct{ url, want string }{
		{"", "1..300 characters"},
		{"http://i.imgur.com/a.webp", "https"},
		{"https://evil.example.com/a.webp", "will not load"},
		{"https://", "needs a host"},
		// THE PARENTHESIS, NAMED ON ITS OWN. A mirror is emitted into a markdown
		// image destination, ![alt](url), so a `)` inside it closes that
		// destination early and spills the rest of the URL onto the page as text.
		// This is the same shape as the escape that broke the site link, and it
		// is the one charset rule with a consequence rather than a preference.
		{"https://i.imgur.com/a).webp", "may not contain"},
		{"https://i.imgur.com/a(b.webp", "may not contain"},
		{"https://i.imgur.com/a\"b.webp", "may not contain"},
		{"https://i.imgur.com/a b.webp", "no spaces"},
		// The wire separators: a mirror carrying one could turn one field into
		// two, or one item into two.
		{"https://i.imgur.com/a,b.webp", "may not contain"},
		{"https://i.imgur.com/a|b.webp", "may not contain"},
		// A host with credentials, a port, or a lookalike suffix is refused —
		// each of these reads as an allowed host to a careless parser.
		{"https://i.imgur.com@evil.example.com/a.webp", "will not load"},
		{"https://i.imgur.com:8080/a.webp", "will not load"},
		{"https://i.imgur.com.evil.example.com/a.webp", "will not load"},
		// A FRAGMENT MUST NOT SMUGGLE A TRUSTED NAME PAST THE CHECK: the host
		// here is evil.example.com and nothing after the # can change that.
		{"https://evil.example.com/#i.imgur.com", "will not load"},
		{"https://evil.example.com?x=i.imgur.com", "will not load"},
	} {
		got := mirrorFault(tc.url)
		if got == "" || !strings.Contains(got, tc.want) {
			t.Fatalf("mirrorFault(%q) = %q, want something containing %q",
				tc.url, got, tc.want)
		}
	}

	// THE CONTROLS. Without these every arm above would pass against a validator
	// that refused literally everything — and the second one is the case the
	// authority parse exists for: a query directly after the host, with no path.
	for _, ok := range []string{
		okMirror,
		"https://i.imgur.com?v=2",
		"https://i.imgur.com/a.webp?v=2#top",
		// The archive's own address, which carries NO file extension — a rule
		// requiring one would have refused the copy kourt.xyz keeps of every
		// image.
		"https://i.imgur.com/" + okHash,
	} {
		if got := mirrorFault(ok); got != "" {
			t.Fatalf("a good mirror was refused: %q -> %q", ok, got)
		}
	}
}

func TestTheHostAllowlistTracksWhatTheBrowserPermits(cur realm, t *testing.T) {
	for _, host := range []string{
		"i.imgur.com", "imgur.com", "gnolang.github.io", "assets.gnoteam.com",
		"raw.githubusercontent.com", "ipfs.io", "cloudflare-ipfs.com",
	} {
		if !mediaHostAllowed(host) {
			t.Fatalf("%q is in gnoweb's CSP and must be allowed here too", host)
		}
	}
	for _, host := range []string{
		"", "evil.com", "imgur.com.evil.com", "notgithub.io",
		// The bare suffix must not pass as a whole host: ".github.io" allowing
		// "github.io" would hand the allowlist to whoever holds that name.
		"github.io", "githubusercontent.com",
	} {
		if mediaHostAllowed(host) {
			t.Fatalf("%q must not be allowed", host)
		}
	}
}

func TestTheArchiveHostFollowsTheConfiguredSite(cur realm, t *testing.T) {
	// kourt.xyz keeps a copy of every image at an address derived from the hash,
	// and the domain it lives on is whatever the admin configured — deriving it
	// from siteDomain rather than hardcoding is what stops the archive and the
	// reader-facing site disagreeing about where the overlay is.
	prev := siteDomain
	defer func() { siteDomain = prev }()

	siteDomain = ""
	if mediaHostAllowed("kourt.xyz") {
		t.Fatal("with no site configured there is no archive host to trust")
	}

	siteDomain = "kourt.xyz"
	if !mediaHostAllowed("kourt.xyz") {
		t.Fatal("the configured site's own domain must be allowed")
	}
	if mediaHostAllowed("other.xyz") {
		t.Fatal("configuring one site must not admit another")
	}
}

func TestACaptionIsOneLineOfClaimText(cur realm, t *testing.T) {
	if got := captionFault("Exhibit A — the email header"); got != "" {
		t.Fatalf("an ordinary caption was refused: %q", got)
	}
	// Quotes are ALLOWED and must survive: people write `the "smoking gun" memo`,
	// and refusing them would be a usability cost paid for nothing, since the
	// JSON writer escapes them.
	if got := captionFault(`the "smoking gun" memo`); got != "" {
		t.Fatalf("quotes in a caption were refused: %q", got)
	}
	for _, tc := range []struct{ in, want string }{
		{strings.Repeat("x", maxCaptionLen+1), "at most"},
		{"two\nlines", "one line"},
		{"a|b", "vertical bar"},
	} {
		if got := captionFault(tc.in); !strings.Contains(got, tc.want) {
			t.Fatalf("captionFault(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestAnImageItemNeedsAHashAndRealDimensions(cur realm, t *testing.T) {
	for _, tc := range []struct{ line, want string }{
		{"img||image/webp|800|600|90210||" + okMirror, "sha256"},
		{"img|" + strings.ToUpper(okHash) + "|image/webp|800|600|90210||" + okMirror, "sha256"},
		{"img|" + okHash[:63] + "|image/webp|800|600|90210||" + okMirror, "sha256"},
		{"img|" + okHash + "|image/webp|0|600|90210||" + okMirror, "dimensions"},
		{"img|" + okHash + "|image/webp|800|600|0||" + okMirror, "bytes"},
		{"img|" + okHash + "|image/webp|800|600|999999999||" + okMirror, "bytes"},
		{"img|" + okHash + "||800|600|90210||" + okMirror, "media type"},
		{"img|" + okHash + "|image/webp|800|600|90210||", "somewhere to find it"},
		{"wat|" + okHash + "|image/webp|800|600|90210||" + okMirror, "img"},
		// A video carries no hash: a streaming host serves no stable bytes to
		// commit to, and pretending otherwise would put a verified badge on
		// something nothing can verify.
		{"vid|" + okHash + "|||||caption|https://ipfs.io/x", "carries no hash"},
	} {
		_, fault := parseMediaFault(tc.line)
		if fault == "" || !strings.Contains(fault, tc.want) {
			t.Fatalf("parseMediaFault(%q) = %q, want something containing %q",
				tc.line, fault, tc.want)
		}
	}

	// THE CONTROLS: one good image, and one good video. Without them every arm
	// above would pass against a parser that refused everything.
	if got, fault := parseMediaFault(imgLine("a caption", okMirror)); fault != "" || len(got) != 1 {
		t.Fatalf("a well-formed image line must parse: %d items, fault %q", len(got), fault)
	}
	if got, fault := parseMediaFault("vid||||||the hearing|https://ipfs.io/x"); fault != "" || len(got) != 1 {
		t.Fatalf("a well-formed video line must parse: %d items, fault %q", len(got), fault)
	}
}

func TestAClaimCarriesAtMostSevenItems(cur realm, t *testing.T) {
	seven := make([]string, 7)
	for i := range seven {
		seven[i] = imgLine("", okMirror)
	}
	if got, fault := parseMediaFault(strings.Join(seven, "\n")); fault != "" || len(got) != 7 {
		t.Fatalf("seven items must parse: %d items, fault %q", len(got), fault)
	}
	if _, fault := parseMediaFault(strings.Join(append(seven, imgLine("", okMirror)), "\n")); !strings.Contains(fault, "at most 7") {
		t.Fatalf("an eighth item must be refused, got %q", fault)
	}
	if _, fault := parseMediaFault("img|" + okHash + "|image/webp|800|600"); !strings.Contains(fault, "8 fields") {
		t.Fatalf("a short line must be refused, got %q", fault)
	}
	// Empty is a working state, not an error: most claims carry nothing.
	if got, fault := parseMediaFault("  "); fault != "" || got != nil {
		t.Fatalf("an empty media argument must yield nothing: %d items, fault %q", len(got), fault)
	}
}

func TestTheReadFormatIsOneLineOfJSON(cur realm, t *testing.T) {
	items := parseMediaArg(imgLine(`the "smoking gun" memo`, okMirror))
	out := encodeMedia(items)

	// ONE LINE, AND THIS IS NOT COSMETIC. The overlay's qeval parser splits raw
	// output on newlines BEFORE it matches a typed value, so a newline anywhere
	// in this payload is read as a second, malformed value.
	if strings.Contains(out, "\n") {
		t.Fatalf("the read format must be one line: %q", out)
	}
	if !strings.HasPrefix(out, "[{") || !strings.HasSuffix(out, "}]") {
		t.Fatalf("expected a JSON array of objects: %q", out)
	}
	// The quotes in the caption survive as escaped JSON rather than ending the
	// string early — which would make the payload unparseable for every reader.
	if !strings.Contains(out, `\"smoking gun\"`) {
		t.Fatalf("a quoted caption must be escaped, not truncated: %q", out)
	}
	if !strings.Contains(out, okHash) || !strings.Contains(out, okMirror) {
		t.Fatalf("the hash and the mirror must both reach the reader: %q", out)
	}
	if encodeMedia(nil) != "[]" {
		t.Fatalf("no media is an empty array, got %q", encodeMedia(nil))
	}
}

func TestRetiringAHostRetractsTheImagesPointingAtIt(cur realm, t *testing.T) {
	// Write-time validation ALONE would grandfather every mirror stored under an
	// older, wider allowlist, so narrowing the list would fail to retract what
	// already points at the dropped host — which would make the allowlist a
	// formality rather than a control. The read path re-asks.
	prev := siteDomain
	defer func() { siteDomain = prev }()

	siteDomain = "kourt.xyz"
	items := parseMediaArg(imgLine("", "https://kourt.xyz/m/"+okHash))
	if !strings.Contains(encodeMedia(items), "kourt.xyz") {
		t.Fatal("a mirror on the configured site must render while it is configured")
	}

	siteDomain = "elsewhere.xyz"
	if strings.Contains(encodeMedia(items), "kourt.xyz") {
		t.Fatal("a mirror whose host has left the allowlist must stop rendering")
	}
}

func TestMediaIsGatedByThePurgeThatTheClaimTextIs(cur realm, t *testing.T) {
	alice := testutils.TestAddress("med-alice")
	testCourt(cur, "medz", testutils.TestAddress("boot-med"), 10_000_000_000)
	dadmin := DirectoryAdmin()
	if dadmin == alice {
		panic("fixture: the subject of the test is the bootstrap DAO member")
	}
	postingFixture(cur, "med", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimPM(cross(cur), "med", "a claim with evidence", "the body",
		imgLine("the memo", okMirror))

	if !strings.Contains(ClaimMedia("med", id), okHash) {
		t.Fatal("a filed image must be readable before anything is purged")
	}

	// THE WHOLE POINT OF THE GATE. A purged claim must not answer with the thing
	// the purge was for, and media is the likeliest surface for that.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "med", id, "csam")
	if got := ClaimMedia("med", id); got != "[]" {
		t.Fatalf("a purged claim must answer with no media, got %q", got)
	}
}

func TestOnlyAGlobalDAOMemberTakesDownOneImage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mp-alice")
	stranger := testutils.TestAddress("mp-stranger")
	testCourt(cur, "mpz", testutils.TestAddress("boot-mp"), 10_000_000_000)
	dadmin := DirectoryAdmin()
	if dadmin == alice || dadmin == stranger {
		panic("fixture: a subject of the test is the bootstrap DAO member")
	}
	postingFixture(cur, "mp", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimPM(cross(cur), "mp", "a claim with two exhibits", "",
		imgLine("first", okMirror)+"\n"+imgLine("second", okMirror))

	// A COURT MODERATOR IS NOT ENOUGH — alice is this court's 1-of-1 mod set, so
	// without this arm the perimeter would read the same if it merely refused
	// strangers, which is the weaker gate a purge verb must not have.
	for _, who := range []address{stranger, alice} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
			PurgeClaimMedia(cross(cur), "mp", id, 0, "csam")
		})
	}

	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "no media item at that position", func() {
		PurgeClaimMedia(cross(cur), "mp", id, 9, "csam")
	})

	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaimMedia(cross(cur), "mp", id, 0, "csam")

	out := ClaimMedia("mp", id)
	// THE SLOT SURVIVES IN PLACE. Compacting would shift every later index, so a
	// moderator's next call would land on an item they had already reviewed and
	// kept — the second exhibit must still be at position 1.
	if !strings.Contains(out, `"purged":true`) {
		t.Fatalf("the purged slot must still be reported, tombstoned: %q", out)
	}
	if strings.Contains(out, "first") {
		t.Fatalf("a purged item's caption is destroyed, not flagged: %q", out)
	}
	if !strings.Contains(out, "second") {
		t.Fatalf("purging one item must leave the others: %q", out)
	}
	// The payload is zeroed, not merely marked.
	if strings.Count(out, okHash) != 1 {
		t.Fatalf("the purged item's hash must be gone, the other's kept: %q", out)
	}

	// A repeat is a no-op rather than an error, so it consumes no proposal and
	// writes no second log row for an act that cannot change anything.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaimMedia(cross(cur), "mp", id, 0, "csam")
}
