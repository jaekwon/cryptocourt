package chat

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// CHAT.md IS THE OPERATOR'S RUNBOOK, AND A FLAG IT NAMES THAT DOES NOT EXIST STOPS A DAEMON.
//
// This is the paneldrift shape again — two definitions of one thing, in two files, with a
// build that cannot see the mismatch — but the failure is worse than a wrong number on a
// screen. Go's flag package does not ignore an unknown flag: it prints "flag provided but not
// defined" and exits 2. So a stale flag name in the deployment notes is not a documentation
// blemish, it is a process that will not start, discovered at the moment somebody is deploying.
//
// It had already happened. CHAT.md said "`--dry-run` is the default" for some time while
// kourtmod defined only --enforce, so an operator following the notes and stating the safe mode
// explicitly — the careful thing to do in a systemd unit — got exit 2 and no scanner. It was
// found by sweeping every backticked identifier in the document against the source, not by
// anything that ran, which is why it is worth a test rather than a one-off fix.
//
// The direction checked is one-way on purpose: every flag the DOCUMENT names must exist. The
// reverse — every flag the code defines must be documented — is a different and much weaker
// property, since --batch and --interval are ordinary tuning knobs that need no prose.
func TestEveryFlagTheRunbookNamesActuallyExists(t *testing.T) {
	root := filepath.Join("..", "..")
	doc, err := os.ReadFile(filepath.Join(root, "CHAT.md"))
	if err != nil {
		t.Fatalf("CHAT.md is this service's runbook and must be readable: %v", err)
	}

	// Every flag any of our binaries defines. Var forms included so a future refactor to
	// flag.StringVar does not quietly empty this set and make the test vacuous.
	defined := map[string]bool{}
	decl := regexp.MustCompile(`flag\.[A-Za-z]+(?:Var)?\((?:&[A-Za-z_][A-Za-z0-9_.]*,\s*)?"([a-z0-9-]+)"`)
	cmds, err := filepath.Glob(filepath.Join(root, "cmd", "*", "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) == 0 {
		t.Fatal("no command sources found; this test cannot verify anything")
	}
	for _, p := range cmds {
		src, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range decl.FindAllSubmatch(src, -1) {
			defined[string(m[1])] = true
		}
	}
	// kourtchatctl does NOT use the flag package — it parses its own arguments, so its accepted
	// names live in a switch on strings.TrimLeft(f, "-") rather than in a declaration. Missing
	// this second authority would make the check report --older-than and --secret-file as
	// undefined, which is the false-positive direction and the one that gets a guard deleted.
	ctl, err := os.ReadFile(filepath.Join(root, "cmd", "kourtchatctl", "main.go"))
	if err != nil {
		t.Fatal(err)
	}
	if sw := regexp.MustCompile(`(?s)switch strings\.TrimLeft\(\w+, "-"\) \{.*?\n\t\}`).Find(ctl); sw != nil {
		for _, m := range regexp.MustCompile(`"([a-z0-9-]+)"`).FindAllSubmatch(sw, -1) {
			defined[string(m[1])] = true
		}
	}

	// GUARD THE FIXTURE'S OWN PRECONDITIONS. If either scan stops matching, `defined` loses
	// entries and every documented flag looks missing — loud, but the opposite mistake is the
	// dangerous one, so both authorities are pinned by a name only they can supply.
	if !defined["enforce"] || !defined["db"] {
		t.Fatalf("the flag-declaration scan is broken: it did not find --enforce and --db, "+
			"which certainly exist. Found %d flags: %v", len(defined), keysOf(defined))
	}
	if !defined["older-than"] || !defined["secret-file"] {
		t.Fatalf("the kourtchatctl argument scan is broken: it did not find --older-than and "+
			"--secret-file, which that tool accepts. Found %d: %v", len(defined), keysOf(defined))
	}

	// Flags as the document writes them: in backticks, leading dashes, nothing else inside.
	named := regexp.MustCompile("`(--[a-z0-9-]+)`").FindAllSubmatch(doc, -1)
	if len(named) == 0 {
		t.Fatal("CHAT.md names no flags in backticks at all; either the runbook lost its " +
			"deployment notes or this pattern no longer matches how they are written")
	}
	seen := map[string]bool{}
	var missing []string
	for _, m := range named {
		f := strings.TrimPrefix(string(m[1]), "--")
		if seen[f] {
			continue
		}
		seen[f] = true
		if !defined[f] {
			missing = append(missing, "--"+f)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("CHAT.md names %d flag(s) that no binary defines: %v\n"+
			"Go's flag package exits 2 on an unknown flag, so each of these is a documented "+
			"invocation that will not start. Either add the flag or fix the prose.\n"+
			"Defined: %v", len(missing), missing, keysOf(defined))
	}
	t.Logf("%d distinct flags named in CHAT.md, all defined; %d defined in total",
		len(seen), len(defined))
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// The same one-way check for the OTHER thing CHAT.md hands an operator to type: the
// kourtchatctl verbs. A renamed verb is a smaller failure than a bad flag — the CLI prints its
// usage rather than exiting silently — but the runbook is still wrong, and this file is where
// that gets noticed.
func TestEveryOperatorVerbTheRunbookNamesActuallyExists(t *testing.T) {
	root := filepath.Join("..", "..")
	doc, err := os.ReadFile(filepath.Join(root, "CHAT.md"))
	if err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile(filepath.Join(root, "cmd", "kourtchatctl", "main.go"))
	if err != nil {
		t.Fatal(err)
	}

	// The dispatch switch is the authority on what verbs exist.
	sw := regexp.MustCompile(`(?s)switch args\[0\] \{.*?\n\t\}`).Find(src)
	if sw == nil {
		t.Skip("kourtchatctl no longer dispatches through a switch; re-derive this check")
	}
	verbs := map[string]bool{}
	for _, m := range regexp.MustCompile(`case ((?:"[a-z-]+"(?:,\s*)?)+):`).FindAllSubmatch(sw, -1) {
		for _, q := range regexp.MustCompile(`"([a-z-]+)"`).FindAllSubmatch(m[1], -1) {
			verbs[string(q[1])] = true
		}
	}
	if len(verbs) < 5 {
		t.Fatalf("the verb scan found only %d verbs (%v); it is broken, because this tool has "+
			"had more than five for a long time", len(verbs), keysOf(verbs))
	}

	// `kourtchatctl <verb>` as the document writes it.
	named := regexp.MustCompile("`kourtchatctl ([a-z-]+)").FindAllSubmatch(doc, -1)
	if len(named) == 0 {
		t.Fatal("CHAT.md shows no kourtchatctl invocations; the operator section is the reason " +
			"this tool exists, so this pattern is probably stale rather than the document empty")
	}
	seen, missing := map[string]bool{}, []string(nil)
	for _, m := range named {
		v := string(m[1])
		if seen[v] {
			continue
		}
		seen[v] = true
		if !verbs[v] {
			missing = append(missing, v)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("CHAT.md tells an operator to run %d kourtchatctl verb(s) that do not exist: "+
			"%v\nActual verbs: %v", len(missing), missing, keysOf(verbs))
	}
	t.Logf("%d distinct verbs shown in CHAT.md, all dispatched; %d exist in total",
		len(seen), len(verbs))
}
