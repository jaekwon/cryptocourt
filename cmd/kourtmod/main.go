// Command kourtmod scans court chat for spam, scams and attacks.
//
// It is a separate process from kourtchat and they share only the database. If this
// never runs, chat works — unscanned messages simply accumulate, and
// /api/chat/health reports a backlog and enforcing:false so the page can say so
// rather than implying moderation that is not happening.
//
//	kourtmod --db ./chat.db --model gemma3:4b            # dry run: logs, punishes nothing
//	kourtmod --db ./chat.db --model gemma3:4b --enforce  # applies timeouts
//
// DRY RUN IS THE DEFAULT, deliberately. A small quantised model will misclassify,
// and the way to find out how often is to watch it against real traffic before
// letting it act. Nothing it can do is permanent in any case: automated
// consequences are bounded timeouts, and only an operator can ban.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
	"github.com/jaekwon/kourt/internal/scan"
)

func main() {
	var (
		db       = flag.String("db", "chat.db", "path to the SQLite database, shared with kourtchat")
		ollama   = flag.String("ollama", "http://127.0.0.1:11434", "Ollama base URL")
		model    = flag.String("model", "gemma3:4b", "model tag; must already be pulled")
		batch    = flag.Int("batch", 8, "messages per cycle")
		interval = flag.Duration("interval", 5*time.Second, "pause between cycles when idle")
		numCtx   = flag.Int("num-ctx", 2048, "context window; the default plus the weights is what blows an 8GB budget")
		enforce  = flag.Bool("enforce", false, "actually apply timeouts (default: dry run)")
		once     = flag.Bool("once", false, "scan one batch and exit")
	)
	flag.Parse()
	lg := log.New(os.Stderr, "kourtmod: ", log.LstdFlags)

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
		Store: store, Cls: cls, Enforce: *enforce,
		Batch: *batch, Interval: *interval, Log: lg,
	}

	mode := "DRY RUN — verdicts recorded, nobody punished"
	if *enforce {
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
