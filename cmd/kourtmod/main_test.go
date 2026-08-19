package main

import (
	"strings"
	"testing"
)

// The two flags that can express the enforcement mode, in all four combinations.
//
// Written as a table because the refusal is the interesting arm and a table of refusals
// proves nothing on its own: a resolver that rejected everything would satisfy the
// contradiction case and break every real invocation. So each refusal sits beside the
// ordinary inputs it must NOT refuse — which is every other row here.
func TestTheEnforcementModeIsUnambiguousOrRefused(t *testing.T) {
	for _, c := range []struct {
		name      string
		enforce   bool
		dryRun    bool
		want      bool
		wantError bool
	}{
		{"neither flag is a dry run, which is the documented default", false, false, false, false},
		{"--dry-run alone states that default rather than inheriting it", false, true, false, false},
		{"--enforce alone applies timeouts", true, false, true, false},
		{"both together are refused, because either guess is a lie about what was asked",
			true, true, false, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveMode(c.enforce, c.dryRun)
			if c.wantError {
				if err == nil {
					t.Fatalf("--enforce with --dry-run must refuse to start; got enforcing=%v "+
						"and no error, which silently picks one of two opposite intentions", got)
				}
				// And it must not enforce on the way out. A refusal that returned true would
				// apply timeouts if a caller ever logged the error and carried on.
				if got {
					t.Error("the refused case must not return enforcing=true")
				}
				return
			}
			if err != nil {
				t.Fatalf("enforce=%v dry-run=%v is unambiguous and must be accepted: %v",
					c.enforce, c.dryRun, err)
			}
			if got != c.want {
				t.Errorf("enforce=%v dry-run=%v: got enforcing=%v, want %v",
					c.enforce, c.dryRun, got, c.want)
			}
		})
	}
}

// The message has to tell the operator what to do instead, because they are reading it in a
// terminal with a daemon that just refused to start. "invalid flags" would leave them
// guessing which of the two to drop.
func TestTheRefusalNamesBothFlagsAndTheWayOut(t *testing.T) {
	_, err := resolveMode(true, true)
	if err == nil {
		t.Fatal("expected a refusal")
	}
	for _, want := range []string{"--enforce", "--dry-run", "neither"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal must mention %q so the operator knows what to change; got: %s",
				want, err)
		}
	}
}
