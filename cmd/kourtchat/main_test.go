package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// THE HASHING KEY'S WARNING, and the case it must NOT fire on.
//
// §3 of CHAT.md said the key was "required to live outside the data directory". Nothing required
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
