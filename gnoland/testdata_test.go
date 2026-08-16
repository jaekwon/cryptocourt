//go:build txtar

// Package gnoland holds the .txtar integration tests: the cryptocourt realms run
// against a real (in-memory) gnoland node, exactly as gno.land's own
// pkg/integration/testdata does. These are the only tests that exercise real
// cross-realm calls, real banker coin movement, real escrow, and the on-chain
// coin invariant — the claims a unit harness cannot fake (testing.SetOriginSend
// declares an envelope without crediting the realm, so in-harness a realm can pay
// out coins that never arrived; here the coins really move).
//
// Run with: make txtar-test   (or: go test -tags txtar ./gnoland/)
//
// TestMain stages the realm sources into $GNOROOT/examples so the scripts'
// `loadpkg gno.land/{p,r}/cryptocourt/...` resolve, then removes them after.
package gnoland

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	integration "github.com/gnolang/gno/gno.land/pkg/integration"
	"github.com/gnolang/gno/gnovm/pkg/gnoenv"
	gno_integration "github.com/gnolang/gno/gnovm/pkg/integration"
	"github.com/rogpeppe/go-internal/testscript"
	"github.com/stretchr/testify/require"
)

func TestCourtTxtar(t *testing.T) {
	t.Parallel()
	p := gno_integration.NewTestingParams(t, "testdata")
	require.NoError(t, integration.SetupGnolandTestscript(t, &p))
	testscript.Run(t, p)
}

// staged is every cryptocourt package the scripts load, in dependency order. The
// /p/ packages map to gno.land/p/cryptocourt/<name>/v0; the realm to
// gno.land/r/cryptocourt/court.
var staged = []struct{ kind, name string }{
	{"p", "checkpoint"}, {"p", "grc20votes"}, {"p", "governor"}, {"p", "twap"},
	{"p", "cshares"}, {"p", "tickbook"}, {"p", "curve"},
	{"r", "court"}, {"r", "courtv2"},
}

func TestMain(m *testing.M) {
	root := gnoenv.RootDir()
	_, thisFile, _, _ := runtime.Caller(0)
	srcRoot := filepath.Join(filepath.Dir(thisFile), "..", "realm")

	var dsts []string
	for _, pk := range staged {
		dst := filepath.Join(root, "examples", "gno.land", pk.kind, "cryptocourt", pk.name)
		if pk.kind == "p" {
			dst = filepath.Join(dst, "v0")
		}
		if err := stagePkg(filepath.Join(srcRoot, pk.kind, pk.name), dst); err != nil {
			panic("txtar staging " + pk.name + ": " + err.Error())
		}
		dsts = append(dsts, dst)
	}

	code := m.Run()

	for _, d := range dsts {
		os.RemoveAll(d)
	}
	os.RemoveAll(filepath.Join(root, "examples", "gno.land", "p", "cryptocourt"))
	os.RemoveAll(filepath.Join(root, "examples", "gno.land", "r", "cryptocourt"))
	os.Exit(code)
}

// stagePkg copies a package's PRODUCTION sources (*.gno except *_test.gno) plus its
// gnomod.toml into dst — test files are never deployed and would not compile on chain.
func stagePkg(src, dst string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() {
			continue
		}
		if n != "gnomod.toml" && !(strings.HasSuffix(n, ".gno") && !strings.HasSuffix(n, "_test.gno")) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(src, n))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dst, n), b, 0o644); err != nil {
			return err
		}
	}
	return nil
}
