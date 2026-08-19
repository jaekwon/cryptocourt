// Command kourtchatctl is the operator's side of chat moderation.
//
// It exists because the automated half deliberately cannot do the harshest thing:
// a scanner verdict tops out at a bounded timeout, and only a human can ban. That
// design is only honest if the human actually has tools, so:
//
//	kourtchatctl -db chat.db list                 what is in force
//	kourtchatctl -db chat.db list -all            including reversed decisions
//	kourtchatctl -db chat.db why 42               the evidence behind one decision
//	kourtchatctl -db chat.db unban 42             reverse it, and un-hide the messages
//	kourtchatctl -db chat.db kick <ip-hash> -for 1h   a bounded, manual timeout
//	kourtchatctl -db chat.db ban <ip-hash>        a permanent ban, by hand
//	kourtchatctl -db chat.db ban -net <net-hash>  the same for a network
//	kourtchatctl -db chat.db hash 203.0.113.7     the hashes for one address
//	kourtchatctl -db chat.db review               what the scanner left for a human
//	kourtchatctl -db chat.db kick -msg 41 -for 1h act on a message you just read
//	kourtchatctl -db chat.db freeze dev/orem      stop serving a purged court
//	kourtchatctl -db chat.db status               backlog, scanner heartbeat, counts
//
// It takes HASHES, not addresses, and that is a consequence of hashing rather than
// an oversight: the addresses are not stored, so neither this tool nor anybody
// holding the database can turn a row back into a person. Read a hash off a `list`
// or `why`, or out of the 403 a caller reports.
//
// `hash` exists because that left a gap with no way out. Every hash had to be read
// off an EXISTING infraction, so an operator holding a fresh database and an address
// they can see in their own proxy logs — a reported harassment case, an address the
// classifier never flagged — had nothing to act on. It hashes FORWARD, which discloses
// nothing new: anyone who can run it already holds the key and the database, and
// CHAT.md §3 concedes that recovering every IPv4 address from those two is seconds of
// work. It refuses to MINT a key, because a mistyped --secret-file would otherwise
// yield a plausible hash under a brand-new key and a ban that matched nobody.
//
// `kick` exists for the same reason in the other direction. The automated half tops out
// at a bounded timeout precisely because proportionate and reversible is the design;
// leaving a human no manual option BUT a permanent ban made the most severe tool the
// only one. A manual kick is capped by nothing — clamping is for automated reasons —
// so `-for` is required rather than defaulted.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

func main() {
	db := flag.String("db", "chat.db", "path to the SQLite database")
	secretFile := flag.String("secret-file", "",
		"the server's IP hashing key; must match kourtchat's, or every hash is wrong")
	flag.Usage = usage
	flag.Parse()
	args := flag.Args()
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	store, err := chat.Open(*db)
	if err != nil {
		die("%v", err)
	}
	defer store.Close()
	ctx := context.Background()

	switch args[0] {
	case "list":
		cmdList(ctx, store, args[1:])
	case "why":
		cmdWhy(ctx, store, args[1:])
	case "unban", "revoke":
		cmdUnban(ctx, store, args[1:])
	case "ban":
		cmdBan(ctx, store, args[1:])
	case "kick":
		cmdKick(ctx, store, args[1:])
	case "hash":
		cmdHash(store, *secretFile, args[1:])
	case "review":
		cmdReview(ctx, store, args[1:])
	case "dismiss":
		cmdDismiss(ctx, store, args[1:])
	case "freeze":
		cmdFreeze(ctx, store, args[1:])
	case "status":
		cmdStatus(ctx, store)
	default:
		die("unknown command %q", args[0])
	}
}

// split separates flag arguments from positional ones, so both orders work.
//
// Go's flag package stops parsing at the first non-flag argument, which makes
// `unban 1 -by jae` — the order anybody would type — fail with "needs one id".
// An operator reversing a bad decision should not have to remember that.
func split(argv []string) (flags, positional []string) {
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
			// A value-taking flag written as "-by jae" carries the next argument.
			if !strings.Contains(a, "=") && i+1 < len(argv) &&
				!strings.HasPrefix(argv[i+1], "-") && takesValue(a) {
				i++
				flags = append(flags, argv[i])
			}
			continue
		}
		positional = append(positional, a)
	}
	return flags, positional
}

// takesValue lists the flags that consume the following argument. Short and
// explicit beats clever: the alternative is asking the FlagSet, which cannot be
// done before parsing.
func takesValue(f string) bool {
	switch strings.TrimLeft(f, "-") {
	case "by", "why", "ip", "n", "db", "for", "secret-file", "msg":
		return true
	}
	return false // -all, -net are booleans
}

func usage() {
	fmt.Fprint(os.Stderr, `kourtchatctl -db <path> <command>

  list [-all] [-ip HASH]   consequences in force (or every one, with -all)
  why ID                   the evidence and reasoning behind one consequence
  unban ID                 reverse a consequence and restore its hidden messages
  kick HASH -for 1h        a bounded manual timeout, short of a ban
  ban HASH [-net] [-why S] a permanent ban, which only a human can issue
  hash ADDR                the address and network hashes for one IP
  review [-all] [-n N]     messages the scanner flagged and did NOT act on
  dismiss ID               record that you read one and chose to do nothing
  freeze CHAIN/COURT       stop serving a court, for an on-chain purge
  status                   backlog, scanner heartbeat, counts

Hashes come from list, why, or hash <addr>. With -secret-file, pass the same path
kourtchat runs with: a different key means every hash here matches nothing.
`)
}

func cmdList(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	all := fs.Bool("all", false, "include reversed consequences")
	ip := fs.String("ip", "", "only this address or network hash")
	limit := fs.Int("n", 50, "how many")
	flags, _ := split(argv)
	_ = fs.Parse(flags)

	rows, err := s.ListInfractions(ctx, *ip, *all, *limit)
	if err != nil {
		die("%v", err)
	}
	if len(rows) == 0 {
		fmt.Println("nothing in force")
		return
	}
	now := time.Now().Unix()
	fmt.Printf("%-5s %-6s %-8s %-14s %-10s %s\n", "id", "kind", "reason", "address", "state", "evidence")
	for _, r := range rows {
		state := "in force"
		switch {
		case r.RevokedAt != 0:
			state = "reversed"
		case r.ExpiresAt == 0:
			state = "permanent"
		case r.ExpiresAt <= now:
			state = "expired"
		default:
			state = fmt.Sprintf("%s left",
				(time.Duration(r.ExpiresAt-now) * time.Second).Truncate(time.Minute))
		}
		fmt.Printf("%-5d %-6s %-8s %-14s %-10s %s\n",
			r.ID, r.Kind, r.Reason, short(r.IPHash), state, oneLine(r.Evidence, 44))
	}
}

func cmdWhy(ctx context.Context, s *chat.Store, argv []string) {
	if len(argv) != 1 {
		die("why needs one consequence id")
	}
	id, err := strconv.ParseInt(argv[0], 10, 64)
	if err != nil {
		die("%v", err)
	}
	rows, err := s.ListInfractions(ctx, "", true, 500)
	if err != nil {
		die("%v", err)
	}
	for _, r := range rows {
		if r.ID != id {
			continue
		}
		fmt.Printf("consequence %d\n", r.ID)
		fmt.Printf("  kind      %s\n", r.Kind)
		fmt.Printf("  reason    %s\n", r.Reason)
		fmt.Printf("  address   %s\n", r.IPHash)
		if r.NetHash != "" {
			fmt.Printf("  network   %s\n", r.NetHash)
		}
		fmt.Printf("  issued    %s\n", time.Unix(r.CreatedAt, 0).Format(time.RFC3339))
		if r.ExpiresAt == 0 {
			fmt.Printf("  expires   never\n")
		} else {
			fmt.Printf("  expires   %s\n", time.Unix(r.ExpiresAt, 0).Format(time.RFC3339))
		}
		if r.RevokedAt != 0 {
			fmt.Printf("  REVERSED  %s by %s\n",
				time.Unix(r.RevokedAt, 0).Format(time.RFC3339), r.RevokedBy)
		}
		// The evidence is a COPY taken when the consequence was recorded, so it
		// survives the message being deleted later. A ban whose evidence has been
		// pruned cannot be appealed, and permanent ones outlive everything else.
		if r.Evidence != "" {
			fmt.Printf("  message   %q\n", r.Evidence)
		}
		if r.Detail != "" {
			fmt.Printf("  finding   %s\n", r.Detail)
		}
		if r.EvidenceID != 0 {
			if v, body, err := s.MessageVerdict(ctx, r.EvidenceID); err == nil {
				fmt.Printf("  verdict   %s\n", v)
				if body != r.Evidence {
					fmt.Printf("  current   %q  (edited or hidden since)\n", body)
				}
			}
		}
		return
	}
	die("no consequence %d", id)
}

func cmdUnban(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("unban", flag.ExitOnError)
	by := fs.String("by", "operator", "who reversed it, for the record")
	flags, pos := split(argv)
	_ = fs.Parse(flags)
	if len(pos) != 1 {
		die("unban needs one consequence id")
	}
	id, err := strconv.ParseInt(pos[0], 10, 64)
	if err != nil {
		die("%v", err)
	}
	if err := s.Revoke(ctx, id, *by); err != nil {
		die("%v", err)
	}
	// Revoke keeps the row and marks it, rather than deleting: the audit trail is
	// the thing that makes "appealable" mean anything. It also un-hides the
	// messages, because restoring the right to post while leaving someone's words
	// hidden is half an apology.
	fmt.Printf("consequence %d reversed by %s; its messages are visible again\n", id, *by)
}

func cmdBan(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("ban", flag.ExitOnError)
	isNet := fs.Bool("net", false, "the hash is a network, not a single address")
	why := fs.String("why", "", "note for the record")
	msg := fs.Int64("msg", 0, "act on the author of this message id, instead of a hash")
	flags, pos := split(argv)
	_ = fs.Parse(flags)
	pos, evID, evText := withAuthor(ctx, s, *msg, pos, *isNet, "ban")
	if len(pos) != 1 || pos[0] == "" {
		die("ban needs one hash — read it from `list`, `why`, `hash <addr>`, or use -msg")
	}
	hash := pos[0]

	in := chat.Infraction{
		Kind: chat.KindBan, Reason: chat.ReasonManual, Detail: *why,
		EvidenceID: evID, Evidence: evText,
	}
	if *isNet {
		// A range ban is the one consequence that reaches a whole network, and it
		// exists only here. The scanner cannot issue one — an automated kick
		// applies to a single address, because a range is a decision a person
		// makes and not a side effect of a model's opinion.
		in.NetHash = hash
		in.IPHash = "net:" + hash // a placeholder key; enforcement matches net_hash
	} else {
		in.IPHash = hash
	}
	id, err := s.Consequence(ctx, in)
	if err != nil {
		die("%v", err)
	}
	scope := "address"
	if *isNet {
		scope = "network"
	}
	fmt.Printf("banned %s %s permanently [consequence %d]\n", scope, short(hash), id)
	fmt.Printf("reverse it with: kourtchatctl unban %d\n", id)
}

// cmdKick applies a bounded manual timeout.
//
// Reason is `manual`, like a ban, which means the enforcer's automated ceiling does not
// clamp it — see chat.statusTx. That is correct and worth stating plainly: the clamp
// exists to stop a MODEL escalating to something permanent, not to overrule a person
// who has decided an hour is the right answer. The duration is therefore required, so
// that "how long" is always a decision somebody made.
func cmdKick(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("kick", flag.ExitOnError)
	for_ := fs.Duration("for", 0, "how long, e.g. 1h or 24h (required)")
	why := fs.String("why", "", "note for the record")
	isNet := fs.Bool("net", false, "the hash is a network, not a single address")
	msg := fs.Int64("msg", 0, "act on the author of this message id, instead of a hash")
	flags, pos := split(argv)
	_ = fs.Parse(flags)
	pos, evID, evText := withAuthor(ctx, s, *msg, pos, *isNet, "kick")
	if len(pos) != 1 || pos[0] == "" {
		die("kick needs one hash — read it from `list`, `why`, `hash <addr>`, or use -msg")
	}
	if *for_ <= 0 {
		die("kick needs -for, e.g. -for 1h; a timeout with no end is a ban")
	}
	in := chat.Infraction{
		Kind: chat.KindKick, Reason: chat.ReasonManual, Detail: *why, Duration: *for_,
		EvidenceID: evID, Evidence: evText,
	}
	if *isNet {
		in.NetHash = pos[0]
		in.IPHash = "net:" + pos[0]
	} else {
		in.IPHash = pos[0]
	}
	id, err := s.Consequence(ctx, in)
	if err != nil {
		die("%v", err)
	}
	scope := "address"
	if *isNet {
		scope = "network"
	}
	fmt.Printf("kicked %s %s for %s [consequence %d]\n", scope, short(pos[0]), *for_, id)
	fmt.Printf("reverse it early with: kourtchatctl unban %d\n", id)
}

// cmdHash prints the hashes for an address, so the other commands have something to
// take. See the package comment for why this is not a privacy regression.
func cmdHash(s *chat.Store, secretFile string, argv []string) {
	_, pos := split(argv)
	if len(pos) != 1 {
		die("hash needs one address, e.g. 203.0.113.7 or 2001:db8::1")
	}
	addr, err := netip.ParseAddr(pos[0])
	if err != nil {
		die("%q is not an IP address: %v", pos[0], err)
	}
	// create=false: minting a key here would produce a confident, useless answer.
	key, err := chat.LoadKey(s, secretFile, false)
	if err != nil {
		if errors.Is(err, chat.ErrNoKey) {
			die("no hashing key yet — start kourtchat once, or point -secret-file at its key")
		}
		die("%v", err)
	}
	h, err := chat.NewHasher(key)
	if err != nil {
		die("%v", err)
	}
	// Each hash labelled with the range it actually covers. The first version of this
	// printed Prefix beside the NETWORK hash — "203.0.113.7/32" next to a hash over
	// 203.0.113.0/24 — which is how an operator bans the wrong scope confidently.
	fmt.Printf("address  %s   (%s)\n", h.Hash(addr), chat.Prefix(addr))
	fmt.Printf("network  %s   (%s)\n", h.HashNet(addr), chat.NetPrefix(addr))
	fmt.Printf("\nkick one address for an hour:  kourtchatctl kick %s -for 1h\n", h.Hash(addr))
	fmt.Printf("ban the network permanently:   kourtchatctl ban -net %s\n", h.HashNet(addr))
}

// withAuthor turns -msg into the hash the caller would otherwise have typed, and into
// the evidence the consequence should carry.
//
// Copying a 32-character hash from one command into another by hand is where an operator
// bans the wrong person, and `review` prints message ids, so acting on what you just read
// should not require the transcription step at all.
//
// It returns the evidence as well because the first version did not, and that broke two
// things at once: `why` on a manual kick showed the operator's note with no record of
// what was said, and the message stayed in the review queue forever, because the queue is
// "flagged with no infraction citing it" and nothing cited it.
func withAuthor(ctx context.Context, s *chat.Store, msg int64, pos []string, isNet bool,
	verb string) (out []string, evidenceID int64, evidence string) {
	if msg == 0 {
		return pos, 0, ""
	}
	if len(pos) > 0 {
		die("%s takes either a hash or -msg, not both", verb)
	}
	ipHash, netHash, body, err := s.MessageAuthor(ctx, msg)
	if err != nil {
		die("%v", err)
	}
	if isNet {
		if netHash == "" {
			die("message %d has no network hash recorded", msg)
		}
		return []string{netHash}, msg, body
	}
	return []string{ipHash}, msg, body
}

// cmdReview prints what the scanner decided not to decide.
//
// The queue exists because §7's reporting carve-out records a verdict and takes no
// action: gemma3:4b cannot separate reporting a scam from sending one, so a message that
// reads as a warning is left for a person. Before this command those messages appeared
// only in the daemon's log, which is not somewhere anyone looks after the fact.
//
// Bodies are printed in FULL, deliberately, unlike `list`, which truncates to keep a
// table readable. The whole purpose here is judging a message, and a judgement made on
// the first forty characters of a scam is not a judgement.
func cmdReview(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("review", flag.ExitOnError)
	all := fs.Bool("all", false, "include ones already dismissed")
	limit := fs.Int("n", 50, "how many")
	flags, _ := split(argv)
	_ = fs.Parse(flags)

	rows, err := s.PendingReview(ctx, *all, *limit)
	if err != nil {
		die("%v", err)
	}
	if len(rows) == 0 {
		fmt.Println("nothing waiting for review")
		return
	}
	now := time.Now().Unix()
	fmt.Printf("%d message(s) the scanner flagged and did not act on:\n", len(rows))
	for _, r := range rows {
		age := (time.Duration(now-r.CreatedAt) * time.Second).Truncate(time.Minute)
		vis := "visible in the court"
		if r.Hidden {
			vis = "hidden"
		}
		fmt.Printf("\n  message %d  %s/%s  %s ago  verdict %s, %s\n",
			r.ID, r.Chain, r.Court, age, r.Verdict, vis)
		fmt.Printf("  author    %s\n", short(r.IPHash))
		fmt.Printf("  moniker   %s\n", r.Moniker)
		fmt.Printf("  said      %s\n", r.Body)
	}
	// The two things to do next, spelled out, because an operator reading this is
	// deciding between them and should not have to reconstruct the syntax.
	fmt.Printf("\nact on one:  kourtchatctl kick -msg <id> -for 1h -why \"...\"\n")
	fmt.Printf("leave it:    kourtchatctl dismiss <id>\n")
}

func cmdDismiss(ctx context.Context, s *chat.Store, argv []string) {
	_, pos := split(argv)
	if len(pos) != 1 {
		die("dismiss needs one message id — read them from `review`")
	}
	id, err := strconv.ParseInt(pos[0], 10, 64)
	if err != nil {
		die("%v", err)
	}
	if err := s.MarkReviewed(ctx, id); err != nil {
		die("%v", err)
	}
	// Says what it did NOT do, because "dismiss" could plausibly mean either.
	fmt.Printf("message %d marked reviewed — nothing was hidden and nobody was kicked\n", id)
	fmt.Printf("see it again with: kourtchatctl review -all\n")
}

func cmdFreeze(ctx context.Context, s *chat.Store, argv []string) {
	if len(argv) != 1 || !strings.Contains(argv[0], "/") {
		die("freeze needs CHAIN/COURT, e.g. dev/orem")
	}
	parts := strings.SplitN(argv[0], "/", 2)
	if err := s.Freeze(ctx, parts[0], parts[1]); err != nil {
		die("%v", err)
	}
	// Latched here rather than re-derived from the chain on every request, because
	// the chain read cannot tell "this court was purged" from "the node is
	// unreachable" — both arrive as a query error. A compliance control whose
	// fail-open trigger is an RPC hiccup is not a control.
	fmt.Printf("%s is frozen: its history is no longer served and posts are refused\n", argv[0])
}

func cmdStatus(ctx context.Context, s *chat.Store) {
	h, err := s.Health(ctx)
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("backlog        %d unscanned\n", h.Backlog)
	if h.ScannerSeen == 0 {
		fmt.Printf("scanner        never seen — chat is UNMODERATED\n")
	} else {
		age := time.Since(time.Unix(h.ScannerSeen, 0)).Truncate(time.Second)
		warn := ""
		if age > 5*time.Minute {
			warn = "  (stale — is kourtmod running?)"
		}
		fmt.Printf("scanner        last seen %s ago%s\n", age, warn)
		fmt.Printf("enforcing      %t\n", h.Enforcing)
		if !h.Enforcing {
			fmt.Printf("               dry run: verdicts are recorded, nobody is punished\n")
		}
	}
	inForce, err := s.CountInfractions(ctx, false)
	if err != nil {
		die("%v", err)
	}
	all, err := s.CountInfractions(ctx, true)
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("consequences   %d in force, %d ever\n", inForce, all)
}

func short(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func oneLine(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > n {
		return s[:n-1] + "…"
	}
	return s
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "kourtchatctl: "+format+"\n", args...)
	os.Exit(1)
}
