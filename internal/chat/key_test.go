package chat

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// LoadKey decides what every public IP tag on the service is computed under, and
// it was at 0% — measured, not guessed. The function's own comment states the
// consequence of the arm that matters: a read-only caller that MINTS instead of
// failing gives "an operator who mistyped --secret-file ... a brand-new key, a
// plausible-looking hash computed under it, and a ban that silently matched
// nobody".
//
// That failure is silent by construction. Every hash still computes, every tag
// still looks like a tag, and the only symptom is bans quietly matching nothing —
// so it cannot be caught by using the thing. It has to be asserted.
//
// The two callers are the two arms: kourtchat passes create=true and is allowed
// to mint on first start; kourtchatctl passes create=false and must refuse.

func TestLoadKeyReadsAKeyFileAndRefusesAShortOne(t *testing.T) {
	dir := t.TempDir()
	s := keyTestStore(t, dir)

	good := filepath.Join(dir, "good.key")
	want := bytes.Repeat([]byte{0xA5}, 32)
	if err := os.WriteFile(good, want, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := LoadKey(s, good, false)
	if err != nil {
		t.Fatalf("a 32-byte key file was refused: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("the key read back differently: %x", got)
	}

	/* SHORT IS REFUSED, NOT PADDED OR ACCEPTED. A 16-byte key still hashes, and
	   the service would run on it — which is the same silent-consequence shape as
	   the minting arm below. */
	short := filepath.Join(dir, "short.key")
	if err := os.WriteFile(short, bytes.Repeat([]byte{1}, 31), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadKey(s, short, true); err == nil {
		t.Fatal("a 31-byte key file was accepted")
	}
}

func TestLoadKeyNeverMintsForAReadOnlyCaller(t *testing.T) {
	dir := t.TempDir()
	s := keyTestStore(t, dir)

	// THE MISTYPED PATH, which is the case the comment is about.
	missing := filepath.Join(dir, "not-here.key")
	_, err := LoadKey(s, missing, false)
	if !errors.Is(err, ErrNoKey) {
		t.Fatalf("a missing key file with create=false gave %v, want ErrNoKey", err)
	}
	if _, statErr := os.Stat(missing); !os.IsNotExist(statErr) {
		t.Fatal("a read-only caller created the key file it was only asked to read")
	}

	// ...and the same refusal with no path at all, where the key would come from
	// the store. kourtchatctl reaches this arm when --secret-file is not given.
	if _, err := LoadKey(s, "", false); !errors.Is(err, ErrNoKey) {
		t.Fatalf("an unset store secret with create=false gave %v, want ErrNoKey", err)
	}
	if _, ok, err := s.SecretIfSet(); err != nil || ok {
		t.Fatal("a read-only caller minted a store secret")
	}
}

func TestLoadKeyMintsOnceAndIsStableAfter(t *testing.T) {
	dir := t.TempDir()
	s := keyTestStore(t, dir)

	path := filepath.Join(dir, "minted.key")
	first, err := LoadKey(s, path, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 32 {
		t.Fatalf("minted a %d-byte key, want 32", len(first))
	}
	if bytes.Equal(first, make([]byte, 32)) {
		t.Fatal("minted an all-zero key")
	}
	/* 0600. The file is the one secret on the box that recovers every address:
	   the comment above the function says the tag and the ban both carry it, and
	   IPv4 is 2^32, so a readable key is seconds of work away from every IP. */
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Fatalf("the minted key file is mode %04o, want 0600", perm)
	}

	/* STABLE ON THE SECOND CALL, which is the property a restart depends on. A
	   fresh key per start would change every public tag and orphan every ban, and
	   it would look exactly like working software. */
	again, err := LoadKey(s, path, true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, again) {
		t.Fatal("a second start minted a different key; every existing tag and ban is now orphaned")
	}
	// ...and a read-only caller can now read what was minted.
	ro, err := LoadKey(s, path, false)
	if err != nil || !bytes.Equal(ro, first) {
		t.Fatalf("a read-only caller could not read the minted key: %v", err)
	}
}

func TestLoadKeyWithNoPathMintsIntoTheStoreAndStaysPut(t *testing.T) {
	dir := t.TempDir()
	s := keyTestStore(t, dir)

	first, err := LoadKey(s, "", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 32 {
		t.Fatalf("minted a %d-byte store key, want 32", len(first))
	}
	again, err := LoadKey(s, "", true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, again) {
		t.Fatal("the store minted a second key over the first")
	}
	// and the read-only arm now succeeds, having refused before it existed
	ro, err := LoadKey(s, "", false)
	if err != nil || !bytes.Equal(ro, first) {
		t.Fatalf("a read-only caller could not read the store key: %v", err)
	}
}

func keyTestStore(t *testing.T, dir string) *Store {
	t.Helper()
	s, err := Open(filepath.Join(dir, "chat.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}
