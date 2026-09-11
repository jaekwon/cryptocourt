// Command kourtchat serves the off-chain court chat.
//
// It accepts, stores, throttles and ENFORCES. It never talks to the model and
// never reads a verdict — that is kourtmod's job, in a separate process, so chat
// works whether or not the scanner is running and an OOM in a 7B model cannot take
// HTTP down with it.
//
//	kourtchat --db ./chat.db --chain dev=http://127.0.0.1:26657
//
// Behind a reverse proxy, and this matters more than any other flag:
//
//	kourtchat --behind-proxy --trusted-proxy 10.0.0.0/8 --country-header CF-IPCountry
//
// Without --behind-proxy the client address is the peer and X-Forwarded-For is
// ignored entirely, so a direct listener cannot be spoofed by sending the header.
// With it, the header is walked right to left and the first hop that is not a
// trusted proxy wins. Setting --behind-proxy with no trusted CIDR is refused: it
// would believe the header from anybody.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"time"

	"github.com/jaekwon/kourt/internal/archive"
	"github.com/jaekwon/kourt/internal/chat"
	"github.com/jaekwon/kourt/internal/geo"
	"path/filepath"
)

// keyWarning reports what is wrong with where the IP hashing key lives, or "" when nothing is.
//
// Three cases, and the first is the default:
//
//	no --secret-file        the key is a row IN the database, so one file carries the hashes
//	                        and the key that reverses them
//	same directory as it     a backup or rsync of that directory carries both, which is the
//	                        threat the hashing exists for
//	under that directory     the same thing. tar and rsync take subdirectories.
//
// THE THIRD CASE USED TO BE SILENT, and it is the one this deployment ships. Measured on the
// running server: --db /var/lib/kourt/chat.db --secret-file /var/lib/kourt/secret/iphash.key,
// with 0600 on both and no warning in thirty days of journal, because /var/lib/kourt/secret is
// not equal to /var/lib/kourt. A copy of /var/lib/kourt \u2014 the natural backup unit, and what a
// VPS snapshot takes \u2014 carries the table and the key that reverses it. CHAT.md \u00a79 states the
// rule as "outside the data directory" and gives /etc/kourt/ip.key as the example; equality is
// narrower than that sentence, so the check disagreed with its own documentation and the
// shipped layout sat in the gap.
//
// CONTAINMENT, NOT A PREFIX TEST, which is the trap this function already had a test for:
// strings.HasPrefix("/var/lib/kourt-backup", "/var/lib/kourt") is true and those are unrelated
// directories. filepath.Rel answers the real question \u2014 a path is under another when the route
// between them does not have to climb out first.
//
// A warning rather than a refusal: refusing would break every deployment that is running this
// way today, and the operator may have a reason. Being unable to see it is the problem.
func keyWarning(secretFile, db string) string {
	if secretFile == "" {
		return "no --secret-file: the IP hashing key is stored inside " + db +
			", so one copy of that file carries both the address hashes and the key that " +
			"reverses them. See CHAT.md \u00a79."
	}
	keyDir, err1 := filepath.Abs(filepath.Dir(secretFile))
	dbDir, err2 := filepath.Abs(filepath.Dir(db))
	if err1 != nil || err2 != nil {
		return "" // cannot compare; not worth a scary message over a path we failed to resolve
	}
	if keyDir == dbDir {
		return "--secret-file " + secretFile + " sits in the same directory as the database; " +
			"a backup of that directory carries both the hashes and the key. See CHAT.md \u00a79."
	}
	if under(keyDir, dbDir) {
		return "--secret-file " + secretFile + " sits under " + dbDir + ", the database's own " +
			"directory; a backup or snapshot of that directory carries both the hashes and the " +
			"key that reverses them. Put the key outside the data directory. See CHAT.md \u00a79."
	}
	if under(dbDir, keyDir) {
		return "the database " + db + " sits under " + keyDir + ", the key's own directory; " +
			"a backup or snapshot of that directory carries both the hashes and the key that " +
			"reverses them. See CHAT.md \u00a79."
	}
	return ""
}

// under reports whether child is inside parent. Both must already be absolute and cleaned.
func under(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	// ".." means the route out of parent, so child is not inside it. "." is equality, which
	// callers have already handled and which is not "under".
	return rel != "." && rel != ".." &&
		!strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

/*
capWarning reports a helper running with no ceiling on what it can spend.

	A WARNING RATHER THAN A REFUSAL, and a default of zero rather than a number,
	for the reason keyWarning gives: refusing would break every deployment
	running this way today and the operator may have a reason. Not being able to
	see it is the problem.
	IT DOES THE ARITHMETIC, because "no cap" is abstract and a number is not. The
	gap fixes the call ceiling — one reply per gap, so 86400/gap calls a day — and
	the input price plus a measured ~2,000-token prompt turns that into a figure
	an operator can compare against what they are willing to lose.
*/
func capWarning(cap int64, gap time.Duration, inPerMTok int64) string {
	if cap > 0 || gap <= 0 {
		return ""
	}
	calls := int64(24 * time.Hour / gap)
	// ~2,000 input tokens per call, measured on the live site once the prompt
	// carried the armour and the refusal list. Output is a rounding error beside
	// it — 24 tokens against 2,000 — so this is deliberately the input half only,
	// and therefore an UNDER-estimate rather than a scare.
	worst := calls * 2000 * inPerMTok / 1_000_000
	return fmt.Sprintf("no --bot-cost-cap: nothing bounds what it spends except "+
		"the gap, which allows %d calls a day — on the order of %d micro-dollars "+
		"at the configured input price, and no alert when it climbs. Set a daily "+
		"ceiling in micro-dollars.", calls, worst)
}

// countryWarning reports a --country-header that now has no effect.
//
// The header is only believed from a trusted proxy. Without --behind-proxy there is no trusted
// proxy, so it is only something the client typed — and before it was gated, that let every
// client choose the flag shown beside its own name. Flags go quiet in that configuration rather
// than being spoofable, and quiet is exactly the kind of change an operator should be told about
// instead of discovering when somebody asks why the flags disappeared.
func countryWarning(countryHeader string, behindProxy bool) string {
	if countryHeader == "" || behindProxy {
		return ""
	}
	return "--country-header " + countryHeader + " has no effect without --behind-proxy: on a " +
		"server that is not behind a proxy, that header is only something the client typed, so " +
		"honouring it would let every client pick the flag beside its own name. No flags will " +
		"be shown from it. Add --behind-proxy with --trusted-proxy, or resolve countries from a " +
		"local table instead. See CHAT.md \u00a73."
}

// modeWarning reports a database other users on this host can read.
//
// Open creates a NEW database 0600, and SQLite copies that onto -wal and -shm, so a fresh
// deployment is closed by default. A database created before that change keeps whatever the
// umask gave it — 0644 under the usual 022 — and nothing would otherwise say so. Measured
// against the real server before the fix: the key file was 0600 while chat.db, chat.db-wal and
// chat.db-shm were all -rw-r--r--.
//
// ALL THREE FILES ARE CHECKED, not just the one named by --db. In WAL mode the main file can be
// nothing but a header while every row lives in the -wal, so an operator who reads a warning
// about chat.db, runs chmod on it alone and sees the warning clear would have protected the
// header and left the messages readable. Whichever files are actually loose get named.
//
// A warning and not a refusal, for the reason keyWarning gives: refusing would break every
// deployment running this way today, and the operator may have a reason. Not being able to see
// it is the problem.
//
// THE KEY CLAUSE DELIBERATELY REPEATS keyWarning, which fires on exactly the same condition, so
// the two always print together and the sentence is always redundant on screen. It stays because
// log lines are read one at a time — grepped, alerted on, pasted into a ticket — and a warning
// that only makes sense next to its neighbour is worse than one that repeats a clause. Deleting
// it would leave the line saying "readable by other users" without the part that makes that
// serious rather than untidy.
func modeWarning(db, secretFile string) string {
	var loose []string
	for _, p := range []string{db, db + "-wal", db + "-shm"} {
		fi, err := os.Stat(p)
		if err != nil {
			// Absent is the common case for -wal and -shm, and a missing or unreadable main
			// database is diagnosed by chat.Open far better than it could be here.
			continue
		}
		if perm := fi.Mode().Perm(); perm&0o077 != 0 {
			loose = append(loose, fmt.Sprintf("%s (%04o)", p, perm))
		}
	}
	if len(loose) == 0 {
		return ""
	}
	msg := "readable by other users on this host: " + strings.Join(loose, ", ") +
		". These hold every message body and the whole consequence history. New databases are " +
		"created 0600; run chmod 600 on each of the files listed."
	if secretFile == "" {
		msg += " With no --secret-file the IP hashing key is inside that same database, so " +
			"anybody who can read it can reverse the address hashes for an address they guess."
	}
	return msg + " See CHAT.md \u00a79."
}

func main() {
	var (
		addr         = flag.String("addr", "127.0.0.1:8788", "listen address")
		db           = flag.String("db", "chat.db", "path to the SQLite database")
		chains       = flag.String("chain", "dev", "comma-separated chain names to serve")
		behindProxy  = flag.Bool("behind-proxy", false, "trust X-Forwarded-For from --trusted-proxy")
		trusted      = flag.String("trusted-proxy", "", "comma-separated CIDRs allowed to set X-Forwarded-For")
		countryHdr   = flag.String("country-header", "", "trusted header carrying an ISO country code, e.g. CF-IPCountry")
		secretFile   = flag.String("secret-file", "", "path to the IP hashing key; defaults to a row in the database")
		healthDetail = flag.Bool("health-detail", false,
			"serve backlog and scanner timing on the public health endpoint (helps an attacker time one)")
		archiveRPC = flag.String("archive-rpc", "",
			"gno RPC endpoint the media archive asks whether a claim references a "+
				"blob; empty disables promotion, so every upload expires")
		archiveRealm = flag.String("archive-realm", "gno.land/r/kourt/kourtv2",
			"realm the media archive reads claim media from")
		archiveEye = flag.String("archive-vision", "",
			"Ollama base URL for looking at filed images; empty means no model "+
				"looks at them and nothing is ever blocked automatically")
		archiveEyeModel = flag.String("archive-vision-model", "llava",
			"vision model the archive asks about filed images")
		appealTo = flag.String("appeal-to", "",
			"where a punished person should complain; the panel stays silent about appeals if unset")
		// THE HELPER IN THE ROOM. Off unless --bot is given: a process that would
		// start spending money because a key happened to be in the database is not
		// a process anybody should have to reason about.
		bot      = flag.Bool("bot", false, "answer questions about the site in chat")
		botModel = flag.String("bot-model", "claude-haiku-4-5-20251001",
			"model the chat helper uses")
		botSite = flag.String("bot-site", "kourt.xyz",
			"the site the helper is helping with, for its prompt")
		botRepo = flag.String("bot-repo", "github.com/jaekwon/cryptocourt",
			"the project's source, for its prompt")
		botDocs = flag.String("bot-chain-docs", "docs.gno.land",
			"gno.land documentation, for its prompt")
		botGap = flag.Duration("bot-gap", chat.BotMinGap,
			"minimum time between two replies, across every room together")
		/* THE ONLY BOUND ON WHAT THE HELPER CAN SPEND USED TO BE TIME. One reply
		   per --bot-gap, newest wins, which at ten seconds is 8,640 calls a day
		   — and per-call input is ~2,000 tokens now that the prompt carries the
		   armour and the refusals, against a lifetime of $0.47 over 514 calls.
		   Nothing read the running total and nothing alerted, so the first sign
		   of a room grinding at it would have been the bill.
		   ZERO BY DEFAULT, because a ceiling is a policy and the operator owns
		   it: a default that silenced a working helper would be this flag's own
		   worst failure. What the process does instead is SAY so at startup, the
		   same posture as the hashing-key warning below. */
		botCap = flag.Int64("bot-cost-cap", 0,
			"most the chat helper may spend in a UTC day, in micro-dollars (0 = no cap)")
		// PRICES ARE CONFIGURATION AND NOT FACTS. They are whatever the vendor
		// charges this account today and this process cannot ask. Wrong numbers
		// make the money column on the diagnostics page wrong and nothing else —
		// the token counts beside it come from the API's own response. CHECK THEM
		// against the current price list rather than trusting these defaults.
		botIn = flag.Int64("bot-price-in", 1_000_000,
			"micro-dollars per million input tokens (verify against current pricing)")
		botOut = flag.Int64("bot-price-out", 5_000_000,
			"micro-dollars per million output tokens (verify against current pricing)")
		// THE BOOTSTRAP WINDOW. On by default because the feature is a form on a
		// page; an operator who has set the key already, or who would rather set it
		// out of band, passes false and the endpoint accepts nothing at all.
		botKeyForm = flag.Bool("bot-key-form", true,
			"accept the helper's API key at /api/chat/botkey until one is set")

		geoLoc    = flag.String("geo-locations", "", "MaxMind GeoLite2-Country-Locations-en.csv")
		geoBlocks = flag.String("geo-blocks", "", "comma-separated GeoLite2-Country-Blocks-IPv{4,6}.csv")

		// THE ONE THAT NEEDS NO ACCOUNT, which is why it exists beside the two
		// above. The MaxMind pair is a licence key and a signup away, so the geo
		// feature shipped switched off and stayed that way; a range file can be
		// fetched by the deploy script.
		geoRanges = flag.String("geo-ranges", "",
			"country file as first,last,CC rows (DB-IP IP-to-Country Lite)")
	)
	flag.Parse()
	lg := log.New(os.Stderr, "kourtchat: ", log.LstdFlags)

	prefixes, err := chat.MustParsePrefixes(*trusted)
	if err != nil {
		lg.Fatal(err)
	}
	policy := chat.IPPolicy{BehindProxy: *behindProxy, Trusted: prefixes}
	if err := policy.Validate(); err != nil {
		// Refusing to start is the point. Starting would mean every visitor shares
		// one identity, or the header is believed from anyone — either way the
		// first timeout applies to strangers.
		lg.Fatal(err)
	}

	store, err := chat.Open(*db)
	if err != nil {
		lg.Fatal(err)
	}
	defer store.Close()

	key, err := chat.LoadKey(store, *secretFile, true)
	if err != nil {
		lg.Fatal(err)
	}
	// SAY WHEN THE HASHING KEY IS NOT PROTECTING ANYTHING.
	//
	// internal/chat/clientip.go claimed the key was "required to live outside the data
	// directory" — a code comment, not CHAT.md, which only ever said "should". Nothing
	// required it, and the DEFAULT is the case that fails: with no --secret-file the key goes
	// into a row of the database itself, so one copy of that file carries both the hashes and
	// the means to reverse them. IPv4 is 2^32; that is every address recovered in seconds.
	//
	// Silence was the wrong answer for the same reason the line below it is not silent — this
	// process already announces an unmoderated chat at startup rather than leaving somebody to
	// infer it. A defence that is not operating should say so where an operator is looking.
	if w := keyWarning(*secretFile, *db); w != "" {
		lg.Print(w)
	}
	// After Open, so the files exist to be statted, and so a database this process just
	// created reports the mode it was actually given rather than nothing at all.
	if w := modeWarning(*db, *secretFile); w != "" {
		lg.Print(w)
	}
	if w := countryWarning(*countryHdr, *behindProxy); w != "" {
		lg.Print(w)
	}
	hasher, err := chat.NewHasher(key)
	if err != nil {
		lg.Fatal(err)
	}

	names := map[string]bool{}
	for _, c := range strings.Split(*chains, ",") {
		if c = strings.TrimSpace(c); c != "" {
			names[c] = true
		}
	}
	if len(names) == 0 {
		lg.Fatal("--chain needs at least one name")
	}

	/* WHETHER THE HELPER WILL RUN IS DECIDED ONCE, HERE, and both the goroutine
	   below and the flag the diagnostics page reports come from that one answer.
	   They used to be decided separately — the field from --bot, the goroutine
	   from --bot AND a key — so a deployment with the flag and no key reported
	   enabled=true and added a phantom participant to every room's count. */
	botKey, botKeySet, botKeyErr := store.BotKey()
	if botKeyErr != nil {
		lg.Printf("chat bot: cannot read the key: %v", botKeyErr)
	}

	srv := &chat.Server{
		Store: store, Hasher: hasher, Policy: policy,
		HealthDetail: *healthDetail,
		AppealTo:     *appealTo,
		Chains:       names, CountryHeader: *countryHdr, Log: lg,
		BotKeyBootstrap: *botKeyForm,
		// BotEnabled is set below, from the one thing that decides it.
	}
	// Flags are decoration, so a missing or broken geo database must never stop the
	// server: it logs and carries on with no flags at all.
	//
	// THE MAXMIND PAIR WINS WHEN BOTH ARE GIVEN, because an operator who went to
	// the trouble of a licence key meant it. Neither is consulted if a trusted
	// CDN is already answering the question — see Server.countryOf, where the
	// header takes precedence over whatever file this loads.
	switch {
	case *geoLoc != "" && *geoBlocks != "":
		if tab, err := geo.LoadMaxMind(*geoLoc, strings.Split(*geoBlocks, ",")...); err != nil {
			lg.Printf("no flags: %v", err)
		} else {
			srv.Geo = tab
			lg.Printf("geo: %d spans, %d countries (maxmind)", tab.Len(), tab.Countries())
		}
	case *geoRanges != "":
		// geo.Load RATHER THAN LoadRanges, so the same flag takes either of
		// DB-IP's files: the country one, or the city one whose coordinates
		// become the presence map's coarse cells. Sniffed from the file's own
		// shape rather than from a second flag that could disagree with it.
		if tab, err := geo.Load(*geoRanges); err != nil {
			lg.Printf("no flags: %v", err)
		} else {
			srv.Geo = tab
			// THE COUNTRY COUNT IS THE USEFUL HALF OF THIS LINE. A file that
			// parsed to a million spans and three countries loaded wrong in a way
			// the span count cannot show.
			//
			// AND WHETHER IT CAN PLACE, because a country file and a city file
			// are the same flag and the same log line otherwise — and the
			// difference is whether the map has dots on it.
			placed := "country only"
			if tab.HasCells() {
				placed = fmt.Sprintf("%d placed in cells", tab.Cells())
			}
			lg.Printf("geo: %d spans, %d countries, %s", tab.Len(), tab.Countries(), placed)
		}
	}
	// GIVE BACK WHAT PARSING THE FILE COST, and this is worth a line of code
	// rather than being left to the collector's own schedule.
	//
	// MEASURED on the real city file: the table itself is 97MB, but reading
	// 658MB of decompressed CSV through it leaves the heap at 188MB and the
	// process holding 333MB from the operating system — on a box with about a
	// gigabyte available and a chain node beside it. One FreeOSMemory returns
	// 227MB of that immediately. It is a startup cost paid once, so the usual
	// argument against forcing a collection does not apply: there is nothing
	// else running yet to be paused.
	if srv.Geo != nil {
		debug.FreeOSMemory()
	}

	h, err := store.Health(context.Background())
	if err == nil && h.ScannerSeen == 0 {
		lg.Printf("no scanner has ever run: chat is UNMODERATED and says so in /api/chat/health")
	}
	/* THE HELPER, built by the one function that knows how to connect it.
	   chat.NewBot returns nil when it must not run and wires Wake and Subscribe
	   when it must — see its doc for why that is not a struct literal here. The
	   server's own flag comes from the SAME result, so "is there a helper" is
	   answered once rather than twice.
	   THE KEY IS READ ONCE, above. A key set through the form afterwards takes
	   effect at the next restart, which the page says rather than papering over:
	   re-reading it every tick would mean a process that starts spending because
	   somebody filled in a form, with nothing in the log to say when. */
	/* THE CLERK CAN SEE THE ROOM IT IS IN, when there is a node to ask. Reported
	   twice: "the clerk doesn't answer anything related to the court, like 'how
	   many claims are there in the court?'" — the filter always accepted that
	   question, and the model simply had no data behind it.
	   THE SAME CLIENT AND THE SAME FLAG the archive uses, built once here rather
	   than twice: one endpoint is one operator decision. chat declares the
	   interface it needs (chat.CourtFacts) and *archive.Chain already satisfies
	   it, so neither package imports the other and this line is the whole seam.
	   NIL WHEN THERE IS NO --archive-rpc, which is the same shape as every other
	   optional half of this command: the clerk then explains mechanics and knows
	   no numbers, exactly as it did before. */
	var courtChain *archive.Chain
	if *archiveRPC != "" {
		courtChain = &archive.Chain{RPC: *archiveRPC, PkgPath: *archiveRealm}
	}
	var facts chat.CourtFacts
	if courtChain != nil {
		facts = courtChain
	}
	helper := chat.NewBot(store, srv, botKey, chat.BotOptions{
		Facts:   facts,
		Enabled: *bot, Model: *botModel,
		Site: *botSite, Repo: *botRepo, ChainDocs: *botDocs,
		MinGap: *botGap, InPerMTok: *botIn, OutPerMTok: *botOut,
		CostCapMicros: *botCap,
		Chains:        names, Log: lg.Printf,
	})
	srv.BotEnabled = helper != nil
	switch {
	case helper != nil:
		go helper.Run(context.Background())
		lg.Printf("chat bot: on, model %s, one reply per %s", *botModel, *botGap)
		if w := capWarning(*botCap, *botGap, *botIn); w != "" {
			lg.Printf("chat bot: %s", w)
		}
	case *bot && !botKeySet:
		lg.Printf("chat bot: enabled but no key is set yet — set one at /api/chat/botkey, then restart")
	}

	lg.Printf("listening on %s, chains %v, proxy=%v", *addr, keys(names), *behindProxy)

	// THE MEDIA ARCHIVE. kourt.xyz's own copy of the images filed with a claim,
	// content-addressed, in this same database — see internal/archive.
	mux := srv.Routes()
	astore, err := archive.NewStore(store.Writer())
	if err != nil {
		lg.Fatal(err)
	}
	// The deployment sits behind nginx, so RemoteAddr is the proxy for every
	// request and would make one rate-limit bucket for the whole internet. The
	// bucket key is HASHED with the same key the chat uses, so an in-memory
	// limiter never holds a raw address.
	archiveClient := func(r *http.Request) string {
		a, err := policy.ClientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"))
		if err != nil {
			return r.RemoteAddr
		}
		return hasher.Hash(a)
	}
	// Same flag the chat uses: the operator numbers are one decision, not two.
	asrv := archive.NewServer(astore, lg, archiveClient).WithHealthDetail(*healthDetail)
	if courtChain != nil {
		asrv = asrv.WithChain(courtChain)
	} else {
		// Said out loud, because the failure is silent otherwise: with no chain
		// to ask, nothing is ever promoted and every upload expires within the
		// hour. That is the safe direction — an archive that cannot check what
		// is referenced must forget rather than become free permanent storage —
		// but an operator who did not mean it would otherwise only discover it
		// when a reader reported a missing image.
		lg.Printf("no --archive-rpc: media uploads will EXPIRE after %s, "+
			"because nothing can confirm a claim references them", archive.StageTTL)
	}
	asrv.Routes(mux)
	// The classifier sorts a queue for a person; it is not a gate. With no
	// --archive-vision nothing looks at filed images and nothing is ever blocked
	// automatically, which is a defensible way to run this and a bad one to
	// discover by accident — so it is said out loud either way.
	var eye archive.ImageClassifier
	if *archiveEye != "" {
		eye = archive.NewOllamaEye(*archiveEye, *archiveEyeModel)
		lg.Printf("archive: %s will look at filed images; only %q above %.2f is "+
			"blocked without a person", *archiveEyeModel, archive.AutoBlockLabel,
			archive.AutoBlockConfidence)
	} else {
		lg.Printf("no --archive-vision: nothing looks at filed images, and the " +
			"archive blocks nothing automatically")
	}
	var backfillChain archive.ClaimCounter
	if *archiveRPC != "" {
		backfillChain = &archive.Chain{RPC: *archiveRPC, PkgPath: *archiveRealm}
	}
	go sweepArchive(astore, backfillChain, eye, lg)

	server := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	lg.Fatal(server.ListenAndServe())
}

// sweepArchive deletes staged media nobody claimed. It runs for the life of the
// process: the TTL is only a promise until something enforces it.
func sweepArchive(st *archive.Store, chain archive.ClaimCounter,
	eye archive.ImageClassifier, lg *log.Logger) {
	for {
		// BACKFILL FIRST, THEN SWEEP. A claim filed fifty-nine minutes ago must
		// be seen before the bytes it points at would be deleted — and it may
		// have been filed from a tab that closed, from the CLI, or from gnoweb,
		// none of which ever tell this service anything.
		if chain != nil {
			if kept, err := st.Backfill(context.Background(), chain); err != nil {
				lg.Printf("archive backfill: %v", err)
			} else if kept > 0 {
				lg.Printf("archive: kept %d upload(s) a claim references", kept)
			}
		}
		// After backfill and before the sweep: only promoted bytes are worth
		// judging, and they are promoted a moment ago.
		if blocked, err := st.ReviewPass(context.Background(), eye, 20); err != nil {
			lg.Printf("archive review: %v", err)
		} else if blocked > 0 {
			lg.Printf("archive: blocked %d image(s) pending review", blocked)
		}
		n, err := st.SweepStaged(context.Background(), time.Now())
		switch {
		case err != nil:
			lg.Printf("archive sweep: %v", err)
		case n > 0:
			lg.Printf("archive: swept %d unclaimed upload(s)", n)
		}
		time.Sleep(10 * time.Minute)
	}
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
