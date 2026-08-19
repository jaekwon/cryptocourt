// Command kourtmod scans court chat for spam, scams and attacks.
//
// It is a separate process from kourtchat and they share only the database. If this
// never runs, chat works — unscanned messages simply accumulate, and
// /api/chat/health reports a backlog and enforcing:false so the page can say so
// rather than implying moderation that is not happening.
//
//	kourtmod --db ./chat.db --model gemma3:4b            # dry run: logs, punishes nothing
//	kourtmod --db ./chat.db --model gemma3:4b --dry-run  # the same, said out loud
//	kourtmod --db ./chat.db --model gemma3:4b --enforce  # applies timeouts
//
// DRY RUN IS THE DEFAULT, deliberately. A small quantised model will misclassify,
// and the way to find out how often is to watch it against real traffic before
// letting it act. Nothing it can do is permanent in any case: automated
// consequences are bounded timeouts, and only an operator can ban.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
	"github.com/jaekwon/kourt/internal/scan"
)

// resolveMode decides whether to enforce from the two flags that can say so.
//
// --enforce is the one that changes behaviour; --dry-run exists because the default was
// previously the ONLY way to express a dry run, and a runbook that inherits a default has
// no defence against the default changing. An operator writing a systemd unit should be
// able to state the mode rather than rely on it, and `--dry-run` is what they will reach
// for — it is the near-universal spelling, and CHAT.md named it in backticks for a while
// before it existed, so anybody following the deployment notes got
// "flag provided but not defined" and a daemon that would not start.
//
// The contradiction is REFUSED rather than resolved, and that is the point of having a
// function here at all. Both silent resolutions are worse than not starting:
//
//	enforce wins    somebody who asked for a dry run gets real timeouts applied
//	dry-run wins    somebody who asked for enforcement is moderating nothing, quietly
//
// The second is the failure this whole service is built to avoid — every indicator green
// while nothing is enforced — so guessing is not available. Neither flag, or either one
// alone, is unambiguous and passes through.
func resolveMode(enforce, dryRun bool) (bool, error) {
	if enforce && dryRun {
		return false, errors.New("--enforce and --dry-run contradict each other: pass " +
			"--enforce to apply timeouts, --dry-run to state the default explicitly, or " +
			"neither. Refusing to guess which one you meant")
	}
	return enforce, nil
}

func main() {
	var (
		db       = flag.String("db", "chat.db", "path to the SQLite database, shared with kourtchat")
		ollama   = flag.String("ollama", "http://127.0.0.1:11434", "Ollama base URL")
		model    = flag.String("model", "gemma3:4b", "model tag; must already be pulled")
		batch    = flag.Int("batch", 8, "messages per cycle")
		interval = flag.Duration("interval", 5*time.Second, "pause between cycles when idle")
		numCtx   = flag.Int("num-ctx", 2048, "context window; the default plus the weights is what blows an 8GB budget")
		enforce  = flag.Bool("enforce", false, "actually apply timeouts (default: dry run)")
		dryRun   = flag.Bool("dry-run", false, "explicitly do not apply timeouts; refuses --enforce")
		once     = flag.Bool("once", false, "scan one batch and exit")
	)
	flag.Parse()
	lg := log.New(os.Stderr, "kourtmod: ", log.LstdFlags)

	enforcing, err := resolveMode(*enforce, *dryRun)
	if err != nil {
		lg.Fatal(err)
	}

	store, err := chat.Open(*db)
	if err != nil {
		lg.Fatal(err)
	}
	defer store.Close()

	cls := scan.NewOllama(*ollama, *model)
	cls.NumCtx = *numCtx

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Fail loudly rather than running against a model that is not there. A typo'd
	// tag otherwise looks exactly like a healthy scanner in a quiet room, which is
	// the worst failure a moderation daemon can have.
	if err := cls.Verify(ctx); err != nil {
		lg.Fatal(err)
	}

	sc := &scan.Scanner{
		Store: store, Cls: cls, Enforce: enforcing,
		Batch: *batch, Interval: *interval, Log: lg,
	}

	mode := "DRY RUN — verdicts recorded, nobody punished"
	if enforcing {
		mode = "ENFORCING — timeouts will be applied"
	}
	lg.Printf("model %s at %s, %s", *model, *ollama, mode)

	if *once {
		if err := store.Heartbeat(ctx, sc.Enforce, *interval); err != nil {
			lg.Printf("heartbeat: %v", err)
		}
		n, err := sc.Tick(ctx)
		if err != nil {
			lg.Fatal(err)
		}
		lg.Printf("scanned %d", n)
		return
	}
	if err := sc.Run(ctx); err != nil && ctx.Err() == nil {
		lg.Fatal(err)
	}
}
