# Verifying a change here

`make check` is the gate: `gofmt`, `go vet`, and the realm suites with the three
guards that hold the documentation to the code. `make chain-test` is separate
because it needs a running gnodev, and `make isolation-test` and `make selftest`
are separate because they are slow — each runs the realm suites many times over.

A green suite is not the same as a checked change. What follows is the part
that is easy to skip. It is specific to this repository rather than general
advice: every item names a way a test here can be green and mean nothing.

## Break the code and watch the test fail

A test written alongside a fix passes because the fix is present, not because
the test would notice its absence. Undo the fix, run the test, and read the
failure. Three things have to hold, and none of them is automatic:

- **The change applied.** A search-and-replace whose pattern does not match
  changes nothing, and the test then passes for the reason it always did.
  Assert the edit landed rather than assuming it.
- **It still compiles.** Removing a check often leaves an unused variable or
  import, and `[build failed]` is not the test disagreeing with you.
- **It failed for the right reason.** Read the message. A test that dies on a
  crashed harness, a timeout, or a different assertion has not exercised the
  property you think it has.

## Failures that look like passes

- **A mutation on a path the test never reaches.** Breaking `guessedWrong` did
  not fail a test about valid tokens, because a valid token never calls it. The
  mutation has to be on the line the test actually runs through.
- **An assertion that any failure satisfies.** "The request was not served"
  passes whether the handler refused it or `http.ServeFile` did, so the guard
  could be deleted with the test still green. Assert the specific answer — the
  status the handler itself produces.
- **A parse error standing in for an execution error.** Injecting a broken
  template expression at the top of a file breaks parsing, which fails
  everything. To test that a page executes, break it inside the body.
- **A harness that exits before the thing it is measuring.** A client process
  that closes its socket on the way out makes a shutdown look prompt for the
  wrong reason. Hold the connection open across the event.
- **A mutant that does not COMPILE, scored as a catch.** This one cost ten rows.
  Go refuses an unused variable, so deleting an `if !fire { return }` leaves
  `fire` declared, still parsing, and unbuildable. The suite exits non-zero — and
  a harness that reads only the exit code calls that CAUGHT. Ten corpus rows were
  "verified" that way; `mutate-parallel`, which classifies build errors
  separately, reported all ten INVALID. Rebuilt so they compiled, **two were
  genuine survivors** — one let a single key permanently destroy a comment, the
  other let a single moderator hide one. `check-mutant-collisions` now refuses a
  row whose mutant orphans a variable, so `make check` catches it without a suite
  having to run. If you write a probe harness, its verdicts are
  CAUGHT / SURVIVED / **INVALID** / ANCHOR-FAIL, and conflating any two of the
  four is how a corpus fills with rows that measure nothing.
- **A threshold tested only where it equals one.** `speechM`-of-n and the global
  DAO's `purgeM` both default to 1 on a fresh fixture, so the first call always
  fires and deleting the threshold entirely leaves the suite green. Any m-of-n
  guard needs a fixture with m above 1, or it is untested by construction.
- **A survey that missed.** `grep 'resume'` finds no test named
  `TestResumeRestoresLiveGuest`. Use `-i`, and treat an empty survey as a reason
  to ask a second differently-shaped question rather than as an answer.

## Restoring shared state in a test

`testing.SetRealm` does **not** take effect inside ANY closure — deferred or
otherwise. A `post := func(text string) { testing.SetRealm(...); Verb(cross(cur), ...) }`
helper looks obviously right and every call inside it arrives as *nobody*: the
caller identity belongs to the test frame, not the closure's. Six escape
assertions failed at "level 0, cannot post" before this was understood. Set the
realm in the test body, one statement before the crossing call.

The deferred case is the same limitation with a worse symptom: the defer
runs as whatever caller the body last set, so a restore that needs the admin is
refused, and the defer's own panic replaces the real failure. A deferred cleanup
here protects nothing and hides the diagnosis.

Restore inline instead, positioned after the last call that needs the changed
state and **before** any assertion that can `t.Fatal`. Package state — the global
DAO's `purgeM`, its membership, a court's mod set — is shared by every test in
the package, and leaving it changed has already taken down five tests in other
files whose only fault was running later.

## Before writing a file

Check whether it exists. `cat > path` silently replaces; `Write` after reading
does not. Overwriting a test file this way takes its assertions with it, and
nothing reports the loss — a suite with one fewer test is still green.

## Tools that do this for you

The three checks under "Break the code and watch the test fail" are exactly
what `scripts/mutate.py` reports on, which is the point of having it rather than
doing them by hand. It takes a JSON list of edits on stdin, applies each one to
the govern realm, runs the suite, and says whether anything objected:

    python3 scripts/mutate.py <<'EOF'
    [{"file": "governor.gno", "label": "anyone may cancel",
      "find": "\tif cur.Previous().Address() != p.proposer {",
      "replace": "\tif false {"}]
    EOF

`BAD ANCHOR` is "the change applied" — a pattern matching zero times is
reported rather than passed over. `INVALID` is "it still compiles". And it runs
the unmutated suite first, because a suite already failing reports every
mutation as caught, which is the same lie told a third way.

Two more run inside `make realm-test`. `check-citations.py` holds the
comments that cite the gno tree to an anchor rather than a line number, in three
directions — the anchor must still match, every row must still be quoted
somewhere, and every gno-tree file NAMED in the prose must have a row. The third
was missing for a long time and is the one that mattered most: without it a
comment could rest an argument on a file in the gno tree and be exempt from the
guard by the act of never having been registered with it. A guard whose coverage
is opt-in covers what somebody remembered. `check-storage.py` reads what each filetest wrote, from `gno test
-v`, and holds the read-only one to writing nothing; a read that starts writing
passes every unit test in the realm and is caught by that line alone.

A fourth holds `doc.gno`'s numbers to the ones the code uses — the six
bootstrap terms against `init`, and the three bounds on a proposal's strings
against their constants. That pair is a duplicated rule the doctrine below says to collapse
and cannot be: a realm cannot read its own source, and a doc comment cannot
call a function. So it is pinned. It matters more than most — the table is what
somebody reads before launching, those six numbers decide whether their first
adoption can pass at all, and a stale one is invisible, because the realm keeps
working and the only symptom is a launch failing on a quorum nobody was told
about. Both sides are evaluated rather than compared as text, since the code
writes a week as `7 * 24 * 60 * 60 / 5` and the doc writes the product.

A fifth runs on its own, because it is slow: `make isolation-test` runs every
realm test as the ONLY test that runs. A gno test file shares package state,
and these suites reset the trees and the supply but not the kind registry and
not the clock — so a test can pass because of what ran before it. Two shapes to
watch for: a test asserting messages that need a kind a neighbour registered,
and a test asserting a holder was empty at epoch 1, true only because neighbours
moved the clock past it.

That is the shape worth remembering: not a test that breaks, but one that
quietly reports on its neighbours. The suite cannot see it, because the suite is
the company it keeps.

`make check` runs all of it — fmt, vet and `realm-test`, which carries
`check-citations`, `check-docnumbers` and `check-storage` with it. The realms
are in it deliberately. A check that covers only the Go code makes "check is
green" a statement about Go while the gno work could be arbitrarily broken, and
the gap stays invisible for as long as somebody is testing the realms by hand on
every change. A habit covering for a target looks identical to a target that
works, right up until the person with the habit stops.

`make selftest` breaks every guard on purpose and checks it notices. A guard
that reports success while measuring nothing is the failure this catches, and
each of them is capable of it.

And it checks itself the same way: it lists every `scripts/check-*.py` and
fails if one has no control pointed at it. Naming its guards by hand was the
same opt-in coverage that let a citation go unregistered and a filetest go
unbudgeted — a new guard with nothing to prove it fires would have sailed
through a green self-test, which is the single outcome a self-test must never
produce.

## Where the same rule lives twice

Some rules exist in more than one place by necessity, and a second copy is how
they drift. One convention first, because it is a rule about writing rather
than a duplication: bounds are written `remaining < amount`, never
`used + amount > cap`. int64 wraps, and the naive form lets a hostile amount
straight past a cap.

Ten rules here would otherwise live twice. Each is one definition: the epoch
length, otherwise written twice with two different block times; the basis-point
scale, otherwise in three files; the rules validator, where one copy checks less
than the other; the reserved-prefix test, in `Offer` and in `govern:retire`; a
period rendered with its duration on one page and without on another; and four
things the tally and the page would each work out for themselves — turnout, the
threshold's denominator, the expiry deadline, and whether the timelock is still
running.

Those last four are the same shape and it is the shape that matters: the
figure a proposal is DECIDED by and the figure a holder READS, computed by
different code. The symptom is a page contradicting its own state — an
all-abstained proposal reporting "no votes cast", or a page printing
"succeeded" and "expired" together. Both look like rendering bugs. Neither
cause is the rendering.

The expiry deadline is the worst of them, because it is easy to write three
times: the tally testing `now > ready+grace`, the page testing it again, and
the page printing the sum a third time as the height it offers to run until.
One definition, several callers.

The tenth is the exception, and the distinction is worth having. A batch
numbers its members in its description and again in its failure message, one
`i+1` per file, and a reader uses that number to join the two. There is no
rule to collapse — it is a CONVENTION, not a computation, and a shared
helper returning `i+1` would be ceremony. It is held by a test that asserts
both numbers at once, with the failing member placed in the middle of three
so an off-by-one in either direction names a different kind.

So: collapse a duplicated rule, pin a duplicated convention. What neither
tolerates is being left with nothing pointed at it, which is how a copy
drifts without anybody noticing.

When you change one, change the others and say so in the commit. Better, if you
can: make it one definition, and let the compiler do the remembering.

## Claims in comments

A comment that describes a defence the code does not have is worse than none.
The shape to watch for is a helper documented as the gate for a rule that
actually lives inline somewhere else, so the helper has no callers and the
comment reads as coverage.

If a mutation proves a line is not load-bearing, either delete the line or write
down what it actually does. `minter.gno` does the second: an unreachable check
kept on purpose, with the reason it cannot be reached stated where it sits.
