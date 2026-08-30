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
//	kourtchatctl -db chat.db prune -older-than 720h   what 30-day retention would drop
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

	"github.com/jaekwon/kourt/internal/archive"
	"github.com/jaekwon/kourt/internal/chat"
	"math"
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
	case "images":
		cmdImages(ctx, store, args[1:])
	case "unblock":
		cmdUnblock(ctx, store, args[1:])
	case "dismiss":
		cmdDismiss(ctx, store, args[1:])
	case "prune":
		cmdPrune(ctx, store, args[1:])
	case "hide":
		cmdHide(ctx, store, args[1:])
	case "reveal":
		cmdReveal(ctx, store, args[1:])
	case "unfreeze":
		cmdUnfreeze(ctx, store, args[1:])
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
	case "by", "why", "ip", "n", "db", "for", "secret-file", "msg", "from", "older-than":
		return true
	}
	return false // -all, -net are booleans
}

// cmdImages is the operator's half of the archive's classifier.
//
// WHY IT EXISTS. The model stores a label, a confidence and its own prose
// explicitly so a person can read them, and until this there was no way to. The
// queue was reachable only from Go, so the reasons were written to a table
// nobody could open — and a queue nobody can open is a queue nobody works
// through, which turns the whole "a person decides" design into a claim rather
// than a practice.
//
// BLOCKED IS PRINTED FIRST because one of these rows is an emergency and the
// rest are reading. An image already off the site needs somebody to agree or
// disagree today; a flagged one that is still serving can wait.
func cmdImages(ctx context.Context, store *chat.Store, args []string) {
	fs := flag.NewFlagSet("images", flag.ExitOnError)
	n := fs.Int("n", 50, "how many to list")
	_ = fs.Parse(args)

	ar, err := archive.NewStore(store.Writer())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	rows, err := ar.PendingReview(ctx, *n)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if len(rows) == 0 {
		fmt.Println("nothing flagged.")
		return
	}
	// THE FULL HASH, ON ITS OWN LINE. A shortened one is prettier and useless:
	// unblock takes the whole thing, so an operator reading a truncated id has
	// to go somewhere else to act on what they are looking at. The id shown is
	// the id the verb takes, or the list is something to admire rather than work
	// from.
	for _, r := range rows {
		state := "still serving"
		if r.Blocked {
			state = "BLOCKED"
		}
		fmt.Printf("%s\n  %-9s %3.0f%%  %-13s %s\n",
			r.SHA256, r.Label, r.Confidence*100, state, r.Why)
	}
	fmt.Printf("\n%d flagged. `unblock SHA256` overrules the model and serves one again.\n",
		len(rows))
}

// cmdUnblock is the human undo that makes automatic blocking survivable at all.
func cmdUnblock(ctx context.Context, store *chat.Store, args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: unblock SHA256")
		os.Exit(2)
	}
	ar, err := archive.NewStore(store.Writer())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := ar.Clear(ctx, args[0]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("serving again, and out of the queue.")
}

func usage() {
	fmt.Fprint(os.Stderr, `kourtchatctl -db <path> <command>

  list [-all] [-ip HASH] [-n N]
                           consequences in force (or every one, with -all)
  why ID                   the evidence and reasoning behind one consequence
  unban ID [-by WHO]       reverse a consequence and restore its hidden messages
                           (also spelled: revoke)
  kick HASH|-msg ID -for 1h [-net] [-why S]
                           a bounded manual timeout, short of a ban
  ban HASH|-msg ID [-net] [-why S]
                           a permanent ban, which only a human can issue
  hash ADDR                the address and network hashes for one IP
  images [-n N]            filed images a model flagged, worst first: what it
                           said, how sure it was, and whether the image is
                           already off the site
  unblock SHA256           overrule the model and serve that image again
  review [-all] [-expand] [-n N]
                           messages the scanner flagged and did NOT act on,
                           grouped by author unless -expand
  dismiss ID | -from HASH  record that you read them and chose to do nothing
  prune -older-than 720h [-apply] [-n N]
                           delete old messages; DRY RUN unless -apply
  freeze CHAIN/COURT       stop serving a court, for an on-chain purge
  unfreeze CHAIN/COURT     put it back; the freeze is recorded as lifted, not erased
  hide ID                  take a message out of sight, punishing nobody
  reveal ID                put back a message hidden as a disclosed secret
  status                   backlog, scanner heartbeat, counts

-msg ID acts on the AUTHOR of that message and cites it, so the consequence carries
the evidence and the command echoes what it acted on. -net widens it to the /24 or
/48, which no automated verdict can ever do.

Hashes come from list, why, or hash <addr>. With -secret-file, pass the same path
kourtchat runs with: a different key means every hash here matches nothing.
`)
}

// dur renders a duration for a human, and does not round the alarming case to nothing.
//
// Truncate(time.Minute) was used at every one of these call sites and it flattened every
// span under a minute to "0s": a grouped review row read "5 over 0s", and a kick with
// forty seconds left read "0s left". Five messages in ten seconds is MORE alarming than
// five over an hour, so the one span worth reading precisely was the one being erased.
func dur(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Round(time.Second).Seconds()))
	}
	return d.Round(time.Minute).String()
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
			state = dur(time.Duration(r.ExpiresAt-now)*time.Second) + " left"
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
				time.Unix(r.RevokedAt, 0).Format(time.RFC3339), attribution(r.RevokedBy))
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
	by := fs.String("by", "", "who reversed it, for the record")
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
		// Both failures used to be indistinguishable from success or from a driver string.
		// `unban 999` printed "sql: no rows in result set", and `unban 1` on an
		// already-reversed row printed "reversed by bob" while the row said alice — crediting
		// the caller with somebody else's decision, in the one record this design keeps on
		// purpose.
		var already *chat.AlreadyRevokedError
		switch {
		case errors.As(err, &already):
			die("consequence %d was already reversed by %s on %s — nothing to do, and it was "+
				"not your decision to claim", already.ID, attribution(already.By),
				time.Unix(already.At, 0).Format(time.RFC3339))
		case errors.Is(err, chat.ErrNoConsequence):
			die("no consequence %d — read the id from `list` or `why`", id)
		default:
			die("%v", err)
		}
	}
	// Revoke keeps the row and marks it, rather than deleting: the audit trail is
	// the thing that makes "appealable" mean anything. It also un-hides the
	// messages, because restoring the right to post while leaving someone's words
	// hidden is half an apology.
	fmt.Printf("consequence %d reversed by %s; its messages are visible again\n",
		id, attribution(*by))
	if attribution(*by) != *by {
		fmt.Printf("no -by was given, so consequence %d's reversal carries no name. The row "+
			"is already marked and cannot be amended, and this is the record an appeal is "+
			"read from — pass -by next time.\n", id)
	}
}

// attribution renders revoked_by for a human, and refuses to dress an absence as a name.
//
// The -by flag used to default to the literal string "operator", so omitting it wrote a value
// that READS like an attribution and answers nothing. A second operator retrying a reversal was
// told "already reversed by operator ... and it was not your decision to claim", which is
// incoherent when the recorded decider is a placeholder — and the schema's own default for the
// column is the honest empty string, which the CLI was overriding with a fake.
//
// The audit trail is the thing that makes "appealable" mean anything, so an unattributed
// reversal has to look unattributed. Not refused, though: refusing -by would break every script
// that reverses in bulk, and the reversal itself is the part somebody is waiting for.
func attribution(by string) string {
	if strings.TrimSpace(by) == "" {
		return "(unattributed)"
	}
	return by
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
	if id == 0 {
		fmt.Print(replayReport(ctx, s, hash, evID, chat.KindBan, "ban"))
		return
	}
	fmt.Printf("banned %s %s permanently [consequence %d]\n", scope, short(hash), id)
	fmt.Println(hideNote(id))
	echoEvidence(evID, evText)
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
	if id == 0 {
		fmt.Print(replayReport(ctx, s, pos[0], evID, chat.KindKick, "kick"))
		return
	}
	fmt.Printf("kicked %s %s for %s — %s [consequence %d]\n",
		scope, short(pos[0]), *for_, humanDuration(*for_), id)
	fmt.Printf("until %s\n", time.Now().Add(*for_).Format(time.RFC3339))
	fmt.Println(hideNote(id))
	echoEvidence(evID, evText)
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

// echoEvidence prints the message a `-msg` action was actually about.
//
// Neither ban nor kick used to show it, and both had the body in hand. A mistyped id — `-msg 14`
// for `-msg 41` — therefore produced "kicked address 28cb400fe2b6 for 1h [consequence 3]" and
// nothing an operator could check it against; they had to run `why` to find out who they had just
// punished. Message ids are also rowids that restart after a prune empties a court (§7), so an id
// read from `review` a while ago can resolve to somebody else entirely.
//
// This does not prevent the wrong action, because the tool is non-interactive on purpose and a
// prompt would break scripting. It makes the wrong action VISIBLE at the moment it happens, next
// to the unban line that reverses it, which is the whole reversibility argument.
// Split so the formatting is testable without capturing stdout. Truncation is by RUNES: a byte
// cut would sever a multibyte character and print a replacement box, which in this repo has
// already been the shape of several bugs.
func evidenceLine(evID int64, evText string) string {
	if evID == 0 {
		return ""
	}
	body := evText
	if r := []rune(body); len(r) > 72 {
		body = string(r[:72]) + "…"
	}
	return fmt.Sprintf("for message %d: %q", evID, body)
}

func echoEvidence(evID int64, evText string) {
	if line := evidenceLine(evID, evText); line != "" {
		fmt.Println(line)
	}
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
	expand := fs.Bool("expand", false, "every message, not one row per author")
	limit := fs.Int("n", 50, "how many")
	flags, _ := split(argv)
	_ = fs.Parse(flags)

	// Grouped by default, because the flat list is a denial-of-attention surface: one
	// address inside the throttle put 70 reporting-shaped messages in the queue and left
	// the single genuine report at position 71 of 71. See chat.ReviewGroups.
	if !*expand {
		cmdReviewGrouped(ctx, s, *all, *limit)
		return
	}
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
		age := dur(time.Duration(now-r.CreatedAt) * time.Second)
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

// cmdReviewGrouped prints one row per author.
//
// A count is the signal. Nobody files seventy incident reports in twenty minutes, so the
// number beside an address says more about whether it is a reporter than any single
// message does — and it says it without the tool having to make that judgement, which is
// the point: the classifier already demonstrated it cannot tell reporting from sending.
func cmdReviewGrouped(ctx context.Context, s *chat.Store, all bool, limit int) {
	groups, err := s.ReviewGroups(ctx, all, limit)
	if err != nil {
		die("%v", err)
	}
	if len(groups) == 0 {
		fmt.Println("nothing waiting for review")
		return
	}
	now := time.Now().Unix()
	total := 0
	for _, g := range groups {
		total += g.Count
	}
	fmt.Printf("%d message(s) from %d author(s), flagged and not acted on:\n",
		total, len(groups))
	for _, g := range groups {
		age := dur(time.Duration(now-g.LastAt) * time.Second)
		fmt.Printf("\n  %s  %s/%s  %d message(s), last %s ago\n",
			short(g.IPHash), g.Chain, g.Court, g.Count, age)
		if g.Count > 1 {
			span := dur(time.Duration(g.LastAt-g.FirstAt) * time.Second)
			extra := ""
			if g.Monikers > 1 {
				extra = fmt.Sprintf(", %d different names", g.Monikers)
			}
			if g.Courts > 1 {
				extra += fmt.Sprintf(", across %d courts", g.Courts)
			}
			fmt.Printf("  pattern   %d over %s%s\n", g.Count, span, extra)
		}
		fmt.Printf("  moniker   %s\n", g.Moniker)
		fmt.Printf("  latest    [%d] %s\n", g.LatestID, g.Latest)
	}
	fmt.Printf("\nread one author:  kourtchatctl review -expand -n 200\n")
	fmt.Printf("act on one:       kourtchatctl kick -msg <id> -for 1h -why \"...\"\n")
	fmt.Printf("clear one author: kourtchatctl dismiss -from <address>\n")
}

func cmdDismiss(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("dismiss", flag.ExitOnError)
	from := fs.String("from", "", "clear every queued message from one address hash")
	flags, pos := split(argv)
	_ = fs.Parse(flags)

	// Bulk, because grouping the view without grouping the action would only move the
	// problem: seeing that seventy messages are one flood, then needing seventy commands
	// to clear it, loses at the dismissal step instead of the reading step.
	if *from != "" {
		if len(pos) > 0 {
			die("dismiss takes either an id or -from, not both")
		}
		n, err := s.MarkReviewedFrom(ctx, *from)
		if err != nil {
			die("%v", err)
		}
		fmt.Printf("%d message(s) from %s marked reviewed — nothing was hidden and nobody was kicked\n",
			n, short(*from))
		fmt.Printf("see them again with: kourtchatctl review -all\n")
		return
	}
	if len(pos) != 1 {
		die("dismiss needs one message id, or -from <address hash> — read them from `review`")
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

// cmdPrune applies a retention window, and reports what it refused to touch.
//
// DRY RUN by default, like the scanner's --enforce. Deleting history is the one operation
// here with no undo — `unban` reverses a consequence, nothing reverses a DELETE — so the
// default has to be the one that cannot lose anything.
//
// The refusal counts are printed even when they are zero, because their absence is
// information too: "nothing is waiting for review" is worth reading on the screen where
// somebody is about to delete a month of history.
func cmdPrune(ctx context.Context, s *chat.Store, argv []string) {
	fs := flag.NewFlagSet("prune", flag.ExitOnError)
	age := fs.Duration("older-than", 0, "delete messages older than this, e.g. 720h (required)")
	limit := fs.Int("n", 5000, "how many at most in one pass")
	apply := fs.Bool("apply", false, "actually delete (default: dry run)")
	flags, _ := split(argv)
	_ = fs.Parse(flags)
	if *age <= 0 {
		die("prune needs -older-than, e.g. -older-than 720h for 30 days")
	}

	run := s.PruneDryRun
	if *apply {
		run = s.Prune
	}
	r, err := run(ctx, *age, *limit)
	if err != nil {
		die("%v", err)
	}

	what := "would delete"
	if *apply {
		what = "deleted"
	}
	fmt.Printf("%s        %d message(s) older than %s\n", what, r.Deleted, *age)
	fmt.Printf("kept                 %d unscanned — the scanner has not looked yet\n",
		r.KeptUnscanned)
	fmt.Printf("                     %d waiting for review — see kourtchatctl review\n",
		r.KeptQueued)
	fmt.Printf("                     %d cited by a consequence still in force\n", r.KeptCited)
	fmt.Printf("remaining            %d message(s)", r.Remaining)
	if r.Oldest > 0 {
		fmt.Printf(", oldest %s", time.Unix(r.Oldest, 0).Format("2006-01-02"))
	}
	fmt.Println()

	if !*apply {
		fmt.Printf("\nthis was a DRY RUN. to do it:  kourtchatctl prune -older-than %s -apply\n", *age)
		return
	}
	if r.Deleted == *limit {
		fmt.Printf("\nthe batch limit was reached — run it again to continue\n")
	}
	// Deleting rows reclaims NOTHING on its own, and an operator who pruned to free disk
	// needs to hear that before they go looking for the space. Measured on 40k messages:
	// 7876K main + 7994K WAL before, byte-identical after pruning every row; a checkpoint
	// then freed the WAL and none of the main file; VACUUM INTO returned 56K. Pruning can
	// even make the total temporarily LARGER, because the deletions are journaled first.
	fmt.Printf("\ndisk is NOT reclaimed by deleting. two steps, in order:\n")
	fmt.Printf("  sqlite3 <db> \"PRAGMA wal_checkpoint(TRUNCATE)\"     frees the -wal, no downtime\n")
	fmt.Printf("  sqlite3 <db> \"VACUUM INTO '/tmp/compact.db'\"       frees the main file, then\n")
	fmt.Printf("                                                     stop, swap it in, restart\n")
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

// cmdUnfreeze is the other half of freeze, and its absence was the gap: a mistyped court name
// withdrew a live room with no way back through the tool.
//
// It refuses when the court was not frozen, rather than reporting success. A typo here is as
// likely as a typo in `freeze`, and "dev/oren is back in service" over a court that never left it
// is the same lie one verb along.
// reportReplay explains a consequence that was not recorded, and finds the one that already was.
//
// Consequence returns (0, nil) when the partial unique index on (evidence_id, kind) rejects a
// replay. That is deliberate and load-bearing — it is what stops a crash between "punish" and
// "mark scanned" from walking the ladder — but the tool printed it as a success:
//
//	kicked address daa27c05ac6b for 1h0m0s [consequence 0]
//	reverse it early with: kourtchatctl unban 0
//
// A kick that never happened, an id that cannot exist, and an instruction pointing at it. So a zero
// is reported as what it is, and the row that already covers this evidence is looked up so the
// operator has something real to act on.
// humanDuration renders a machine duration the way a person reads one, because "876000h0m0s" does
// not read as a hundred years and that is exactly the typo it hides.
//
// Measured: `kick -for 876000h` is accepted, and `list` shows "876000h0m0s left". A timeout of a
// hundred years is a ban wearing a kick's label — the tool refuses a MISSING -for with "a timeout
// with no end is a ban", and then accepts one that has no end in practice. Rather than invent a
// policy ceiling, which would be arbitrary wherever it landed and would refuse a legitimate long
// timeout, say what the duration is so the operator sees the extra zero.
func humanDuration(d time.Duration) string {
	// Pluralised, because "about 1 months" is what an operator reads while deciding whether this
	// tool is careless — and this repo had already caught the same blemish once, in the panel's
	// "paused for another 1 hours". Reintroducing it two files later is why it is a helper now.
	say := func(n float64, unit string) string {
		if n == 1 {
			return "about 1 " + unit
		}
		return fmt.Sprintf("about %.0f %ss", n, unit)
	}
	switch {
	case d >= 365*24*time.Hour:
		return say(math.Round(d.Hours()/(365*24)), "year")
	case d >= 30*24*time.Hour:
		return say(math.Round(d.Hours()/(30*24)), "month")
	case d >= 24*time.Hour:
		return say(math.Round(d.Hours()/24), "day")
	case d >= time.Hour:
		return say(math.Round(d.Hours()), "hour")
	case d >= time.Minute:
		return say(math.Round(d.Minutes()), "minute")
	case d >= time.Second:
		return say(math.Round(d.Seconds()), "second")
	}
	return "less than a second, so nobody is kept out at all"
}

// hideNote states the half of a consequence that the duration does not govern.
//
// Measured: a kick of one nanosecond leaves state=ok — nobody is blocked for any measurable time —
// and still hides the author's last ten minutes, indefinitely, until somebody runs unban. The
// duration is presented to the operator as the scope of the action and controls only the posting
// block; the hiding outlasts it and is undone by the same reversal.
func hideNote(id int64) string {
	return fmt.Sprintf("their messages from the last %s are hidden too, and stay hidden until "+
		"`unban %d` — the duration does not govern that half.", chat.HideWindow, id)
}

func replayReport(ctx context.Context, s *chat.Store, hash string, evID int64, kind, verb string) string {
	out := fmt.Sprintf("no new consequence was recorded: message %d already has a %s that has not "+
		"been\nreversed, so this %s would have been a duplicate.\n", evID, kind, verb)
	rows, err := s.ListInfractions(ctx, hash, false, 200)
	if err != nil {
		return out
	}
	for _, r := range rows {
		if r.EvidenceID == evID && r.Kind == kind {
			out += fmt.Sprintf("it is consequence %d, issued %s — `why %d` for the detail, "+
				"`unban %d` to reverse it.\n",
				r.ID, time.Unix(r.CreatedAt, 0).Format(time.RFC3339), r.ID, r.ID)
			break
		}
	}
	return out
}

// cmdHide takes a message out of sight without punishing anybody, which is the other half of
// reveal and was missing.
//
// reveal's own output ends "if that phrase is real rather than a published test vector, hide it
// again and tell its owner" — advice for an action the tool did not offer. The store has had
// HideMessage since the scanner needed it for the reporting carve-out; only the CLI verb was
// absent, so an operator who revealed a message and then realised it was a real key had no way
// back. Guidance the code cannot support is the defect this repo keeps finding in other people's
// documents, committed here in my own.
//
// Three outcomes, told apart rather than collapsed: no such message, already out of sight, or
// hidden now. HideMessage alone cannot distinguish the first two — it requires hidden=0 and says
// only "no visible message" — so existence is checked first.
func cmdHide(ctx context.Context, s *chat.Store, argv []string) {
	_, pos := split(argv)
	if len(pos) != 1 {
		die("hide needs one message id — read it from `review`")
	}
	id, err := strconv.ParseInt(pos[0], 10, 64)
	if err != nil {
		die("%v", err)
	}
	_, _, body, err := s.MessageAuthor(ctx, id)
	if err != nil {
		die("%v", err)
	}
	// The specific sentence for the case we recognise, and the real error otherwise — which is
	// what `reveal` below has always done. Discarding err here meant a hide against a closed or
	// unwritable database reported "already out of sight", sending an operator to `list` to look
	// for a consequence that was never the problem.
	if err := s.HideMessage(ctx, id); err != nil {
		if errors.Is(err, chat.ErrNotVisible) {
			die("message %d exists but is already out of sight — a consequence hides one "+
				"(see `list`) and so does the scanner for a disclosed secret (`reveal` puts "+
				"that back)", id)
		}
		die("%v", err)
	}
	fmt.Printf("message %d is hidden in place: %q\n", id, chat.Preview(body))
	fmt.Printf("nobody was punished for it and its author was told nothing; `reveal %d` undoes this.\n", id)
}

// cmdReveal puts back a message the scanner hid as a disclosed secret.
//
// The scanner hides a valid BIP-39 phrase on sight and does not punish for it, which is right: a
// recovery phrase must leave the room whether it was posted by a victim, a warning or a thief. But
// nothing could undo it, and the case that will actually happen is not the one HideMessage's comment
// weighed — it reasoned about a checksum passing "by luck, one chance in sixteen". A PUBLISHED TEST
// VECTOR is not luck: it is a valid phrase, deliberately typed, by exactly this audience. Somebody
// explaining seed phrases in a crypto court quotes "abandon abandon … about", and both published
// vectors come back secret=true.
//
// So this exists, and it is deliberately awkward in one respect: it prints only a short PREVIEW of
// what it restored. The body may be somebody's actual key, and an operator's terminal and shell
// history are not where that belongs — enough to confirm the id, and `why` for the rest.
func cmdReveal(ctx context.Context, s *chat.Store, argv []string) {
	_, pos := split(argv)
	if len(pos) != 1 {
		die("reveal needs one message id — read it from `review`")
	}
	id, err := strconv.ParseInt(pos[0], 10, 64)
	if err != nil {
		die("%v", err)
	}
	r, err := s.Reveal(ctx, id)
	if err != nil {
		die("%v", err)
	}
	if !r.OK {
		die("message %d is not hidden as a disclosed secret — `unban` restores messages hidden "+
			"by a consequence, and nothing else hides one", id)
	}
	fmt.Printf("message %d is visible again in %s (%s): %q\n", id, r.Court, r.Moniker, r.Preview)
	fmt.Printf("it was hidden because it contains a valid recovery phrase. If that phrase is\n")
	fmt.Printf("real rather than a published test vector, hide it again and tell its owner.\n")
}

func cmdUnfreeze(ctx context.Context, s *chat.Store, argv []string) {
	if len(argv) != 1 {
		die("unfreeze needs CHAIN/COURT, e.g. dev/orem")
	}
	parts := strings.SplitN(argv[0], "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		die("unfreeze needs CHAIN/COURT, e.g. dev/orem")
	}
	lifted, err := s.Unfreeze(ctx, parts[0], parts[1])
	if err != nil {
		die("%v", err)
	}
	if !lifted {
		die("%s is not frozen — nothing to lift (check the spelling against `status`)", argv[0])
	}
	fmt.Printf("%s is back in service: its history is served again and posts are accepted\n", argv[0])
	// Said plainly, because the reason a court was withdrawn may not have gone away.
	fmt.Printf("the freeze is recorded as lifted rather than erased; if it was withheld for a\n")
	fmt.Printf("purge, check that the content should be public again before telling anyone\n")
}

// staleNote judges the age of a heartbeat against the cadence the scanner PROMISED, not against a
// constant of its own.
//
// It used to warn past a fixed five minutes. A scanner polling on `--interval 10m` — a sensible
// choice for a quiet court sharing a GPU with other work — is then permanently "stale — is kourtmod
// running?" while running perfectly, and an operator chases a phantom. Measured: a six-minute-old
// heartbeat, healthy for that configuration, warned.
//
// Three cadences of silence is the bound. One is ordinary — the read can land just before the next
// write — and two is a single missed cycle, which a slow batch explains. Three is a pattern. Floored
// at a minute so the 5s default does not warn on fifteen seconds of nothing.
//
// A cadence of zero means the scanner did not say: an older row, or a caller with no interval. Then
// there is nothing to derive a bound from and the old five minutes is as good an answer as any,
// which is why it survives as the fallback rather than being deleted.
func staleNote(age, every time.Duration) string {
	bound := 5 * time.Minute
	if every > 0 {
		if bound = 3 * every; bound < time.Minute {
			bound = time.Minute
		}
	}
	if age <= bound {
		return ""
	}
	if every > 0 {
		return fmt.Sprintf("  (stale — over %s of silence on a %s cadence; is kourtmod running?)",
			bound, every)
	}
	return "  (stale — is kourtmod running?)"
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
		warn := staleNote(age, time.Duration(h.SeenEvery)*time.Second)
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

	// Loud, and phrased as what it means rather than as a number. An exhausted row leaves
	// the backlog, never gets a verdict, and so never reaches the review queue either —
	// so with every other line on this screen green, this is the only place an outage
	// shows up at all. See chat.Health.Unscannable.
	if h.Unscannable > 0 {
		fmt.Printf("UNSCANNED      %d message(s) gave up after 5 failed attempts and were\n",
			h.Unscannable)
		fmt.Printf("               NEVER classified — nobody looked at them, automatically\n")
		fmt.Printf("               or otherwise. Usually means the model was unreachable.\n")
	}

	// The review queue, here rather than only under `review`, because a queue nobody is
	// told about is a queue nobody reads. `status` is what an operator runs; if the
	// deferred messages are only visible to somebody who already knows to look for them,
	// §7's carve-out is a deferral to nobody.
	waiting, err := s.PendingReview(ctx, false, 500)
	if err != nil {
		die("%v", err)
	}
	if len(waiting) == 0 {
		fmt.Printf("review queue   empty\n")
		return
	}
	// Capped at the same 500 the query is, and says so instead of implying an exact
	// count it did not measure.
	more := ""
	if len(waiting) == 500 {
		more = "+"
	}
	fmt.Printf("review queue   %d%s message(s) flagged and NOT acted on — a person must look\n",
		len(waiting), more)
	fmt.Printf("               kourtchatctl review\n")
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
