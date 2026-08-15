//go:build gnochain

package chain

import (
	"os"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
)

// The whole loop, including the part that changes something.
//
// Propose, vote, wait out the timelock, execute, and check the realm actually
// did the thing. Everything up to the delay has been on chain for a while; the
// delay itself has not, because the built-in kinds hold a decision for two days
// — 34,560 blocks — and gnodev makes a block only when there is a transaction.
// So reaching it costs about an hour of sending, which is why this is behind an
// environment variable rather than in chain-test.
//
// It is worth running anyway, once, because everything below the delay is a
// different claim from everything above it: that a Kind's Do runs, that its
// effect persists, and that the proposal ends up executed rather than merely
// decided.
func TestIntegrationGovernExecutesAfterTheDelay(t *testing.T) {
	if os.Getenv("SLOW_EXECUTE") == "" {
		t.Skip("SLOW_EXECUTE unset: this waits out a 34,560-block timelock")
	}
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	realmPath := deployGovern(t, root, rootAddr)

	governCall(t, root, rootAddr, realmPath, "Mint", rootAddr.String(), "1000000")
	sealCurrentEpoch(t, root, rootAddr)

	id := proposeOnChain(t, root, rootAddr, realmPath,
		"govern:minter", "none", "give up the mint forever")
	governCall(t, root, rootAddr, realmPath, "Vote", id, "yes")
	if got := qeval(t, root, realmPath, "State("+id+")"); !strings.Contains(got, "succeeded") {
		t.Fatalf("State(%s) = %s, want succeeded", id, got)
	}

	// The minter is still there, because deciding is not doing.
	if got := qeval(t, root, realmPath, "Minter()"); !strings.Contains(got, rootAddr.String()) {
		t.Fatalf("the minter changed before the proposal executed: %s", got)
	}

	// Wait it out. About an hour.
	ready := chainHeight(t) + 34_560 + 10
	t.Logf("waiting out the timelock: height %d, executing at %d", chainHeight(t), ready)
	advanceToHeight(t, root, rootAddr, ready)

	if _, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Execute", Args: []string{id},
	}); err != nil {
		t.Fatalf("Execute after the delay: %+v", err)
	}

	if got := qeval(t, root, realmPath, "State("+id+")"); !strings.Contains(got, "executed") {
		t.Fatalf("State(%s) = %s, want executed", id, got)
	}
	// And the kind's Do actually did it: the mint is gone, permanently.
	if got := qeval(t, root, realmPath, "Minter()"); !strings.Contains(got, `("" `) {
		t.Errorf("Minter() = %s, want empty — the handler ran but its effect did "+
			"not stick", got)
	}
	if _, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Mint",
		Args: []string{rootAddr.String(), "1"},
	}); err == nil {
		t.Error("minting still works after the holders voted the power away")
	} else if !strings.Contains(err.Error(), "supply is fixed") {
		t.Errorf("minting failed for the wrong reason: %+v", err)
	}
}
