package chat

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
)

// ErrNoKey means no hashing key exists yet, and the caller asked not to create one.
var ErrNoKey = errors.New("chat: no hashing key exists yet")

// LoadKey resolves the HMAC key both binaries hash addresses with.
//
// It lives here rather than in either command because both of them need the SAME
// answer, and the failure mode of two copies drifting apart is not a build error but a
// silent wrong one: the operator tool would compute hashes that match nothing the
// server ever wrote, `ban` would appear to succeed, and the banned address would keep
// posting. Shared code makes that divergence impossible rather than unlikely.
//
// A file OUTSIDE the data directory is preferred. The database row is the fallback so
// a single-machine run needs no setup, and it is worth being explicit about what that
// costs: hashing addresses defends against a stray copy of the .db file, and a key in
// that same file defends against nothing — a backup, an rsync or a container snapshot
// carries both, and IPv4 is only 2^32, so recovering every address is seconds of work.
//
// create=false is for read-only callers. Minting a key on their behalf would be worse
// than failing: an operator who mistyped --secret-file would get a brand-new key, a
// plausible-looking hash computed under it, and a ban that silently matched nobody.
func LoadKey(store *Store, path string, create bool) ([]byte, error) {
	if path != "" {
		b, err := os.ReadFile(path)
		if err == nil {
			if len(b) < 32 {
				return nil, fmt.Errorf("%s holds %d bytes; the key must be at least 32", path, len(b))
			}
			return b, nil
		}
		if !os.IsNotExist(err) {
			return nil, err
		}
		if !create {
			return nil, fmt.Errorf("%s: %w", path, ErrNoKey)
		}
		k := make([]byte, 32)
		if _, err := rand.Read(k); err != nil {
			return nil, err
		}
		// O_EXCL, so two processes starting together cannot both create it — a lost
		// race would silently lift every consequence and change every public tag.
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return nil, fmt.Errorf("creating %s: %w", path, err)
		}
		defer f.Close()
		if _, err := f.Write(k); err != nil {
			return nil, err
		}
		return k, nil
	}
	if !create {
		key, ok, err := store.SecretIfSet()
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, ErrNoKey
		}
		return key, nil
	}
	return store.Secret(func() []byte {
		k := make([]byte, 32)
		if _, err := rand.Read(k); err != nil {
			panic(err) // a keyless start would make every hash predictable
		}
		return k
	})
}
