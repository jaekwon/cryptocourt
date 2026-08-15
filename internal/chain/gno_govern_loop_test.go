//go:build gnochain

package chain

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// epochBlocks mirrors the realm's own constant. Duplicated deliberately: if the
// realm changes it, this test should fail rather than quietly follow, because
// the number is frozen once deployed and a change is a migration rather than an
// edit.
const epochBlocks = 720

// A question asked, weighed and decided, on a chain.
//
// The realm's own tests drive this with an injected clock, which is the only
// way to reach a two-day timelock in a unit test and says nothing about whether
// the same sequence survives real transactions: a snapshot taken at a height
// nobody controls, weight read back out of the checkpoint store through the
// package, a tally settled by arithmetic rather than by a test calling settle.
//
// What this cannot reach is Execute succeeding. The built-in kinds carry a
// two-day timelock — 34,560 blocks — and gnodev makes a block per transaction,
// so getting there costs about an hour of sending. That is the cost of a safe
// default rather than a gap in the design, and the refusal at the boundary IS
// checked below, which is the half that can go wrong silently.
func TestIntegrationGovernProposeAndVoteOnChain(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	realmPath := deployGovern(t, root, rootAddr)

	// Minted BEFORE the epoch turns. A proposal reads the last SEALED epoch, so
	// supply that appears in the same epoch as the question is not in the
	// electorate — which is the anti-flash-loan property, seen from the inside.
	governCall(t, root, rootAddr, realmPath, "Mint", rootAddr.String(), "1000000")

	// Seal whatever epoch that mint landed in, wherever the chain happens to be.
	//
	// Not a fixed height. Advancing to 720 works only on a young chain, where
	// the mint falls in epoch 1 and 720 seals it. gnodev persists, so a later
	// run starts past 720, the mint lands in the current epoch, advancing is a
	// no-op, and the realm refuses the proposal with "nothing was in issue at
	// that epoch" — correctly, because at the last sealed epoch there was
	// nothing.
	//
	// A test that passes on a fresh node and fails on a used one is worse than
	// one that fails always.
	sealCurrentEpoch(t, root, rootAddr)

	t.Logf("height %d, realm reports Epoch() = %s", chainHeight(t),
		strings.TrimSpace(qeval(t, root, realmPath, "Epoch()")))

	id := proposeOnChain(t, root, rootAddr, realmPath,
		"govern:minter", "none", "fix the supply forever")
	t.Logf("proposal id %s, weight at the snapshot: %s", id,
		strings.TrimSpace(qeval(t, root, realmPath,
			"PastVotes(\""+rootAddr.String()+"\", Epoch()-1)")))

	// Weight comes from the checkpoint store, through the package deployed
	// separately, at an epoch chosen by the realm rather than by this test.
	//
	// The vote is decisive, so the proposal settles inside this transaction and
	// the outcome is announced by it. Worth asserting here because an outcome
	// nothing emits is invisible off chain, and this is the ordinary way a
	// proposal ends.
	voteRes, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Vote", Args: []string{id, "yes"},
	})
	if err != nil {
		t.Fatalf("Vote: %+v", err)
	}
	evs := fmt.Sprint(voteRes.DeliverTx.Events)
	for _, want := range []string{"ProposalSettled", "succeeded"} {
		if !strings.Contains(evs, want) {
			t.Errorf("the deciding vote did not announce %q:\n%s", want, evs)
		}
	}

	// One holder with the entire supply clears a 20% quorum and a 66%
	// threshold, and the tally settles on the arithmetic rather than waiting
	// out a week of voting blocks: no remaining vote could change it.
	t.Logf("after voting, State(%s) = %s", id,
		strings.TrimSpace(qeval(t, root, realmPath, "State("+id+")")))
	if got := qeval(t, root, realmPath, "State("+id+")"); !strings.Contains(got, "succeeded") {
		t.Fatalf("State(%s) = %s, want succeeded — a unanimous vote of the whole "+
			"supply did not decide it", id, got)
	}

	// And the timelock holds. This is the half worth having on chain: a delay
	// that failed open would look identical to one that worked, right up until
	// somebody executed a proposal the holders were still reading.
	_, err = root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Execute", Args: []string{id},
	})
	if err == nil {
		t.Fatal("Execute succeeded inside the two-day delay window")
	}
	if !strings.Contains(err.Error(), "still in the delay window") {
		t.Fatalf("Execute inside the delay failed for the wrong reason: %+v", err)
	}

	// Nothing moved, which is what a refused execution has to mean.
	if got := qeval(t, root, realmPath, "Minter()"); !strings.Contains(got, rootAddr.String()) {
		t.Errorf("the minter changed despite the execution being refused: %s", got)
	}
}

// proposeOnChain opens a proposal and returns its id as a string.
//
// The id comes back in the transaction's result rather than from a query: it is
// what Propose returns, and reading it out is the only way to vote on it.
func proposeOnChain(t *testing.T, c *gnoclient.Client, addr crypto.Address, realmPath, kind, payload, title string) string {
	t.Helper()
	res, err := c.Call(baseCfgFor(t, c, addr), vm.MsgCall{
		Caller: addr, PkgPath: realmPath, Func: "Propose",
		Args: []string{kind, payload, title},
	})
	if err != nil {
		t.Fatalf("Propose(%s, %s): %+v", kind, payload, err)
	}
	out := string(res.DeliverTx.Data)
	// The VM returns a typed value: `(1 int64)`. The digits are the id.
	start := strings.IndexAny(out, "0123456789")
	if start < 0 {
		t.Fatalf("Propose returned %q, with no id in it", out)
	}
	end := start
	for end < len(out) && out[end] >= '0' && out[end] <= '9' {
		end++
	}
	return out[start:end]
}

// sealCurrentEpoch moves the chain into the next epoch, so the one just used
// can be voted on.
//
// Measured from wherever the chain IS rather than from zero, which is the whole
// point: gnodev persists between runs, so "far enough" is not a fixed height.
func sealCurrentEpoch(t *testing.T, root *gnoclient.Client, rootAddr crypto.Address) {
	t.Helper()
	h := chainHeight(t)
	advanceToHeight(t, root, rootAddr, (h/epochBlocks+1)*epochBlocks)
}

// advanceToHeight sends cheap transactions until the chain reaches a height.
//
// gnodev makes a block when there is a transaction and not otherwise, so this
// is the only way to move a clock that is measured in blocks. Roughly ten
// blocks a second, so sealing an epoch costs somewhere under seventy seconds
// depending on where in one the chain happens to sit.
func advanceToHeight(t *testing.T, root *gnoclient.Client, rootAddr crypto.Address, target int64) {
	t.Helper()
	_, sink := rawClient(t, 9)
	for h := chainHeight(t); h < target; h = chainHeight(t) {
		if _, err := root.Send(baseCfgFor(t, root, rootAddr), bank.MsgSend{
			FromAddress: rootAddr, ToAddress: sink,
			Amount: std.MustParseCoins("1ugnot"),
		}); err != nil {
			t.Fatalf("advancing the chain at height %d: %+v", h, err)
		}
	}
}

func chainHeight(t *testing.T) int64 {
	t.Helper()
	cl, err := rpcclient.NewHTTPClient(rpcURL)
	if err != nil {
		t.Fatalf("rpc: %v", err)
	}
	st, err := cl.Status(context.Background(), nil)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	return st.SyncInfo.LatestBlockHeight
}
