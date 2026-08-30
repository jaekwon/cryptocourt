package kourtv2

import (
	"strconv"
	"strings"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// mediaDestination is the ONE url gnoweb's markdown will point at, and it is the
// archive's whenever there is an archive to point at.
//
// A markdown image has a single destination and no `onerror`, so this surface
// has no fallback chain: whichever host is named here is the host every reader's
// browser contacts. Naming a mirror the FILER chose would make every claim page
// a small amplifier aimed wherever they liked, at readers who — on gnoweb, whose
// CSP forbids the fetch — cannot verify what comes back either.
//
// So: the archive, derived from the hash on the domain the admin configured.
// The cost is honest. If the archive does not hold the bytes the image is broken
// here, while kourt.xyz still finds it through a mirror and can prove it matches.
// A broken image on the surface that cannot verify beats a working one that
// cannot be trusted and discloses its readers.
//
// Video is the exception, and not by preference: the archive does not mirror it,
// so a video item has nowhere to point but the host that streams it.
func mediaDestination(m *mediaItem) string {
	if m.kind == mediaKindImage && m.sha256 != "" &&
		siteDomain != "" && siteDomainFault(siteDomain) == "" {
		return "https://" + siteDomain + "/m/" + m.sha256
	}
	for _, u := range m.mirrors {
		// Re-asked here as well as at the item level, so a mirror whose host has
		// left the allowlist is never the one a page points at.
		if mirrorFault(u) == "" {
			return u
		}
	}
	return ""
}

// writeClaimMedia puts the claim's evidence on the page, under the body.
//
// EVERY EXHIBIT IS NUMBERED, AND THE NUMBER IS VISIBLE. PurgeClaimMedia takes a
// zero-based index, and without a number on the page a moderator taking down the
// third exhibit would be counting positions in a JSON payload. The reader wants
// it too: "the second exhibit" is how people argue about evidence.
//
// A purged or unavailable exhibit KEEPS ITS PLACE and says what happened. A gap
// that silently renumbered the images around it would leave every later exhibit
// referring to something else than it did yesterday, in the middle of an
// argument about which one shows what.
// verifyElsewhere names the surface that CAN check an exhibit, when there is one
// to name. Built from the same configured domain the archive lives on, so the
// two can never disagree about where the overlay is.
func verifyElsewhere() string {
	if siteDomain == "" || siteDomainFault(siteDomain) != "" {
		return ""
	}
	return " [" + siteDomain + "](https://" + siteDomain + ") checks it."
}

func writeClaimMedia(b *strings.Builder, c *Court, cs *claimState) {
	items := claimMediaVisible(c, cs)
	if len(items) == 0 {
		return
	}
	total := strconv.Itoa(len(items))
	b.WriteString("## Evidence filed with this claim\n\n")
	// WHAT THIS PAGE CANNOT TELL YOU, said before the pictures rather than after.
	//
	// The whole value of filing a hash is that a swapped image is detectable —
	// and this surface cannot perform that check, because gnoweb's CSP forbids
	// fetching a third-party image at all. A reader shown evidence with no
	// mention of that would reasonably assume the court had vouched for it.
	// Silence here is not neutral; it is a claim the court cannot support.
	b.WriteString("_The court recorded a fingerprint of each image when the claim " +
		"was filed, so a swap can be detected — but not on this page._" + verifyElsewhere() + "\n\n")
	for i := range items {
		m := &items[i]
		pos := strconv.Itoa(i+1) + " of " + total
		if m.purged {
			b.WriteString("_Exhibit " + pos + " was taken down._\n\n")
			continue
		}
		dest := mediaDestination(m)
		if dest == "" {
			b.WriteString("_Exhibit " + pos + " is not currently available._\n\n")
			continue
		}
		// The caption is author-written, so it goes through InlineText — the
		// right tool for text, exactly as it is the wrong tool for the URL on the
		// same line, which is emitted raw because it was validated fail-closed.
		caption := ""
		if m.caption != "" {
			caption = " — " + sanitize.InlineText(m.caption)
		}
		if m.kind == mediaKindVideo {
			// LINKED, NOT VERIFIED, and it has to say so. A streaming host serves
			// no stable bytes to commit to, so nothing can check this the way an
			// image is checked; giving it the same chrome as a verified exhibit
			// would drain the distinction of meaning everywhere it appears.
			b.WriteString("[▶ Exhibit " + pos + caption + "](" + dest +
				") _(a link; the court holds no copy and cannot vouch for it)_\n\n")
			continue
		}
		// The alt text carries the POSITION only, because the caption is printed
		// visibly on the next line. Repeating it makes a screen reader say the
		// same words twice, and makes a broken image show them twice.
		b.WriteString("![Exhibit " + pos + "](" + dest + ")\n\n")
		b.WriteString("_Exhibit " + pos + caption + "_\n\n")
	}
}

// ClaimMediaPage answers with the evidence of a RUN of claims in one read.
//
// WHY A BATCH EXISTS AT ALL. The map draws a node per claim and wants a
// thumbnail on each, and the overlay has no bulk claim fetch — it issues a read
// per claim. Asking per claim for media too would mean fifty extra round trips
// before a fifty-claim map could draw, and the map is deliberately built to
// paint before its bodies arrive. One read for the page it is drawing keeps
// that promise.
//
// Every item goes through claimMediaVisible, the same gate the single read uses,
// so a purged claim answers with nothing here exactly as it does there. A batch
// that skipped the gate would be a way to read past a purge fifty at a time.
//
// A claim that does not exist contributes an empty array rather than aborting:
// the caller is drawing a range, and one hole in it must not cost the page.
// count is clamped so a caller cannot ask for the whole docket in one read.
func ClaimMediaPage(courtSlug string, fromID uint64, count int) string {
	c := mustCourt(courtSlug)
	if count < 1 {
		return "[]"
	}
	if count > maxMediaPage {
		count = maxMediaPage
	}
	var b strings.Builder
	b.WriteString("[")
	for i := 0; i < count; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		id := fromID + uint64(i)
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			b.WriteString("[]")
			continue
		}
		b.WriteString(encodeMedia(claimMediaVisible(c, v.(*claimState))))
	}
	b.WriteString("]")
	return b.String()
}

// PurgeClaimMedia destroys one media item on a claim. Global DAO members only,
// at the purge threshold, with a statutory category — the same gate every other
// purge verb in this realm carries, including the panic string verbatim, because
// check-epoch-coherence requires every purge to speak with one voice so a new
// one cannot drift its own authorization past the census.
//
// WHAT IS DESTROYED. The hash, the mirrors and the caption: the item's whole
// payload, zeroed rather than flagged, exactly as PurgeBoardRow zeroes a
// comment's text. The realm never held the bytes, so this cannot unpublish them
// — what it removes is the court's pointer to them and the court's word that
// they are evidence. Taking the bytes down is the archive's job (CLAIM_MEDIA
// §3.2), and the two are deliberately independent: either alone suffices to
// remove an image from the overlay, and neither can rewrite what was filed.
//
// THE SLOT SURVIVES, tombstoned in place. Removing the element would shift every
// later index, so a moderator working through seven items would find their
// second call landing on one they had already reviewed and kept.
//
// idx is zero-based, and a repeat is a no-op rather than an error — checked
// before the vote, so it consumes no m-of-n proposal and writes no second log
// row for an act that cannot change anything.
func PurgeClaimMedia(cur realm, courtSlug string, claimID uint64, idx uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if idx >= uint64(len(cs.media)) {
		panic("kourtv2: this claim carries no media item at that position")
	}
	if cs.media[idx].purged {
		return
	}
	fire, votedCode := approveAction(d.pending,
		"mediapurge:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(idx, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	m := &cs.media[idx]
	m.purged = true
	m.sha256 = ""
	m.mirrors = nil
	m.caption = ""
	m.mime = ""
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, "media-purge:"+strconv.FormatUint(idx, 10)+":"+votedCode, "")
	emitPurge(c.id, claimID, "media-item", who)
}

// MEDIA A CLAIM CARRIES, AND THE PROOF IT HAS NOT CHANGED. docs/CLAIM_MEDIA.md
// is the design record; this file is the chain's half of it.
//
// THE REALM NEVER SEES THE BYTES. It stores a sha256 the author committed to at
// filing time and a list of places the bytes may be found. That is the whole
// idea, and it answers two things a bare URL could not:
//
//   - A host that deletes the image cannot delete the evidence. Anyone may
//     re-serve the same bytes, and the hash proves they are the same bytes.
//   - The author cannot swap the bytes afterward. A URL's contents are mutable;
//     a hash is not. Without this, an author could take a position, watch the
//     market, and re-point the image — which is the exact attack the body's
//     append-only rule exists to prevent, through a door the body never opened.
//
// The hash is a COMMITMENT, not a proof of content: the realm cannot check it,
// and a wrong one only makes the author's own image fail to render everywhere.
const (
	maxClaimMediaCount = 7
	maxMirrorsPerItem  = 4
	maxMediaURLLen     = 300
	maxCaptionLen      = 120
	// 256 KiB. The composer downscales to fit this without ever telling anyone
	// about it (CLAIM_MEDIA §2.2), so the cap is a backstop, not a user-facing
	// rule. It also bounds what a hostile mirror can stream at a viewer.
	maxMediaBytes = 262144
	maxMediaDim   = 20000
	// One map draw's worth of claims, and a ceiling on what a single read can
	// cost the node. The overlay pages its docket well below this.
	maxMediaPage = 64
)

// mediaKind is spelled rather than inferred. A video item has no hash — a
// streaming host serves no stable bytes to commit to — and inferring "no hash
// means video" would silently turn a malformed image item into a video one.
const (
	mediaKindImage = "img"
	mediaKindVideo = "vid"
)

type mediaItem struct {
	kind    string // mediaKindImage | mediaKindVideo
	sha256  string // 64 lowercase hex; empty for video
	mime    string
	w, h    int
	bytes   int
	caption string
	mirrors []string
	// purged tombstones the slot IN PLACE. Removing the element would shift
	// every later index, so a moderator working through seven items would have
	// their second call land on one they had already reviewed and kept.
	purged bool
}

// mediaCharFault rejects anything that has no business in a URL and would cost
// us dearly somewhere downstream. The parentheses are the ones worth naming: a
// mirror is emitted into a markdown image destination, `![alt](url)`, and a `)`
// inside it closes that destination early and spills the remainder onto the page
// as text. That is the same class of bug as the `kourt\.xyz` escape that broke
// the site link — a string put through the wrong text machinery. The answer is
// the same as it was there: validate fail-closed on write, emit raw, and never
// reach for sanitize.InlineText on a URL, which escapes `.` `-` `_` `(` `)` and
// would turn every mirror into a corpse.
//
// `,` and `|` are excluded because they are the wire format's separators, and a
// URL carrying one would let a single field become two.
func mediaCharFault(s string) string {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x21 || c > 0x7e {
			return "a mirror is printable ASCII with no spaces"
		}
		switch c {
		case '"', '\'', '<', '>', '(', ')', '\\', ',', '|', '`':
			return "a mirror may not contain " + string(rune(c))
		}
	}
	return ""
}

func isHexLower(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}

// mirrorFault is split from any panic for siteDomainFault's reason: the RENDER
// path must be able to ask the same question without being able to abort a page.
// A bad stored value costs the image, never the claim underneath it.
//
// This matters more here than it does for the site domain, because the host
// allowlist can narrow after a value is stored. Render re-asks, so retiring a
// host retracts the images already pointing at it instead of grandfathering them.
func mirrorFault(u string) string {
	if len(u) == 0 || len(u) > maxMediaURLLen {
		return "a mirror is 1.." + strconv.Itoa(maxMediaURLLen) + " characters"
	}
	if fault := mediaCharFault(u); fault != "" {
		return fault
	}
	const scheme = "https://"
	if !strings.HasPrefix(u, scheme) {
		return "a mirror is https — plain http is blocked as mixed content"
	}
	// The authority ends at the FIRST of '/', '?' or '#'. Cutting only at '/'
	// would read "i.imgur.com?v=2" as the host and refuse a URL whose query
	// follows the host directly — fail-closed, but refused for a reason nobody
	// could act on. Cutting at all three also keeps a fragment from smuggling a
	// trusted-looking name past the check: in "https://evil.com/#i.imgur.com"
	// the host is and stays evil.com.
	host := u[len(scheme):]
	for _, sep := range []byte{'/', '?', '#'} {
		if i := strings.IndexByte(host, sep); i >= 0 {
			host = host[:i]
		}
	}
	if host == "" {
		return "a mirror needs a host"
	}
	if !mediaHostAllowed(host) {
		return "the browser will not load images from " + host +
			"; see the allowed hosts on the help page"
	}
	return ""
}

// THE HOST ALLOWLIST MIRRORS GNOWEB'S CSP, AND HAS TO.
//
// An image only loads if the browser's Content-Security-Policy permits its host,
// and a blocked image is a broken glyph on the page with NO error signal back to
// the realm — the chain would believe it had published something the reader
// cannot see. So the realm refuses at write time what the browser would refuse
// at load time, and the reader gets a message from the court instead of silence.
//
// The list tracks gnoweb's `cspImgHost`. Drift is the standing hazard: if gnoweb
// narrows its policy, claims pointing at a dropped host break, and nothing here
// will know. Kept a const for v1 — one less governance surface, and promoting it
// to a SetSiteDomain-shaped parameter later is additive.
var mediaHostsExact = []string{
	"gnolang.github.io",
	"assets.gnoteam.com",
	"sa.gno.services",
	"imgur.com",
	"github.com",
	"imgflip.com",
	"ipfs.io",
	"cloudflare-ipfs.com",
}

var mediaHostSuffixes = []string{
	".imgur.com",
	".github.io",
	".githubusercontent.com",
	".imgflip.com",
}

// mediaHostAllowed. The overlay's own domain is allowed WITHOUT being listed
// here, because it is not a constant: kourt.xyz keeps a copy of every image at
// an address derived from the hash, and the domain that archive lives on is the
// one the admin configured. Deriving it from siteDomain rather than hardcoding
// means the archive and the reader-facing site can never disagree about where
// the overlay is.
func mediaHostAllowed(host string) bool {
	if host == "" {
		return false
	}
	if siteDomain != "" && host == siteDomain && siteDomainFault(siteDomain) == "" {
		return true
	}
	for _, h := range mediaHostsExact {
		if host == h {
			return true
		}
	}
	for _, s := range mediaHostSuffixes {
		// A suffix match must not accept the bare suffix as a whole host:
		// ".github.io" would otherwise let "github.io" through, and a longer
		// host is required for the label to mean anything.
		if len(host) > len(s) && strings.HasSuffix(host, s) {
			return true
		}
	}
	return false
}

// captionFault. A caption is the exhibit label AND the alt text, which is why it
// is worth carrying an extra author-written string: "Exhibit A — the email
// header" is better evidence and better accessibility than a generated
// "image 1 of 3".
//
// It is claim text (owner ruling, CLAIM_MEDIA §10.6), so it takes the body's
// rule whole — fixed at creation, no editor, gated by the same purge. Newlines
// and the separators are refused so one caption can never become two fields or
// two items.
func captionFault(s string) string {
	if len(s) > maxCaptionLen {
		return "a caption is at most " + strconv.Itoa(maxCaptionLen) + " characters"
	}
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\n', '\r':
			return "a caption is one line"
		case '|':
			return "a caption may not contain a vertical bar"
		}
		if s[i] < 0x20 && s[i] != '\t' {
			return "a caption may not contain control characters"
		}
	}
	return ""
}

// mediaItemFault validates one parsed item. Returns "" when the item is usable.
func mediaItemFault(m *mediaItem) string {
	switch m.kind {
	case mediaKindImage:
		if len(m.sha256) != 64 || !isHexLower(m.sha256) {
			return "an image needs a sha256: 64 lowercase hex characters"
		}
		if m.w <= 0 || m.h <= 0 || m.w > maxMediaDim || m.h > maxMediaDim {
			return "an image needs real dimensions"
		}
		if m.bytes <= 0 || m.bytes > maxMediaBytes {
			return "an image is 1.." + strconv.Itoa(maxMediaBytes) + " bytes"
		}
		if m.mime == "" {
			return "an image needs a media type"
		}
	case mediaKindVideo:
		// No hash: a streaming host serves no stable bytes to commit to. The
		// consequence is carried honestly to the reader — a video is LINKED, not
		// verified — because giving an unverifiable item the same chrome as a
		// verified one would drain the badge of meaning everywhere it appears.
		if m.sha256 != "" {
			return "a video link carries no hash"
		}
	default:
		return "a media item is " + mediaKindImage + " or " + mediaKindVideo
	}
	if fault := captionFault(m.caption); fault != "" {
		return fault
	}
	if len(m.mirrors) == 0 {
		return "a media item needs somewhere to find it"
	}
	if len(m.mirrors) > maxMirrorsPerItem {
		return "a media item lists at most " + strconv.Itoa(maxMirrorsPerItem) + " mirrors"
	}
	for _, u := range m.mirrors {
		if fault := mirrorFault(u); fault != "" {
			return fault
		}
	}
	return ""
}

// parseMediaArg reads the argument a caller hands OpenClaimPM.
//
// The format is deliberately dull, because parsing is the expensive direction
// and no JSON package is in this realm's dependency set:
//
//	kind|sha256|mime|w|h|bytes|caption|mirror[,mirror...]
//
// one item per line. Newlines are fine HERE — this is a transaction argument.
// They are not fine on the way out (see encodeMedia).
//
// Every fault panics: a claim is filed once and forever, so a media list that
// was silently dropped would be discovered by the author only after they had
// paid the deposit for a claim they cannot amend.
// parseMediaFault is the fault half, split from the panic for the reason
// siteDomainFault is: a validator that can only abort cannot be asked a question,
// and every arm of it would then need a court fixture and a crossing call to
// test. The realm's own idiom is fault-then-must, and this follows it.
func parseMediaFault(arg string) ([]mediaItem, string) {
	trimmed := strings.TrimSpace(arg)
	if trimmed == "" {
		return nil, ""
	}
	lines := strings.Split(trimmed, "\n")
	if len(lines) > maxClaimMediaCount {
		return nil, "a claim carries at most " +
			strconv.Itoa(maxClaimMediaCount) + " media items"
	}
	out := make([]mediaItem, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		f := strings.Split(line, "|")
		if len(f) != 8 {
			return nil, "a media item has 8 fields separated by |"
		}
		m := mediaItem{
			kind:    f[0],
			sha256:  f[1],
			mime:    f[2],
			w:       atoiOr0(f[3]),
			h:       atoiOr0(f[4]),
			bytes:   atoiOr0(f[5]),
			caption: f[6],
		}
		for _, u := range strings.Split(f[7], ",") {
			if u != "" {
				m.mirrors = append(m.mirrors, u)
			}
		}
		if fault := mediaItemFault(&m); fault != "" {
			return nil, fault
		}
		out = append(out, m)
	}
	return out, ""
}

func parseMediaArg(arg string) []mediaItem {
	items, fault := parseMediaFault(arg)
	if fault != "" {
		panic("kourtv2: " + fault)
	}
	return items
}

func atoiOr0(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}

// jsonString quotes a Go string for the JSON emitted by encodeMedia. Only `"`
// and `\` and the control characters need handling, and captionFault has already
// refused the controls — but this escapes them anyway rather than trusting a
// check made somewhere else about a value read back out of storage.
func jsonString(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0xf])
				continue
			}
			b.WriteByte(c)
		}
	}
	b.WriteString(`"`)
	return b.String()
}

// encodeMedia is the READ format, and it is JSON on ONE LINE for a reason that
// is not taste. The overlay's qeval parser splits raw output on newlines BEFORE
// it matches a typed value, so any newline in this payload is read as a second,
// malformed value. JSON also carries captions containing spaces, several
// mirrors, and the purge tombstone without inventing a second separator scheme.
//
// Emitting JSON is concatenation; parsing it would need a package this realm
// does not depend on. The wire format is asymmetric so each direction does the
// cheap thing.
func encodeMedia(items []mediaItem) string {
	if len(items) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteString("[")
	for i := range items {
		if i > 0 {
			b.WriteString(",")
		}
		m := &items[i]
		b.WriteString(`{"kind":`)
		b.WriteString(jsonString(m.kind))
		// A purged slot keeps its POSITION and loses everything else. The reader
		// is told there was something here and that it was taken down, which is
		// honest, and the indices stay the ones a moderator's next call will use.
		if m.purged {
			b.WriteString(`,"purged":true}`)
			continue
		}
		b.WriteString(`,"sha256":`)
		b.WriteString(jsonString(m.sha256))
		b.WriteString(`,"mime":`)
		b.WriteString(jsonString(m.mime))
		b.WriteString(`,"w":`)
		b.WriteString(strconv.Itoa(m.w))
		b.WriteString(`,"h":`)
		b.WriteString(strconv.Itoa(m.h))
		b.WriteString(`,"bytes":`)
		b.WriteString(strconv.Itoa(m.bytes))
		b.WriteString(`,"caption":`)
		b.WriteString(jsonString(m.caption))
		b.WriteString(`,"mirrors":[`)
		n := 0
		for _, u := range m.mirrors {
			// Re-validated on the way OUT, not only on the way in. Write-time
			// validation alone grandfathers every mirror stored under an older,
			// wider allowlist — so retiring a host would fail to retract the
			// images already pointing at it, which would make the allowlist a
			// formality rather than a control.
			if mirrorFault(u) != "" {
				continue
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(jsonString(u))
			n++
		}
		b.WriteString(`]}`)
	}
	b.WriteString("]")
	return b.String()
}
