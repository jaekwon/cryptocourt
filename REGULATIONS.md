# REGULATIONS.md — US regulatory reference for cryptocourt

> Research reference, **not legal advice**. Compiled from three primary-source
> research passes (gambling/state law; CFTC/CEA; securities + "information system"
> defense) + a crypto-securities case-law pass, current to ~Aug 2026. Tags:
> **[SETTLED]** / **[CONTESTED]** / **[UNTESTED]**. Items that could not be
> re-verified against primary sources this session are marked **[verify]**.
> Append new findings at the bottom (§9) with dates.

## 1. The three regimes in one view

| Axis | Hook | Escape that actually works |
|---|---|---|
| State gambling | consideration + chance + prize; operator liability for "advancing/profiting" even with no house | Remove an element (no loss of principal → weak/no consideration-loss; no real-money prize), or CEA preemption via CFTC registration |
| CFTC / CEA | binary event contract = "swap"/option in *exclusive* CFTC jurisdiction (7 U.S.C. §1a(47)(A)(i)-(ii)); settlement timing irrelevant | Register (DCM+DCO), or don't be a bilateral event-contingent payment at all |
| Securities (SEC) | Howey investment contract; yield/appreciation expectations from others' efforts | Fail a prong (consumption purchase, no common enterprise, no efforts-of-others); non-binding 2025 staff posture is friendly but reversible |

**Master finding:** no U.S. prediction market has EVER been held "not gambling" or
"not a derivative" on the merits by relabeling. The two proven escapes are (a)
become a regulated derivative (CEA preemption), or (b) remove the wager substance.
Cryptocourt V2 takes (b). [SETTLED as to the history; (b)'s specific shape UNTESTED]

## 2. State gambling law (details)

- Elements: consideration + chance + prize (FCC v. ABC, 347 U.S. 284 (1954)).
  "Chance" = outcome not under the actor's control/influence. Tests by state:
  predominance (majority), "any chance" (minority — e.g. AZ/AR/IA/TN [verify]),
  **material element** (MPC/NY — skill does NOT save you), gambling-instinct
  (historical). N.Y. Penal Law §225.00 verbatim covers staking on "a future
  contingent event not under his control or influence". [SETTLED]
- Skill-in-predicting an uncontrolled outcome is still chance-wagering: sports
  betting; DFS (~10 AGs called it gambling 2015-16; NY *legislated* an exception;
  White v. Cuomo, 38 N.Y.3d 209 (2022) — App. Div. said gambling, Ct. App.
  reversed on roster-control; CA AG Op. 23-1001 (2025) DFS = illegal wagering).
  [SETTLED framework; per-state CONTESTED]
- **No-house/P2P does not help**: operator "advances"/"profits from" gambling
  (NY §225.00); exchanges = bookmaking/pool wagering; Intrade (pure P2P) killed
  by CFTC suit (2012). [SETTLED]
- Humphrey v. Viacom (D.N.J. 2007): entry fees ≠ bets where fees are paid
  win-or-lose, prizes are **predetermined and not funded by the entries**, and
  the operator is **not a stakeholder** — the structural template V2's
  emission-funded (not loser-funded) rewards lean toward. [PARTIALLY VERIFIED]
- Federal overlay defers to state law: UIGEA (31 U.S.C. §5361-67, payment rule,
  §5362(10) defers; the DFS carve-out ≠ legality); IGBA (18 U.S.C. §1955 requires
  a state-law violation); Wire Act sports-only in the 1st Cir. (NH Lottery v.
  Rosen, 986 F.3d 38 (2021)) — likely not the hook for fact claims. [SETTLED/1st Cir.]

## 3. CFTC / CEA (details)

- "Swap" reaches event contracts twice: §1a(47)(A)(i) (option of any kind) and
  (A)(ii) (payment "dependent on the occurrence... of an event or contingency
  associated with a potential financial, economic, or commercial consequence") —
  **no futurity requirement**; instant settlement irrelevant. "Excluded
  commodity" §1a(19)(iv). No "actual delivery" escape (§2(c)(2)(D) is for
  physical retail commodities). [SETTLED]
- Lawful retail path = DCM + DCO only (Kalshi; Polymarket-US via acquiring QCX,
  DCM 7/9/2025; Aristotle DCM 9/5/2025). Off-exchange = per-se illegal
  (In re Blockratize/Polymarket, CFTC 22-09 (2022), $1.4M). [SETTLED]
- **Decentralization is no defense**: CFTC v. Ooki DAO (N.D. Cal., default
  judgment 6/8/2023): a DAO is a "person"; members = token-holders who VOTED;
  personal liability theory (contested — default judgment, Mersinger dissent).
  Reaches admin keys, governance cohorts, fee recipients, front-ends. [outcome
  SETTLED; voter-liability theory CONTESTED]
- §5c(c)(5)(C) special rule (unlawful activity / terrorism / assassination / war /
  gaming / similar): Kalshi v. CFTC (D.D.C. 9/12/2024) — elections ≠ gaming;
  CFTC's block power narrow; appeal dropped 5/7/2025. 2024 restrictive NPRM
  (89 FR 48968) withdrawn 2/6/2026 (91 FR 5386); narrower "Prediction Markets"
  NPRM 91 FR 35806 (6/12/2026) **proposed, not final** — re-pull when final.
  [SETTLED / EVOLVING]
- CEA preemption of state gambling law exists **only for registered products**
  (3d Cir. KalshiEX v. Flaherty, 172 F.4th 220 (2026) [verify]; mixed state
  results; Ohio held sports contracts gambling; no SCOTUS). [CONTESTED]
- No-action lane (IEM 1992/93; PredictIt 14-130 (2014) → revoked 8/4/2022 →
  Clarke v. CFTC, 74 F.4th 627 (5th Cir. 2023) = APA-only; relief restored/
  modified 25-20 (2025)): academic, non-profit, capped — does not scale, not a
  merits ruling. [SETTLED]

## 4. Securities (details)

- Howey (328 U.S. 293): money / common enterprise / profit expectation / efforts
  of others. Glosses: "solely" ≠ literal (Turner, 9th Cir. 1973 — "undeniably
  significant" managerial efforts); commonality has a circuit split (horizontal
  vs vertical); fixed returns count (Edwards); consumption defeats profit
  expectation (Forman). [SETTLED]
- **YES/NO outcome positions: likely NOT securities** — payout from an exogenous
  fact + counterparties, not managerial effort (Noa v. Key Futures; Belmont
  Reid); zero-sum P2P lacks horizontal commonality (Revak; Milnarik). FLIPS if
  the operator pools stakes / markets returns (SEC v. SG Ltd., 265 F.3d 42 (1st
  Cir. 2001) — "it's a game" label did not control). "Not a security" ≠
  unregulated (CFTC/gambling still apply). [SETTLED doctrine, application untested]
- **Bonding-curve coin: likely a security at issuance while an identifiable team
  drives value** (DAO Report 2017 — voting doesn't help; Munchee 2017 — "utility"
  label doesn't help). Secondary-market status genuinely unresolved, NO circuit
  precedent: Ripple (programmatic sales not securities; $125M paid 2025,
  district-only) vs Terraform (manner-of-sale rejected, MTD 7/31/2023) vs
  Coinbase/Failla (ecosystem view; dismissed w/ prejudice 2/27/2025) vs
  Binance/Jackson (rejects per-se "embodiment"). [CONTESTED]
- **Bonding curves specifically: NO SEC precedent** — only private litigation
  (pump.fun / Baton Corp. class action(s), S.D.N.Y. 2025, caption/docket
  [verify]; no merits ruling). A genuine gap. [UNTESTED]
- 2024-26 SEC posture: sharp pullback — Peirce Crypto Task Force (1/2025),
  Atkins chair (4/21/2025), marquee cases dropped, staff statements that
  memecoins / PoW mining / protocol staking / covered stablecoins are generally
  not securities (non-binding; Crenshaw dissents), SAB 122 rescinds SAB 121,
  GENIUS Act enacted (PL 119-27, 7/2025), CLARITY Act pending, 2026 SEC
  interpretive release w/ 5-category token taxonomy. Friendly but **non-binding
  and reversible**. [SETTLED as fact; durability UNKNOWN]
- The memecoin statement does NOT cover a coin with governance + utility + yield
  (all three pull back toward Howey) and carves out structures "designed to
  evade". [SETTLED as to the statement's own terms]
- Protocol-staking statement (5/2025): staking rewards for protocol participation
  generally not securities transactions — the friendliest analogy for V2's
  emission ("participation rewards"), though cryptocourt's emission rewards
  *correctness in a contest adjudicated by vote*, which is further from
  ministerial validation than PoS. [helpful analogy, UNTESTED fit]

## 5. The "information system" defense — verdict

As a relabel: **WEAK → form-over-substance**. No court has adopted an
information/speech rationale (Kalshi won on statutory grounds + preemption, not
the 1st Amendment; a 3d Cir. dissent called the relabel "alchemy"; Giboney:
speech integral to conduct is regulable). IEM/PredictIt's "research purpose" was
a discretionary, revocable, non-generalizable accommodation. It becomes
defensible only by CHANGING SUBSTANCE: (a) be a regulated derivative on
non-contest verifiable facts, or (b) remove the peer-funded money wager — V2
takes (b). [SETTLED as to history]

## 6. Design levers — what actually matters

| Lever | Effect |
|---|---|
| Loser-funded payouts (zero-sum) vs issuance-funded | **Material** — the single cleanest de-gambling change |
| Real money exits contingent on outcomes | **Material** — avoid entirely (V2: GNOT burned, rewards in CC) |
| Subject: verifiable fact vs election/sports/awards "contest" | **Material** — contests trip CEA "gaming" + state law |
| CFTC DCM registration | **Material** — the only state-law preemption |
| Payout = predetermined/formulaic, operator not a stakeholder | **Material** (Humphrey factors) |
| "Factual claims only", "no future settlement", correctness-weighting | Partial/cosmetic — substance controls |
| Non-transferable positions | Helps securities, can forfeit preemption; product cost |
| Decentralization / non-custody | Helps securities (efforts-of-others), **does not help** CFTC/gambling (Ooki, Polymarket) |
| Non-profit / "verdict-as-product" framing | Rhetoric, not doctrine |

## 7. Cryptocourt-specific exposure map (V2)

1. **Emission-funded winner rewards** — recharacterization risk as a common-pool
   prize via dilution (accepted gray, owner sign-off; see PLAN.md §7.2).
2. **CC coin under Howey** — yield-ish emission + paid contributors strengthen
   prongs 3/4; mitigants: non-redeemable in-protocol (transferable), work/correctness-gated
   rewards, comms hygiene, no treasury expectations (GNOT burned). Main
   accepted risk.
3. **Voter liability (Ooki theory)** — mitigate with a Wyoming DUNA wrapper
   (2024 act: member-liability shield for DAO-like associations [verify with
   counsel]), rules-based payouts only, no real-money flows directed by votes.
4. **Forfeitable answer/dispute/flag bonds** — retained, but as of PLAN v0.11
   every forfeiture BURNS in full and the prevailing party is compensated by a
   capped protocol-emission slice ("forfeitures burn; compensation mints"):
   no loser-pays-winner transfer exists anywhere. This removed the vet-ranked
   #1 residual on both the gambling and CFTC axes (V1's own doc had described
   bonds as "a bet between two people"). Remaining theory: conduct-priced loss
   on a vote outcome, defended on the appeal-bond/sanction analogy —
   materially stronger post-burn, still [UNTESTED].
5. **Claims subject matter** — avoid elections/sports/awards categories; prefer
   verifiable factual/economic claims. Editorial policy, cheap to keep.

## 8. Standing to-dos for counsel

- Opinion: no-loss + bounded-emission + burn structure vs state gambling (esp.
  material-element and any-chance states) and CEA §1a(47)(A)(ii).
- Opinion: CC under Howey with emission; transferability on/off.
- DUNA formation + fit for the governor/`grc20votes` cohort.
- Re-pull when final: CFTC "Prediction Markets" rule (91 FR 35806); CLARITY Act;
  pump.fun/Baton docket status.

## 9. Append log (new findings below, dated)

- 2026-08-15: Initial compilation from the three DD memos + crypto case-law pass.
- 2026-08-15 (legal vet, primary-sourced): **Kent v. PoolTogether** verified from
  the order (E.D.N.Y. 21-cv-6025, Doc. 135, 6/7/2023): no-loss crypto protocol;
  dismissed for lack of Article III standing (withdrawable principal ⇒ no
  injury; foregone interest "a problem of his own making"); WITHOUT prejudice;
  court analogized to prize-linked savings ("no-loss lotteries"). Standing-only
  — blocks private suits, not AGs. [SETTLED as to holding]
- 2026-08-15: **Prize-linked savings cuts AGAINST "returned principal ⇒ no
  consideration"**: American Savings Promotion Act, Pub. L. 113-251 (2014,
  govinfo-verified) defines a savings-promotion raffle's returnable deposit as
  its "sole consideration" and had to statutorily exempt such raffles from
  lottery law. Argue "nothing staked or risked UPON THE OUTCOME" (N.Y. Penal
  §225.00(2), text verified) — not "no consideration". [SETTLED]
- 2026-08-15: **Humphrey pin verified** (2007 WL 1797648 at *9): factors = fees
  unconditional / prizes "amounts certain and guaranteed" / operator doesn't
  compete. Variable pro-rata shares flunk factor 2; a fixed published RATE
  scores better than a contested pool (the V2 reservoir helps here). Also Las
  Vegas Hacienda v. Gibson, 77 Nev. 25 (1961) (fee that doesn't make up the
  purse ≠ wager). [PARTIALLY VERIFIED — unpublished op.]
- 2026-08-15: **White v. Cuomo (38 N.Y.3d 209, 2022) also supplies a
  fixed-prize/entry-fee principle** (verified, NY official reporter): prizes
  predetermined, announced, neutral operator, unchanged by entrant numbers/fees
  ⇒ not gambling under the NY Constitution; "dominating element" standard.
  Nuances §2's "material element — skill does NOT save you" line: Penal Law
  text unchanged, but the state's high court is friendlier to fixed-prize
  contest design than the AG-era posture suggested. [SETTLED]
- 2026-08-15: **KalshiEx v. Flaherty verified from the 3d Cir. opinion**
  (No. 25-1922, decided 4/6/2026): PI affirmed; field+conflict preemption of NJ
  gambling law **limited to swaps on CFTC-licensed DCMs**; BOTH majority and
  dissent read §1a(47)(A)(ii) broadly (sports outcomes fit "associated with a
  potential financial, economic..." consequence). [SETTLED; F.4th cite verify]
- 2026-08-15: **CFTC rulemaking chain re-verified via Federal Register API** +
  ONE GAP the original DD missed: "Data Reporting Requirements for Certain
  Event Contracts," proposed 7/1/2026 (doc 2026-13239). Re-pull all four at
  final. [SETTLED as to existence]
- 2026-08-15: **Wyoming DUNA verified from enrolled 2024 SF0050** (W.S.
  17-32-101–129, eff. 7/1/2024): ≥100 members (auto-conversion below,
  §114(b)(iii)); no dividends (§104(b)) BUT "reasonable compensation … for
  services rendered, including … voting or participation" expressly permitted
  (§104(c)(i)); member shield §107/§109; DLT governance §121–122; §118(b)
  preserves other law (federal untested); membership-consent mechanics needed;
  tax unresolved. [SETTLED as to statute text]
- 2026-08-15: **Munchee burn passage verified** (33-10445): the SEC cited a
  token-burn-for-scarcity-appreciation pitch as Howey evidence. Never market
  the GNOT burn as scarcity/"monetary meme"; describe as verifiable on-chain
  mechanics. [SETTLED]
- 2026-08-15: **SEC protocol-staking statement verified via proxy** (5/29/2025):
  rewards from "administrative or ministerial" protocol participation are not
  securities transactions; excludes liquid staking/restaking; staff-level, no
  legal force. Helpful analogy for V2 emission; imperfect fit (V2 rewards
  adjudicated correctness). MSB/ICO-seller-of-own-CVC characterization of the
  one-way curve: FinCEN 2019 guidance could not be fetched [verify] — counsel
  checkbox added to PLAN §7.5.
