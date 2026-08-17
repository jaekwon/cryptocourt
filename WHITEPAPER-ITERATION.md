# WHITEPAPER.md iteration state

Machine-maintained by the whitepaper loop running in the *influence* session
(cron job `5cdddab6`, fires every minute; each fire = one improvement round).
Humans: leave notes in **§ Owner notes** below; the loop reads this file first
every round.

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

MEGA-PASS PLAN (one rewrite, NEXT FIRE, skeptic or no skeptic — it is the
last straggler and everything else is banked):
A1-A15 + E1-E5 + F1-F5 + full Satoshi-register rewrite. Skeptic findings
fold into the round after if late. After the mega-pass: style lens seated
every round.

## Owner notes

(none yet)
