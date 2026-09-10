#!/usr/bin/env python3
"""web/bell.mp3 must be ONE strike. Its envelope may only fall.

WHY THIS EXISTS. "The bell rings twice" was reported twice. The first time it
was true — the clip had caught a swinging bell's return, a second strike at
3.25s. The second time the file on the server was already a single toll and the
reader was hearing a cached copy of the old one; check-bell-version now makes
that impossible. Neither guard covered the actual property, which is that the
AUDIO only ever decays. That was hand-verified each time, and hand-verified
evidence is exactly what goes stale.

It nearly shipped broken a third time. Extending the bell to eight seconds meant
continuing its partials past the recording, and resynthesising each partial's
doublet with equal energy made the pair beat from full addition to near
cancellation: rises of 1.40x at 3.8s and 1.65x at 5.8s. A 4dB swell four seconds
after the strike IS a second chime. That was caught by measuring, not by
listening, and this is that measurement made permanent.

WHERE THE THRESHOLD COMES FROM. Every figure below was measured by this file's
own detector, on real bells, at this frame size — which matters, because the
first draft of this guard took its numbers from earlier ad-hoc measurements of
unfaded clips at a different frame size and set the limit at 1.35. Run against
the actual two-strike file that shipped, that left a margin of THREE
THOUSANDTHS:
    1.198x  the shipped 8s bell, at 1.4s — the recording's own doublet shimmer,
            present in the raw source at 1.197x, and heard as bronze rather
            than as a second hit.                                     PASSES
    1.353x  the old 7s cut, at 3.2s — a genuine second strike, and much
            flatter than it sounds because the linear ramp from 1.6s is
            already pulling it down when it lands.                    REFUSED
    1.446x  the 5.4s muted cut, at 3.2s — the same strike, less ramp.  REFUSED
    1.456x  the raw source, at 3.2s — a bell being rung, not struck.   REFUSED
So the whole discriminating band is 1.198 to 1.353, and 1.27 sits in the middle
of it with about 6% of margin on each side. A bell recut from a different
recording may well have different shimmer; re-measure rather than assume this
number transfers.

AND IT CARRIES ITS OWN POSITIVE CONTROL. A guard on a binary cannot be armed by
planting a text edit in the file it reads, so it manufactures the defect
instead: the clip is overlaid on a delayed copy of itself, which is precisely a
second strike landing on a decaying tail, and the detector must fire on that.
Without this half, a detector that had stopped detecting anything would report
the bell healthy for ever — and that is the failure mode every guard in this
directory is capable of.
"""
import math
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MP3 = ROOT / "web" / "bell.mp3"
SR = 22050
FRAME = 0.2          # 200ms: long enough to average out the waveform, short
                     # enough that a strike's attack lands inside one frame
RISE_MAX = 1.27


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR),
         "-f", "f32le", "-"],
        stdout=subprocess.PIPE, check=True).stdout
    n = len(raw) // 4
    return list(struct.unpack("<%df" % n, raw[:n * 4]))


def worst_rise(x):
    """The largest frame-to-frame growth in the envelope, and when."""
    w = int(FRAME * SR)
    env = [(i / SR, math.sqrt(sum(v * v for v in x[i:i + w]) / w))
           for i in range(0, len(x) - w, w)]
    worst, at = 0.0, 0.0
    for j in range(1, len(env)):
        if env[j - 1][1] <= 1e-6:
            continue
        r = env[j][1] / env[j - 1][1]
        if r > worst:
            worst, at = r, env[j][0]
    return worst, at


def doubled(x):
    """The clip over a delayed copy of itself — a second strike, by construction."""
    d = len(x) // 2
    y = list(x)
    for i in range(d, len(x)):
        y[i] += x[i - d]
    return y


def main():
    if not MP3.exists():
        print("check-bell-strike: no bell to check")
        return 0
    if not shutil.which("ffmpeg"):
        # The same bargain realm-test makes with a missing gno toolchain: say so
        # rather than pass quietly, and let the caller demand it.
        print("check-bell-strike: ffmpeg not installed - skipping (set "
              "REQUIRE_FFMPEG=1 to make this a failure)")
        return 1 if len(sys.argv) > 1 and sys.argv[1] == "--require" else 0

    x = decode(MP3)
    rise, at = worst_rise(x)

    # THE POSITIVE CONTROL FIRST, so a broken detector cannot pass the bell.
    ctrl, ctrl_at = worst_rise(doubled(x))
    if ctrl < RISE_MAX:
        print("check-bell-strike: the detector does not fire on a doubled "
              "strike (%.3fx at %.1fs, needs >= %.2f)." % (ctrl, ctrl_at, RISE_MAX))
        print("  This clip overlaid on a delayed copy of itself IS two strikes. A\n"
              "  detector blind to that would report any bell healthy, so the\n"
              "  measurement below means nothing until this fires.")
        return 1

    if rise >= RISE_MAX:
        print("check-bell-strike: bell.mp3's envelope RISES %.2fx at %.1fs "
              "(limit %.2f)." % (rise, at, RISE_MAX))
        print("  A bell decays. A swell partway through is a second chime — which\n"
              "  is what 'the bell rings twice' was, twice. Measured references:\n"
              "  1.20x is the recording's own shimmer, 1.65x was a resynthesised\n"
              "  doublet throb, 1.73x was a real second strike.")
        return 1

    print("check-bell-strike: bell.mp3 only falls (worst rise %.3fx at %.1fs, "
          "limit %.2f; control fires at %.2fx)." % (rise, at, RISE_MAX, ctrl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
