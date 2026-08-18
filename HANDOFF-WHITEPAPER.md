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
3. The mockup's "claims reference real documents and events" assertion is
   fact-checked (round-2 critic, web-verified: EcoHealth grant, DEFUSE, intel
   split, Fauci-Fifth July 2026 w/ Al Jazeera source, raccoon-dog samples).
   Keep those citations handy for launch comms — the whitepaper itself carries
   no footnotes by register, so the receipts live in the iteration log.

## When the loop finishes

Convergence = ≥10 rounds and 4 consecutive clean rounds; then the loop deletes
its own cron job and updates this file with a final status line. If the
influence session dies first, the cron job dies with it — everything here
stays valid, and the iteration file's round log shows exactly where it
stopped. To resume by hand: read WHITEPAPER-ITERATION.md top to bottom, then
continue the round protocol described there.

**OWNER DIRECTIVE (2026-08-17, via the influence session): COMMIT the
whitepaper files (WHITEPAPER.md, WHITEPAPER-ITERATION.md, HANDOFF-WHITEPAPER.md)
and the website (web/**, WEBSITE-ITERATION.md, HANDOFF-WEBSITE.md) to the
courtv2-moderation branch. The influence session never commits by standing
constraint — this repo is yours. The reskin SETTLED 2026-08-17
(sign-off sweep: zero findings) — everything is stable; commit when ready.**

*Status: **CONVERGED AND FINAL**, 2026-08-17. 34 rounds, ~116 findings applied
across 9 critic lenses; converged on 4 consecutive clean rounds after 22+
substantive ones. Every mechanism claim verified against realm code with
file:line; the example's real-world references web-verified (sources in
WHITEPAPER-ITERATION.md). The document is publication-ready pending owner
read-through and the counsel checkpoint PLAN §7.5 calls for. The loop has
moved to phase 2 (website UX) per the owner directive — see
WEBSITE-ITERATION.md.*
