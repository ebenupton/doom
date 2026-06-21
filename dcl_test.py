#!/usr/bin/env python3
"""Standalone random+directed regression for the 6502 span clipper (DCL).

The integrated regression only checks 6502-vs-6502 self-consistency at a handful
of viewpoints. This drives `draw_clipped_line` ($2015) DIRECTLY with synthetic
pools + lines and checks its emitted segments against an independent per-column
trapezoid-clip reference (a per-column reference is legitimate as a TEST oracle).

A pool is a left-to-right list of trapezoid spans; each span covers columns
[XSTART,XEND] with a top edge TL@XLO -> TR@(XLO+DEN) and bottom BL->BR. The DCL
must emit the line exactly where it lies inside some span's aperture.

The reference computes, per column x in the line's range, line_y(x); finds the
covering span; and marks x drawn iff top(x) <= line_y(x) <= bot(x). We compare
the set of drawn columns (the clip EXTENT — what the over-extension bug gets
wrong) with a small tolerance for ±1 boundary-rounding.

Usage:
    python3 dcl_test.py                 # directed + random smoke (fast)
    python3 dcl_test.py 2000000         # N random cases
    python3 dcl_test.py 2000000 12345   # N random, fixed seed
"""
import os, sys, random
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
from span_clip_6502 import SpanClip6502

Y_BIAS = 48
VIS_YMAX = 207
# ZP / pool addresses (from span_clip.asm)
ZP_HEAD = 0xC0
L_XL, L_YL, L_XR, L_YR = 0xA8, 0xA9, 0xAA, 0xAB
DCL_REC_LO, DCL_REC_HI = 0xBC, 0xBD
POOL_NEXT, POOL_XLO, POOL_DEN = 0x0400, 0x0420, 0x0440
POOL_TL, POOL_BL, POOL_TR, POOL_BR = 0x0460, 0x0480, 0x04A0, 0x04C0
POOL_XSTART, POOL_XEND = 0x04E0, 0x0500
POOL_OT, POOL_OB, POOL_IT, POOL_IB = 0x0520, 0x0540, 0x0560, 0x0580
LINE_OUT_COUNT, LINE_OUT_BUF = 0x0200, 0x0201
DCL_ENTRY = 0x2015        # JMP draw_clipped_line
RASTER_ENTRY = 0xA900


class DCLHarness:
    def __init__(self):
        self.sc = SpanClip6502()
        self.mpu = self.sc.mpu
        self.mem = self.mpu.memory
        self.mem[RASTER_ENTRY] = 0x60      # stub rasteriser with RTS

    def set_pool(self, spans):
        """spans: list of dicts {xs,xe,tl,tr,bl,br} in left-to-right order."""
        m = self.mem
        for i, s in enumerate(spans):
            slot = i + 1
            nxt = slot + 1 if i + 1 < len(spans) else 0
            den = max(1, s['xe'] - s['xs'])
            ot = min(s['tl'], s['tr']); it = max(s['tl'], s['tr'])
            ob = max(s['bl'], s['br']); ib = min(s['bl'], s['br'])
            m[POOL_NEXT + slot] = nxt
            m[POOL_XLO + slot] = s['xs']; m[POOL_DEN + slot] = den
            m[POOL_TL + slot] = s['tl']; m[POOL_TR + slot] = s['tr']
            m[POOL_BL + slot] = s['bl']; m[POOL_BR + slot] = s['br']
            m[POOL_XSTART + slot] = s['xs']; m[POOL_XEND + slot] = s['xe']
            m[POOL_OT + slot] = ot; m[POOL_OB + slot] = ob
            m[POOL_IT + slot] = it; m[POOL_IB + slot] = ib
        m[ZP_HEAD] = 1 if spans else 0

    def run(self, line):
        m = self.mem; mpu = self.mpu
        xl, yl, xr, yr = line
        m[L_XL] = xl; m[L_YL] = yl; m[L_XR] = xr; m[L_YR] = yr
        m[DCL_REC_LO] = 0; m[DCL_REC_HI] = 0      # records off
        m[LINE_OUT_COUNT] = 0
        mpu.pc = DCL_ENTRY; mpu.sp = 0xFD; mpu.p = 0x30
        m[0x01FF] = 0xFE; m[0x01FE] = 0xFF
        for _ in range(200000):
            if mpu.pc == 0xFF00:
                break
            mpu.step()
        segs = []
        n = m[LINE_OUT_COUNT] // 4      # COUNT is a byte offset (4 bytes/seg)
        for i in range(n):
            b = LINE_OUT_BUF + i * 4
            segs.append((m[b], m[b + 1], m[b + 2], m[b + 3]))
        return segs


def drawn_cols_6502(segs):
    cols = set()
    for (x0, y0, x1, y1) in segs:
        for x in range(min(x0, x1), max(x0, x1) + 1):
            cols.add(x)
    return cols


def ref_drawn_cols(spans, line):
    """Per-column trapezoid-clip oracle (float). Returns set of drawn columns."""
    xl, yl, xr, yr = line
    drawn = set()
    for x in range(xl, xr + 1):
        ly = yl if xr == xl else yl + (yr - yl) * (x - xl) / (xr - xl)
        for s in spans:
            if s['xs'] <= x <= s['xe']:
                if s['xe'] == s['xs']:
                    t, b = s['tl'], s['bl']
                else:
                    f = (x - s['xs']) / (s['xe'] - s['xs'])
                    t = s['tl'] + (s['tr'] - s['tl']) * f
                    b = s['bl'] + (s['br'] - s['bl']) * f
                if t <= ly <= b:
                    drawn.add(x)
                break
    return drawn


def max_run(cols):
    """Longest run of consecutive columns in a set (for tolerance)."""
    if not cols:
        return 0
    s = sorted(cols); best = run = 1
    for i in range(1, len(s)):
        run = run + 1 if s[i] == s[i - 1] + 1 else 1
        best = max(best, run)
    return best


def check(h, spans, line, tol=2):
    """Return None if OK, else a mismatch description."""
    h.set_pool(spans)
    segs = h.run(line)
    got = drawn_cols_6502(segs)
    ref = ref_drawn_cols(spans, line)
    extra = got - ref       # 6502 drew, reference says no  (over-draw / over-extend)
    missing = ref - got     # reference says draw, 6502 didn't
    # tolerate isolated ±1 boundary-rounding columns; flag runs > tol
    if max_run(extra) > tol or max_run(missing) > tol:
        return dict(line=line, spans=spans, extra=sorted(extra)[:40],
                    missing=sorted(missing)[:40], segs=segs)
    return None


# ---------------- directed cases ----------------
def directed_cases():
    cases = []
    # The 845,-3084,215 bug: line grazes aperture top at slot3/slot4 boundary,
    # then runs above slot4 aperture. Should draw only cols 80..82.
    cases.append((
        [dict(xs=0, xe=39, tl=48, tr=48, bl=207, br=207),
         dict(xs=39, xe=78, tl=48, tr=48, bl=207, br=207),
         dict(xs=78, xe=82, tl=66, tr=66, bl=207, br=207),
         dict(xs=82, xe=157, tl=68, tr=68, bl=205, br=205),
         dict(xs=176, xe=255, tl=48, tr=48, bl=207, br=207)],
        (80, 69, 158, 40)))
    return cases


def gen_random(rng):
    """Random flat-or-sloped pool + line, biased Y in [0,255]."""
    # build 1..6 left-to-right spans, optionally with gaps
    nspans = rng.randint(1, 6)
    spans = []
    x = rng.randint(0, 20)
    for _ in range(nspans):
        w = rng.randint(1, 80)
        xs = x; xe = min(255, x + w)
        if xs >= 255:
            break
        # aperture within [Y_BIAS, VIS_YMAX]; flat 60% of the time
        if rng.random() < 0.6:
            t = rng.randint(Y_BIAS, VIS_YMAX - 1)
            b = rng.randint(t + 1, VIS_YMAX)
            spans.append(dict(xs=xs, xe=xe, tl=t, tr=t, bl=b, br=b))
        else:
            tl = rng.randint(Y_BIAS, VIS_YMAX - 1); tr = rng.randint(Y_BIAS, VIS_YMAX - 1)
            bl = rng.randint(max(tl, tr) + 1, VIS_YMAX); br = rng.randint(max(tl, tr) + 1, VIS_YMAX)
            if bl <= tl or br <= tr:
                bl = min(VIS_YMAX, tl + 1); br = min(VIS_YMAX, tr + 1)
            spans.append(dict(xs=xs, xe=xe, tl=tl, tr=tr, bl=bl, br=br))
        x = xe + rng.randint(0, 6)     # gap or abut
    if not spans:
        spans = [dict(xs=0, xe=255, tl=48, tr=48, bl=207, br=207)]
    # line: random endpoints, Y full u8 range (incl off-aperture/off-screen)
    xl = rng.randint(0, 255); xr = rng.randint(0, 255)
    if xl > xr:
        xl, xr = xr, xl
    yl = rng.randint(0, 255); yr = rng.randint(0, 255)
    return spans, (xl, yl, xr, yr)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    h = DCLHarness()
    fails = []
    # directed first
    for spans, line in directed_cases():
        r = check(h, spans, line)
        tag = "OK" if r is None else "MISMATCH"
        print(f"directed {line}: {tag}")
        if r:
            print(f"   extra(over-draw) cols: {r['extra']}")
            print(f"   missing cols:          {r['missing']}")
            print(f"   6502 segs: {r['segs']}")
            fails.append(r)
    # random
    rng = random.Random(seed)
    for i in range(n):
        spans, line = gen_random(rng)
        r = check(h, spans, line)
        if r is not None:
            fails.append(r)
            if len(fails) <= 8:
                print(f"RANDOM MISMATCH #{len(fails)}: line={r['line']}")
                print(f"   spans={r['spans']}")
                print(f"   extra={r['extra']} missing={r['missing']} segs={r['segs']}")
        if (i + 1) % 100000 == 0:
            print(f"  ...{i+1}/{n} checked, {len(fails)} fails")
    print(f"\nDONE: {n} random cases, {len(fails)} mismatches (tol=2).")


if __name__ == '__main__':
    main()
