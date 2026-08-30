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
		// The registrable suffix is not itself a host we trust.
		"github.io", "githubusercontent.com",
		// THE HOST EQUAL TO THE SUFFIX, dot and all. This is the case the length
		// guard in mediaHostAllowed actually exists for, and the only one that
		// distinguishes it: HasSuffix("github.io", ".github.io") is already
		// false because the string is shorter, so dropping `len(host) > len(s)`
		// changes nothing for the entries above — a mutation probe proved it by
		// surviving. ".github.io" is the same length as the suffix, matches it,
		// and is the label a URL like https://.github.io/x would present.
		".github.io", ".imgur.com", ".githubusercontent.com",
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
		// THE DIRECTION CONTROLS. The rule below already said a caption carries no
		// control characters and meant it, but it read BYTES and these are three
		// bytes each, so it never saw one. U+202E reorders everything after it: a
		// filer could make the rendered exhibit label disagree with the label the
		// chain stores, permanently, since a caption is claim text and there is no
		// editor.
		{"the memo \u202e gnidnats", "direction"},
		{"a \u202d b", "direction"},
		{"a \u2066 b \u2069", "direction"},
	} {
		if got := captionFault(tc.in); !strings.Contains(got, tc.want) {
			t.Fatalf("captionFault(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}

	// COUNTED IN CHARACTERS, NOT BYTES. This used to be len(s), so an ordinary
	// 82-character Russian caption — 152 bytes — was refused while web/media.js,
	// which counts code points, accepted it: the composer waved the claim
	// through and the transaction aborted saying "at most 120 characters" about a
	// caption of 82. Every non-Latin script hit the wall at roughly half the
	// stated limit. The two sides had only ever been compared on ASCII, where a
	// byte and a character are the same thing.
	cyrillic := "Протокол заседания городского совета от 12 октября"
	if got := captionFault(cyrillic); got != "" {
		t.Fatalf("an ordinary Russian caption was refused: %q", got)
	}
	if len(cyrillic) <= len([]rune(cyrillic)) {
		t.Fatal("this fixture is meant to be longer in bytes than in characters")
	}
	if got := captionFault(strings.Repeat("б", maxCaptionLen)); got != "" {
		t.Fatalf("a caption of exactly the cap was refused: %q", got)
	}
	if got := captionFault(strings.Repeat("б", maxCaptionLen+1)); !strings.Contains(got, "at most") {
		t.Fatalf("one character past the cap was accepted: %q", got)
	}

	// AND ORDINARY RIGHT-TO-LEFT TEXT STILL WORKS. The marks carry no override
	// power and honest Arabic and Hebrew use them; refusing those would break
	// real captions to prevent nothing.
	for _, ok := range []string{"محضر اجتماع المجلس البلدي", "\u200fמסמך רשמי מהעירייה"} {
		if got := captionFault(ok); got != "" {
			t.Fatalf("captionFault(%q) refused right-to-left text: %q", ok, got)
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

	// Gaps a mutation sweep found: a conditional nothing depended on.
	fourMirrors := okMirror + "," + okMirror + "," + okMirror + "," + okMirror
	if _, fault := parseMediaFault(imgLine("", fourMirrors)); fault != "" {
		t.Fatalf("four mirrors is the cap, not one past it: %q", fault)
	}
	if _, fault := parseMediaFault(imgLine("", fourMirrors+","+okMirror)); !strings.Contains(fault, "at most 4") {
		t.Fatalf("a fifth mirror must be refused, got %q", fault)
	}
	// A caption may not smuggle a control character onto a page or a terminal.
	if fault := captionFault("a\x07b"); !strings.Contains(fault, "control") {
		t.Fatalf("a control character in a caption must be refused, got %q", fault)
	}
	// A blank line between items is whitespace, not a malformed item.
	if got, fault := parseMediaFault(imgLine("", okMirror) + "\n\n" + imgLine("", okMirror)); fault != "" || len(got) != 2 {
		t.Fatalf("blank lines are skipped: %d items, fault %q", len(got), fault)
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

// THE EXACT BYTES THE OVERLAY PRODUCES. Every other test here hand-writes an
// argument to the same spec media.js was written to — which checks that the spec
// is self-consistent, not that the two sides agree. These strings were taken
// from web/media.js's mediaArgLine by running it, and pasted verbatim.
//
// They differ from the hand-written ones in a way that only luck made harmless:
// the client emits 0 for a video's width, height and length where the fixtures
// here leave those fields empty. atoiOr0 accepts both, so it parses — and if it
// ever stopped, nothing would have noticed until a video exhibit failed to file.
const clientImageLine = "img|1111111111111111111111111111111111111111111111111111111111111111|" +
	"image/webp|800|600|90210|the memo|https://i.imgur.com/abc.webp"

const clientVideoLine = "vid|||0|0|0|the hearing|https://i.imgur.com/v.mp4"

// THE OTHER HALF OF THE SEAM. web/tests/media_test.js holds this exact string as
// `fromChain` and asserts the overlay parses it into a card. If encodeMedia's
// output drifts — a renamed field, a dropped one, whitespace — that suite is
// what fails, and this is what tells you why.
func TestWhatTheOverlayReadsIsWhatThisEmits(cur realm, t *testing.T) {
	items := parseMediaArg(clientImageLine)
	got := encodeMedia(items)
	want := `[{"kind":"img","sha256":"1111111111111111111111111111111111111111111111111111111111111111",` +
		`"mime":"image/webp","w":800,"h":600,"bytes":90210,"caption":"the memo",` +
		`"mirrors":["https://i.imgur.com/abc.webp"]}]`
	if got != want {
		t.Fatalf("the overlay is pinned to a payload this no longer emits:\n got  %s\n want %s", got, want)
	}

	// The tombstone's shape is pinned too: the page shows a gap rather than
	// renumbering around it, and it can only do that if it reads this marker.
	items[0].purged = true
	items[0].sha256, items[0].mirrors, items[0].caption = "", nil, ""
	if g := encodeMedia(items); g != `[{"kind":"img","purged":true}]` {
		t.Fatalf("the tombstone the overlay looks for is not what this writes: %s", g)
	}
}

func TestTheOverlaysOwnArgumentParses(cur realm, t *testing.T) {
	got, fault := parseMediaFault(clientImageLine + "\n" + clientVideoLine)
	if fault != "" {
		t.Fatalf("the overlay builds an argument this realm refuses: %q", fault)
	}
	if len(got) != 2 {
		t.Fatalf("expected both exhibits, got %d", len(got))
	}
	if got[0].kind != mediaKindImage || got[0].caption != "the memo" ||
		got[0].w != 800 || got[0].bytes != 90210 {
		t.Fatalf("the image did not survive the round trip: %+v", got[0])
	}
	// A video's empty numbers must read as zero rather than as a fault, which is
	// what atoiOr0 is for and what nothing had ever relied on.
	if got[1].kind != mediaKindVideo || got[1].sha256 != "" ||
		got[1].w != 0 || got[1].bytes != 0 || got[1].caption != "the hearing" {
		t.Fatalf("the video did not survive the round trip: %+v", got[1])
	}
	// And what comes back out is what a client reads.
	out := encodeMedia(got)
	if !strings.Contains(out, "the hearing") || !strings.Contains(out, "the memo") {
		t.Fatalf("the round trip lost a caption: %s", out)
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

func TestTheEntrypointRefusesWhatTheValidatorRefuses(cur realm, t *testing.T) {
	// EVERY PARSE TEST CALLS parseMediaFault DIRECTLY, which skips the one line
	// that turns a fault into a refusal — so nothing proved that OpenClaimPM,
	// the entrypoint a person actually reaches, stops a bad argument at all. A
	// validator whose caller ignores it is decoration, and this is the caller.
	alice := testutils.TestAddress("ep-alice")
	testCourt(cur, "epz", testutils.TestAddress("boot-ep"), 10_000_000_000)
	postingFixture(cur, "ep", alice, 50_000_000_000)

	for _, bad := range []struct{ arg, want string }{
		{"img|" + okHash + "|image/webp|800|600", "8 fields"},
		{"img|nothex|image/webp|800|600|90210||" + okMirror, "sha256"},
		{imgLine("", "http://i.imgur.com/a.webp"), "https"},
		{imgLine("", "https://evil.example.com/a.webp"), "will not load"},
		// A bar in a caption is caught by the FIELD COUNT, not by captionFault:
		// the caption is field seven, so a bar in it makes nine fields out of
		// eight. captionFault's own bar rule is therefore unreachable through
		// this entrypoint — belt and braces behind a split that already refuses
		// it, which is worth knowing before somebody trusts it as the gate.
		{imgLine("a|b", okMirror), "8 fields"},
	} {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, bad.want, func() {
			OpenClaimPM(cross(cur), "ep", "a claim", "", bad.arg)
		})
	}

	// THE CONTROL: the same entrypoint takes a good one. Without it every arm
	// above would pass against an entrypoint that refused everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimPM(cross(cur), "ep", "a claim that files", "", imgLine("ok", okMirror))
	if !strings.Contains(ClaimMedia("ep", id), okHash) {
		t.Fatal("a well-formed argument must actually be stored")
	}

	// And a refusal costs nothing: the deposit is not spent on a claim that was
	// never opened, so the count must not have moved for the five above.
	if ClaimCount("ep") != id {
		t.Fatalf("a refused claim must not consume an id: count %d, last id %d",
			ClaimCount("ep"), id)
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

	// THE INDEX IS ON THE PAGE, IN THE SHAPE EVERY OTHER PURGE USES. modActLine
	// prints the act code straight to the moderation log, and PurgeClaimMedia
	// takes that index as its handle — a power addressed by an id nobody can see
	// is a power nobody can use, and an id in a shape nobody recognises is the
	// same failure one step on.
	// Asserted in the ESCAPED form the page actually carries. modActLine runs the
	// code through sanitize.InlineText, which escapes `-` and `#` — they render
	// back to a reader as written, but a substring match sees the backslashes.
	// This is the same escaping that once broke the site link by turning
	// kourt.xyz into kourt\.xyz, and it is worth matching what is on the page
	// rather than what one expects to be.
	logPage := Render("mp/mod")
	if !strings.Contains(logPage, `media\-purge\#0:csam`) {
		t.Fatalf("the log must name the exhibit by the handle the verb takes:\n%s", logPage)
	}

	// A repeat is a no-op rather than an error, so it consumes no proposal and
	// writes no second log row for an act that cannot change anything.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaimMedia(cross(cur), "mp", id, 0, "csam")
}

func TestThePageNamesTheArchiveRatherThanTheFilersMirror(cur realm, t *testing.T) {
	// THE POINT OF THIS TEST. A markdown image has one destination and no
	// onerror, so whichever host the page names is the host every reader's
	// browser contacts — and gnoweb's CSP forbids the fetch that would let a
	// reader verify what came back. Pointing at a URL the FILER chose would make
	// every claim page a small amplifier aimed wherever they liked.
	prev := siteDomain
	defer func() { siteDomain = prev }()

	m := parseMediaArg(imgLine("the memo", okMirror))[0]

	siteDomain = "kourt.xyz"
	if got := mediaDestination(&m); got != "https://kourt.xyz/m/"+okHash {
		t.Fatalf("with a site configured the page must point at the archive, got %q", got)
	}

	// With no archive to point at, a mirror is all there is.
	siteDomain = ""
	if got := mediaDestination(&m); got != okMirror {
		t.Fatalf("with no site configured the mirror is the fallback, got %q", got)
	}

	// A video has nowhere else to go: the archive does not mirror it.
	v := parseMediaArg("vid||||||the hearing|" + okMirror)[0]
	siteDomain = "kourt.xyz"
	if got := mediaDestination(&v); got != okMirror {
		t.Fatalf("a video points at its host, got %q", got)
	}
}

func TestEveryExhibitIsNumberedAndKeepsItsPlace(cur realm, t *testing.T) {
	prev := siteDomain
	defer func() { siteDomain = prev }()
	siteDomain = "kourt.xyz"

	alice := testutils.TestAddress("mr-alice")
	testCourt(cur, "mrz", testutils.TestAddress("boot-mr"), 10_000_000_000)
	dadmin := DirectoryAdmin()
	if dadmin == alice {
		panic("fixture: the subject of the test is the bootstrap DAO member")
	}
	postingFixture(cur, "mr", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimPM(cross(cur), "mr", "a claim with exhibits", "",
		imgLine("the memo", okMirror)+"\n"+
			imgLine("the reply", okMirror)+"\n"+
			"vid||||||the hearing|"+okMirror)

	page := Render("mr/1")
	if !strings.Contains(page, "Evidence filed with this claim") {
		t.Fatalf("the evidence must be reachable on the claim page:\n%s", page)
	}
	for _, want := range []string{"Exhibit 1 of 3", "Exhibit 2 of 3", "Exhibit 3 of 3"} {
		if !strings.Contains(page, want) {
			t.Fatalf("every exhibit is numbered; missing %q", want)
		}
	}
	// WHAT THIS PAGE CANNOT TELL YOU, SAID OUT LOUD. The whole value of filing a
	// hash is that a swap is detectable, and gnoweb cannot perform that check —
	// its CSP forbids fetching a third-party image at all. A reader shown
	// evidence with no mention of that would reasonably take the court to have
	// vouched for it, so silence here is not neutral: it is a claim the court
	// cannot support.
	if !strings.Contains(page, "but not on this page") {
		t.Fatalf("the page must say it cannot check the evidence it is showing:\n%s", page)
	}
	if !strings.Contains(page, "[kourt.xyz](https://kourt.xyz) checks it") {
		t.Fatalf("...and name the surface that can:\n%s", page)
	}
	// The alt text carries the position only: the caption is printed visibly on
	// the next line, and repeating it makes a screen reader say the same words
	// twice and a broken image show them twice.
	if strings.Contains(page, "![Exhibit 1 of 3 — the memo]") {
		t.Fatalf("the alt text must not repeat the visible caption:\n%s", page)
	}

	// AND THE CAPTION REACHES THE PAGE. Asserting only the numbering left the
	// caption branch untested: a mutation that dropped captions entirely changed
	// nothing any test could see, because every exhibit under test was
	// uncaptioned or checked only for its number.
	if !strings.Contains(page, "Exhibit 1 of 3 — the memo") {
		t.Fatalf("an exhibit's caption must reach the reader:\n%s", page)
	}

	// The archive, not the mirror the filer named.
	if !strings.Contains(page, "https://kourt.xyz/m/"+okHash) {
		t.Fatalf("the page must point at the archive:\n%s", page)
	}
	// A video is LINKED, not verified, and must say so rather than wearing the
	// same chrome as an exhibit the court can check.
	if !strings.Contains(page, "cannot vouch for it") {
		t.Fatalf("a video must be marked as unverified:\n%s", page)
	}
	if strings.Contains(page, "![Exhibit 3") {
		t.Fatal("a video is a link, never an image")
	}

	// AN EXHIBIT WITH NOWHERE TO POINT SAYS SO, rather than rendering an empty
	// image tag. Reached when no site is configured and every mirror has left
	// the allowlist — rare, and exactly when a reader most needs telling.
	{
		var nb strings.Builder
		prevSite := siteDomain
		siteDomain = ""
		writeClaimMedia(&nb, &Court{}, &claimState{media: []mediaItem{{
			kind: mediaKindImage, sha256: okHash, mime: "image/webp",
			w: 8, h: 6, bytes: 12, mirrors: []string{"https://gone.example/x.webp"},
		}}})
		siteDomain = prevSite
		if !strings.Contains(nb.String(), "not currently available") {
			t.Fatalf("an exhibit with nowhere to point must say so:\n%s", nb.String())
		}
		// And an UNCAPTIONED exhibit still renders, numbered, with no stray
		// separator left where a caption would have been. Checked on the exhibit
		// line specifically: the section's own note carries an em dash of its
		// own, and a whole-page search for one finds that instead.
		if strings.Contains(nb.String(), "Exhibit 1 of 1 — ") {
			t.Fatalf("an uncaptioned exhibit must not carry an empty caption:\n%s", nb.String())
		}
	}

	// A TAKEN-DOWN EXHIBIT KEEPS ITS PLACE. Renumbering the images around a gap
	// would leave every later exhibit referring to something else than it did
	// yesterday, in the middle of an argument about which one shows what.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaimMedia(cross(cur), "mr", id, 0, "csam")
	page = Render("mr/1")
	if !strings.Contains(page, "Exhibit 1 of 3 was taken down") {
		t.Fatalf("a purged exhibit keeps its number and says what happened:\n%s", page)
	}
	if !strings.Contains(page, "Exhibit 2 of 3") {
		t.Fatal("the exhibits after a takedown keep the numbers they had")
	}

	// And the whole section goes when the claim itself is purged.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "mr", id, "csam")
	if strings.Contains(Render("mr/1"), "Evidence filed with this claim") {
		t.Fatal("a purged claim shows no evidence section")
	}
}

func TestACaptionCannotBreakOutOfTheAltText(cur realm, t *testing.T) {
	// The caption sits inside ![...](...), so a `]` in it would close the alt
	// text early and let the rest land as page markup. InlineText is the right
	// tool for text on the same line whose URL must never touch an escaper.
	prev := siteDomain
	defer func() { siteDomain = prev }()
	siteDomain = "kourt.xyz"

	var b strings.Builder
	cs := &claimState{media: parseMediaArg(imgLine("a](b) [x](evil", okMirror))}
	writeClaimMedia(&b, &Court{}, cs)
	out := b.String()

	if strings.Contains(out, "](evil") {
		t.Fatalf("a caption must not open a second destination:\n%s", out)
	}
	if !strings.Contains(out, "https://kourt.xyz/m/"+okHash) {
		t.Fatalf("the real destination must survive the escaping:\n%s", out)
	}
}

func TestOneReadCarriesAWholeMapsWorthOfEvidence(cur realm, t *testing.T) {
	// WHY THIS EXISTS. The map draws a node per claim and wants a thumbnail on
	// each, and the overlay has no bulk claim fetch. Asking per claim would mean
	// fifty extra round trips before a fifty-claim map could draw, and the map is
	// built to paint before its bodies arrive.
	alice := testutils.TestAddress("mpg-alice")
	testCourt(cur, "mpgz", testutils.TestAddress("boot-mpg"), 10_000_000_000)
	dadmin := DirectoryAdmin()
	if dadmin == alice {
		panic("fixture: the subject of the test is the bootstrap DAO member")
	}
	postingFixture(cur, "mpg", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaimPM(cross(cur), "mpg", "first", "", imgLine("one", okMirror))
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mpg", "second, carrying nothing")
	testing.SetRealm(testing.NewUserRealm(alice))
	id3 := OpenClaimPM(cross(cur), "mpg", "third", "", imgLine("three", okMirror))

	page := ClaimMediaPage("mpg", 1, 4)
	if strings.Contains(page, "\n") {
		t.Fatalf("the batch must be one line, like every other read: %q", page)
	}
	if !strings.Contains(page, "one") || !strings.Contains(page, "three") {
		t.Fatalf("both claims' evidence must be in the page: %q", page)
	}

	// ONE ENTRY PER CLAIM ASKED FOR, IN ORDER, INCLUDING THE GAPS. The caller is
	// drawing a range, so position i must mean claim fromID+i or the thumbnails
	// land on the wrong nodes. Claim 2 carries nothing and claim 4 does not
	// exist; both are empty entries rather than absences.
	if !strings.HasPrefix(page, "[[") {
		t.Fatalf("the page is an array of entries: %q", page)
	}
	if !strings.Contains(page, "],[],[") {
		t.Fatalf("a claim carrying nothing must hold its position: %q", page)
	}
	if !strings.HasSuffix(page, ",[]]") {
		t.Fatalf("a claim that does not exist must be a hole, not an abort: %q", page)
	}

	// THE SAME GATE AS THE SINGLE READ. A batch that skipped it would be a way
	// to read past a purge sixty-four claims at a time.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "mpg", id3, "csam")
	if strings.Contains(ClaimMediaPage("mpg", 1, 4), "three") {
		t.Fatal("a purged claim must answer with nothing in the batch too")
	}

	// The count is clamped so no caller can ask for the whole docket at once.
	if ClaimMediaPage("mpg", 1, 0) != "[]" {
		t.Fatal("a zero count reads nothing")
	}
	// Clamped, so no caller can ask for the whole docket in one read. Counting
	// the separators rather than the brackets: an entry with mirrors carries
	// brackets of its own.
	if n := strings.Count(ClaimMediaPage("mpg", 1, 9999), "],["); n != maxMediaPage-1 {
		t.Fatalf("the count must clamp to %d entries, saw %d separators", maxMediaPage, n)
	}
}

func TestWithNoOverlayThePageStillSaysItCannotCheck(cur realm, t *testing.T) {
	// The caveat is unconditional; only the pointer to a surface that CAN check
	// depends on one being configured. A court running without an overlay must
	// not silently drop the warning along with the link.
	prev := siteDomain
	defer func() { siteDomain = prev }()

	var b strings.Builder
	cs := &claimState{media: parseMediaArg(imgLine("the memo", okMirror))}

	siteDomain = ""
	out := b.String()
	b.Reset()
	writeClaimMedia(&b, &Court{}, cs)
	out = b.String()
	if !strings.Contains(out, "but not on this page") {
		t.Fatalf("the caveat must not depend on an overlay existing:\n%s", out)
	}
	if strings.Contains(out, "checks it") {
		t.Fatalf("with no site configured there is no surface to name:\n%s", out)
	}
}


// THE ALLOWLIST IS A PARAMETER (owner ruling, CLAIM_MEDIA §10.1), and the reason
// it is one is that the list it tracks — gnoweb's cspImgHost — belongs to
// somebody else. A const cannot be corrected without redeploying the realm.
func TestMediaHostsAreAdminSettable(cur realm, t *testing.T) {
	defer restoreMediaHosts()

	if !mediaHostAllowed("i.imgur.com") {
		t.Fatal("the shipped defaults do not allow imgur")
	}
	mediaHostsExact = parseMediaHosts("example.org", false)
	mediaHostSuffixes = parseMediaHosts(".example.org", true)
	if mediaHostAllowed("i.imgur.com") {
		t.Fatal("a host dropped from the list is still allowed")
	}
	if !mediaHostAllowed("cdn.example.org") || !mediaHostAllowed("example.org") {
		t.Fatal("a host added to the list is not allowed")
	}
}

// AND REMOVING ONE IS RETROACTIVE, which is what makes this the host kill switch
// §10.4 asked for. mediaDestination re-asks mirrorFault on every render rather
// than trusting what passed at write time, so a claim filed while a host was
// allowed stops pointing at it the moment it is not — no purge, no migration.
func TestDroppingAHostTakesEffectOnClaimsAlreadyFiled(cur realm, t *testing.T) {
	defer restoreMediaHosts()

	m := &mediaItem{kind: mediaKindImage, sha256: okHash, mime: "image/webp",
		w: 800, h: 600, bytes: 1000, mirrors: []string{okMirror}}
	// With no site domain configured there is no archive to prefer, so the
	// destination is the mirror itself — which is what makes the change visible.
	before := siteDomain
	siteDomain = ""
	defer func() { siteDomain = before }()

	if got := mediaDestination(m); got != okMirror {
		t.Fatalf("a filed exhibit did not point at its mirror: %q", got)
	}
	mediaHostsExact = parseMediaHosts("example.org", false)
	mediaHostSuffixes = nil
	if got := mediaDestination(m); got != "" {
		t.Fatalf("the page still points at a host the court no longer allows: %q", got)
	}
}

func TestAMediaHostListIsRefusedWholeOrNotAtAll(cur realm, t *testing.T) {
	defer restoreMediaHosts()

	for _, tc := range []struct{ list, want string; suffix bool }{
		{"imgur.com,BAD.com", "lowercase", false},
		{"imgur.com,has space.com", "lowercase", false},
		{"imgur.com,.imgur.com", "does not begin with a dot", false},
		{"imgur.com,imgur.com", "listed twice", false},
		{"imgur.com,ex..ample.com", "empty label", false},
		{"imgur.com,example.com.", "empty label", false},
		{".imgur.com,imgur.com", "begins with a dot", true},
		{"imgur.com:443", "lowercase", false},
		{"https://imgur.com", "lowercase", false},
	} {
		func() {
			defer func() {
				r := recover()
				if r == nil {
					t.Fatalf("parseMediaHosts(%q) was accepted", tc.list)
				}
				if !strings.Contains(r.(string), tc.want) {
					t.Fatalf("parseMediaHosts(%q) said %q, want %q", tc.list, r, tc.want)
				}
			}()
			parseMediaHosts(tc.list, tc.suffix)
		}()
	}
	// A whole good list is taken.
	got := parseMediaHosts("imgur.com, github.com", false)
	if len(got) != 2 || got[0] != "imgur.com" || got[1] != "github.com" {
		t.Fatalf("a good list did not parse: %v", got)
	}
}

// The overlay reads this to make its own refusals match, so it has to be ONE
// line: the overlay's parseTyped splits raw output on newlines before it matches
// a typed value.
func TestMediaHostsReadsBackAsOneLine(cur realm, t *testing.T) {
	defer restoreMediaHosts()

	mediaHostsExact = parseMediaHosts("imgur.com,github.com", false)
	mediaHostSuffixes = parseMediaHosts(".imgur.com", true)
	got := MediaHosts()
	if got != "imgur.com,github.com|.imgur.com" {
		t.Fatalf("MediaHosts() = %q", got)
	}
	if strings.Contains(got, "\n") {
		t.Fatal("MediaHosts must be one line")
	}
}

// restoreMediaHosts puts the shipped defaults back, so one test cannot decide
// what another sees.
func restoreMediaHosts() {
	mediaHostsExact = appendAll(nil, defaultMediaHostsExact)
	mediaHostSuffixes = appendAll(nil, defaultMediaHostSuffixes)
}
