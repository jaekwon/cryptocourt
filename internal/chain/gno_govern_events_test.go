//go:build gnochain

package chain

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	ctypes "github.com/gnolang/gno/tm2/pkg/bft/rpc/core/types"
	"github.com/gnolang/gno/tm2/pkg/crypto"
)

// Every event the realm documents, seen coming out of a real transaction.
//
// doc.gno calls these "everything an indexer needs", and an indexer matches on
// the NAME. A typo in one is invisible everywhere else: the realm works, the
// tests pass, the balances are right, and whoever is watching the chain simply
// never sees that kind of thing happen. Transfer and Approval are worse than
// the rest, because those names are the GRC20 wire contract — the whole reason
// this realm keeps its own ledger and conforms on the wire instead of on the
// type.
//
// This can only be done from out here. gno's test stdlib cannot read emitted
// events at all, so the nine documented events had three assertions between
// them — ProposalSettled in the loop test, DelegateChanged in the live one,
// KindOffered in the offerer's. Transfer, Approval, Mint, Burn, ProposalOpened
// and Voted had never been observed leaving the realm.
//
// Fields as well as names, because an event with the right name and the wrong
// contents is the same silence one step later.
func TestIntegrationGovernEmitsWhatAnIndexerNeeds(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	_, aliceAddr := rawClient(t, 1)
	_, bobAddr := rawClient(t, 2)
	realmPath := deployGovern(t, root, rootAddr)

	me, alice, bob := rootAddr.String(), aliceAddr.String(), bobAddr.String()

	// Mint, and the GRC20 names on the way through.
	//
	// A mint emits BOTH "Mint" and a "Transfer" with an empty from, and the
	// Transfer is the one an indexer needs: grc20 declares MintEvent and never
	// emits it, sending a Transfer from nowhere instead, so anything written
	// against the standard reconstructs supply by summing Transfers. Asserting
	// only "Mint" is what let this realm satisfy the claim about names while
	// breaking the thing the names were for.
	mintEvs := emits(t, root, rootAddr, realmPath, "Mint", []string{me, "1000000"},
		"Mint", me, "1000000")
	wantTransferWithEmpty(t, mintEvs, "Mint", "from")

	emits(t, root, rootAddr, realmPath, "Transfer", []string{alice, "1000"},
		"Transfer", me, alice, "1000")
	emits(t, root, rootAddr, realmPath, "Approve", []string{bob, "250"},
		"Approval", me, bob, "250")

	burnEvs := emits(t, root, rootAddr, realmPath, "Burn", []string{"7"},
		"Burn", me, "7")
	wantTransferWithEmpty(t, burnEvs, "Burn", "to")

	// Delegation already had an assertion, inside a test about delegation
	// behaving correctly. Repeated here because this test is the one place the
	// whole set is checked together, and a set with a hole in it is what let
	// six of these go unobserved.
	emits(t, root, rootAddr, realmPath, "Delegate", []string{bob},
		"DelegateChanged", me, bob)

	// And the governance pair. Opening announces the id, the kind and the
	// snapshot epoch; voting announces the weight, which is the number a reader
	// cannot derive from the balance because it is read at a sealed epoch.
	sealCurrentEpoch(t, root, rootAddr)
	res, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Propose",
		Args: []string{"govern:minter", alice, "hand the mint to alice"},
	})
	if err != nil {
		t.Fatalf("Propose: %+v", err)
	}
	id := digitsOf(t, string(res.DeliverTx.Data))
	want(t, fmt.Sprint(res.DeliverTx.Events), "ProposalOpened",
		"ProposalOpened", id, "govern:minter", me)

	// Bob votes: he holds nothing, but the delegation above pointed the whole
	// supply at him, so his weight is real and is what the event must carry.
	//
	// Funded first — a key with no ugnot cannot send, and every account but the
	// root one starts empty.
	bobCl, _ := rawClient(t, 2)
	fundFor(t, root, rootAddr, bobAddr)
	vres, err := bobCl.Call(baseCfgFor(t, bobCl, bobAddr), vm.MsgCall{
		Caller: bobAddr, PkgPath: realmPath, Func: "Vote", Args: []string{id, "abstain"},
	})
	if err != nil {
		t.Fatalf("Vote: %+v", err)
	}
	want(t, fmt.Sprint(vres.DeliverTx.Events), "Voted",
		"Voted", id, bob, "abstain")

	// And a vote that carries a reason puts it on the same event — the only
	// place it exists, since the realm stores none of it.
	//
	// Cast by BOB, not by root: root delegated its whole holding to bob a few
	// lines above, so root is the one address here with no voting power left.
	id2 := digitsOf(t, string(mustCall(t, root, rootAddr, realmPath, "Propose",
		[]string{"govern:minter", bob, "hand the mint to bob"}).DeliverTx.Data))
	res2 := mustCall(t, bobCl, bobAddr, realmPath, "VoteWithReason",
		[]string{id2, "yes", "bob has run the faucet for a year"})
	evs2 := fmt.Sprint(res2.DeliverTx.Events)
	want(t, evs2, "VoteWithReason", "Voted", "reason",
		"bob has run the faucet for a year")

	// And a plain vote carries NO reason attribute at all — not an empty one.
	//
	// That is a deliberate choice with two halves, and nothing was holding
	// either: an empty attribute on every vote would charge every voter gas to
	// say nothing, and it would leave an indexer unable to tell a voter who
	// declined to explain from one whose client cannot ask. A mutation
	// attaching a reason to every plain Vote passed the whole suite, because
	// the only assertion here was that a reason APPEARS when asked for.
	//
	// Cast by ALICE on a proposal of its own: bob holds the delegated supply,
	// so any vote of his decides the question and closes it, and alice's
	// thousand against a million cannot.
	aliceCl, _ := rawClient(t, 1)
	fundFor(t, root, rootAddr, aliceAddr)
	// A different PAYLOAD, not just a different title: the open index is keyed
	// by a digest of kind and payload, so re-proposing "govern:minter alice"
	// is refused as a duplicate of the one opened above.
	id3 := digitsOf(t, string(mustCall(t, root, rootAddr, realmPath, "Propose",
		[]string{"govern:minter", "none", "fix the supply forever"}).DeliverTx.Data))
	if strings.Contains(vres_reasonless(t, aliceCl, aliceAddr, realmPath, id3), "reason") {
		t.Error("a plain vote emitted a reason attribute; an indexer then " +
			"cannot tell silence from an empty answer, and every voter pays " +
			"gas for the emptiness")
	}
}

// vres_reasonless casts a plain vote and returns its rendered events.
func vres_reasonless(t *testing.T, c *gnoclient.Client, addr crypto.Address,
	realmPath, id string,
) string {
	t.Helper()
	return fmt.Sprint(mustCall(t, c, addr, realmPath, "Vote",
		[]string{id, "abstain"}).DeliverTx.Events)
}

// mustCall sends a call and fails the test if it does not land.
func mustCall(t *testing.T, c *gnoclient.Client, addr crypto.Address,
	realmPath, fn string, args []string,
) *ctypes.ResultBroadcastTxCommit {
	t.Helper()
	res, err := c.Call(baseCfgFor(t, c, addr), vm.MsgCall{
		Caller: addr, PkgPath: realmPath, Func: fn, Args: args,
	})
	if err != nil {
		t.Fatalf("%s(%s): %+v", fn, strings.Join(args, ", "), err)
	}
	return res
}

// wantTransferWithEmpty requires a Transfer event carrying an EMPTY key, which
// is how the standard marks the counterparty that does not exist.
//
// Checked on the rendered event text rather than by walking typed attributes,
// which is what the rest of this file does. An attribute renders as `{key
// value}`, so an empty one renders as `{key }` — the key, a space, and the
// closing brace with nothing between. No ordinary transfer produces that,
// because an address is never empty.
//
// Matching `key ""` instead fails against a realm that is emitting correctly.
// Worth keeping the shape in the comment: the rendering is the thing being
// matched, and it is not JSON.
func wantTransferWithEmpty(t *testing.T, evs, what, key string) {
	t.Helper()
	if !strings.Contains(evs, "Transfer") {
		t.Errorf("%s emitted no Transfer at all, so an indexer summing "+
			"Transfers to track supply will never see it:\n%s", what, evs)
		return
	}
	if !strings.Contains(evs, "{"+key+" }") {
		t.Errorf("%s emitted a Transfer without an empty %q, so it does not "+
			"read as a supply change to anything written against grc20:\n%s",
			what, key, evs)
	}
}

// emits calls a function and requires every wanted string in its events.
func emits(t *testing.T, c *gnoclient.Client, addr crypto.Address,
	realmPath, fn string, args []string, wants ...string,
) string {
	t.Helper()
	res, err := c.Call(baseCfgFor(t, c, addr), vm.MsgCall{
		Caller: addr, PkgPath: realmPath, Func: fn, Args: args,
	})
	if err != nil {
		t.Fatalf("%s(%s): %+v", fn, strings.Join(args, ", "), err)
	}
	evs := fmt.Sprint(res.DeliverTx.Events)
	want(t, evs, fn, wants...)
	return evs
}

func want(t *testing.T, evs, what string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(evs, w) {
			t.Errorf("%s did not emit %q:\n%s", what, w, evs)
		}
	}
}

func digitsOf(t *testing.T, out string) string {
	t.Helper()
	start := strings.IndexAny(out, "0123456789")
	if start < 0 {
		t.Fatalf("no proposal id in %q", out)
	}
	end := start
	for end < len(out) && out[end] >= '0' && out[end] <= '9' {
		end++
	}
	return out[start:end]
}
