# Handoff: the Kourt website (web/)

**To the courtv2-moderation session** (or whoever picks this up next).

**STATUS: the loop is STOPPED (owner order, 2026-08-17, after round 90).**
The overlay in `web/` was polished across ~90 logged rounds (phases 1-4;
final arc = information discovery: map, search, sort, disclosure, clocks,
moderation provenance, the chain's policing lists, open-ballot discovery).
State and full round log: `WEBSITE-ITERATION.md`. No cron is running.

At stop, EVERYTHING IS GREEN: 14 node harnesses (scratchpad *_test.js) and
7 Chromium probe suites (d2-d6, d64, d*_extra) ALL PASS; both pages serve 200.
Open threads for whoever resumes: (1) the D6-4 critic and the D6-5..8 spec
lens were stopped mid-run unread — D6-4 stands on its own 10/10 probe + full
regression evidence; (2) the remaining ranked backlog is D6-5 elections
discovery, D6-6 answerability honesty, D6-7 /me spendable-vs-locked, D6-8
folder open-counts (context in the 84w-2 gap-review log row); (3) one known
soft spot the last critic named: a staked ballot OLDER than the newest-100
/needs probe window lands in the votable list under the generic hedge —
un-adjudicated; (4) realm wishlists + one realm ERRATUM (suspension-mask
copy) live in WEBSITE-ITERATION.md § Owner notes.

## Ground rules while the loop runs

- The loop writes **only** `web/**`, `WEBSITE-ITERATION.md`, and this file,
  and never commits. Realm code and docs are read, never written.
- Source-of-truth order: realm code > WHITEPAPER.md > site copy. §7.4 comms
  hygiene binds all copy (no profit/yield/return framing; principal never a
  wager; no live tallies while sealed; verdicts show their route).
- Please don't hand-edit `web/` mid-loop; a note in WEBSITE-ITERATION.md
  § Owner notes is picked up within minutes.

## What the site is now

One self-contained `web/index.html` (no build, no external assets), hash-routed:
directory / court / claim / your-positions / what-needs-you / how-it-works /
raw-chain view. Three action paths on every button:

1. **gnoweb link** — `<gnoweb-host>/r/kourt/kourtv2$help&func=…` with args
   pre-filled (baseline; works from file://).
2. **CLI toggle** — a copyable `gnokey maketx call` with the documented
   fee floor (`--gas-fee 10000ugnot --gas-wanted 10000000`), one `--args`
   per argument, `--send` only on Buy; chainid/remote from config.
3. **✍ Sign (Adena)** — connect via AddEstablish/GetAccount; DoContract
   `/vm.m_call`; chain-id guard with SwitchNetwork; per-arg confirmation
   prompts; envelope codes 0/4000/3001 surfaced inline. Live mode only.

Demo mode (default) is a faithful offline sample — zero network calls, action
buttons inert with an explanatory note, sample address on the me/needs views.
Config presets: local gnodev / sapphire (rpc.sapphire.testnets.gno.land:443,
chain `sapphire-1`) / custom; persists in localStorage.

## Decisions an owner may want to veto

- **Light-theme accent darkened one step** (`#9c6f2a` → `#96692a`) and a
  per-theme `--accent-ink` added so the filled primary button passes WCAG AA
  (dark theme was ~2.5:1). Pure design-token change; easy to revert.
- Copy now states mechanics the earlier draft softened: the claim fee and its
  two burn paths ("the spam price"), the qualified-answerer priority day, the
  flag half-burn, and the provisional-loser early exit. All code-verified
  (round 10, citations in WEBSITE-ITERATION.md).
- Wallet posture: Sign appears only in live mode with a connected address;
  demo never signs, never queries.

## When the loop finishes

Convergence = ≥10 substantive rounds AND 4 consecutive CLEAN; then the loop
deletes its cron job and updates this file with a final status line. To resume
by hand: read WEBSITE-ITERATION.md top to bottom and continue its protocol.

**OWNER DIRECTIVE (2026-08-17): please COMMIT the website (web/**, the two
iteration/handoff files) along with the whitepaper — see HANDOFF-WHITEPAPER.md.
The post-convergence reskin (records-office tokens, per-claim sparklines,
wireframe row anatomy) SETTLED 2026-08-17 after four verification rounds —
sign-off sweep returned zero findings. web/ is stable; COMMIT WHEN READY.**

*Status: **CONVERGED**, 2026-08-17. 41 rounds, 27 independent critic sweeps,
~90 verified findings applied. Converged on 4 consecutive CLEAN sweeps whose
lenses were: reward-pull completeness + epoch-snapshot accuracy (38),
transaction-argument fidelity across all three signing paths (39), read-path
contract fidelity against realm bodies (40), and a full final coherence
re-verification (41). Every mechanism statement, argument name/order, tuple
shape, status string, purge gate, and constant on the page is realm-verified
with file:line evidence in WEBSITE-ITERATION.md. The demo dataset is
realm-producible end to end (curve prices, conviction caps, bond formulas,
draw splits). Remaining items for a human: the manual browser pass in
WEBSITE-ITERATION.md § Owner notes (Adena gasFee/gasWanted question, the
820px stack), the WHITEPAPER hedging-analysis erratum (code excludes a
staker's address wholesale), and the realm-side notes (gate CourtName like
ClaimTitle; two wording nits). The loop's cron (d6b47efa) is deleted; the
influence session stands by for the owner's next phase.*
