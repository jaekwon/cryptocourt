package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// THE HASHING KEY'S WARNING, and the case it must NOT fire on.
//
// internal/chat/clientip.go said the key was "required to live outside the data directory" — a
// code comment, not CHAT.md, which only ever said "should". Nothing required
// it, nothing checked it, and the DEFAULT is the case that fails: with no --secret-file the key
// becomes a row in the database, so one copy of that file carries both the address hashes and the
// means to reverse them. The process said nothing about it at startup, while announcing an
// unmoderated chat two lines later — so the one defence that was silently absent was the one
// nobody was told about.
//
// A warning that fires on a correct setup is a warning an operator learns to skip, which is why
// the negative cases below carry as much weight as the positive ones.
func TestKeyWarningFiresOnlyWhenTheKeyIsUnprotected(t *testing.T) {
	for _, c := range []struct {
		name       string
		secretFile string
		db         string
		wantWarn   bool
		contains   string
	}{
		{
			name: "no secret file: the key lives in the database",
			db:   "/var/lib/kourt/chat.db", wantWarn: true, contains: "/var/lib/kourt/chat.db",
		},
		{
			name:       "key beside the database",
			secretFile: "/var/lib/kourt/ip.key", db: "/var/lib/kourt/chat.db",
			wantWarn: true, contains: "same directory",
		},
		{
			name:       "key elsewhere, which is the point",
			secretFile: "/etc/kourt/ip.key", db: "/var/lib/kourt/chat.db",
			wantWarn: false,
		},
		{
			name:       "both bare filenames, so both in the working directory",
			secretFile: "ip.key", db: "chat.db",
			wantWarn: true, contains: "same directory",
		},
		{
			name:       "mixed relative and absolute resolving to one directory",
			secretFile: "/var/lib/kourt/../kourt/ip.key", db: "/var/lib/kourt/chat.db",
			wantWarn: true, contains: "same directory",
		},
		{
			name:       "a subdirectory is NOT the same directory",
			secretFile: "/var/lib/kourt/keys/ip.key", db: "/var/lib/kourt/chat.db",
			wantWarn: false,
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := keyWarning(c.secretFile, c.db)
			if c.wantWarn && got == "" {
				t.Errorf("keyWarning(%q, %q) said nothing; this configuration means a single "+
					"file or directory carries both the hashes and the key",
					c.secretFile, c.db)
			}
			if !c.wantWarn && got != "" {
				t.Errorf("keyWarning(%q, %q) = %q; warning on a correct setup is how a warning "+
					"gets ignored", c.secretFile, c.db, got)
			}
			if c.contains != "" && !strings.Contains(got, c.contains) {
				t.Errorf("the message must name what is wrong: %q does not contain %q",
					got, c.contains)
			}
			// Every warning points at the section that explains the consequence, because a
			// warning nobody can act on is noise.
			if got != "" && !strings.Contains(got, "CHAT.md") {
				t.Errorf("a warning must say where to read about it: %q", got)
			}
		})
	}
}

// A subdirectory case worth its own assertion, because "same directory" is easy to implement as a
// prefix test and a prefix test is wrong: /var/lib/kourt-backup would match /var/lib/kourt.
func TestKeyWarningDoesNotConfuseASiblingDirectoryForTheSameOne(t *testing.T) {
	for _, pair := range [][2]string{
		{"/var/lib/kourt-backup/ip.key", "/var/lib/kourt/chat.db"},
		{"/var/lib/kourtx/ip.key", "/var/lib/kourt/chat.db"},
	} {
		if got := keyWarning(pair[0], pair[1]); got != "" {
			t.Errorf("keyWarning(%q, %q) = %q; those are different directories",
				pair[0], pair[1], got)
		}
	}
	// And the true positive it must still catch, expressed the way an operator would type it.
	dir := t.TempDir()
	if got := keyWarning(filepath.Join(dir, "ip.key"), filepath.Join(dir, "chat.db")); got == "" {
		t.Error("a key and a database in one directory must warn")
	}
}

// THE FILE-MODE WARNING, and the setup it must stay quiet about.
//
// Measured against the real server before chat.Open was changed: with --secret-file pointing
// elsewhere, the key was 0600 and chat.db, chat.db-wal and chat.db-shm were all -rw-r--r--,
// because SQLite creates a database 0644 under the usual umask. In the DEFAULT configuration
// there is no --secret-file and the hashing key is a row in that same world-readable file, so
// any local user could read both the address hashes and the key that reverses them.
//
// Open now creates a new database 0600 and SQLite copies that onto -wal and -shm — verified
// live, all four files came back -rw------- while an ordinary post and GET still worked. This
// warning is for the databases that already exist, which keep the mode they were given.
func TestTheFileModeWarningAndWhatItMustNotWarnAbout(t *testing.T) {
	write := func(t *testing.T, path string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(path, []byte("x"), mode); err != nil {
			t.Fatal(err)
		}
		// WriteFile applies the umask, so set the mode explicitly or the fixture measures the
		// umask of whoever ran the tests rather than the case it means to.
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("a 0600 database is the correct setup and must be silent", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "chat.db")
		write(t, db, 0o600)
		if w := modeWarning(db, "/etc/kourt/key"); w != "" {
			t.Errorf("a correctly-moded database must not warn; got: %s", w)
		}
	})

	t.Run("a database nobody has created yet must be silent", func(t *testing.T) {
		// chat.Open diagnoses a bad path far better than this could, and a warning here would
		// fire before the real diagnosis and bury it.
		if w := modeWarning(filepath.Join(t.TempDir(), "absent.db"), ""); w != "" {
			t.Errorf("a missing database is not this warning's business; got: %s", w)
		}
	})

	t.Run("a 0644 database is named, with the fix", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "chat.db")
		write(t, db, 0o644)
		w := modeWarning(db, "/etc/kourt/key")
		if w == "" {
			t.Fatal("a world-readable database must be reported")
		}
		for _, want := range []string{db, "0644", "chmod 600"} {
			if !strings.Contains(w, want) {
				t.Errorf("the warning must contain %q so it is actionable; got: %s", want, w)
			}
		}
	})

	t.Run("a group-readable database counts too", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "chat.db")
		write(t, db, 0o640)
		if modeWarning(db, "/etc/kourt/key") == "" {
			t.Error("0640 lets another account read every message body; it must be reported")
		}
	})

	// THE HALF-FIXED CASE, and the reason all three files are checked. An operator who reads a
	// warning about chat.db, runs chmod on that alone and watches the warning clear would have
	// protected a file that in WAL mode can be nothing but a header, while every row stayed
	// readable in the -wal beside it.
	t.Run("a tightened main file with a loose WAL still warns, and names the WAL", func(t *testing.T) {
		dir := t.TempDir()
		db := filepath.Join(dir, "chat.db")
		write(t, db, 0o600)
		write(t, db+"-wal", 0o644)
		w := modeWarning(db, "/etc/kourt/key")
		if w == "" {
			t.Fatal("the rows live in the WAL; a loose WAL must be reported even when the " +
				"main file is closed")
		}
		if !strings.Contains(w, "chat.db-wal") {
			t.Errorf("the warning must name the WAL, or the operator cannot act on it; got: %s", w)
		}
		if strings.Contains(w, "chat.db (") {
			t.Errorf("the main file is 0600 and must not be listed as loose; got: %s", w)
		}
	})

	// The key clause is conditional, and both directions matter: claiming the key is in the
	// database when it is not would send an operator to rotate something that was never exposed.
	//
	// It fires on the same condition as keyWarning, so on screen the two always appear together
	// and the sentence is redundant. That is deliberate — see modeWarning — because a log line
	// gets read on its own. Asserted here so the redundancy cannot be tidied away by accident.
	t.Run("the key clause tracks whether the key is actually in there", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "chat.db")
		write(t, db, 0o644)
		withKey := modeWarning(db, "")
		if !strings.Contains(withKey, "reverse the address hashes") {
			t.Errorf("with no --secret-file the key is in that file and the warning must say "+
				"so; got: %s", withKey)
		}
		separate := modeWarning(db, "/etc/kourt/key")
		if strings.Contains(separate, "reverse the address hashes") {
			t.Errorf("with a separate --secret-file the hashes are not reversible from this "+
				"file, and saying they are would send an operator to rotate a key that was "+
				"never exposed; got: %s", separate)
		}
	})
}

// THE COUNTRY HEADER'S WARNING, and the three configurations it must stay quiet about.
//
// The header is only believed from a trusted proxy now. Without --behind-proxy there is no
// trusted proxy, so honouring it would let every client choose the flag beside its own name —
// which is what happened before it was gated. Flags going quiet is the safe outcome and a
// visible one, since an operator who set the flag deliberately would otherwise be left
// wondering where the flags went.
func TestTheCountryHeaderWarningFiresOnlyWhereTheHeaderIsIgnored(t *testing.T) {
	for _, c := range []struct {
		name    string
		header  string
		proxy   bool
		wantMsg bool
	}{
		{"set without --behind-proxy: ignored, so say so", "CF-IPCountry", false, true},
		{"set with --behind-proxy: honoured, nothing to report", "CF-IPCountry", true, false},
		{"not set at all: no flags either way, and no warning", "", false, false},
		{"not set, behind a proxy: still nothing to report", "", true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			w := countryWarning(c.header, c.proxy)
			if c.wantMsg && w == "" {
				t.Fatal("a header that will be ignored must be reported at startup")
			}
			if !c.wantMsg && w != "" {
				t.Fatalf("nothing is wrong with this configuration; got: %s", w)
			}
			if !c.wantMsg {
				return
			}
			// Actionable: name the flag, say flags are off, and give the way out.
			for _, want := range []string{c.header, "--behind-proxy", "No flags"} {
				if !strings.Contains(w, want) {
					t.Errorf("the warning must mention %q; got: %s", want, w)
				}
			}
		})
	}
}
