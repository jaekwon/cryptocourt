//go:build gnochain

package chain

import (
	"fmt"
	"path"
	"strings"
	"testing"

	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/gnovm/pkg/gnolang"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// A realm that is not govern publishes a power, on a chain.
//
// This is the claim the governor's whole shape rests on, and it has only ever
// been checked from inside package govern — where a test writes to the kind
// registry directly, proving the machinery rather than the claim — or in a
// filetest, which is one process and no chain.
//
// It also closes the only thing this realm emits that nothing asserted.
// KindOffered carries the name, the offerer and all six terms; gno's test
// stdlib cannot read events, and Offer takes a Kind INTERFACE, which MsgCall
// cannot carry. So the only way to see it is a second realm, deployed, calling
// Offer for us.
func TestIntegrationGovernOfferFromAnotherRealm(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)

	// Both fresh, so this compiles today's source on both sides.
	//
	// The tempting shortcut is to deploy govern at its REAL path, because the
	// offerer imports it by name and an import is a literal. That deploys once
	// per node and is "already deployed" forever after, which silently pins the
	// test to whatever govern that node saw first: add an exported function to
	// govern, call it from the offerer, and this fails with `undefined:
	// govern.TextOnly` while every local test passes, because realm-test stages
	// both from source and agrees with itself.
	//
	// An import cannot be uniquified in a FILE. It can be in a MemPackage, which
	// is what AddPackage actually compiles — so the import is rewritten in
	// memory, on the way past.
	governAt := deployGovern(t, root, rootAddr)

	offererPath := path.Dir(governOffererPath) + "/" + runTag() + "/" + path.Base(governOffererPath)
	mempkg, err := gnolang.ReadMemPackage("../../realm/r/offerer", offererPath, gnolang.MPUserProd)
	if err != nil {
		t.Fatalf("read offerer: %v", err)
	}
	rewrote := false
	for _, f := range mempkg.Files {
		if strings.Contains(f.Body, governRealmPath) {
			f.Body = strings.ReplaceAll(f.Body, governRealmPath, governAt)
			rewrote = true
		}
	}
	if !rewrote {
		t.Fatalf("no file in the offerer imports %s, so nothing was pointed at "+
			"the realm this test just deployed", governRealmPath)
	}
	if _, err := root.AddPackage(baseCfgFor(t, root, rootAddr), vm.MsgAddPackage{
		Creator: rootAddr, Package: mempkg,
		MaxDeposit: std.MustParseCoins("500000000ugnot"),
	}); err != nil {
		t.Fatalf("addpkg %s: %+v", offererPath, err)
	}

	// A name nothing has taken. Offer binds a name to its code forever and
	// refuses to rewrite one, so a fixture with a constant name would work
	// exactly once per chain — which is why the offerer takes it as an
	// argument.
	kindName := "greet/" + runTag()
	res, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: offererPath, Func: "OfferNamed",
		Args: []string{kindName},
	})
	if err != nil {
		t.Fatalf("OfferNamed(%s): %+v", kindName, err)
	}

	// The event, which is the whole point of coming out here.
	evs := fmt.Sprint(res.DeliverTx.Events)
	for _, want := range []string{
		"KindOffered",
		kindName, // the name it was published under
		"2000",   // quorum, as the offerer chose it
		"5100",   // threshold
	} {
		if !strings.Contains(evs, want) {
			t.Errorf("the offer did not announce %q:\n%s", want, evs)
		}
	}

	// And govern can be asked about it, by name, from outside. Preview renders
	// the kind's own Describe and says it cannot be proposed yet — which is
	// the correct state for something offered and not adopted, and the
	// distinction the whole two-step exists for.
	prev := qeval(t, root, governAt, `Preview("`+kindName+`", "well met")`)
	if !strings.Contains(prev, "greet the holders with: well met") {
		t.Errorf("Preview does not render the offerer's own Describe:\n%s", prev)
	}
	if !strings.Contains(prev, "not been adopted") {
		t.Errorf("Preview does not say the kind is unadopted, so publishing "+
			"code and being granted authority look the same:\n%s", prev)
	}

	// Offering grants nothing: proposing it is refused until the holders vote.
	if _, err := root.Call(baseCfgFor(t, root, rootAddr), vm.MsgCall{
		Caller: rootAddr, PkgPath: governAt, Func: "Propose",
		Args: []string{kindName, "well met", "say hello"},
	}); err == nil {
		t.Error("an offered kind could be proposed without being adopted")
	} else if !strings.Contains(err.Error(), "offered but not adopted") {
		// Asserted rather than logged. This was a t.Logf, which meant the test
		// accepted any refusal at all and recorded the message as a curiosity —
		// on the one test whose whole subject is the difference between having
		// published a kind and having been granted authority for it. The
		// refusal naming that difference is the observable half of the two-step
		// design.
		t.Errorf("proposing an offered-but-unadopted kind refused with %v, "+
			"which does not say that it is the ADOPTION that is missing", err)
	}
}

const governOffererPath = "gno.land/r/cryptocourt/offerer"
