"""A Digital Privacy court: one thesis, fourteen findings, seven sets.

WHY THIS FILE EXISTS AT ALL, which is the point worth reading first. The court it
builds was created by hand against the live chain — a court, a claim, seven
folders, fourteen more claims and eleven edges, thirty-two signed transactions —
and none of it was in the tree. A reseed runs ONE scenario and starts the chain
from genesis, so the next `seed-remote.sh` would have erased the lot with nothing
in the repo to rebuild it from. That is the whole reason a court belongs in a
scenario rather than in a shell history: the chain is not the record, this is.

TWO WAYS TO RUN IT, and they differ in one line:

    # a fresh chain that holds THIS court and nothing else (destructive)
    OWNER_ADDR=g1yours... CONFIRM=yes sh scripts/seed-remote.sh scenarios/privacy.py

    # or replay it onto a chain that already has other courts
    python3 scripts/scenario.py scenarios/privacy.py --emit plan --out /tmp/privacy.sh

The second is what makes this court survivable alongside covid_demo's: a reseed
cannot be incremental (EnableTestClock refuses on a realm with any history), but
the emitted PLAN is just gnokey calls and can be replayed onto a running chain.
Nothing here arms the clock, which is what keeps that option open.

THE CREATION BURN IS PRICED BEFORE THE COURT IS OPENED, and that ordering is
load-bearing. courtCreationBurnInit ships at zero and covid_demo turns it on at
2 GNOT in its LAST few steps — after its own courts are open, so its
`StartCourt` sends nothing. This scenario has to work in both worlds: on a fresh
chain the burn is off, and replayed onto the live chain it is already 2 GNOT. So
it sets the price itself and then pays it, which is correct either way instead of
correct in one.

WHAT THE COURT ARGUES, and the honest limits of it. Every claim below is filed
from ONE investigation — Gamers Nexus, "216,000,000 Spy TVs | The LG Smart TV
Problem", 2026-09-06 — and each body names the timestamp it came from so a reader
can check it rather than take it. The claims are propositions about what a
product does, not about anyone's intent, and one report is where a claim like
this starts, not where it ends.

    sh scripts/seed-node.sh scenarios/privacy.py
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import Scenario, DEPLOYER  # noqa: E402

# Never a txtar: it asserts on a real court's shape rather than on one rule, and
# the whole file is content.
CI = False

SLUG = "privacy"

# 2 GNOT, matching what covid_demo leaves the chain at. Named once so the price
# set and the price paid cannot drift apart.
CREATION_BURN = 2_000_000

# Enough coin to cover fifteen claim deposits at the 1 CC dust floor plus their
# fees. 1 GNOT mints ~44.7 CC on a fresh curve — cost is ceil(minted²/2e9), so
# the first GNOT buys far more than the filing needs, and buying more would burn
# GNOT this court has no use for.
SEED_BUY = 1_000_000

DESC = ("Claims about what consumer devices do with what they can see, hear and "
        "record — and whether the buyer can refuse it. Behaviour, not intent: "
        "what the device sends, to whom, and what a refusal actually changes.")

THESIS_TITLE = ("LG smart TVs operate as spyware: they fingerprint what is on the "
                "screen and capture room audio, and send it off the set for ad "
                "targeting, without consent a buyer can refuse")

THESIS_BODY = """The proposition: an LG smart TV, as sold and in its default state, collects data about what is watched and what is said in the room, and transmits it for commercial use — and a buyer cannot decline this and keep the functions the set was advertised with.

Filed on the evidence assembled in the Gamers Nexus investigation "216,000,000 Spy TVs — The LG Smart TV Problem" (2026-09-06, 2h16m). What that report sets out, by its own sections:

- ACR (automatic content recognition) fingerprints whatever reaches the screen, including from attached inputs, and reports it upstream. LG's own sales language for this is quoted: we own the glass (13:19).
- Audio was captured from the microphone, and video from a webcam, while the set appeared to be off — and audio was still captured with the set unplugged from the network (0:00, 46:19, 55:19).
- Captured speech was found stored as plain-text transcripts (46:19).
- The sets were observed acting as residential proxies and opening ports by UPnP (58:42).
- The data reaches LG Ad Solutions and Alphonso, with further third-party connections (1:13:53, 1:21:15).
- Consent is obtained through dark patterns (22:04); the agreements impose forced arbitration (1:28:23); and DMCA s1201 is cited as deterring the independent research that would settle the question (1:38:33).

This is a claim about what the product does, not about anyone's intent. One investigation is where a claim like this starts, not where it ends: LG's own response, independent replication, model and firmware differences, and any evidence that the collection can in fact be refused all belong on the board."""

# (key, name, desc, parent-key or None). Order is the id order: folder ids are
# assigned sequentially from 1, so a parent must be listed before its children.
SETS = [
    ("captures", "What it captures", "The set's own sensors and what they take in.", None),
    ("hears", "What it hears", "The microphone, and what becomes of what it picks up.", "captures"),
    ("sees", "What it sees", "The panel and its inputs, fingerprinted.", "captures"),
    ("network", "Your network", "What the set does to the house it is plugged into.", None),
    ("goes", "Where it goes", "Who receives it once it leaves the set.", None),
    ("refuse", "Can you refuse", "The consent the buyer is offered, and what it covers.", None),
    ("untested", "Why it goes untested", "What stands between the claim and a test of it.", None),
]

# (key, set-key, title, body). Again in id order — the thesis is claim 1, so
# these are 2..15.
CLAIMS = [
    ("micoff", "hears",
     "An LG TV captured microphone audio while the screen appeared to be off",
     "Gamers Nexus reports recording from the TV's microphone while the set "
     "appeared to be off, and describes the result as a clean capture rather "
     "than a degraded one (0:00). The proposition is about the powered-down "
     "appearance specifically: a set that looks off to the room is still taking "
     "audio in."),
    ("micunplug", "hears",
     "An LG TV captured microphone audio while it was unplugged from the network",
     "Reported at 0:00 and returned to at 10:06, where the investigation "
     "addresses the common belief that pulling the Ethernet cable is enough to "
     "stop the set collecting. If audio is captured with no network attached, "
     "the collection is local and the network only decides when it leaves."),
    ("plaintext", "hears",
     "Speech picked up in the room was found stored on the TV as plain-text transcripts",
     "At 46:19 the investigation recovers what it describes as a speech-to-text "
     "log of things said in the room. The claim is about the STORED artefact: "
     "not an audio buffer, but text, which is cheap to keep indefinitely."),
    ("eightk", "hears",
     "Captured audio is downsampled to 8 kHz mono, a format for cheap speech storage rather than for sound",
     "Described at 26:08. 8 kHz mono is telephone-grade: it is the wrong choice "
     "for reproducing sound and the right one for keeping intelligible speech "
     "small. The claim is that the processing is shaped for retention of words."),
    ("webcam", "sees",
     "An LG TV can record from a connected webcam while it appears to be off",
     "Stated at 0:00 alongside the microphone finding. Distinct from the audio "
     "claims because it needs an attached camera, so it bears on what a set "
     "with a peripheral can do rather than on every set as shipped."),
    ("acr", "sees",
     "ACR fingerprints whatever reaches the screen and matches it against media databases to identify the household's viewing",
     "At 13:19 the investigation quotes LG's own sales language for automatic "
     "content recognition — that they know who is in the household, which "
     "devices are there and what those people are exposed to on TV. The claim "
     "is that the panel's contents are converted to a fingerprint and "
     "identified, not merely counted."),
    ("acrmonitor", "sees",
     "ACR keeps running when an LG TV is used as a plain monitor",
     "Reported at 13:19. This is the claim that matters to anyone who thought "
     "the answer was to stop using the smart features: if fingerprinting "
     "continues on an HDMI input, declining the apps does not decline the "
     "watching."),
    ("lanscan", "network",
     "An LG TV continuously scans the local network and harvests device names, signal strengths and MAC addresses",
     "At 16:33, from intercepted traffic and from decompiled firmware: a "
     "continuous scan of the LAN collecting display names, signal strength and "
     "MAC addresses, which are uniquely identifiable per device. The claim is "
     "about inventorying the household's other hardware, which is a different "
     "act from watching the screen."),
    ("proxy", "network",
     "LG TV apps enrol the set as a residential proxy, renting the household's connection to third parties",
     "At 58:42, on findings attributed to Spur: proxy companies were often the "
     "publishers of the apps, suggesting the apps existed to acquire "
     "residential IP addresses. Amazon and Roku are reported to have already "
     "banned apps doing this. The claim is that the household's connection is "
     "resold, which puts a stranger's traffic behind its address."),
    ("alphonso", "goes",
     "LG Ad Solutions is Alphonso Inc., in which LG took a controlling stake in 2021",
     "At 1:13:53: LG Ad Solutions states it is incorporated as Alphonso Inc., "
     "and LG acquired a controlling stake in 2021, described at the time as "
     "building a cross-device advertising platform for LG TVs. The claim "
     "identifies the corporate destination rather than characterising it."),
    ("toggle", "refuse",
     "The privacy toggle offered at setup does not control tracking; it controls advertising frequency-capping cookies",
     "At 22:04. The switch reads as a choice about being tracked and, on "
     "inspection, governs how often a given advert is repeated. The claim is "
     "that the control offered and the control implied are different things — "
     "which is what makes it a dark pattern rather than a poor default."),
    ("clicks", "refuse",
     "Reading LG's agreements on the TV took 1,246 remote clicks for six user agreements and 1,459 more for four account terms",
     "Counted on camera at 1:02:46, with the observation that the set may sleep "
     "before a reader finishes. A precise, checkable number, and the most "
     "testable claim in this court: anyone with the same model can repeat the "
     "count."),
    ("arbitration", "untested",
     "LG's agreements impose forced arbitration, removing the buyer's route to a court",
     "At 1:28:23, with Louis Rossmann. The claim is narrow and legal rather "
     "than technical: whatever the set does, the agreement a buyer accepts to "
     "use it forecloses the venue in which they could contest it."),
    ("dmca", "untested",
     "DMCA section 1201 makes removing the surveillance a potential copyright crime",
     "At 1:38:33: circumventing a digital lock can itself be an offence, "
     "independently of what is behind the lock. The claim is that the law "
     "deters the modification and the independent research that would settle "
     "every other claim in this court."),
]

# (from-key, to-key or "THESIS", stance)
#
# NOT A HUB, AND THE REALM IS WHY. maxAssocInPerAuthor is 4: one author may hang
# at most four edges on any single claim, because filling a claim's 64 inbound
# slots is meant to cost sixteen distinct addresses each paying its own storage
# deposit. The hand-built version of this court pointed all fourteen findings at
# the thesis and was refused on the fifth — "you already hold 4 associations on
# that claim" — with four already on chain. That refusal is the design working: a
# map built by one voice is SUPPOSED to be thin at the top, and the rest of the
# thesis's inbound edges are for other people to assert.
#
# So four go to the thesis and the rest are local and evidential. Claims that
# merely share a subject are related by their SET, which is what folder
# membership already says; an association asserts that one claim BEARS ON
# another, and inventing those to fill out a picture would be the one dishonest
# thing this court could do. Hence no edge between the LAN scan and the
# residential proxy: both are the set using the household's network, and neither
# is evidence for the other.
EDGES = [
    ("micoff", "THESIS", "supports"),
    ("micunplug", "THESIS", "supports"),
    ("plaintext", "THESIS", "supports"),
    ("eightk", "THESIS", "supports"),

    ("eightk", "plaintext", "supports"),      # the format explains the retention
    ("webcam", "micoff", "supports"),         # same "appears off", second sensor
    ("acrmonitor", "acr", "supports"),        # extends ACR past the smart features
    ("alphonso", "acr", "supports"),          # names the destination it serves
    ("clicks", "toggle", "supports"),         # unreadable terms leave only the toggle
    ("clicks", "arbitration", "supports"),    # the unread agreement is the one that binds
    ("dmca", "arbitration", "supports"),      # the second bar to ever testing this
]

STANCE_ARG = {"supports": "supports", "contests": "contests"}

s = Scenario("privacy", __doc__.split("\n\n")[0])

# ---- the court -------------------------------------------------------------
# Priced first, then paid — see the header. SetCourtCreationBurn to a value the
# chain may already hold is harmless and keeps this correct on a fresh chain too.
s.call(DEPLOYER, "SetCourtCreationBurn", [str(CREATION_BURN)])
s.call(DEPLOYER, "StartCourt", [SLUG, "Digital Privacy Court"],
       send=f"{CREATION_BURN}ugnot", note="the court, and the burn that opens it")
s.call(DEPLOYER, "SetCourtDesc", [SLUG, DESC])

# Coin before claims: a claim costs a deposit in the COURT'S OWN coin, and a
# court that has just been created has none of it. This is the step whose absence
# makes every OpenClaim below fail on an insufficient balance.
s.buy(DEPLOYER, SLUG, SEED_BUY)

# The thesis is claim 1, and it is filed OUTSIDE any set: it is what the court is
# about, not one of the findings under it.
s.claim(DEPLOYER, SLUG, THESIS_TITLE, THESIS_BODY)
THESIS_ID = 1

# ---- the sets --------------------------------------------------------------
# ids are sequential from 1 in creation order, which is why SETS is ordered
# parents-first rather than alphabetically.
FID = {}
for key, name, desc, parent in SETS:
    FID[key] = len(FID) + 1
    if parent is None:
        s.folder(DEPLOYER, SLUG, name, desc)
    else:
        s.call(DEPLOYER, "CreateFolderIn", [SLUG, str(FID[parent]), name, desc])

# ---- the findings ----------------------------------------------------------
CID = {}
for key, setkey, title, body in CLAIMS:
    CID[key] = THESIS_ID + len(CID) + 1
    s.call(DEPLOYER, "OpenClaimIn", [SLUG, str(FID[setkey]), title, body])

# ---- the argument ----------------------------------------------------------
for frm, to, stance in EDGES:
    a = CID[frm]
    b = THESIS_ID if to == "THESIS" else CID[to]
    s.call(DEPLOYER, "AddAssociation", [SLUG, str(a), str(b), STANCE_ARG[stance]])

# ---- what the seed promises ------------------------------------------------
# final=True on all three: these are claims about the chain when the scenario
# ENDS, which is the only thing the genesis path can read back — it applies every
# transaction in one block and cannot assert anything at a point in the middle.
# THE SLUG GOES IN BARE. The emitter quotes a string argument itself and refuses
# to guess at nested quoting — passing '"privacy"' produced a backslash-quote
# inside an already-quoted argument and it declined the whole plan, correctly.
s.expect("ClaimCount", [SLUG], r"[(]%d uint64[)]" % (1 + len(CLAIMS)), final=True,
         note="the thesis plus every finding")
s.expect("FolderCount", [SLUG], r"[(]%d int[)]" % len(SETS), final=True,
         note="seven sets, two of them nested")
s.expect("CourtDesc", [SLUG], r"what a refusal actually changes", final=True,
         note="the court says what belongs in it")

# The harness reads this name, not a main(): scenario.py imports the module and
# takes SCENARIO off it, so every emitter sees the same built object.
SCENARIO = s
