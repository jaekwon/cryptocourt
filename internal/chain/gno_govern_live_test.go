//go:build gnochain

package chain

import (
	"fmt"
	"path"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/gnovm/pkg/gnolang"
	gnochain "github.com/gnolang/gno/gnovm/stdlibs/chain"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// The token half of the governor, driven by real transactions.
//
// Everything here is checked by the realm's own tests already. What those
// cannot check is that any of it is REACHABLE from a transaction, and that is
// a separate question with its own ways of failing: MsgCall carries arguments
// as strings, so every parameter has to be a scalar the VM will convert, and a
// crossing call needs a real caller rather than a harness override.
//
// It also measures the one number the whole design is built on — what a new
// key costs against what an update costs — which is not observable anywhere
// except on a chain that charges for it.
func TestIntegrationGovernTokenOnChain(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	_, aliceAddr := rawClient(t, 1)
	_, bobAddr := rawClient(t, 2)

	realmPath := deployGovern(t, root, rootAddr)

	// A crossing call, from a transaction, with an int64 parameter arriving as
	// a string. If argument conversion did not work this is where it stops.
	governCall(t, root, rootAddr, realmPath, "Mint", aliceAddr.String(), "1000")

	if got := qeval(t, root, realmPath, "BalanceOf(\""+aliceAddr.String()+"\")"); !strings.Contains(got, "1000") {
		t.Fatalf("BalanceOf after Mint = %s, want 1000", got)
	}
	// Self-delegated by default, which is the property that makes quorum mean
	// what it says. Nobody called Delegate here.
	if got := qeval(t, root, realmPath, "VotesOf(\""+aliceAddr.String()+"\")"); !strings.Contains(got, "1000") {
		t.Fatalf("VotesOf after Mint = %s, want 1000 — a holder who never "+
			"called Delegate has no weight, which is the OZ behaviour this "+
			"realm exists not to have", got)
	}

	// What a new key costs, against what an update costs.
	//
	// Taken from the chain's own accounting rather than by differencing
	// balances: every transaction carries a StorageDepositEvent with the exact
	// bytes and fee. Differencing works too, but it has to subtract a gas fee
	// written down in another file, so the measurement quietly depends on
	// baseCfgFor never changing — a number in two places.
	//
	// This is the number every decision in the checkpoint store was made
	// against.
	// An account this realm has never seen. The realm is deployed at a fresh
	// path every run, so an unused key index has no record in it regardless of
	// what previous runs left on the node.
	_, freshCryptoAddr := rawClient(t, 7)
	freshAddr := freshCryptoAddr.String()

	newKey, newBytes := storageCost(t, root, rootAddr, realmPath, "Mint", freshAddr, "10")
	update, updBytes := storageCost(t, root, rootAddr, realmPath, "Mint", freshAddr, "10")

	t.Logf("first mint to an address (new record): %d ugnot for %d bytes", newKey, newBytes)
	t.Logf("second mint to the same address (update): %d ugnot for %d bytes", update, updBytes)
	if update <= 0 || newKey <= 0 {
		t.Fatalf("deposits came out as %d and %d — no StorageDepositEvent was "+
			"found and these numbers mean nothing", newKey, update)
	}
	// "Far more", not "more". Ten times is well under what this measures and
	// well over what a design built on the opposite assumption would show, so
	// it fails a regression without breaking when the chain reprices bytes.
	// Asserted on BYTES as well as on price. The fee is bytes times a chain
	// parameter, so a chain that reprices storage moves every ugnot figure here
	// and moves no byte figure at all — the design's claim is about size, and
	// this is the form of it that survives a reprice.
	if newBytes < 10*updBytes {
		t.Errorf("a new record was %d bytes and an update %d, a ratio of %.1f — "+
			"the checkpoint store is built on new keys being the expensive "+
			"thing", newBytes, updBytes, float64(newBytes)/float64(updBytes))
	}
	if newKey < 10*update {
		t.Errorf("a new record cost %d and an update cost %d, a ratio of %.1f — "+
			"every choice in the checkpoint store assumes new keys are the "+
			"expensive thing, and at this ratio they are not",
			newKey, update, float64(newKey)/float64(update))
	}

	// A second change within one epoch costs NOTHING.
	//
	// Not "little" — the transaction carries no StorageDepositEvent at all,
	// because the record was rewritten at the same encoded size and there is no
	// delta to charge for. This is the whole argument for quantising the clock
	// into epochs instead of checkpointing per block, and it is the cheapest
	// claim in the design to check: no epoch has to pass for it.
	// The minter holds nothing by default — minting to somebody is not holding
	// anything — so give it something to send.
	governCall(t, root, rootAddr, realmPath, "Mint", rootAddr.String(), "100")
	// Sent to the measurement address rather than to bob: bob's balance is
	// asserted below, and paying him three tokens here to time something moved
	// that assertion out from under itself. Which the suite caught, and which
	// is the argument for a test that says what it expects rather than what it
	// happens to observe.
	governCall(t, root, rootAddr, realmPath, "Transfer", freshAddr, "1")
	_, firstBytes := storageCost(t, root, rootAddr, realmPath, "Transfer", freshAddr, "1")
	_, againBytes := storageCost(t, root, rootAddr, realmPath, "Transfer", freshAddr, "1")
	t.Logf("repeat transfers inside one epoch: %d bytes, then %d", firstBytes, againBytes)
	// This assertion is only worth anything because the mint measurements above
	// came back non-zero: storageCost reports a missing event as zero, quite
	// correctly, so a helper that had stopped reading events at all would pass
	// this line and fail those. Do not reorder them.
	if againBytes != 0 {
		t.Errorf("a repeated transfer inside one epoch charged for %d bytes, "+
			"want 0 — same-epoch coalescing is not working, and every trade is "+
			"paying for a checkpoint nobody asked for", againBytes)
	}

	// Naming yourself as your own delegate, from an address the realm has never
	// seen, writes nothing at all.
	//
	// Everybody is self-delegated already, so the record such a call would
	// create stores a default. Priced here rather than counted in a unit test,
	// because "no key" and "no bytes" are different claims and this is the one
	// the chain charges for.
	lonerClient, lonerAddr := rawClient(t, 8)
	fundFor(t, root, rootAddr, lonerAddr)
	_, selfBytes := storageCost(t, lonerClient, lonerAddr, realmPath, "Delegate", lonerAddr.String())
	if selfBytes != 0 {
		t.Errorf("self-delegating from an empty address wrote %d bytes, want 0",
			selfBytes)
	}
	// Naming somebody else does write, because that is not the default and has
	// to survive until there is something to move. Which also shows the
	// measurement above is not simply blind.
	_, otherBytes := storageCost(t, lonerClient, lonerAddr, realmPath, "Delegate", bobAddr.String())
	t.Logf("delegate to self from nothing: %d bytes; to another: %d", selfBytes, otherBytes)
	if otherBytes <= 0 {
		t.Error("delegating to another address wrote nothing, so the intent is " +
			"lost — or storageCost has stopped reading events")
	}

	// Delegation moves the say and not the money, over a real transaction.
	governCall(t, root, rootAddr, realmPath, "Mint", bobAddr.String(), "500")
	aliceClient, _ := rawClient(t, 1)
	fundFor(t, root, rootAddr, aliceAddr)

	// Captured rather than fired and forgotten: delegation is the only state
	// change in the realm that no other event reveals, so an indexer that
	// cannot see this one cannot track voting power at all. gno's test stdlib
	// has no way to read emitted events, which is why this is asserted here
	// and not in a unit test.
	res, err := aliceClient.Call(baseCfgFor(t, aliceClient, aliceAddr), vm.MsgCall{
		Caller: aliceAddr, PkgPath: realmPath, Func: "Delegate",
		Args: []string{bobAddr.String()},
	})
	if err != nil {
		t.Fatalf("Delegate: %+v", err)
	}
	// DeliverTx.Events, not the Log. The log line renders "events:[]" whatever
	// was emitted, which is a convincing way to be told the wrong thing — it
	// cost a run here, reported as the realm emitting nothing.
	evs := fmt.Sprint(res.DeliverTx.Events)
	for _, want := range []string{"DelegateChanged", aliceAddr.String(), bobAddr.String()} {
		if !strings.Contains(evs, want) {
			t.Errorf("the Delegate transaction did not report %q:\n%s", want, evs)
		}
	}

	if got := qeval(t, root, realmPath, "BalanceOf(\""+aliceAddr.String()+"\")"); !strings.Contains(got, "1000") {
		t.Errorf("delegating moved alice's balance: %s", got)
	}
	if got := qeval(t, root, realmPath, "VotesOf(\""+aliceAddr.String()+"\")"); !strings.Contains(got, "0") {
		t.Errorf("alice kept her votes after delegating them away: %s", got)
	}
	if got := qeval(t, root, realmPath, "VotesOf(\""+bobAddr.String()+"\")"); !strings.Contains(got, "1500") {
		t.Errorf("bob votes %s, want 1500 — alice's 1000 plus his own 500", got)
	}
}

// The governor's entrypoints are reachable from a transaction, and the chain
// has to be old enough to hold a vote.
//
// Both halves are the same fact from opposite sides. A proposal is (kind,
// payload, title) and a vote is (id, choice) — an int64 and a string — because
// MsgCall carries []string and the VM converts only scalars. Reaching the
// realm's OWN refusal is the proof the conversion happened: the message comes
// from inside the function body, so the arguments were marshalled, converted
// and bound before it was produced.
func TestIntegrationGovernEntrypointsAreCallable(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	realmPath := deployGovern(t, root, rootAddr)

	// An int64 parameter, sent as a string, reaching a body that rejects it for
	// its own reasons rather than the VM rejecting it for shape.
	_, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Vote",
		Args: []string{"999", "yes"},
	})
	if err == nil {
		t.Fatal("voting on a proposal that does not exist was accepted")
	}
	if !strings.Contains(err.Error(), "no such proposal") {
		t.Fatalf("Vote(999, \"yes\") failed before reaching the realm: %+v\n\n"+
			"Wanted the realm's own \"no such proposal\". Anything else means "+
			"the int64 never converted, and a proposal id cannot be sent from "+
			"a transaction at all.", err)
	}

	// A fresh chain cannot hold a vote yet, and says so.
	//
	// Voting weight is read at a SEALED epoch, and epoch 1 is not sealed until
	// the chain passes epochBlocks. On gnodev that is 720 transactions, since
	// it only makes a block when there is one; on a real chain it is an hour.
	// Worth pinning: it is a cold start nobody would predict from the source,
	// and the message is the only thing that explains it.
	// Only askable while the chain is young, and a chain passes its first epoch
	// once and never comes back — so this is checked when the height allows and
	// says plainly when it does not. The always-running version of this
	// assertion is TestAChainTooYoungToHaveSealedAnEpochCannotVote in the realm,
	// which drives the electorate directly and does not care what time it is.
	if h := chainHeight(t); h >= epochBlocks {
		t.Logf("height %d is past the first epoch (%d blocks), so the cold "+
			"start is not observable on this node; the realm's own test covers "+
			"it on every run", h, epochBlocks)
		return
	}
	_, err = root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: realmPath, Func: "Propose",
		Args: []string{"govern:minter", "none", "fix the supply"},
	})
	if err == nil {
		t.Fatal("Propose was accepted on a chain with no sealed epoch")
	}
	if !strings.Contains(err.Error(), "too young to vote") {
		t.Fatalf("Propose on a young chain failed for the wrong reason: %+v", err)
	}
}

// ---------------------------------------------------------------- helpers --

// deployGovern publishes every /p/ the realm imports, in dependency order, and
// then the realm itself.
//
// The order is not cosmetic and cannot be undone: AddPackage compiles on chain,
// so an import that does not resolve is a deploy that FAILS, and a realm cannot
// be redeployed at its path. Splitting the ledger out of the realm added a
// second dependency here and nothing local noticed — `gno test` resolves from
// the examples tree, where all of them are staged together. Only a chain says
// which of them a deploy actually needs.
func deployGovern(t *testing.T, root *gnoclient.Client, rootAddr crypto.Address) string {
	t.Helper()
	for _, dep := range governDeps {
		pkg, err := gnolang.ReadMemPackage(dep.dir, dep.path, gnolang.MPUserProd)
		if err != nil {
			t.Fatalf("read %s: %v", dep.path, err)
		}
		if _, err := root.AddPackage(baseCfgFor(t, root, rootAddr), vm.MsgAddPackage{
			Creator: rootAddr, Package: pkg,
			MaxDeposit: std.MustParseCoins("500000000ugnot"),
		}); err != nil && !alreadyDeployed(err) {
			t.Fatalf("addpkg %s: %+v", dep.path, err)
		}
	}
	realmPath := path.Dir(governRealmPath) + "/" + runTag() + "/" + path.Base(governRealmPath)
	mempkg, err := gnolang.ReadMemPackage("../../realm/r/govern", realmPath, gnolang.MPUserProd)
	if err != nil {
		t.Fatalf("read govern realm: %v", err)
	}
	if _, err := root.AddPackage(baseCfgFor(t, root, rootAddr), vm.MsgAddPackage{
		Creator: rootAddr, Package: mempkg,
		MaxDeposit: std.MustParseCoins("500000000ugnot"),
	}); err != nil {
		t.Fatalf("addpkg %s: %+v", realmPath, err)
	}
	return realmPath
}

func governCall(t *testing.T, c *gnoclient.Client, addr crypto.Address, realmPath, fn string, args ...string) {
	t.Helper()
	if _, err := c.Call(baseCfgFor(t, c, addr), vm.MsgCall{
		Caller: addr, PkgPath: realmPath, Func: fn, Args: args,
	}); err != nil {
		t.Fatalf("%s(%s): %+v", fn, strings.Join(args, ", "), err)
	}
}

func ugnotOf(t *testing.T, c *gnoclient.Client, addr crypto.Address) int64 {
	t.Helper()
	acc, _, err := c.QueryAccount(addr)
	if err != nil {
		t.Fatalf("account %s: %v", addr, err)
	}
	return acc.GetCoins().AmountOf("ugnot")
}

func fundFor(t *testing.T, root *gnoclient.Client, rootAddr, to crypto.Address) {
	t.Helper()
	if _, err := root.Send(baseCfgFor(t, root, rootAddr), bank.MsgSend{
		FromAddress: rootAddr, ToAddress: to,
		Amount: std.MustParseCoins("500000000ugnot"),
	}); err != nil {
		t.Fatalf("fund %s: %+v", to, err)
	}
}

// storageCost calls a function and returns what the chain charged for the
// storage it changed, and how many bytes that was.
//
// Read off the StorageDepositEvent the transaction carries. Nothing here has to
// know the gas fee, which is the point: the fee lives in baseCfgFor, and a
// measurement that subtracts it is a measurement that breaks silently when
// somebody edits the other file.
func storageCost(t *testing.T, c *gnoclient.Client, addr crypto.Address, realmPath, fn string, args ...string) (int64, int64) {
	t.Helper()
	res, err := c.Call(baseCfgFor(t, c, addr), vm.MsgCall{
		Caller: addr, PkgPath: realmPath, Func: fn, Args: args,
	})
	if err != nil {
		t.Fatalf("%s(%s): %+v", fn, strings.Join(args, ", "), err)
	}
	for _, ev := range res.DeliverTx.Events {
		if sd, ok := ev.(gnochain.StorageDepositEvent); ok {
			return sd.FeeDelta.Amount, sd.BytesDelta
		}
	}
	// No event means no storage changed, which is a real answer and the one a
	// coalesced write gives: the object was rewritten at the same encoded size,
	// so there is no delta to charge for. Treating its absence as a failure
	// turns the best result the design produces into a broken measurement.
	return 0, 0
}
