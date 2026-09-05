package chat

import "sync"

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
}

func newPulse() *pulse {
	return &pulse{per: map[string]chan struct{}{}, global: make(chan struct{})}
}

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
}

// fireAll wakes every waiter, for the changes that do not name a court.
func (p *pulse) fireAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	close(p.global)
	p.global = make(chan struct{})
	// The per-court channels are left alone: a global wake reaches their waiters
	// through the second channel they are already selecting on, and closing both
	// would wake each waiter twice for one change.
}

// pulseKey names a court. The chain is part of it because a court slug is only
// unique within one — "orem" on dev and "orem" on kourt-1 are two rooms.
func pulseKey(chain, court string) string { return chain + "\x00" + court }
