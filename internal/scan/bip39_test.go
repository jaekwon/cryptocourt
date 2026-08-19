package scan

import (
	"hash/crc32"
	"strings"
	"testing"
)

// THE WORDLIST GUARANTEE, DRIVEN WITH A LIST THAT IS WRONG.
//
// bip39.go says the CRC is checked at init "because a mistyped word would weaken the detector
// silently", and that claim used to be untestable: init either panics or it does not, and nothing
// short of a subprocess can observe the difference. The whole seed-phrase detector rests on this
// list being the canonical one — the file's own history is a 136-word subset that left the
// detector permanently silent while looking implemented — so the check is worth more than trust.
//
// The enforced value also used to exist twice: a string constant a test compared against a copy of
// itself, and init's own separate 0xc1dbd296 literal. Editing the constant moved the test and the
// documentation and left the guarantee where it was.
func TestTheWordlistCheckRejectsAWrongList(t *testing.T) {
	// THE PAIRED POSITIVE, and the one that matters most: the list actually shipped must pass.
	// Without it every refusal below could come from a check that rejects everything.
	if err := verifyWordlist(bip39Words, bip39CRC); err != nil {
		t.Fatalf("the shipped wordlist must satisfy its own check: %v", err)
	}

	t.Run("a single mistyped word is caught", func(t *testing.T) {
		// One letter, in a word the old truncated subset would never have reached.
		bad := strings.Replace(bip39Words, "sausage", "sausige", 1)
		if bad == bip39Words {
			t.Fatal("the fixture did not change anything, so it proves nothing")
		}
		err := verifyWordlist(bad, bip39CRC)
		if err == nil {
			t.Fatal("a mistyped word must be refused; this is the silent weakening the " +
				"comment in bip39.go warns about")
		}
		if !strings.Contains(err.Error(), "crc32") {
			t.Errorf("the error must say what failed, so a build break is diagnosable: %v", err)
		}
	})

	t.Run("a truncated list is caught", func(t *testing.T) {
		words := strings.Fields(bip39Words)
		short := strings.Join(words[:136], " ") // the exact subset this detector once shipped
		if err := verifyWordlist(short, bip39CRC); err == nil {
			t.Fatal("the 136-word subset is how the detector went silent before and must not " +
				"pass its own check")
		}
	})

	// THE WORD-COUNT BRANCH, which the CRC otherwise hides: reaching it needs a list whose CRC
	// is correct AND whose count is wrong, so the expected CRC is passed in rather than read.
	// init passes the constant, so there is still one enforced value.
	t.Run("the right checksum with the wrong word count is still refused", func(t *testing.T) {
		short := "abandon ability able"
		err := verifyWordlist(short, crc32.ChecksumIEEE([]byte(short)))
		if err == nil {
			t.Fatal("a three-word list must not pass the size check")
		}
		if !strings.Contains(err.Error(), "distinct words") {
			t.Errorf("this must fail on the COUNT, not the checksum, or the branch is still "+
				"unreached: %v", err)
		}
	})

	t.Run("duplicates are counted as duplicates", func(t *testing.T) {
		// 2048 words of which only one is distinct: the size check reads distinct words, not
		// fields, so this is refused for the reason it should be.
		dup := strings.TrimSpace(strings.Repeat("abandon ", bip39Size))
		err := verifyWordlist(dup, crc32.ChecksumIEEE([]byte(dup)))
		if err == nil {
			t.Fatal("2048 copies of one word is not a wordlist")
		}
		if !strings.Contains(err.Error(), "distinct") {
			t.Errorf("want the distinctness complaint, got: %v", err)
		}
	})
}
