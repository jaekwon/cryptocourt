package governor

// The governor's own kinds act on the governor, and take it as an argument.
//
// They cannot hold one. A kind is a value in that governor's own registry, so a
// back-pointer is a reference cycle — and the VM refuses to finalize it:
//
//	unexpected unreal object: type=*gnolang.HeapItemValue ... isNewReal=true
//
// Every test passed and the realm's own filetests wrote their storage; the
// panic came afterwards, at persistence, which is the one place a cycle shows
// up and the reason it survived being reasoned about. So the built-ins are
// stateless values and the engine hands them the governor at the moment it
// dispatches.
//
// The three methods mirror Kind's, minus the realm token: a built-in acts on
// the registry rather than on the world, so it has no use for a sub-realm and
// is never given one.
type builtin interface {
	Name() string
	describe(g *Governor, payload string) string
	check(g *Governor, payload string) error
	run(g *Governor, dispatch Dispatch, payload string) error
}

// asBuiltin reports whether a kind is one of the governor's own.
//
// A type assertion rather than a name check. The reserved prefix says what a
// kind is CALLED and Offer refuses it, but the dispatch has to be decided by
// what a kind IS — a nominal check is the one thing an impostor cannot satisfy,
// which is the same argument grc20's IsCanonicalTeller makes.
func asBuiltin(k Kind) (builtin, bool) {
	b, ok := k.(builtin)
	return b, ok
}

// The Kind side of a built-in, so it satisfies the interface the registry
// stores. Reached only through the engine, which checks asBuiltin first.
func (k adoptKind) Describe(payload string) string { return "" }
func (k adoptKind) Check(payload string) error     { return errBuiltinNeedsEngine }
func (k adoptKind) Do(_ int, rlm realm, payload string) error {
	return errBuiltinNeedsEngine
}

func (k retireKind) Describe(payload string) string { return "" }
func (k retireKind) Check(payload string) error     { return errBuiltinNeedsEngine }
func (k retireKind) Do(_ int, rlm realm, payload string) error {
	return errBuiltinNeedsEngine
}

func (k rulesKind) Describe(payload string) string { return "" }
func (k rulesKind) Check(payload string) error     { return errBuiltinNeedsEngine }
func (k rulesKind) Do(_ int, rlm realm, payload string) error {
	return errBuiltinNeedsEngine
}

func (k batchKind) Describe(payload string) string { return "" }
func (k batchKind) Check(payload string) error     { return errBuiltinNeedsEngine }
func (k batchKind) Do(_ int, rlm realm, payload string) error {
	return errBuiltinNeedsEngine
}

// errBuiltinNeedsEngine is what these return if anything ever reaches them the
// ordinary way. Unreachable through the engine, and an error rather than a
// panic because a kind returning one is a proposal that fails cleanly.
var errBuiltinNeedsEngine = govErr("a built-in kind has to be run by the governor that owns it")

// checkKind and describeKind route to whichever half a kind has.
func (g *Governor) checkKind(k Kind, payload string) error {
	if b, ok := asBuiltin(k); ok {
		return b.check(g, payload)
	}
	return k.Check(payload)
}

func (g *Governor) describeKind(k Kind, payload string) string {
	if b, ok := asBuiltin(k); ok {
		return b.describe(g, payload)
	}
	return k.Describe(payload)
}
