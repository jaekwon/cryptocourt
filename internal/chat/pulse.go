package chat

import (
	"sync"
	"sync/atomic"
)

// A CHANGE SIGNAL, so a reader does not have to ask again to find out that
// nothing happened.
//
// The panel polls: every six seconds it re-reads a court's last fifty rows,
// because that full re-read is what makes a moderator's hide disappear from a
// screen already showing it. That is correct and it is also why a message takes
// up to six seconds to travel between two devices in the same room — the delay
// is the interval, not the network.
//
// A long poll removes the interval without giving up the full re-read: the GET
// holds until something changes, then answers with the same payload it always
// sent. What this file provides is the "something changed" half.
//
// ONE CHANNEL PER COURT, CLOSED RATHER THAN SENT ON. A close wakes every waiter
// at once and cannot block a writer, which is the property that matters here: a
// post must never wait on a reader, and a reader that has gone away must not
// leave a message in a buffer for the next one to receive as if it were its own.
// The channel is replaced in the same lock, so a waiter that arrives after a
// close gets the next one rather than a channel that is already spent.
//
// AND ONE GLOBAL CHANNEL BESIDE IT. Posting names a court; hiding a message,
// revoking a consequence, freezing a court and pruning do not, or name it only
// through rows this package would have to read back to find out. Those fire the
// global signal, every waiter wakes, and each re-reads its own court — a wasted
// wake-up for the courts that did not change, at the cost of one query, and
// never a missed one. Moderation is rare; posts are not, and posts are exact.
//
// NOT PERSISTED, DELIBERATELY. This is a wake-up, not a fact: everything a
// client learns still comes from the store on the next read. A restart drops
// every waiter, their requests end, and their clients poll again — which is the
// behaviour they already had before this file existed.
type pulse struct {
	mu     sync.Mutex
	per    map[string]chan struct{}
	global chan struct{}

	// AND ONE FOR AN OBSERVER OF EVERYTHING, which the two above cannot serve.
	//
	// A reader watches ONE court, so `fire` closes that court's channel and
	// leaves the rest alone — deliberately, because posts are frequent and exact.
	// `global` is the other extreme: it is closed only by fireAll, for the
	// changes that name no court.
	//
	// An IN-PROCESS observer wants neither. The site's own answerer has to hear
	// about a message in ANY room, and it cannot subscribe per-court because it
	// does not know which rooms exist until it looks. Handing it `global` was the
	// bug: MEASURED, an ordinary post fired the per-court channel and left global
	// untouched, so the answerer's subscription never fired at all and it fell
	// back to its fifteen-second tick — while the code around it claimed it
	// reacted in about a second.
	//
	// Closed by BOTH fire and fireAll, so it means "something changed" and
	// nothing narrower. It costs a post one extra close and costs readers
	// nothing: no reader selects on it.
	any chan struct{}

	// changes counts how many times anything has happened anywhere since this
	// process started.
	//
	// A SEQUENCE NUMBER, NOT A STATISTIC. It exists so a reader watching the
	// presence page can tell "something happened" from "your poll timed out"
	// without being told WHAT happened — the number is the only thing published,
	// and one increment carries no court, no name, no location and no content.
	// Two events arriving inside one poll are one increment of two, which the
	// page reads as "at least one thing happened"; nothing is lost that this
	// page is entitled to know.
	//
	// AN ATOMIC BESIDE THE LOCK, not a field inside it, so a reader can compare
	// against it without waiting on a post. The bump happens under the lock
	// because its callers already hold it; the read must not need it.
	//
	// IT RESETS ON RESTART, and that is fine and deliberate: a client comparing
	// against a stale higher number sees a mismatch and treats it as a change,
	// which is exactly right — the process it was talking to is gone.
	changes atomic.Int64
}

func newPulse() *pulse {
	return &pulse{per: map[string]chan struct{}{},
		global: make(chan struct{}), any: make(chan struct{})}
}

// watchAny is the observer's subscription. Like watch, it must be taken BEFORE
// the caller looks at the store, or a change landing in between closes a channel
// nobody was holding and the observer sleeps through it.
func (p *pulse) watchAny() <-chan struct{} {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.any
}

// bumpAny closes and replaces the observer channel. Callers hold the lock.
func (p *pulse) bumpAny() {
	p.changes.Add(1)
	close(p.any)
	p.any = make(chan struct{})
}

// changeCount is the sequence number a client compares against. See changes.
func (p *pulse) changeCount() int64 { return p.changes.Load() }

// watch hands back the two channels a waiter selects on. TAKEN BEFORE THE
// CALLER LOOKS AT THE STORE, always: a post landing between the look and the
// wait would otherwise close a channel nobody was holding yet, and the waiter
// would sleep through the very change it asked about. Reversing those two lines
// is the whole bug, so the comment lives here rather than at the call site.
func (p *pulse) watch(key string) (court, global <-chan struct{}) {
	p.mu.Lock()
	defer p.mu.Unlock()
	c, ok := p.per[key]
	if !ok {
		c = make(chan struct{})
		p.per[key] = c
	}
	return c, p.global
}

// fire wakes everyone watching one court.
func (p *pulse) fire(key string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if c, ok := p.per[key]; ok {
		close(c)
		p.per[key] = make(chan struct{})
	}
	// ...and an observer of everything hears about it even when no reader was
	// watching this court. The `ok` above is why that has to be separate: with no
	// waiter registered for a court there is no channel to close, and an observer
	// that relied on it would hear nothing.
	p.bumpAny()
}

// fireAll wakes every waiter, for the changes that do not name a court.
func (p *pulse) fireAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	close(p.global)
	p.global = make(chan struct{})
	p.bumpAny()
	// The per-court channels are left alone: a global wake reaches their waiters
	// through the second channel they are already selecting on, and closing both
	// would wake each waiter twice for one change.
}

// pulseKey names a court. The chain is part of it because a court slug is only
// unique within one — "orem" on dev and "orem" on kourt-1 are two rooms.
func pulseKey(chain, court string) string { return chain + "\x00" + court }
