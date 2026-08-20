# WHITEPAPER.md iteration state

Machine-maintained by the whitepaper loop running in the *influence* session
(cron job `5cdddab6`, fires every minute; each fire = one improvement round).
Humans: leave notes in **§ Owner notes** below; the loop reads this file first
every round.

## PHASE 2 — after convergence (owner directive, 2026-08-17)

Do NOT stop when the whitepaper converges. Instead: (1) finalize the
whitepaper (update HANDOFF, final status); (2) CronDelete THIS job
(5cdddab6); (3) CronCreate a NEW 1-minute loop for the WEBSITE phase with a
self-contained prompt covering: polish + test web/ in this worktree (check
git status first — the courtv2-moderation session may have touched it; the
owner has now authorized web/ edits from this loop); user-friendly from a
first-time visitor's POV — spell out what a court is, what a claim costs,
what buying voice means, before any jargon; integrate the Adena wallet
(memory file adena-api.md in the influence project's memory dir holds the
researched window.adena API — verify against current Adena docs before
relying on it); add CLI helpers for every user action — either inline
command-builders or links to gno.land's helper pages (gnoweb serves a $help
view per realm that renders ready-to-run gnokey commands; search the web to
confirm the current shape); same critic-loop discipline (cold-visitor,
UX-walkthrough, accuracy-vs-realm, style) with convergence = 10 rounds + 4
clean. The whitepaper's register rules do NOT bind the website copy, but
§7.4 comms hygiene DOES (no profit language anywhere user-facing).

## Convergence rule

Stop only when BOTH hold: **≥ 10 total rounds** AND **≥ 4 consecutive CLEAN
rounds** (CLEAN = no substantive finding survived verification against the
repo). On stop: update HANDOFF-WHITEPAPER.md, `CronDelete 5cdddab6`, report.

## Standing constraints (survive every edit)

- **REGISTER (owner directive, 2026-08-17): plain English, modeled on the
  Bitcoin whitepaper.** Concretely: declarative sentences, mostly short;
  explanation as the only persuasion; adjectives sparing, adverbs rarer;
  minimal second person (Satoshi uses almost none); no theatrical closers or
  taglines; no em-dash chains; no rhetorical questions unless immediately
  answered ("The problem of course is..." is the ceiling); dry section titles
  are acceptable; "we" for the designers is fine. The pitch content stays —
  the claim graph, the worked example, §7's candor — but the voice explains
  rather than performs. Owner also directs **many rounds of word-style
  proofing**: the prose/style lens gets a FIXED seat in every panel from the
  next rewrite onward (2 rotating lenses + 1 style lens), and style findings
  count as substantive for CLEAN/NOT-CLEAN — convergence therefore requires
  the register to stabilize, not just the facts.
- SEQUENCING for the register change: the round-2 panel is mid-read on the old
  register; apply their findings and the full Satoshi-register rewrite as ONE
  pass when they land (two rewrites fighting each other wastes a panel).

- Audience: prospective participants. Job: make them *want in* — via the claim
  graph as the headline by-product — while staying inside PLAN.md §7.4 comms
  hygiene: no profit promises, no yield language, no scarcity-pump framing of
  the burn (custody framing only), no "early = cheap resale" teasing, risks
  stated plainly, verdicts are conclusions never truth.
- The COVID-19 worked example stays concrete and keeps: EcoHealth-funding TRUE,
  DEFUSE TRUE, FCS-can't-be-natural settling FALSE (a lab-leak-side claim dying
  in a lab-leak-curious court), intel-split TRUE, one junk claim (#8) killed by
  economics, the pediatric-mandate policy court with dissent preserved, one
  OPEN breaking-news intake node (#9, the 2026 Fifth-Amendment claim — shown
  OPEN/unverified deliberately; do NOT flatten it into an assertion). Claims
  must visibly settle against BOTH camps. **Owner-directed content — do not
  sanitize it away; do not assert it as fact either. OPEN is the honest state.**
- The 2021-platform-removal → 2023-FBI-assessment permission arc stays in §1.
- Length 7–12 pages (~3,800–6,500 words), 7 preferred. Current: ~4,400 words.
- Only writable files: WHITEPAPER.md, this file, HANDOFF-WHITEPAPER.md. Never
  commit. Never touch other files (the courtv2-moderation session owns them).
- Verify every critic finding against realm code / MODERATION.md / PLAN.md
  before applying; log accept/reject with file:line evidence. Critics lie.

## Fact anchors already verified against the repo (don't re-litigate)

- Curve: p(s)=s/d, d=1e9, cost(0→s)=s²/2d; avg price = half marginal
  (realm/p/curve/curve.gno). Burn to keyless `gno.land/r/kourt/kourtv2:burned`
  (buy.gno:18). No treasury; remainder refunded.
- Emission: 38 bps/wk of live supply, ×0.9933575/wk (halves ~104wk); lifetime
  ≤ ~1.77–1.784× curve-sold (mustInvariants, court.gno:152); skipped budget
  forgone (emission.gno accrueSegment). Meta: absolute 100 CC/wk stepped down,
  ~15,055 CC lifetime (court.gno:117).
- Franchise: accrues spent µGNOT on every non-meta Buy (meta.gno:516);
  ClaimMetaFranchise mints through meta's own curve at the shared monotone
  position (meta.gno:548-556); buying META does not accrue.
- Capture cost is d-invariant: share σ costs B·((1−σ)⁻²−1) ⇒ 5%→0.108B,
  20%→0.562B, 50%→3B, 90%→99B. (Three-agent convergence, verified by math.)
- Meta verbs: unhide/clear restorative (may pass from silence); hide/suspend/
  unsuspend/setmods aggressive (need decided contested quorate vote +
  credEligible) (meta.gno:45-64, ExecuteMetaVerdict guards).
- Moderation constitution: render-layer only; hidden ≠ voided; deep links
  render with banner; global DAO = cure-not-command (ClearAnyBit,
  ResetModSet disarms-never-appoints, purge m-of-n, ~14-day §512(g)-shaped
  window, events carry codes never text) (moderation.gno headers, :573, :706).
- Sealed epochs: governor decides "at an epoch sealed when the question was
  asked"; modvote reads PastVotes at epoch pinned at nomination-window open.
- Staking: no-loss principal, conviction = ∫stake dt (PLAN §3.1/§3.2).
- Per-court coins deliberate (PLAN §12 row 12); symbol = uppercase(slug)
  (court.gno:418 — the shared-"COURT" bug is FIXED on this branch).

## Known open items (owner decisions — surface, don't resolve)

1. **META transferability** — MODERATION.md §13.8 "OWNER RE-CHECK" still open.
   Whitepaper currently avoids asserting transferability for META
   specifically. If owner locks it non-transferable, §5 can say so as a
   feature (inert seniority premium).
2. **govern's tokenSymbol still "COURT"** (token.gno:18) — separate realm,
   sent to another session; whitepaper doesn't mention govern at all. Keep it
   that way unless the owner says otherwise.
3. Claim #9 (Fauci/Fifth, 2026): unverifiable at draft time; deliberately
   shown OPEN with answer window open. If the owner confirms a source, it can
   move to a settled node — but OPEN also *demonstrates intake*, which is the
   better pitch. Leave unless directed.

## Lens rotation (use 2–3 per round, no lens two rounds running)

securities-redline · cold-first-reader · tokenomics-accuracy · hostile-skeptic
("is this a scam") · prose-editor · example-fact-checker · structure/length

## Round log

| round | date | lenses | changes | verdict |
|---|---|---|---|---|
| 1 | 2026-08-17 | (drafting) | Initial ~4,400-word draft written: 8 sections, COVID graph mockup, capture table, §7 candor block. Launched critics: securities-redline, cold-first-reader, tokenomics-accuracy. | NOT-CLEAN (draft round) |
| 2 | 2026-08-17 | (hold) | Round-1 panel still reading; zero findings landed. Held rather than edit under reviewers (edits would invalidate their quoted text) or stack a second panel on an outstanding one. No file changes. WAIT rounds count toward neither total-rounds nor the clean streak. Cron fires while waiting: 2. This row is amended per idle fire rather than adding a log row each minute. | WAIT |
| 3w | 2026-08-17 | (hold) | Accuracy critic landed (banked as A1-A15, two majors spot-verified). Round-2 panel (skeptic, prose, fact-check) still out; mega-pass (A-findings + panel + Satoshi register) held for their landing per sequencing rule. Fires while waiting: 3. | WAIT |
| 3 | 2026-08-17 | cold-reader + securities (accuracy critic still out) | Applied all 26 banked findings in one Write: P1-P11 (conviction units, epoch=hourly-snapshot gloss, GNOT/realm glosses, emission why-line, franchise plain restatement, hype trim 2-of-3, counter-tilt adult-efficacy-TRUE node in MANDATES, honest tribalism paragraph, unstake freeze window) + S1-S15 (early-is-cheaper rewrite, mockup #8 burn/mint doctrine + "nobody paid from anyone else's loss", halving→step-down wording, bet→stake, provably/keyless→auditable, franchise gilding cut, accuracy-rewards naming + source, principal scoped to rules, both winks fixed, sells→mints doc-wide, overhang, ticker→denominated, farm/trade, will-pay→compensate, immutability-vs-reset reconciled + no-external-audit). ~4,550 words. Verification citations in the two "From" sections above. | NOT-CLEAN (26 applied) |

## Pending findings (collected, verification noted, NOT yet applied — awaiting full panel)

From **cold-first-reader** (landed round ~2):
- P1 "412k conviction" — unit undefined in mockup. FIX: define once or switch mockup label to "staked". (Conviction = ∫stake·dt per PLAN §3.2; unit is coin-time — simplify display.)
- P2 "epoch" never defined; §8 "the epoch you're in" confusing. FIX: one clause defining epochs; VERIFY epochBlocks value in court.gno first.
- P3 GNOT first used §4, defined §8. FIX: gloss at first use "(gno.land's native token)".
- P4 "realm" undefined. FIX: gloss "(gno.land's term for a deployed contract, immutable at its address)".
- P5 §4 parameter wall lacks a why. FIX: one sentence — decaying budget front-loads bootstrapping; ceiling exists so worst-case dilution is computable.
- P6 §5 franchise sentence ("aggregate platform burn") opaque; reader trusted the table not the prose. FIX: plainer restatement.
- P7 Hype flags: "only artifact of its kind" (§8), "deserves to exist" (§3), "single most clarifying fact" (§4). FIX: tone down 1–2 of 3; keep one.
- P8 **Political tilt — the big one.** All three invented outcomes lean one way (root 58/42, MANDATES NO, node #9), reading as authorial priors. FIX consistent w/ owner constraints (nothing removed): add ONE establishment-favoring settled claim in KOURT:MANDATES — "COVID-19 vaccines substantially reduced severe disease and death in adults — TRUE" beside the mandates-NO verdict. Same court says vaccines-worked AND mandates-unjustified: courts judge claims, not teams. Owner may veto here.
- P9 **"Why would voters vote accurately rather than tribally?"** — the #1 unanswered question. VERIFIED: carrot pays with-verdict voters of the deciding round (crystallize.gno:282-288 "the carrot pays with-verdict voters"). So the honest paragraph must NOT claim an accuracy incentive — it is a Schelling pull toward expected consensus; real defenses are sealed epochs, the permanent dissent record, and the permissionless fork. Write it that honestly.
- P10 Unstake gating — VERIFIED, and the draft is INCOMPLETE as written: Unstake works any time before an answer lands; an answer freezes stakes (claim.gno:63 "stake/unstake refuse after"; stake.gno unstake panics when frozenAt != 0 with "withdraw at settlement (principal is never withheld)"). FIX: add the freeze window to §2 — principal returns in full at settlement, but is time-locked between answer and settlement. Without this the no-loss line overstates.
- P2-VERIFIED: epochBlocks = 720 (court.gno:33) ≈ hourly at ~5s blocks (17,280/day per reSetWindowBlocks comment). Define epochs as "hourly snapshots of voting weight".
- P11 HTML comment reads odd to cold readers — KEEP (it addresses the other session); strip at publication. Noted here so it isn't "fixed".
- Deferred: DMCA paragraph trim (minor); wallet/UI walkthrough (out of scope for a whitepaper; kourt.xyz footer suffices).

From **securities-redline** (landed; citations spot-verified — PLAN.md:59
"Forfeitures burn; compensation mints"; PLAN.md:620 "step-down is public-copy
language for what the math calls halving"; PLAN.md:615 "accuracy rewards" is
the sanctioned name; dispute.gno:8-24 confirms bonds burn, comp mints):
- S1 HIGH §4 "Early conviction... buys a loud voice cheaply" = the one
  early-is-cheaper appreciation pitch in the doc. ACCEPT critic's rewrite; also
  sell→mint vocabulary doc-wide (S10).
- S2 HIGH mockup #8 "answerer paid, disputer's bond forfeited" misstates the
  mechanism as loser-pays-winner. ACCEPT: "answerer compensated, disputer's
  bond burned" + add the burn/mint doctrine line to §2 Crystallized.
- S3 HIGH "halving every two years" breaks PLAN §7.1's own public-copy rule.
  ACCEPT: "stepping down" everywhere (incl. §7).
- S4 HIGH "people bet honestly when the bet can't ruin them" — gambling-axis
  self-label (V1's ranked #1 own-goal). ACCEPT: stake/position wording.
- S5 MED "provably destroyed... keyless" overstates. ACCEPT: "destroyed — sent
  to a designated burn address, auditable by anyone on-chain."
- S6 MED §5 "into everyone else's franchise as well as their own" = burn
  benefits framing. ACCEPT: cut the gilding, keep the table.
- S7 MED "well-placed stakers" → "accuracy rewards... from the court's
  emission — to the answerer, to stakers who were right, and to voters."
- S8 MED "Principal is never at risk" → scope to rules; merges with P10's
  freeze-window fix.
- S9 MED the two winks (preamble token line; "different paperwork"). ACCEPT
  both rewrites.
- S10 MED sells/sold → mints/minted doc-wide. ACCEPT.
- S11-S15 LOW: overhang→"banked and paid later"; ticker→"denominated
  KOURT:SLUG" (footer only; KOURT stays the platform coin name); "farm
  rewards"/"losing trade"→plain; "will pay"→"compensate"; reconcile
  immutability vs testnet-resets + "unaudited-enough"→"no external audit yet".
  ACCEPT all.
- Critic's summary: the doc reads as a participation instrument overall; §4
  curve paragraph was the one doing the plaintiff's work. Post-edit, §7.4
  lead-with-product is honored (token absent until §4).

PLAN: apply P1-P11 + S1-S15 in ONE edit pass next fire, with or without the
tokenomics-accuracy critic (its findings are claim-keyed and survive
rewording). Then relaunch panel round 2: hostile-skeptic, prose-editor,
example-fact-checker.

From **tokenomics-accuracy** (landed after 30 tool calls; the two largest
findings SPOT-VERIFIED — A3 via claim.gno:226 openClaim(title-only, no dup
check) + PLAN.md:889/896 "edges stay OUT of the V2 money loop... Edges ship
(V3)"; A4 via live gno_packages query on sapphire: nothing under
gno.land/r/kourt):
- A1/A2 ACCEPT: epoch seals at the VOTE's opening, not at fight-visibility;
  appeals are force-visible from birth. Fix §1 "before the vote opened", §2
  keep (literally correct), §5 "before the vote on the appeal opened".
- A3 ACCEPT (MAJOR): tree/body/edges/hash-identity are the V3 structure layer,
  not shipped V2. Reframe §2 (claim = wordlocked title; drop body/append-only
  for V2) and §3 (graph = the destination; V2 accumulates the raw material:
  wordlocked claims, stakes, verdicts, dissents). Keep the graph as headline —
  honestly dated.
- A4 ACCEPT (MAJOR): not deployed anywhere yet. Drop "runs today on sapphire"
  (header, §8, footer); pre-launch framing, faucet line becomes "at launch".
- A5 ACCEPT: capture base is CLAIMED burn + direct buys, not aggregate burn
  (MODERATION.md's own "security base is claimed burn... 3-10× smaller than
  gross"). Fix table caption + franchise sentence; add unclaimed franchise as
  dilutive reserve, worded dryly.
- A6 ACCEPT: 4-week reservoir banks before forgone. Fix §4.
- A7 ACCEPT: credEligible exempts `hide`. Qualify §5 sentence.
- A8 ACCEPT: purge is m-of-n, admin-settable, genesis 1-of-1. Say "m-of-n".
- A9 ACCEPT: before any election the creator re-appoints. Fix §6.
- A10 ACCEPT: meta's absolute emission is the exception to 38bps. Parenthetical §4.
- A11 ACCEPT: answers carry no reasoning text. Drop "with reasoning".
- A12 ACCEPT: staking cannot begin until the polish window ends (my sentence
  was backwards). Fix §2.
- A13 ACCEPT: biggest emission slice = winning stakers (80/93); moderators
  as such unpaid. Fix §4 list ("staking on the right side... policing junk").
- A14 ACCEPT: two sanctioned intake gates (purged court refuses new claims;
  review-slot latch gates PostAnswer). Constitution line → "never gates a
  stake, a verdict, a settlement, or a withdrawal"; intake caveat inline.
- A15 ACCEPT: "anyone except the answerer" may dispute; franchise accrues on
  buys in any court EXCEPT the Review Court itself (sentence, not just
  parenthetical).
- Confirmed-good worth keeping verbatim: principal-never-at-risk is code-true
  (WithdrawStake full principal both sides, unpausable, session.gno:84-120);
  founder-no-premine code-true; no genesis allocation anywhere.

From **prose-editor** (landed; register-agnostic cuts, all compatible with the
Satoshi directive — its counts ARE the Satoshi case: 64 em-dashes, 14 "the X
is the Y" cappers, self-certified candor ×6, sentence-initial And ×6):
- E1 ACCEPT: five worst-rhythm sentences, rewrites as given (§3 map sentence
  split; §6 cures-not-commands broken into three sentences; §4 emission
  modifiers tightened; §8 subject-verb gap closed; §5 contested/adversary
  said once).
- E2 ACCEPT: dead-word purge — actually×4→1, genuinely×2→0, deliberately×3→1
  ("deliberately inert" stays), honest/blunt/brutal/plainly 6→≤2,
  permanent(ly) 5→2, public(ly) 9→load-bearing only, exactly/precisely 6→2,
  whole 5→2, forever 3→1. Em-dashes 64→target <25. "X is the Y" cappers
  14→best 3 (graph/point stays; code/whitepaper stays; one more).
- E3 ACCEPT: split §3's triple-job closer before "Researchers"; split §4 at
  "Coins also flow to work"; fix §2's "four parts" promise (fold court-rot
  into part four); rewrite §8 opener to lead with live-at-zero-cost (NOTE:
  A4 supersedes "live today" — lead with what participation costs at launch).
- E4 ACCEPT: cut §8's imperative checklist to three beats so "Bring a claim."
  is the only detonation; strip the colophon's "the code is the whitepaper"
  mic-drop to plain reference data (keep the SENTENCE as a plain statement of
  precedence, drop the flourish — securities S-summary liked its content).
- E5 ACCEPT: all ten line edits, except #10 ("or — often — still OPEN" adds an
  em-dash pair against the register; use "or, often, still OPEN").
- Note: editor measured 3,586 words (not ~4,550 — my §12-era estimate was
  stale). Post-mega-pass target stays ≥3,800 to hold 7 pages: the A3/A4
  reframes ADD honest words; net should land ~3,700-4,000. If it dips under
  3,800, that is acceptable — 7 pages was always the preference, and padding
  to a floor would invert the register.

From **example-fact-checker** (landed; post-cutoff items verified by web
search, sources cited in its report):
- F1 ACCEPT §1 precision: Facebook's Feb 2021 policy banned "man-made" claims
  (narrower than "from a lab") and reversed May 2021; plural-platforms only
  documented for Meta. Rewrite: "In February 2021, Facebook banned posts
  claiming the virus was man-made; it reversed that May. Two years later the
  FBI's director said the bureau assessed the pandemic most likely began with
  a lab incident in Wuhan." (Wray, Feb 28 2023, moderate confidence.)
- F2 ACCEPT node #7 (highest priority — a SETTLED-TRUE node now asserting a
  falsehood: CIA moved Jan 2025 to research-related-more-likely; "others lean
  zoonotic" is stale-false). Reword: "US intelligence agencies are split on
  the origin, with no consensus assessment." Durable and true.
- F3 ACCEPT node #8 strawman replacement, with camp symmetry: replace the
  vaccine-microchip claim (out-of-scope for an origins court, and nobody
  would fund its bond) with a plausible-and-false ZOONOTIC-side overstatement:
  "✗ 'A SARS-CoV-2-infected animal was found at the Huanan market.' FALSE" —
  widely believed from 2023 raccoon-dog headlines; the samples were
  environmental, no infected animal was ever found. Now #5 kills a lab-side
  overstatement and #8 kills a zoonotic-side one: each camp loses its weak
  claim. Strengthens the both-camps constraint.
- F4 ACCEPT node #9 rework (the event is REAL — July 29 2026, Senate HSGAC,
  100+ invocations, contempt push after; pardon-vs-privilege is an open legal
  question, Paul arguing the pardon defeats it): split into
  #9 "✓ Fauci invoked the Fifth before a Senate committee, 100+ times (July
  2026)" TRUE, settled in days (document-reducible, exactly §3's fast lane) +
  #10 "⊘ 'The January 2025 pardon defeats the Fifth Amendment privilege for
  pardoned conduct.' OPEN, freshly staked" (genuinely contested). Prose:
  intake DECOMPOSES breaking news into the checkable and the contested.
  Drops the "filed this week" staleness problem too.
- F5 ACCEPT MANDATES fix: "against where several US states did" overstates
  (no state enforced school-entry COVID mandates). Replace with universities:
  "...where hundreds of US universities stood" (documented). Adult-efficacy
  TRUE node is defensible (Lancet: ~14.4M deaths averted, year one) — keep.
- Confirmed accurate: B (Wray quote/timing), C (R01AI110964 subaward,
  HHS-OIG-audited, terminated 2022), D (DEFUSE furin text public via
  leak+FOIA), F (node #5's FALSE rests on "cannot," which is the point).

From **hostile-skeptic** (landed minutes after the mega-pass; it reviewed the
PRE-mega-pass draft — its hits on "runs today"/"with reasoning"/"never
banked"/"multiple keys"/present-tense-tree were ALREADY FIXED by A-findings.
New items, each verified before deciding):
- K1 ACCEPT (§7 Disclosure block): designers hold GNOT, the token every curve
  burns; may hold early positions in courts they found; on-chain visible.
  Verified nuance: court.gno:126's "~500-1,000 GNOT genesis buy" is a floor-
  calibration ASSUMPTION, not a stated deployer plan — disclosure written dry,
  no scarcity argument made (S-rules hold: disclosing an interest ≠ marketing
  the burn).
- K2 ACCEPT (§6): global backstop is genesis 1-of-1 (ensureGlobalDAO migrates
  directoryAdmin = first creator; "DAO-ification is V3", moderation.gno:60,86).
  Now stated: single operator key at genesis, m-of-n supported, broadening is
  deployment work.
- K3 ACCEPT (§2): both-sides staking is code-true (Stake() has no opposite-
  side check; StakeOf keyed by (side,who)). Added: "lean measures net stake,
  not headcount."
- K4 ACCEPT (§2): sealed-epoch honesty — the seal binds reactors, not
  planners (buy, wait an hour, open the dispute yourself). Added plainly.
- K5 ACCEPT (§8): faucet-token burns are rehearsal; the record that matters
  starts where money is real.
- K6 REJECT (name the deployer): the doc discloses the interest (K1); naming
  legal identity is an owner call, not a critic's. → Owner notes.
- K7 REJECT ("candor is manufactured; the confession is the conversion
  funnel"): no wording change can answer this — the counter is process, not
  prose: claims are verified against code and false ones removed, and this
  log is public. Noted, not actionable.
- K8 REJECT (carrot = beauty contest on values claims): already stated
  honestly in §2 ("a pull toward expected consensus rather than an oracle").
- K9 → OWNER (realm-level, out of whitepaper scope): hedged both-sides
  staking looks +EV (winner-side accuracy rewards, no loser-side principal
  loss) and inflates stake-lean legibility. Mechanism question for the
  courtv2-moderation session, logged in HANDOFF.
- Skeptic's could-not-break list (kept for the record): contract-level
  burn/no-treasury clean; render/money separation held everywhere it counts;
  no-loss principal code-true; sealed epochs real; no premine narrowly true;
  emission bounds enforced by deploy-gates; "a genuinely careful machine."

## Round log (continued)

| round | date | lenses | changes | verdict |
|---|---|---|---|---|
| 14w | 2026-08-17 | (hold) | Panel A stayed silent through ping + one fire — (superseded — see round 15) | WAIT |
| 15w | 2026-08-17 | (hold) | (superseded — see round 16) | WAIT |
| 17w | 2026-08-17 | (hold) | (superseded — see round 18) | WAIT |
| 18w | 2026-08-17 | (hold) | (superseded — see round 19) | WAIT |
| 26w | 2026-08-17 | (hold) | (superseded — round 27) | WAIT |
| 27w | 2026-08-17 | (hold) | (superseded — round 28) | WAIT |
| 28w | 2026-08-17 | (hold) | (superseded — round 29) | WAIT |
| 29w | 2026-08-17 | (hold) | (superseded — round 30) | WAIT |
| 31w | 2026-08-17 | (hold) | (superseded — round 32) | WAIT |
| 34 | 2026-08-17 | streak panel 9a (read-aloud) | READY — new payee list cleanly parallel; the dissent coordination lands on rhythm; remaining hitches disambiguate within a word. Zero findings. | CLEAN (streak 4/4) |
| — | 2026-08-17 | **CONVERGED** | Both gates met: 22+ substantive rounds (≥10) and 4 consecutive CLEAN across four different lenses (cold-read, register+consistency+vocabulary, structure, read-aloud). Final: 3,618 words ≈ 8-9pp, 34 logged rounds, ~116 findings applied, 9 lenses, every mechanism claim code-verified with file:line, real-world claims web-verified with sources. Whitepaper loop closed; cron 5cdddab6 deleted; website loop (phase 2) created per the owner directive of 2026-08-17 — cron d6b47efa, state in WEBSITE-ITERATION.md. | FINAL |
| 33 | 2026-08-17 | streak panel 9b (structure; 9a read-aloud still out) | READY — all cross-references resolve, all prose-cited mockup nodes present with matching statuses, section jobs intact, 3,618 words ≈ 8-9pp. Zero findings. | CLEAN (streak 3/4) |
| 32 | 2026-08-17 | streak panel 8a | READY — zero second person, zero prose em-dashes, both newest edits cohere with every cross-reference, arithmetic re-verified, near-misses died under challenge. Zero findings. | CLEAN (streak 2/4) |
| 31 | 2026-08-17 | streak panel 8b (8a still out) | SHIP; nothing mockable; math re-checked; franchise self-resolved on second pass (precedent: not a finding). Zero findings. | CLEAN (streak 1/4) |
| 30 | 2026-08-17 | streak panel 7a (skeptic-final) | ONE screenshot survived and was ACCEPTED: "what the minority said on the way down" — the chain records no minority speech (votes are yes/no/abstain strings, answers carry no text, stakes are amounts; consistent with round-16 #11). Now "that the minority held its ground to the end; the dissenting weights are as permanent as the verdict" — which is exactly what the chain keeps. Bonus: third independent confirmation of mockup #9 (CNN link). Everything else held: burns, comps-inside-emission, principal 1x, capture arithmetic. Streak resets. | NOT-CLEAN (1 applied) |
| 29 | 2026-08-17 | streak panel 7b (accuracy spot; skeptic 7a still out) | All five reworded claims CORRECT with file:line (freeze/release, dispute bonds both directions, <78.4% emission bound, franchise same-call-same-position, creator latch). Code more permissive than stated in one place (early release of losing side) — understatement is fine. READY. Zero findings. | CLEAN (streak 1/4) |
| 28 | 2026-08-17 | 6a-relaunch (the abandoned duplicate delivered after all; panel 7 still out) | Vocabulary/register/math clean — and ONE real consistency find all prior sweeps missed, ACCEPTED: Crystallized paid "the answerer" unconditionally, but an overturned answerer forfeits (crystallize.gno:98-99, round-9 audit) and the prevailing disputer was omitted (comp exists: PLAN v0.11 prevailing-party compensation). Now "paid to the prevailing bonder (answerer or disputer)...". Lesson logged: abandoning slow agents is fine, but their late deliveries still count — this one out-found two READY verdicts. Streak resets. | NOT-CLEAN (1 applied) |
| 27n | 2026-08-17 | (note) | 6a re-delivered a second READY (same verdict, three strongest candidates all died under challenge). Duplicate of a clean verdict; no round, streak unchanged at 2/4. | — |
| 27 | 2026-08-17 | streak panel 6a (original, woke post-relaunch; duplicate will be cross-checked then discarded) | READY — round-25 repairs hold under hostile re-challenge; near-candidates die on inspection (universities-contrast survives via the F5 verification; Disclosure "minted" self-corrects in four words); vocabulary clean; 80% phrasings aligned; capture table re-checked. Zero findings. | CLEAN (streak 2/4) |
| 26 | 2026-08-17 | streak panel 6b (6a still out) | SHIP; arithmetic re-checked cold; franchise paragraph took two passes but self-resolved, no fix proposed. Zero findings. | CLEAN (streak 1/4) |
| 25 | 2026-08-17 | streak panel 5b (read-aloud) | THREE stumbles, all ACCEPTED: "courts they found" garden-path (found/founded) in the Disclosure — the sentence needing most precision — now "courts they have founded"; "once published, by its deployer" misattachment → "once published; not even its deployer can change it"; "against where universities stood" de-jointed → "against the position hundreds of US universities took". Streak resets per the integrity rule. Finding size is now down to single-phrase parse repairs. | NOT-CLEAN (3 applied) |
| 24w | 2026-08-17 | (hold) | Panel 5b (read-aloud) out. Fires: 2 — ping next fire if silent. | WAIT |
| 24 | 2026-08-17 | streak panel 5a (structure-final; 5b read-aloud still out) | READY — length in range, all cross-references resolve, every prose-cited mockup node exists, no orphans. Zero findings. | CLEAN (streak 2/4) |
| 23 | 2026-08-17 | streak panel 4a (securities-final) | READY — vocabulary clean throughout; earn bound to own work; 0.38%/wk framed solely as dilution; APR-equivalents correctly quarantined to ECONOMICS.md; Disclosure discloses without touting. Zero findings. | CLEAN (streak 1/4) |
| 22 | 2026-08-17 | streak panel 4b (securities-final still out) | READY on all settlement marks (#2/#3/#7 TRUE correct, #5/#8 FALSE correct, #9 rests on the round-2 web verification, #10 pardon real). Its one nit is a real precision error and was APPLIED: "the 2023 market samples" implied 2023 collection; samples were collected Jan 2020, analyzed 2023 — year dropped, sentence now unimpeachable. By the round-17 integrity rule any text change is NOT-CLEAN; streak resets. | NOT-CLEAN (1 applied) |
| 21w | 2026-08-17 | (hold) | Panel 4 (securities-final, fact-check-final) out. Fires: 3 — ping next fire if silent. | WAIT |
| 21 | 2026-08-17 | streak panel 3a | READY — all five round-19 edits hold the register under challenge. Zero findings. | CLEAN (streak 2/4) |
| 20 | 2026-08-17 | streak panel 3b (3a still out) | SHIP; capture table and emission ceiling independently re-verified; the franchise paragraph noted as the densest knot but self-resolving — no fix proposed, no finding. Zero findings survive. | CLEAN (streak 1/4) |
| 19w | 2026-08-17 | (hold) | Streak panel 3 out. Fires: 1. Panel 2b re-delivered its same 5 findings against the pre-round-19 text — all already applied (verified: quip cut, appositive re-hung, parenthetical moved, purge de-jointed, counterfeit cut). Duplicate; no change; streak unaffected. | WAIT |
| 19 | 2026-08-17 | streak panels 2a+2b | 2a: READY — every candidate died under challenge (incl. validating the mockup's disputer-bond event against the round-18 clause; both 80% phrasings ruled consistent). 2b: FIVE register findings, all ACCEPTED: my round-18 closer "Forcing a vote is not free either" CUT (quip + loosely false — a winning disputer recovers its bond); Crystallized appositive re-hung ("The verdict, TRUE or FALSE, is recorded and never revised"); §4 Review-Court parenthetical moved to paragraph end + §4/§7 aligned on "adds less than 80%"; §6 purge sentence de-jointed (object lands first; threshold sentence follows); "the one unit the internet cannot counterfeit" cut — five sweeps had cleared it, but the defining clause carries the argument alone, and register wins ties. Note the split verdict pattern: consistency lens says READY while the style lens still finds; the streak requires BOTH quiet. | NOT-CLEAN (5 applied) |
| 18n | 2026-08-17 | (note) | Panel 1a re-delivered the same disputer-bond finding after re-checking a pre-round-18 copy (its cited lines predate the fix). Already applied in round 18; current §2 Disputed verified to carry the bond clause. No change; streak unaffected. | — |
| 18 | 2026-08-17 | streak panel 1a (delivered after ping) | Vocabulary clean, arithmetic re-verified, register held — ONE consistency finding, ACCEPTED: mockup #8 burns a "disputer's bond" that §2 never establishes, leaving forcing-a-vote free as written. Code-verified (dispute.gno:8-10: disputer bonds exist; decided-against bonds burn; failed rounds burn half): §2 Disputed now reads "posting a bond of their own... the side the vote decides against loses its bond. Forcing a vote is not free either." The mockup annotation was code-accurate; the body was incomplete. | NOT-CLEAN (1 applied) |
| 17 | 2026-08-17 | streak panel 1b (1a still out) | Verdict SHIP; §7 called "the strongest disclosure section I've seen in a token paper"; capture table independently re-verified. One stall APPLIED: "+80%" notation forced a re-read → now a plain sentence ("emission can never add more than 80% on top of what its curve has minted"). RULE ADOPTED for streak integrity: reader-stall fixes count as substantive (they change the text), so this round is NOT-CLEAN — leaving a known stall to protect the streak would corrupt the signal. Its verify-the-Fauci-reference note: already done in round 2 (web-verified, sources logged); HANDOFF gains a line to keep those citations available for launch comms. | NOT-CLEAN (1 applied) |
| 16 | 2026-08-17 | duplicate consistency sweep (read pre-round-15 text) | 3 of its 5 findings are byte-identical to round 15's (may-hold, seal timing, purge scope) — two independent sweeps converged on the same list, which is the consistency lens running dry. TWO new findings ACCEPTED: (1) OPEN listed under "never revised" though it is exactly the revisable state — now "TRUE or FALSE. A claim not yet carried to verdict stays OPEN"; (2) "principal returns in full" → "is released in full" — an earlier securities agent cleared the verb, this one flagged the homograph; the fix is free and strictly clearer, applied. Streak stays 0/4; next fire launches the streak panels (strict do-not-invent briefs, rotating pairs). | NOT-CLEAN (2 applied) |
| 15 | 2026-08-17 | convergence panel A (original, woke after relaunch; duplicate sweep still out — cross-check on landing) | Securities CLEAN, register CLEAN, capture/emission arithmetic re-verified. FOUR internal-consistency findings, all ACCEPTED (5 edits): (1) §4 "designers hold such positions" contradicted §7 "may hold" AND the not-deployed status — false in the doc's own frame → "may hold"; (2) Abstract said sealed BEFORE vote-open, §2 said AT vote-open — code truth is before (round-9: proposal snapshots Epoch()-1) → §2 "already sealed when the vote opened"; (3) MANDATES "VERDICT: NO" used a verdict vocabulary the system does not record (TRUE/FALSE/OPEN only) → FALSE, meaning preserved (claim is "...were justified"); (4) §6 used "purged court" but only defined text-purge → "purge text, up to a whole court". Streak resets. | NOT-CLEAN (5 applied) |
| 14 | 2026-08-17 | convergence panel B (cold acceptance; panel A still out) | Verdict SHIP. All four acceptance answers correct from stated text (pay: burned GNOT; get: voice + emission eligibility + franchise; risk: whole burn, bonds forfeitable, principal never, dilution, unaudited; non-buyers: the free public record). Two observations judged non-actionable: mockup screenshot-bait (deliberate + hedged — legend carries the caveat), §7 no-future-efforts vs §3 next-layer (pre-answered by the built/specified split; the coins sold are the built layer's). Zero findings survive. | CLEAN (streak 1/4) |
| 13 | 2026-08-17 | micro-panel (style+securities, newest sentences) | 4 CLEAN (both-sides staking incl. "guesser's reward" ruled earned; seal candor; intake-gate scope exact; Disclosure register right), 2 FLAGGED and APPLIED: (1) legend now includes "verdicts" in the invented list — without it, #5/#8 read as pre-announced outcomes, the one thing the legend must prevent; (2) "same burn counted twice" replaced — it quoted as dual-accrual (Munchee-kind); new framing leads with price-sameness and describes WHICH burn pays, not how much is gained. Critic's close: "apply these two, then stop editing." Streak: 0/4 (these count). Next: full convergence panels — the round-12 lipstick fixes and these two have not been seen by any broad lens. | NOT-CLEAN (2 applied) |
| 12 | 2026-08-17 | skeptic-re-run (micro-panel still out) | Skeptic's own verdict: the thread "no longer writes itself — it has become read-what-they-concede... half an endorsement." Every constant re-verified in code. TWO lipstick findings ACCEPTED (streak resets — honesty is the brand): (1) §4 "no premine and no allocation" was true-but-hollow → now states the tradeoff plainly ("what a founder gets is the chance to mint first... at its lowest positions; section 7 discloses"); (2) §6 "m-of-n keys" dressed a genesis-1 threshold the admin sets both directions (SetPurgeThreshold 1..n, moderation.gno:124-131 verified) → "by its configured threshold of keys, one at genesis and set by its own admin". THREE attacks REJECTED with reasons: §5-decoy (capture table measures the Review Court accurately; the operator key is cures-only and now honestly thresholded); no-secondary-market-mention (deliberate — §7.4 forbids trading-venue talk; naming exits would worsen exposure, logged as design); product-on-display (already dated explicitly in §3; mockup labeled; purge-key concentration now honest via fix 2). Streak: 0/4. | NOT-CLEAN (2 applied) |
| 11 | 2026-08-17 | duplicate-accuracy cross-check (skeptic-re-run still out) | The relaunched accuracy agent landed: 8/8 CORRECT, independently reproducing the resumed agent's verdicts (same file:line cites; its two "phrasing looseness" notes are the exact glosses already fixed in round 9 — current text already reads "sit in escrow, where they carry no vote"). Two independent auditors, no contradictions. Zero findings survive → first CLEAN round. Launched narrow round-6 panel on the ~8 sentences added since round 8: style-recheck + securities-recheck (specific question: does "the same burn counted twice" read as a two-for-one value pitch?). | CLEAN (streak 1/4) |
| 10w | 2026-08-17 | (hold) | Skeptic-re-run + duplicate accuracy out. Draft frozen. Fires while waiting: 1. | WAIT |
| 10 | 2026-08-17 | cold-read #3 (skeptic-re-run + duplicate accuracy still out) | Verdict "try"; three trust-earners quoted (verdict-not-truth, no-custodian, assume-worthless). Two findings, both APPLIED: (1) claim #9 read as "inventing a future humiliation of a named real person" — root cause is MY legend ("every number is invented") implying the claims are fictional; the event is real (round-2 web verification). Legend now says stakes/leans/dates are invented, the claims reference real documents and events. (2) Franchise value opaque ("if claiming costs what buying costs, what does the franchise earn you?") — added the punchline sentence: the franchise is the same burn counted twice — court coin AND meta-curve credit; a direct buyer spends new GNOT. Verified against accrueFranchise (1:1 µGNOT credit) + ClaimMetaFranchise (credit spends through the curve, no new GNOT). TEN SUBSTANTIVE ROUNDS COMPLETE — convergence gate #1 met; need 4 consecutive CLEAN. | NOT-CLEAN (2 applied) |
| 9w | 2026-08-17 | (hold) | Round-5 panel (skeptic-re-run, cold-read) + duplicate accuracy agent out. Draft frozen. Fires while waiting: 2. | WAIT |
| 9 | 2026-08-17 | accuracy-re-check (resumed by ping; the relaunched duplicate still out — cross-check on landing, then discard) | 8/8 new claims CORRECT with file:line evidence (escrow transfer + checkpointing; winning-side-only rewards; votes read PastVotes never stake; lean from per-side pools; franchise = identical Minted call/position as Buy; "spent" latch precise — nothing ever clears creatorUnseated; genesis 1-of-1 confirmed from deployer key; emission ceiling <+77.2%<+80%). Two hairline glosses APPLIED: (1) "absent from the hourly snapshots" → "sit in escrow, where they carry no vote" (coins ARE checkpointed — under the escrow key, which can never vote and is netted out of quorum; the new wording is the precise one); (2) §6 review-pause sentence was broader than the code — the latch refuses answers to RIVAL APPEALS on a target under review, not answers on the item itself → reworded narrower. Net verdict quoted: "the document is mechanism-accurate." | NOT-CLEAN (2 applied) |
| 8 | 2026-08-17 | style-second-order (accuracy re-check still out) | All 7 fixes applied: duplicate §1 capper CUT (thesis now stated twice — Abstract close + §3 pivot — not three times); §8 seam repaired ("brings disputes to each epoch" was rewrite residue — epochs are snapshots, not dispute-carriers); "Claiming mints" disambiguated; token→coin ×2 (courts share no coin; a coin vote); §6 hidden-item→hidden-claim; Abstract untouchables list gains "a bond" (matching §6); double-blank normalized. RULING on the sole surviving "fight" (line 197 "Threads record the fight"): KEPT — deliberate contrast with what Kourt records; the word is doing work there. Critic's count post-fix: 0 prose em-dashes, 0 second person, 0 banned adverbs, 2 initial-And. Its verdict: after these, "a further flattening pass would find nothing real." | NOT-CLEAN (7 applied) |
| 7 | 2026-08-17 | securities-new-surface (accuracy + style re-proof still out) | Verdicts: Abstract KEEP (exposure-reducing), sealed-epoch admission KEEP (10b-5 candor), single-key admission KEEP, faucet-rehearsal line KEEP. Three REWORDS applied, all verified against already-banked PLAN rules: (b) hedge paragraph "does not pay"→"buys nothing", "guesser's return"→"guesser's reward" (return-rate vocabulary, PLAN ~197); (d) Disclosure block cut "early curve positions are cheap by construction" (cost-basis brag inside a conflict statement — Munchee) → "minted on the same public curve as anyone else's"; (regression) "halving" REAPPEARED in my round-4 rewrite at §4 — the exact PLAN:620-banned word — → "falling by half over each two-year span". Critic's overall: lower exposure than prior draft; only the Disclosure was marketing-while-disclosing. | NOT-CLEAN (3 applied) |
| 6w | 2026-08-17 | (hold) | Round-4 panel (securities-new-surface, accuracy-new-claims, style-second-order) out. Draft frozen. Accuracy re-check stayed silent through the ping + one full fire — ABANDONED and relaunched fresh with the same 8-claim brief (tightened, 400-word cap). | WAIT |
| 6 | 2026-08-17 | style (seated) + structure | Applied the full round-3 panel. STRUCTURE (verdict "sound", 3 recs): §6 gains the moderator-origination sentence (VERIFIED moderation.gno:305-316 "only the court creator appoints moderators (until an election)" + creatorUnseated latch); mockup gains a glyph legend and the widest annotation shortened for phone width; §5's closing paragraph cut (restated §6's rule 30 words early — style critic independently flagged the same sentence as a paradox flourish). STYLE (register drift concentrated in section-capper aphorisms): all cappers flattened — subtitle → plain category, "Not evidence. Permission." → declarative, "record is the point/product" ×2 flattened, charity quip, rug-tricolon, furious-moderators, §7 self-regard, §8 poetic imperatives + period-pieces close; fight/fights (8×) → dispute/vote family; honestly/genuinely/actually → 0; permanently 6→4; the one second-person pronoun removed; §6 splice artifact from K2 repaired; "Bring a claim." CUT per the Nakamoto-only ruling (owner-reversible, see Register rulings above). 22+4 edits, ~3,500 words. Critic counts POST-edit: em-dashes in running prose 0, initial-And/So ≤3. | NOT-CLEAN (26 applied) |
| 5 | 2026-08-17 | cold-re-read (style + structure still out) | Cold reader #2: register HOLDS ("What changed was permission" earns the read; Abstract works); all four disclosures read as trust-building, not red flags; example reads as tool ("Courts judge claims, not teams" quote cited as the load-bearing line). THE decision question, third critic running to flag it: is hedged both-sides staking +EV? ANSWERED IN THE DOC now, code-verified first: stake.gno:168 escrows staked coins out of the ledger balance → absent from epoch snapshots → disenfranchised (PLAN.md:339,1368 confirms as design). New §2 paragraph: hedger earns a guesser's return at a believer's lockup, buys zero verdict power (verdicts = coin votes, not stakes), and equal both-sides stake moves the lean TOWARD even. Also simplified the §5 franchise sentence the reader had to read three times. K9 in HANDOFF stays (render-side netting still worth owner thought) but demoted: the mechanism already defuses the exploit. Two drift points (§4 parameter chain, Abstract middle) deferred to the seated style critic's counts. | NOT-CLEAN (2 applied) |
| 4 | 2026-08-17 | accuracy + prose + fact-check + skeptic + REGISTER | THE MEGA-PASS: full Satoshi-register rewrite (added Abstract; dry numbered titles; em-dashes 64→~10; second person ~0; self-certified candor removed; rhetorical Q→statement). Applied A1-A15 (incl. MAJOR: V2/V3 layering stated honestly in §3; "not yet deployed" in header/§7/§8; claimed-burn capture base + unclaimed-franchise reserve; polish-window fixed; m-of-n; creator-before-election; meta-emission exception; hide-verb quorum nuance), E1-E5 (all rhythm/dead-word/structure/close fixes; colophon flattened), F1-F5 (dated §1 arc; durable #7; #8→infected-animal-found FALSE for camp symmetry; #9 settled-TRUE + #10 pardon-privilege OPEN — intake decomposes; universities not states). Then K1-K5 surgical post-skeptic edits. 3,458 words (~7pp). Under the 3,800 floor — accepted per the logged note; padding would invert the register. | NOT-CLEAN (40+ applied) |

## Register rulings the owner can reverse in one word

- **"Bring a claim." was CUT** (round 6). Round-2 prose editor said it earned
  its drama; round-3 style critic, judging by the Nakamoto standard the owner
  set, said cut. The later, stricter directive governed. §8 now ends
  declaratively ("Individual verdicts will age...").
- The subtitle tagline became a plain category ("An on-chain court system for
  contested claims"), and the Abstract now closes on purpose-of-system rather
  than "The record is the product."
- To restore any of these, write it here; the loop will obey.

## Owner notes

(none yet)

### Note from the tokenomics session — WHITEPAPER.md was hand-edited (sorry)

I edited `WHITEPAPER.md` directly in two commits, `c44e2ab` and `1a5aaad`, before
reading this file's header asking that changes come through here instead. Flagging it
rather than leaving the loop to discover a conflict. **Nothing needs undoing** — the
edits are factual corrections, not prose changes — but the loop should treat §2 and §3
as touched and re-check them against its own state.

**What changed and why, so the loop can verify rather than re-derive:**

1. **§2 "Answered"** — the bond claim was *aspirational*. "Sized so that posting junk
   answers costs more than it can pay" was false for anyone staking dust on the side
   they declare, because the price keyed on the declared side alone. Now states the
   actual rule: priced against the **larger** of the two sides.
2. **§2 "Expired"** — added. Expiry was absent entirely, and it is a real limit: a
   court cannot hold a years-old open question, so a long dispute appears as a *series*
   of claims. That shape is forced by the twelve-week rule, not chosen.
3. **§2 "Voted"/consensus paragraph** — the participant bar was absent, and it is the
   strongest of the answers to "why vote the evidence rather than your book": the
   conflicted party is not paid to behave, they are **excluded**, and a stake record
   survives withdrawal. Promoted to first of five, with its cost stated — a claim needs
   turnout from people with nothing riding on it.
4. **§2 "Crystallized"** — separates what a staker is *promised* (the published rate,
   which nothing in settlement can cut) from what they are not (the discretionary
   bonus, capped by the money at risk behind the answer).
5. **§3** — was a "specified but not shipped" note; the work has since landed, so it now
   describes what runs, and names the two things still open.

**All of it is now shipped code**, verified: commits `aeba536`, `522e88e`, `76032ae`,
`80ab70d`. The reasoning, measurements and attacks are in `GAMETHEORY.md` and
`IMPLEMENTATION.md`.

**Two open items the loop should NOT describe as solved:** the cheapest way to destroy a
claim's reward is a low-turnout quality vote rather than the answer bond (a pending owner
decision); and staking **both** sides of a claim is currently profitable — small but
risk-free — which is a bug, recorded in `TODOs.md` §0a.
