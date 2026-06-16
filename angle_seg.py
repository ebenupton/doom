"""Option 2b: angle-space seg projection (no per-vertex rotation), integer
math mirroring what the 6502 will do, so it can be the bit-exact reference.

Per seg:
  - static constants (precompute -> ROM): na = seg normal fine-angle,
    rlen = reciprocal of seg length in 0.16 (1/len << 16).
  - per frame: c = signed perp distance in s.4 =
        ((wy1-py)*ldx - (wx1-px)*ldy) * rlen >> 12        [1/len<<16, >>12 -> <<4]
  - per endpoint:
        wa  = point_to_angle(dx,dy)              (4096-fine world angle)
        phi = clamp(a_fine - wa, +/-ANG45)       (view-relative, FOV clamp)
        sx  = clamp(VATOX_centre(phi), 0, 255)
        depth = (c * COS[phi]) / COS[a_fine-phi-na]    (sign-normalised, rounded)
        ft = HALF_H - round((ch-vz)*FOCAL*16 / depth)   (depth carries the <<4)
        fb = HALF_H - round((fh-vz)*FOCAL*16 / depth)

Validated: validate_angle_seg.py (X), validate_2b.py / validate_2b_fp.py (Y).
"""
import math
import angle_bbox as A

FINE = A.FINEANGLES
MASK = A.ANGMASK
ANG45 = A.ANG45
ANG90 = A.ANG90
FOCAL = 128
HALF_W = 128
HALF_H = 80
CFRAC = 16                      # 4 fractional bits on c

# 8-bit cosine table over the fine circle (cos table precision is not the
# limiter; 8 bits suffices -- see validate_2b_fp.py).
_COS = [round(256 * math.cos(f / FINE * 2 * math.pi)) for f in range(FINE)]


def _signed(a):
    a &= MASK
    return a - FINE if a >= FINE // 2 else a


def _rdiv(num, den):            # rounded integer divide, den > 0
    return (num + (den // 2 if num >= 0 else -(den // 2))) // den


def seg_consts(ldx, ldy):
    """Static per-seg constants (would live in ROM): (na_fine, rlen_0_16).
    n = (-ldy, ldx)/len  -> na = atan2(ldx, -ldy)."""
    L = math.hypot(ldx, ldy)
    if L == 0:
        return 0, 0
    na = round(math.atan2(ldx, -ldy) / (2 * math.pi) * FINE) & MASK
    rlen = round((1 << 16) / L)
    return na, rlen


def _vatox_centre(phi):
    idx = phi + ANG90
    idx = max(0, min(A.ANG180, idx))
    return (A._vatox_lo[idx] + A._vatox_hi[idx]) // 2


def seg_2b(wx1, wy1, wx2, wy2, ldx, ldy, ch, fh, px, py, ab, vz, na, rlen):
    """Return [(sx1,ft1,fb1),(sx2,ft2,fb2)] for the two endpoints, or None."""
    a_fine = (ab * (FINE // 256)) & MASK
    cross = (wy1 - py) * ldx - (wx1 - px) * ldy
    c = (cross * rlen) >> (16 - 4)            # s.4 : (1/len<<16)*cross >>12 = (cross/len)<<4
    out = []
    for (wx, wy) in ((wx1, wy1), (wx2, wy2)):
        dx, dy = wx - px, wy - py
        wa = A.point_to_angle(dx, dy)
        phi = _signed(a_fine - wa)
        phi = max(-ANG45, min(ANG45, phi))
        sx = max(0, min(255, _vatox_centre(phi)))
        cph = _COS[phi & MASK]
        cden = _COS[(a_fine - phi - na) & MASK]
        num, den = c * cph, cden
        if den < 0:
            num, den = -num, -den
        if den == 0:
            return None
        depth = _rdiv(num, den)               # = CFRAC * true_depth
        if depth <= 0:
            return None
        ft = HALF_H - _rdiv((ch - vz) * FOCAL * CFRAC, depth)
        fb = HALF_H - _rdiv((fh - vz) * FOCAL * CFRAC, depth)
        out.append((sx, ft, fb))
    return out
