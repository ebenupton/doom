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

# Cosine table: 256 entries at byte-angle resolution (index = fineangle>>4),
# values cos*127 as s8 (single byte) -- 256 bytes, and keeps the 6502 depth math
# 8-bit (c*cph is s16xs8; depth divide is s24/s8). cos magnitude precision is
# not the limiter (0.59px Y vs true, same as cos*256). 6502: idx=(angle>>4)&255.
_COSSHIFT = 4
_COSSCALE = 127
_COSR = [round(_COSSCALE * math.cos((i << _COSSHIFT) / FINE * 2 * math.pi)) for i in range(256)]
def _cos(f):
    return _COSR[(f & MASK) >> _COSSHIFT]


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


def proj_y(h, depth, vz):
    """Screen Y of height h at a column whose CFRAC*depth is `depth`."""
    return HALF_H - _rdiv((h - vz) * FOCAL * CFRAC, depth)


def proj_y_delta(hd, depth):
    """Screen Y of a pre-subtracted height delta hd=(h-vz)."""
    return HALF_H - _rdiv(hd * FOCAL * CFRAC, depth)


def seg_2b(wx1, wy1, wx2, wy2, ldx, ldy, px, py, ab, na, rlen):
    """Return [(sx1,depth1),(sx2,depth2)] for the two endpoints, or None.
    depth is CFRAC*true_depth; feed it to proj_y(h, depth, vz) for any height."""
    a_fine = (ab * (FINE // 256)) & MASK
    cross = (wy1 - py) * ldx - (wx1 - px) * ldy
    c = (cross * rlen) >> (16 - 4)            # s.4 : (cross/len)<<4
    out = []
    for (wx, wy) in ((wx1, wy1), (wx2, wy2)):
        dx, dy = wx - px, wy - py
        wa = A.point_to_angle(dx, dy)
        phi = _signed(a_fine - wa)
        phi = max(-ANG45, min(ANG45, phi))
        sx = max(0, min(255, _vatox_centre(phi)))
        cph = _cos(phi)
        cden = _cos(a_fine - phi - na)
        num, den = c * cph, cden
        if den < 0:
            num, den = -num, -den
        if den == 0:
            return None
        depth = _rdiv(num, den)               # = CFRAC * true_depth
        if depth <= 0:
            return None
        out.append((sx, depth))
    return out
