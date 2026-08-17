# Handoff: the Kourt whitepaper

**To the courtv2-moderation session** (or whoever picks this up next).

A participant-facing whitepaper is being drafted and iterated in this worktree
by a loop running in the *influence* session (owner-directed, 2026-08-17).
Three files are involved, all new, all untracked, none of yours touched:

| file | what |
|---|---|
| `WHITEPAPER.md` | the document — ~4,400 words, 8 sections |
| `WHITEPAPER-ITERATION.md` | round log, standing constraints, verified fact anchors, open items |
| `HANDOFF-WHITEPAPER.md` | this note |

## Ground rules while the loop runs

- The loop edits **only** those three files and never commits. Your PLAN.md /
  MODERATION.md / realm code are read, never written.
- **Source-of-truth order: realm code > MODERATION.md/PLAN.md > whitepaper.**
  The whitepaper's own footer says the code is controlling. If you change
  mechanics (tickers, verbs, budgets), the loop's accuracy critics should
  catch it — but a one-line note in WHITEPAPER-ITERATION.md § Owner notes is
  faster.
- Please don't hand-edit WHITEPAPER.md mid-loop (merge hazard with the next
  round). Notes in the iteration file get picked up next round, usually within
  minutes.

## What the whitepaper commits to (so you can veto early)

- Brand: **Kourt / kourt.xyz / ticker KOURT / display KOURT:SLUG / Review
  Court = KOURT:META** — per the owner's supersession note in MODERATION.md
  §13.9.
- Pitch: the claim graph as the durable by-product; worked example = COVID-19
  origins court + a pediatric-mandate policy court (owner-directed).
- Posture: PLAN §7.4 comms hygiene throughout — participation not investment,
  burn framed as custody-elimination never scarcity, no yield story, §7 is a
  blunt "what this is not."

## Open items it surfaced for owners (also in the iteration file)

4. **Hedged staking looks +EV (realm-level, from the hostile-skeptic round):**
   one address may stake both sides of a claim (stake.gno permits it); losers
   keep principal, winner-side stakers draw accuracy rewards — so hedging both
   sides appears strictly positive-EV and inflates the stake-lean that renders
   as "58/42". If intended (a liquidity/legibility trade), document it; if
   not, the fix is realm-side (e.g. net-of-hedge lean in render, or excluding
   self-offsetting stake from reward draws).
5. **Genesis global backstop is 1-of-1** (ensureGlobalDAO migrates the first
   creator; DAO-ification is V3): whitepaper now says so plainly; decide the
   mainnet m-of-n plan before launch.
6. **Deployer identity naming**: the whitepaper discloses designer GNOT
   holdings and possible early positions (dry, no scarcity argument); whether
   to NAME the deployer is an owner call it deliberately does not make.

1. **META transferability** (§13.8 OWNER RE-CHECK) — the whitepaper ducks it;
   a decision would let §5 say something stronger.
2. **govern's `tokenSymbol = "COURT"`** (token.gno:18) — already sent to
   another session; whitepaper never mentions govern.
3. The example's breaking-news node (#9) is deliberately OPEN/unverified.

## When the loop finishes

Convergence = ≥10 rounds and 4 consecutive clean rounds; then the loop deletes
its own cron job and updates this file with a final status line. If the
influence session dies first, the cron job dies with it — everything here
stays valid, and the iteration file's round log shows exactly where it
stopped. To resume by hand: read WHITEPAPER-ITERATION.md top to bottom, then
continue the round protocol described there.

*Status: loop ACTIVE as of 2026-08-17 (round 1 complete, critics running).*
