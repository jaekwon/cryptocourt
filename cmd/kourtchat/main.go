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
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
	"github.com/jaekwon/kourt/internal/geo"
)

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
		geoLoc    = flag.String("geo-locations", "", "MaxMind GeoLite2-Country-Locations-en.csv")
		geoBlocks = flag.String("geo-blocks", "", "comma-separated GeoLite2-Country-Blocks-IPv{4,6}.csv")
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

	srv := &chat.Server{
		Store: store, Hasher: hasher, Policy: policy,
		HealthDetail: *healthDetail,
		Chains:       names, CountryHeader: *countryHdr, Log: lg,
	}
	// Flags are decoration, so a missing or broken geo database must never stop the
	// server: it logs and carries on with no flags at all.
	if *geoLoc != "" && *geoBlocks != "" {
		tab, err := geo.LoadMaxMind(*geoLoc, strings.Split(*geoBlocks, ",")...)
		if err != nil {
			lg.Printf("no flags: %v", err)
		} else {
			srv.Geo = tab
			lg.Printf("geo: %d prefixes loaded", tab.Len())
		}
	}

	h, err := store.Health(context.Background())
	if err == nil && h.ScannerSeen == 0 {
		lg.Printf("no scanner has ever run: chat is UNMODERATED and says so in /api/chat/health")
	}
	lg.Printf("listening on %s, chains %v, proxy=%v", *addr, keys(names), *behindProxy)

	server := &http.Server{
		Addr:              *addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	lg.Fatal(server.ListenAndServe())
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
