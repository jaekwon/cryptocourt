#!/usr/bin/env python3
"""Let Emmanuel ring on past the point where the recording interrupts it.

THE PROBLEM. The source is ten seconds of a bell being RUNG, not struck once:
fresh strikes land at 3.3s and 4.2s and the level never falls below ~0.38 of
peak until the file simply ends. The only clean decay in it is 0 to ~3.2s, which
is why the shipped clip is 3.15s. There is no longer take to cut.

WHAT A BELL TAIL IS. After the transient, a bell is a sum of exponentially
decaying sinusoids — that is the physics. Measured here: hum 89Hz, prime 170,
tierce 213, nominal 356 (loudest), then 444, 532, 940. So the tail can be
CONTINUED rather than invented: same partials, same decay, past the splice. The
attack and 2.4s of real bell are untouched and the join is crossfaded. Nothing
here is a synthesised bell; it is this bell's own voice, extrapolated.

TWO MEASUREMENTS THAT HAD TO BE DONE PROPERLY.

  THE BEAT. Every partial of a real bell arrives as a DOUBLET a fraction of a
  hertz apart, because the casting is never perfectly axisymmetric, and the slow
  beat between each pair is the shimmer that makes bronze sound like bronze. A
  1s Hann window resolves 4Hz and cannot separate a 0.85Hz pair, so trying to
  fit the two members separately just walks both onto the same blended peak.
  The beat is measured instead from the ENVELOPE of the band — where |A(t)|
  dips, the pair is out of phase — and resynthesised as a true doublet.

  THE DECAY, which is NOT measurable per partial from this recording. Two
  windows gave nonsense — half the partials read "never decays", because the
  windows sat 1.1s apart and the beat period is ~1.2s, so each landed at a
  different point of the same beat and their ratio described the beat. A nine
  point regression over the same 2s was no better: the wobble inside the fitting
  span reaches 20dB and five of seven groups pinned to the floor. Two seconds of
  a beating pair does not contain the answer.
  Measured BROADBAND it is clean, because the two members of a doublet cannot
  cancel in total band energy the way they do at the group's centre: 1.47dB/s
  over 0.7-2.7s, 4.4dB of residual wobble, a half-life of 4.1 SECONDS. Each
  partial then takes that rate scaled by sqrt(f/356), since a bell's high
  partials damp faster than its hum — the shape is a model, the rate is measured.

AND SO NO LICENCE IS NEEDED, which was a surprise. The plan had been to slow the
decay artificially on the grounds that a 13-tonne bourdon must ring longer than
the recording suggests. It already does: at 1.47dB/s the tail is only 9dB down
six seconds past the splice. The earlier -6.7dB/s figure came from measuring the
SHIPPED clip, which has a fade baked into its last 0.8s — the fade, not the
bell. The 3.15s clip was never short because the bell is short. It was short
because the ringer struck it again. The --decay knob survives as a flag and
defaults to 1.0, which is to say: off.
"""
import argparse
import math
import struct
import subprocess

SR = 44100


def decode(path, sr=SR):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
        stdout=subprocess.PIPE, check=True).stdout
    return list(struct.unpack("<%df" % (len(raw) // 4), raw[:len(raw) // 4 * 4]))


def demod(x, f, centre, width):
    """Complex amplitude of f at time `centre`, phase referred to that centre."""
    n = int(width * SR)
    i0 = int(centre * SR) - n // 2
    if i0 < 0 or i0 + n > len(x):
        return 0.0, 0.0
    re = im = wsum = 0.0
    for k in range(n):
        w = 0.5 - 0.5 * math.cos(2 * math.pi * k / (n - 1))
        t = (k - n / 2.0) / SR
        a = 2 * math.pi * f * t
        v = x[i0 + k] * w
        re += v * math.cos(a)
        im -= v * math.sin(a)
        wsum += w
    return math.hypot(re, im) * 2.0 / wsum, math.atan2(im, re)


def refine(x, f0, centre, width, span):
    """Search for the group's true centre frequency, held near the seed."""
    best, bf, step = -1.0, f0, span
    for _ in range(4):
        cand = [bf + step * s for s in (-1, -0.5, 0, 0.5, 1)]
        for f in cand:
            if abs(f - f0) > span * 1.5:
                continue
            m, _ = demod(x, f, centre, width)
            if m > best:
                best, nf = m, f
        bf, step = nf, step / 2.5
    return bf


def broadband_decay(x, t0, t1):
    """The one decay rate that IS measurable here. See the module docstring:
    total band energy does not suffer the doublet cancellation that ruins a
    per-partial fit, so this regression is over a 4dB wobble, not a 20dB one."""
    def rms(t, w=0.20):
        i0 = int((t - w / 2) * SR)
        n = int(w * SR)
        f = x[i0:i0 + n]
        return math.sqrt(sum(v * v for v in f) / len(f)) if f else 0.0
    pts = [(t0 + i * 0.1, rms(t0 + i * 0.1)) for i in range(int((t1 - t0) / 0.1) + 1)]
    pts = [(t, m) for t, m in pts if m > 1e-7]
    n = len(pts)
    sx = sum(t for t, _ in pts)
    sy = sum(math.log(m) for _, m in pts)
    sxx = sum(t * t for t, _ in pts)
    sxy = sum(t * math.log(m) for t, m in pts)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    resid = [math.log(m) - (slope * t + (sy - slope * sx) / n) for t, m in pts]
    return max(0.02, -slope), 8.6859 * (max(resid) - min(resid))


def fit_group(x, f0, t0, t1, splice):
    """Frequency, beat split and splice-phase for one partial group."""
    f = refine(x, f0, (t0 + t1) / 2, 0.9, 3.0)
    # |A(t)| sampled across the clean tail. 0.25s window: wide enough in
    # frequency to hold the whole doublet, short enough to SEE its beat.
    ts = [t0 + i * (t1 - t0) / 8.0 for i in range(9)]
    env = [demod(x, f, t, 0.25)[0] for t in ts]
    good = [(t, m) for t, m in zip(ts, env) if m > 1e-7]
    if len(good) < 5:
        return None
    n = len(good)
    sx = sum(t for t, _ in good)
    sy = sum(math.log(m) for _, m in good)
    sxx = sum(t * t for t, _ in good)
    sxy = sum(t * math.log(m) for t, m in good)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    # THE BEAT, from the residual after that trend is divided out: the dips are
    # where the pair opposes. Period -> frequency split. The TREND itself is
    # discarded — it is the unmeasurable per-partial decay — but removing it is
    # still the right way to expose the dips.
    resid = [math.log(m) - (slope * t + (sy - slope * sx) / n) for t, m in good]
    dips = [i for i in range(1, n - 1) if resid[i] < resid[i - 1] and resid[i] <= resid[i + 1]]
    if len(dips) >= 2:
        period = (good[dips[-1]][0] - good[dips[0]][0]) / (len(dips) - 1)
    elif len(dips) == 1:
        period = (t1 - t0)             # one dip in the span: at least this long
    else:
        period = 0.0
    split = (1.0 / period) if period > 0.4 else 0.0
    split = min(split, 3.0)
    amp, ph = demod(x, f, splice, 0.30)
    return {"f": f, "a": amp, "ph": ph, "split": split,
            "wobble": max(resid) - min(resid)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--splice", type=float, default=2.40)
    ap.add_argument("--xfade", type=float, default=0.35)
    ap.add_argument("--length", type=float, default=8.0)
    ap.add_argument("--decay", type=float, default=1.0)
    ap.add_argument("--fade_from", type=float, default=1.6,
                    help="linear ramp to silence starts here (the approved recipe)")
    ap.add_argument("--peak", type=float, default=0.0796)
    ap.add_argument("--shimmer", type=float, default=0.0,
                    help="resynthesise the doublet beat; >0 throbs, see the code")
    args = ap.parse_args()

    x = decode(args.src)
    GROUPS = [89.0, 170.5, 213.0, 356.0, 444.0, 532.0, 940.0]
    d0, wob = broadband_decay(x, 0.70, 2.70)
    print("  broadband decay %.3f nepers/s = %.2f dB/s (half-life %.2fs), "
          "%.1f dB wobble" % (d0, 8.6859 * d0, math.log(2) / d0, wob))
    parts = []
    print("  group      freq   amp@splice  decay dB/s  half-life   beat split  wobble")
    for f0 in GROUPS:
        g = fit_group(x, f0, 0.70, 2.70, args.splice)
        if not g:
            print("  %6.0f    (no clean fit)" % f0)
            continue
        # sqrt(f/nominal): the rate is measured, the frequency shape is a model.
        d = d0 * math.sqrt(g["f"] / 356.0) * args.decay
        print("  %6.0f  %8.2f   %9.5f  %10.2f  %7.2fs  %8.2fHz  %5.2f"
              % (f0, g["f"], g["a"], -8.6859 * d, math.log(2) / d,
                 g["split"], g["wobble"]))
        # THE DOUBLET IS DELIBERATELY NOT RESYNTHESISED, and this is the one
        # decision in here that cost something real.
        # Split equally, a pair beats from full addition to near-total
        # cancellation: the 8s tail measured rises of 1.4x at 3.8s and 1.65x at
        # 5.8s, and a 4dB swell arriving four seconds after the strike is
        # audibly A SECOND CHIME. That is the exact bug this clip exists to fix
        # — "the bell rings twice", reported twice. To hold the envelope's rise
        # under 1.06x the two members need an amplitude ratio of 34:1, which is
        # no beat at all, so pretending otherwise buys nothing.
        # What is lost is shimmer, and it is mostly not lost: the first 2.75s
        # are the real recording and carry the real beat. Past the splice the
        # bell rings out smooth. --shimmer re-enables the pair for anyone who
        # wants to hear why it is off.
        if args.shimmer > 0.001 and g["split"] > 0.05:
            hi = g["a"] * (1.0 - args.shimmer / 2)
            lo = g["a"] * (args.shimmer / 2)
            parts.append({"f": g["f"] - g["split"] / 2, "a": hi, "d": d, "ph": g["ph"]})
            parts.append({"f": g["f"] + g["split"] / 2, "a": lo, "d": d, "ph": g["ph"]})
        else:
            parts.append({"f": g["f"], "a": g["a"], "d": d, "ph": g["ph"]})

    n_out = int(args.length * SR)
    y = [0.0] * n_out
    real_end = int((args.splice + args.xfade) * SR)
    for i in range(min(real_end, n_out, len(x))):
        y[i] = x[i]

    # The continuation, phase-referred to the splice so it lines up with the
    # real audio it fades out of. Phasor recurrence rather than cos() per
    # sample per partial — same arithmetic, a few times less of it.
    start = int(args.splice * SR)
    tail = [0.0] * (n_out - start)
    for p in parts:
        step = complex(math.cos(2 * math.pi * p["f"] / SR), math.sin(2 * math.pi * p["f"] / SR))
        dec = math.exp(-p["d"] / SR)
        z = complex(math.cos(p["ph"]), math.sin(p["ph"])) * p["a"]
        for i in range(len(tail)):
            tail[i] += z.real
            z = z * step * dec
    for i in range(start, n_out):
        s = tail[i - start]
        if i < real_end:
            k = (i - start) / float(real_end - start)
            g = 0.5 - 0.5 * math.cos(math.pi * k)
            y[i] = y[i] * (1 - g) + s * g
        else:
            y[i] = s

    # THE LINEAR DISAPPEARANCE, and it is copied deliberately from the recipe
    # that was already approved: "softened and faded linearly over most of its
    # length, 7s, quiet, with the fade running from 1.6s to the end".
    # IT IS ALSO WHAT KEEPS THE ENVELOPE HONEST. Without it the raw source's own
    # doublet shimmer shows up as rises of 1.20x at 1.4s and 1.2s — real, in the
    # recording, and absent from the shipped clip precisely because a ramp that
    # has been descending since 1.6s cannot be climbed by a 1.6dB swell. Any
    # rise in this envelope reads as another chime, so the ramp is not a
    # cosmetic choice.
    # A longer clip is where this treatment finally gets room: the same ramp
    # over 8s instead of 3.15s is the same instruction, slower.
    f0 = min(args.fade_from, args.length * 0.5)
    i0 = int(f0 * SR)
    for i in range(i0, n_out):
        y[i] *= (n_out - i) / float(n_out - i0)

    pk = max(abs(v) for v in y) or 1.0
    y = [v * (args.peak / pk) for v in y]

    wav = args.out.rsplit(".", 1)[0] + ".wav"
    data = b"".join(struct.pack("<h", max(-32768, min(32767, int(v * 32767)))) for v in y)
    with open(wav, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
                + struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16)
                + b"data" + struct.pack("<I", len(data)) + data)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-codec:a", "libmp3lame",
                    "-b:a", "56k", "-ar", "44100", "-ac", "1", args.out], check=True)
    print("wrote %s  (%.1fs, decay x%.2f)" % (args.out, args.length, args.decay))


if __name__ == "__main__":
    main()
