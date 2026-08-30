package archive

import (
	"sync"
	"time"
)

// A token bucket per client, so one uploader cannot fill the staging area faster
// than the sweep empties it.
//
// This is the SECOND line, not the first. The real bound on abuse is that staged
// bytes expire unless an on-chain claim references them (see StageTTL) — an
// attacker who defeats this limiter still only rents an hour of disk. The
// limiter exists so they cannot rent a lot of it at once.
const (
	uploadBurst   = 12
	uploadRefill  = 20 * time.Second // one token back per interval
	limiterMaxIPs = 4096
)

type bucket struct {
	tokens int
	last   time.Time
}

type limiter struct {
	mu sync.Mutex
	at map[string]*bucket
}

func newLimiter() *limiter {
	return &limiter{at: make(map[string]*bucket)}
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	b, ok := l.at[key]
	if !ok {
		// A full map must not become a way to evict everyone else's bucket, so
		// once it is full the map stops growing and the sweep below reclaims it.
		if len(l.at) >= limiterMaxIPs {
			l.reapLocked(now)
		}
		if len(l.at) >= limiterMaxIPs {
			// Still full of ACTIVE buckets. Refusing is the safe answer: this is
			// a burst larger than the service is sized for, and letting it
			// through unmetered is the failure this whole file prevents.
			return false
		}
		b = &bucket{tokens: uploadBurst, last: now}
		l.at[key] = b
	}

	if gained := int(now.Sub(b.last) / uploadRefill); gained > 0 {
		b.tokens += gained
		if b.tokens > uploadBurst {
			b.tokens = uploadBurst
		}
		b.last = now
	}
	if b.tokens <= 0 {
		return false
	}
	b.tokens--
	return true
}

// reapLocked drops buckets that have sat full long enough to be indistinguishable
// from a client that never called.
func (l *limiter) reapLocked(now time.Time) {
	idle := uploadRefill * time.Duration(uploadBurst)
	for k, b := range l.at {
		// REFILL FIRST, THEN ASK IF IT IS FULL. This compared the STORED token
		// count, which is only updated inside allow() — so a bucket that had ever
		// spent a token looked permanently non-full here and could never be
		// reclaimed, however long it had been idle. The map then filled and
		// stayed full, and every new client was refused for good: 4096 distinct
		// uploaders and nobody else could ever upload again.
		//
		// Its 0% coverage is what hid it. reapLocked runs only when the map is
		// full, and no test had ever filled it.
		if now.Sub(b.last) <= idle {
			continue
		}
		if b.tokens+int(now.Sub(b.last)/uploadRefill) >= uploadBurst {
			delete(l.at, k)
		}
	}
}
