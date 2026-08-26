// The overlay's domain, and the header that routes a gnoweb reader to it.
//
// gnoweb serves this realm's own Render() and always will — that is the
// guarantee the whole design rests on, and nothing here weakens it. But the
// overlay at kourt.xyz is where most people should be reading, so every gnoweb
// page carries a link to the same thing over there.
//
// ONE REALM-WIDE VALUE, SET BY THE GLOBAL DAO ADMIN, AND BY NOBODY ELSE. Not the
// meta court, not a court's moderators, and there is no per-court override — the
// `ladder` and `creditRates` shape of "realm default, court may override" is
// deliberately NOT used here. A court that could point its own pages at a domain
// of its choosing could route its readers anywhere while wearing the platform's
// name, and the meta court exists to review claims rather than to own the
// platform's front door.
package kourtv2

import (
	"chain"
	"strconv"
	"strings"
)

// A hostname, and only a hostname: no scheme, no path, no query, no port.
//
// THE REALM OWNS THE PATH. Storing a host and building "https://<host>/#/c/…"
// here means the link on a claim page can only ever point at the SAME claim on
// the overlay. Store a base URL instead and an admin could set
// "evil.example/#/c/other/1?" and every page would deep-link somewhere it does
// not say it goes. The admin chooses the house; the realm still writes the
// address on the envelope.
//
// The character set is also what makes the value safe to PRINT. Every byte it
// permits is inert in both of the contexts the banner puts it in: inert as
// markdown link text (no brackets, parens, backticks, emphasis), and inert as a
// link destination (no whitespace, no ")", no "<" or ">"). So the banner needs
// no escaper — and must not use one. sanitize.InlineText backslash-escapes "."
// and "-", which renders "kourt.xyz" correctly as text but writes
// "https://kourt\.xyz/" into the destination. An escaper applied to the wrong
// context is not defence in depth; it is a broken link.
//
// The defence in depth that IS right here is fail-closed: siteBanner re-checks
// the stored value and prints nothing if it fails, so a value that ever reaches
// the variable without passing this function costs a missing header rather than
// a malformed page.
const maxSiteDomainLen = 100

// siteDomain is empty until an admin sets one, and empty is a working state:
// every page renders exactly as it did before, with no header at all. A realm
// that only worked once somebody configured a website would be a realm that
// depends on a website.
var siteDomain string

// siteDomainFault names what is wrong with d, or "" when nothing is.
//
// Split from the panic so the render path can ask the same question without
// being able to abort a page: a bad stored value must cost the header, never the
// claim underneath it.
func siteDomainFault(d string) string {
	if len(d) < 4 || len(d) > maxSiteDomainLen {
		return "a site domain is 4..100 characters"
	}
	if !strings.Contains(d, ".") {
		return "a site domain needs a dot — it is a hostname, not a word"
	}
	if d[0] == '.' || d[0] == '-' || d[len(d)-1] == '.' || d[len(d)-1] == '-' {
		return "a site domain may not begin or end with a dot or a hyphen"
	}
	for i := 0; i < len(d); i++ {
		c := d[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'
		if !ok {
			return "a site domain is lowercase letters, digits, dots and " +
				"hyphens only — no scheme, no path, no port"
		}
	}
	if strings.Contains(d, "..") {
		return "a site domain may not contain an empty label"
	}
	return ""
}

func mustSiteDomain(d string) {
	if fault := siteDomainFault(d); fault != "" {
		panic("kourtv2: " + fault)
	}
}

// SetSiteDomain points every gnoweb page at the overlay. Global DAO admin only.
func SetSiteDomain(cur realm, domain string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the site domain")
	}
	mustSiteDomain(domain)
	siteDomain = domain
	// Emitted for the reason SetLadderDefault is: this changes every page in the
	// realm at once and there is no court to log it against, so the event is the
	// only record there can be.
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-site-domain:"+domain,
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}

// ClearSiteDomain takes the header off every page. Same seat.
//
// It exists because a domain that lapses is worse than none: a header pointing
// at a host somebody else now owns is the realm recommending a stranger.
func ClearSiteDomain(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin clears the site domain")
	}
	if siteDomain == "" {
		panic("kourtv2: no site domain is set")
	}
	siteDomain = ""
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "clear-site-domain",
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}

// SiteDomain is the configured overlay host, or "" when there is none.
func SiteDomain() string { return siteDomain }

// sitePath maps a gnoweb render path onto the overlay's own routing.
//
// The overlay is a hash-routed single page — "#/", "#/c/<slug>",
// "#/c/<slug>/<id>", "#/me" — so the mapping is small and total. Anything this
// realm serves that the overlay has no route for resolves to the nearest thing
// it does: a board or a row goes to its CLAIM, a moderation log to its COURT.
// That is a deliberate choice over linking to a route that does not exist —
// sending a reader to the claim they were reading about is right even before the
// overlay learns to show comments, and it stays right afterwards.
func sitePath(path string) string {
	parts := strings.SplitN(path, "/", 4)
	if path == "" || parts[0] == "" {
		return "#/"
	}
	if len(parts) == 1 {
		// The help page is the realm's own; the overlay has no route for it and
		// linking to "#/c/how-it-works" would send a reader to a court that
		// cannot exist. The directory is the nearest true thing.
		if parts[0] == helpPath {
			return "#/"
		}
		return "#/c/" + parts[0]
	}
	switch parts[1] {
	case "me":
		return "#/me"
	case "mod":
		return "#/c/" + parts[0]
	}
	// A numeric second segment is a claim; everything under it (board, a row,
	// a positions page) belongs to that claim.
	if _, err := strconv.ParseUint(parts[1], 10, 64); err != nil {
		return "#/c/" + parts[0]
	}
	return "#/c/" + parts[0] + "/" + parts[1]
}

// siteBanner is the header itself, empty when no domain is configured.
//
// It sits beside testClockBanner in Render() for the same reason that one does:
// a disclosure that appears on some pages and not others is a disclosure a
// reader cannot rely on. First thing, every page, or not at all.
func siteBanner(path string) string {
	// Fail closed. No domain is the ordinary case; a domain that does not
	// validate is the one that should never happen, and both cost exactly the
	// header. See the note above on why this is the right guard and an escaper
	// is not.
	if siteDomain == "" || siteDomainFault(siteDomain) != "" {
		return ""
	}
	return "[Read this on " + siteDomain + " →](https://" + siteDomain + "/" +
		sitePath(path) + ")\n\n"
}
