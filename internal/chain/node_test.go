//go:build gnochain

// Package chain holds the tests that can only be true of a chain.
//
// The gno unit suite runs the realms in a harness. A harness cannot tell you
// whether the source compiles on chain, what a transaction actually costs, what
// an indexer sees, or whether the deploy fits in a block's gas — and those are
// the claims the design rests on. Everything here needs a running node.
//
// Requires gnodev on 127.0.0.1:26657, chain id dev. A bare
// `go test -tags gnochain` skips without one; `make chain-test` sets
// REQUIRE_GNODEV so a missing node fails loudly instead. A silent skip on the
// only target that compiles the realms would report success for a check that
// never ran.
package chain

import (
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	"github.com/gnolang/gno/tm2/pkg/crypto"
)

const (
	rpcURL  = "http://127.0.0.1:26657"
	chainID = "dev"

	// One mnemonic for every account these tests use, indexed by bip39
	// derivation. Well-known and worthless: it is gnodev's own test seed.
	testMnemonic = "source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast"
)

// nodeUp requires a reachable gnodev, or skips.
func nodeUp(t *testing.T) {
	t.Helper()
	c := &http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(rpcURL + "/status")
	if err != nil {
		if os.Getenv("REQUIRE_GNODEV") != "" {
			t.Fatalf("no gnodev on %s (%v) — this run demanded one; start `gnodev` and retry", rpcURL, err)
		}
		t.Skipf("no gnodev on %s (%v) — run `gnodev` and retry", rpcURL, err)
	}
	resp.Body.Close()
}

// rawClient builds a signing client at a bip39 index.
//
// The index is the whole of an account's identity here: index 0 deploys and
// mints, and the rest are holders. Deriving them rather than funding fresh keys
// means an address that never signs needs no balance at all, which is what lets
// a test mint to forty holders cheaply.
func rawClient(t *testing.T, index uint32) (*gnoclient.Client, crypto.Address) {
	t.Helper()
	signer, err := gnoclient.SignerFromBip39(testMnemonic, chainID, "", index, 0)
	if err != nil {
		t.Fatal(err)
	}
	rpc, err := rpcclient.NewHTTPClient(rpcURL)
	if err != nil {
		t.Fatal(err)
	}
	info, err := signer.Info()
	if err != nil {
		t.Fatal(err)
	}
	return &gnoclient.Client{Signer: signer, RPCClient: rpc}, info.GetAddress()
}

// baseCfgFor reads the account's sequence and builds a transaction config.
//
// GasWanted is a ceiling and the fee above it is flat, so a generous ceiling
// costs nothing and a tight one fails a deploy that would otherwise have
// worked. AddPackage COMPILES on chain, so what a deploy costs scales with the
// source — comments included, and these realms carry a great many. The chain's
// own consensus maximum is 10,000,000,000; this leaves slack under it rather
// than sitting against it.
func baseCfgFor(t *testing.T, c *gnoclient.Client, addr crypto.Address) gnoclient.BaseTxCfg {
	t.Helper()
	acc, _, err := c.QueryAccount(addr)
	if err != nil {
		t.Fatalf("account %s: %v", addr, err)
	}
	return gnoclient.BaseTxCfg{
		GasFee: "1000000ugnot", GasWanted: 1_000_000_000,
		AccountNumber: acc.AccountNumber, SequenceNumber: acc.Sequence,
	}
}

// runTag is a tag unique to this process run, used to give each deploy a fresh
// realm path so a run always compiles the code in the working tree rather than
// finding an older copy already on the node.
//
// Lowercase letters only: a realm path segment may not carry digits mid-name.
func runTag() string {
	n := time.Now().UnixNano()
	var b []byte
	for n > 0 {
		b = append(b, byte('a'+n%26))
		n /= 26
	}
	return string(b)
}
