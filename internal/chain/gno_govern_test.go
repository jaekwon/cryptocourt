//go:build gnochain

package chain

import (
	"path"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/gnovm/pkg/gnolang"
	gnochain "github.com/gnolang/gno/gnovm/stdlibs/chain"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// Deploying the governor is the only thing that compiles it on chain.
//
// Every other check it has runs inside `gno test`, against sources copied into
// $GNOROOT/examples. That catches a great deal and cannot catch the things
// that are only true of a chain: whether the package it imports resolves when
// it is fetched rather than found on disk, whether init() sees a deployer,
// whether the whole thing fits inside a transaction's gas. Until this test the
// govern realm had never been deployed anywhere.
//
// It also pins the deploy ORDER, which is the part that cannot be undone.
// p/kourt/checkpoint/v0 has to exist on chain before r/kourt/govern will
// compile, and a realm cannot be redeployed at its path — so getting the order
// wrong costs the path rather than the transaction.
const (
	governPkgPath    = "gno.land/p/kourt/checkpoint/v0"
	governVotesPath  = "gno.land/p/kourt/grc20votes/v0"
	governEnginePath = "gno.land/p/kourt/governor/v0"
	governRealmPath  = "gno.land/r/kourt/govern"
)

// governDeps is every /p/ the realm imports, in the order a chain needs them.
// Listed once, used by deployGovern and by the ordering test below.
var governDeps = []struct{ dir, path string }{
	{"../../realm/p/checkpoint", governPkgPath},
	{"../../realm/p/grc20votes", governVotesPath},
	{"../../realm/p/governor", governEnginePath},
}

func TestIntegrationGovernDeploys(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)

	// The package goes to its REAL path, not a unique one, because the realm's
	// import names it literally and an import cannot be uniquified. Which means
	// this succeeds once per node and is "already deployed" every run after —
	// not a failure, and the assertion that matters is the realm compiling
	// against it below.
	//
	// The trailing v0 is allowed even though the package is called checkpoint:
	// LastPathElement skips a single version suffix before comparing.
	// Every dependency, in order, because the realm imports more than one now
	// and a chain is the only thing that says so: `gno test` resolves from the
	// examples tree, where they are all staged together, so a missing deploy is
	// invisible locally and fatal on chain.
	for _, dep := range governDeps {
		pkg, err := gnolang.ReadMemPackage(dep.dir, dep.path, gnolang.MPUserProd)
		if err != nil {
			t.Fatalf("read %s: %v", dep.path, err)
		}
		switch _, err := root.AddPackage(baseCfgFor(t, root, rootAddr), vm.MsgAddPackage{
			Creator: rootAddr, Package: pkg,
			MaxDeposit: std.MustParseCoins("500000000ugnot"),
		}); {
		case err == nil:
			t.Logf("deployed %s", dep.path)
		case alreadyDeployed(err):
			// Said out loud, because "it passed" reads the same either way and
			// the re-run branch is the one that is easy to get wrong: if the
			// matching were too narrow this would pass exactly once per node
			// and fail forever after, which looks like a real regression.
			t.Logf("%s was already on chain, which is the expected second-run path", dep.path)
		default:
			t.Fatalf("addpkg %s: %+v", dep.path, err)
		}
	}
	// The realm gets a fresh path every run, so this always compiles the
	// CURRENT sources rather than silently re-testing what a previous run left
	// behind. The tag is a parent element: the last one has to equal the
	// package name.
	realmPath := path.Dir(governRealmPath) + "/" + runTag() + "/" + path.Base(governRealmPath)
	mempkg, err := gnolang.ReadMemPackage("../../realm/r/govern", realmPath, gnolang.MPUserProd)
	if err != nil {
		t.Fatalf("read govern realm: %v", err)
	}
	res, err := root.AddPackage(baseCfgFor(t, root, rootAddr), vm.MsgAddPackage{
		Creator: rootAddr, Package: mempkg,
		MaxDeposit: std.MustParseCoins("5000000000ugnot"),
	})
	if err != nil {
		t.Fatalf("addpkg %s: %+v\n\nIf this says the checkpoint package is not "+
			"available, the dependency was not deployed first — that is the "+
			"ordering this test exists to hold.", realmPath, err)
	}

	// What publishing costs, watched rather than discovered.
	//
	// AddPackage compiles AND stores the source, so both figures scale with the
	// file — comments included, and three quarters of that realm is comments.
	// It grew past a 200,000,000 gas ceiling without anybody noticing, and the
	// symptom was every govern test on this chain failing at once, in about a
	// second each, which reads as the realm being broken rather than as it
	// having got bigger.
	//
	// A ceiling with room, not the figure: it moves whenever a comment does,
	// and a test that fails on prose gets deleted rather than read. What this
	// catches is the doubling, and it names the current cost when it fires so
	// the next person has the number rather than a limit.
	// Halved when the engine moved to /p/: the realm now publishes 68 million
	// against a ceiling that had been six times that, and a ceiling that loose
	// catches nothing. 150 million is about double the current cost, which is
	// what this is for — a doubling is the change worth a build break, and a
	// few percent of comment drift is not.
	const gasCeiling = 150_000_000
	// Both halves of what a launch costs, because a deployer has to fund both
	// and only one of them is gas. The deposit is permanent and much the larger
	// number in ugnot; docs/DESIGN.md carries the pair, and doc.gno's launch
	// order quotes them for the person actually sending the transaction.
	var depositBytes, depositFee int64
	for _, ev := range res.DeliverTx.Events {
		if sd, ok := ev.(gnochain.StorageDepositEvent); ok {
			depositBytes, depositFee = sd.BytesDelta, sd.FeeDelta.Amount
		}
	}
	t.Logf("publishing the realm cost %d gas and %d bytes of storage deposit (%d ugnot)",
		res.DeliverTx.GasUsed, depositBytes, depositFee)
	if res.DeliverTx.GasUsed > gasCeiling {
		t.Errorf("deploying the realm now costs %d gas against a ceiling of %d. "+
			"AddPackage compiles on chain, so this grows with the source; raise "+
			"the ceiling deliberately or find out what got large. Whoever "+
			"launches this needs the figure — docs/DESIGN.md carries it.",
			res.DeliverTx.GasUsed, gasCeiling)
	}
	if depositBytes <= 0 {
		t.Errorf("the deploy reported no StorageDepositEvent, so the figure a " +
			"launch is budgeted against is not being measured at all")
	}

	// init() takes the minter from OriginCaller at deploy. There is no deployer
	// in a gno test harness, so every unit test assigns the package var
	// directly and this is the first time the real thing runs.
	minter := qeval(t, root, realmPath, "Minter()")
	if !strings.Contains(minter, rootAddr.String()) {
		t.Errorf("Minter() = %s, want the deploying address %s — init() did not "+
			"capture the deployer, and nothing that mints is reachable",
			minter, rootAddr.String())
	}

	// The page renders. It is the surface a holder actually meets, and on a
	// realm this fresh it is also the only evidence that the token half came up
	// at all — the supply line reads the checkpointed series through the
	// package that was deployed a moment ago.
	//
	// Asserted on facts about THIS DEPLOYMENT, not on the page's wording.
	//
	// A chain test cannot share constants with a gno realm, so every string it
	// quotes is a copy — and a copy that only runs when somebody has a node
	// running. Renaming a heading broke this test while realm-test stayed green
	// for two commits, which is exactly the failure that division of labour
	// prevents: the realm's suite owns what the page SAYS, and this owns that
	// it renders at all, from a realm that was deployed a moment ago, naming
	// the token and the deployer it captured.
	page := qeval(t, root, realmPath, `Render("")`)
	if len(page) < 50 {
		t.Errorf("the page is %d characters, which is not a page:\n%s", len(page), page)
	}
	if !strings.Contains(page, "COURT") {
		t.Errorf("the page does not name the token:\n%s", page)
	}
	if !strings.Contains(page, rootAddr.String()) {
		t.Errorf("the page does not name the minter it just captured, so either "+
			"init did not run or the page cannot see it:\n%s", page)
	}
}

// alreadyDeployed reports whether AddPackage failed only because the path is
// taken, which for a fixed-path dependency is the normal case on the second
// run and every run after.
func alreadyDeployed(err error) bool {
	s := err.Error()
	return strings.Contains(s, "already exists") ||
		strings.Contains(s, "package already registered") ||
		strings.Contains(s, "duplicate")
}

func qeval(t *testing.T, c *gnoclient.Client, pkgPath, expr string) string {
	t.Helper()
	res, _, err := c.QEval(pkgPath, expr)
	if err != nil {
		t.Fatalf("qeval %s %s: %+v", pkgPath, expr, err)
	}
	return res
}
