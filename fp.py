"""Fixed-point arithmetic helpers for the DOOM wireframe renderer.

Pure 8-bit arithmetic: all multiplies are 8x8 (16-bit product).

Coordinates are prescaled at WAD load time (divide by 8) so that
view-space values, screen coordinates, and projection factors all
fit in 8 bits.

Formats:
  8.0   -- prescaled world coords, view-space positions, screen pixels
  1.7   -- sin/cos (8-bit signed, 7 fractional bits)
  0.8   -- reciprocal scale (FOCAL/vy), parametric t, slopes
  8.0   -- screen coordinates (X: 0..255, Y: 0..159)
"""

import math

# -- Shift constants ----------------------------------------------------------

FP7 = 7   # 1.7 (sin/cos)
FP8 = 8   # 0.8 (reciprocal, parametric t, slopes)

# -- Core arithmetic ----------------------------------------------------------

mul_counts = {"view": 0, "proj": 0, "clip": 0, "other": 0}
_mul_cat = "other"

def mul_reset():
    """Reset all multiply counters."""
    for k in mul_counts: mul_counts[k] = 0

def mul_cat(cat):
    """Set the current multiply category."""
    global _mul_cat; _mul_cat = cat

def m8(a, b):
    """Count and perform an 8x8 multiply (no shift). Returns a*b."""
    mul_counts[_mul_cat] += 1
    return a * b

def fp_mul8(a, b):
    """Counted 8x8 signed multiply, shift right by 8."""
    mul_counts[_mul_cat] += 1
    return (a * b) >> 8

def fp_mul7(a, b):
    """Counted 8x8 signed multiply, shift right by 7."""
    mul_counts[_mul_cat] += 1
    return (a * b) >> 7

def fp_div8(num, den):
    """Signed divide: (num << 8) // den.  Returns 0 if den == 0.
    Truncates toward zero for consistency with C/hardware."""
    if den == 0:
        return 0
    r = num << 8
    if (r < 0) != (den < 0):
        return -(abs(r) // abs(den))
    return abs(r) // abs(den)

def s8(x):
    """Clamp/wrap to signed 8-bit range."""
    x = x & 0xFF
    return x - 0x100 if x >= 0x80 else x

def clamp(x, lo, hi):
    """Clamp x to [lo, hi]."""
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x

# -- Sin/cos table (1.7 signed, 8-bit) ---------------------------------------
#
# 256 entries covering 0..360deg.  Each entry is int8: -128..+127.
# angle_byte: 0=0deg, 64=90deg, 128=180deg, 192=270deg.

_SIN_TABLE = []
for _i in range(256):
    _rad = _i * 2.0 * math.pi / 256.0
    _val = round(math.sin(_rad) * 128)
    _val = max(-128, min(127, _val))
    _SIN_TABLE.append(_val)

def fp_sin(angle_byte):
    """8-bit angle -> 1.7 signed sin value."""
    return _SIN_TABLE[angle_byte & 0xFF]

def fp_cos(angle_byte):
    """8-bit angle -> 1.7 signed cos value."""
    return _SIN_TABLE[(angle_byte + 64) & 0xFF]

# -- Reciprocal tables (perspective scale) ------------------------------------
#
# Fixed-point renders at 256x160.
# FOCAL_X = 128 (256/2), FOCAL_Y = 154 (128 * 1.2, rounded).
# With prescaled coords (everything / 8), the projection is
# scale-invariant: focal lengths stay the same.
#
# recip_x[vy] = min(128 / vy, 255) for vy in 1..127
# recip_y[vy] = min(154 / vy, 255) for vy in 1..127
# Both results are 0.8 unsigned (0..255).

FP_RENDER_W = 256
FP_RENDER_H = 160
FP_FOCAL_X = FP_RENDER_W // 2              # 128
FP_FOCAL_Y = int(FP_FOCAL_X * 1.2 + 0.5)  # 154
HALF_W = FP_RENDER_W // 2   # 128
HALF_H = FP_RENDER_H // 2   # 80

# Reciprocal tables with 2 fractional bits: 512 entries stored.
# A 3rd fractional bit is resolved by averaging adjacent entries
# (add + shift, no multiply), giving 1024 effective resolution from
# a 512-entry table.
RECIP_FRAC_BITS = 3   # 3 bits extracted from vy; top 2 index the table, LSB averages
RECIP_TABLE_BITS = 2   # table indexed by top 2 fractional bits
RECIP_TABLE_SIZE = 128 << RECIP_TABLE_BITS  # 512 stored entries

_RECIP_X_HI = [0] * (RECIP_TABLE_SIZE + 1)  # +1 for averaging guard
_RECIP_X_LO = [0] * (RECIP_TABLE_SIZE + 1)
_RECIP_Y_HI = [0] * (RECIP_TABLE_SIZE + 1)
_RECIP_Y_LO = [0] * (RECIP_TABLE_SIZE + 1)
for _i in range(1, RECIP_TABLE_SIZE + 1):
    _rx = min((FP_FOCAL_X << (8 + RECIP_TABLE_BITS)) // _i, 0x7FFF)
    _ry = min((FP_FOCAL_Y << (8 + RECIP_TABLE_BITS)) // _i, 0x7FFF)
    _RECIP_X_HI[_i] = _rx >> 8;  _RECIP_X_LO[_i] = _rx & 0xFF
    _RECIP_Y_HI[_i] = _ry >> 8;  _RECIP_Y_LO[_i] = _ry & 0xFF
_RECIP_X_HI[0] = 0x7F; _RECIP_X_LO[0] = 0xFF
_RECIP_Y_HI[0] = 0x7F; _RECIP_Y_LO[0] = 0xFF

def fp_recip_x(vy_idx_3):
    """Returns (hi, lo) of 8.8 horizontal reciprocal.
    vy_idx_3: 5.3 index (3 fractional bits from vy).
    Top 2 bits index the 512-entry table.  LSB averages with next entry.
    """
    vy_idx_3 = max(2, min((RECIP_TABLE_SIZE << 1) - 1, vy_idx_3))
    i = vy_idx_3 >> 1                        # 5.2 table index
    if vy_idx_3 & 1:                          # LSB set: average with next
        hi = (_RECIP_X_HI[i] + _RECIP_X_HI[i + 1]) >> 1
        lo = (_RECIP_X_LO[i] + _RECIP_X_LO[i + 1]) >> 1
        return hi, lo
    return _RECIP_X_HI[i], _RECIP_X_LO[i]

def fp_recip_y(vy_idx_3):
    """Returns (hi, lo) of 8.8 vertical reciprocal."""
    vy_idx_3 = max(2, min((RECIP_TABLE_SIZE << 1) - 1, vy_idx_3))
    i = vy_idx_3 >> 1
    if vy_idx_3 & 1:
        hi = (_RECIP_Y_HI[i] + _RECIP_Y_HI[i + 1]) >> 1
        lo = (_RECIP_Y_LO[i] + _RECIP_Y_LO[i + 1]) >> 1
        return hi, lo
    return _RECIP_Y_HI[i], _RECIP_Y_LO[i]

# -- Projection helpers (two 8x8 multiplies each) ----------------------------

def fp_project_x(vx, recip_hi, recip_lo):
    """Project view-space X to screen X (integer).

    sx = 128 + vx * recip_hi + (vx * recip_lo >> 8)
    Two 8x8 multiplies.
    """
    return HALF_W + m8(vx, recip_hi) + (m8(vx, recip_lo) >> 8)

def fp_project_y(height_delta, recip_hi, recip_lo):
    """Project height delta to screen Y (integer).

    sy = 80 - (height_delta * recip_hi + (height_delta * recip_lo >> 8))
    Two 8x8 multiplies.  No sub-pixel needed for Y (heights are integer).
    """
    return HALF_H - (m8(height_delta, recip_hi) + (m8(height_delta, recip_lo) >> 8))

# -- Clip function helpers (0.8 slope, 8.0 intercept) -------------------------

def fp_linfn(y1, y2, sx1, sx2):
    """Two-point -> (slope_8, intercept).

    y1, y2: screen Y in 8.0.
    sx1, sx2: screen X in 8.0.
    slope = (dy << 8) / dx -> 0.8 signed.
    intercept = y1 - (slope * sx1) >> 8 -> 8.0.
    """
    dx = sx2 - sx1
    if abs(dx) < 1:  # less than 1 pixel
        return (0, (y1 + y2) >> 1)
    dy = y2 - y1
    # slope in 0.8: (dy << 8) / dx
    slope_8 = fp_div8(dy, dx)
    # intercept in 8.0: y1 - (slope * sx1) >> 8
    intercept = y1 - fp_mul8(slope_8, sx1)
    return (slope_8, intercept)

def fp_eval(fn, x):
    """Evaluate slope-intercept at screen X (8.0) -> screen Y (8.0).

    fn = (slope_8, intercept).
    result = (slope * x) >> 8 + intercept.
    slope_8(0.8) * x(8.0) = 8x8 -> >>8 -> 8.0, + intercept(8.0).
    """
    return fp_mul8(fn[0], x) + fn[1]

# -- View transform (8x8 multiplies) -----------------------------------------

def fp_to_view(wx, wy, vx_88, vy_88, sin_a, cos_a):
    """Prescaled world to view space, returning (vx, vy, vy_frac).

    wx, wy: 8.0 signed prescaled vertex coords.
    vx_88, vy_88: 8.8 signed prescaled player position.
    sin_a, cos_a: 1.7.

    Integer and fractional deltas are rotated SEPARATELY (all 8x8 muls),
    then combined before the final shift.  This preserves sub-pixel
    precision from the 8.8 player position AND avoids truncation-
    compounding between rotation terms.
    Returns (vx_int, vy_int, vy_idx) where vy_idx is a 5.2 index into
    the 512-entry reciprocal table (2 extra fractional bits, zero cost).
    8 multiplies total (4 for integer deltas, 4 for fractional deltas).
    """
    dx_88 = (wx << 8) - vx_88
    dy_88 = (wy << 8) - vy_88
    dx_hi = dx_88 >> 8
    dy_hi = dy_88 >> 8
    dx_lo = dx_88 & 0xFF
    dy_lo = dy_88 & 0xFF
    # Integer-part rotation (4 x 8x8 muls, results in 8.7)
    raw_vx = m8(dx_hi, sin_a) - m8(dy_hi, cos_a)
    raw_vy = m8(dx_hi, cos_a) + m8(dy_hi, sin_a)
    # Fractional-part rotation (4 x 8x8 muls, results in 1.15)
    frac_vx = m8(dx_lo, sin_a) - m8(dy_lo, cos_a)
    frac_vy = m8(dx_lo, cos_a) + m8(dy_lo, sin_a)
    # Combine: 8.7 << 1 -> 8.8, plus 1.15 >> 7 -> 1.8
    total_vy = raw_vy * 2 + (frac_vy >> 7)
    evx = (raw_vx * 2 + (frac_vx >> 7)) >> 8
    evy = total_vy >> 8
    # Extract 5.3 recip index from the 8.8 combined vy
    evy_idx = max(2, total_vy >> (8 - RECIP_FRAC_BITS))
    return evx, evy, evy_idx

# -- Near clip (8-bit view coords) -------------------------------------------

NEAR_FP = 1  # 8.0

def fp_near_clip(vx1, vy1, vx2, vy2):
    """Clip to vy >= NEAR.  All 8.0.  Returns (vx1,vy1,vx2,vy2) or None.

    Parametric t in 0.8: t = ((NEAR - vy1) << 8) / (vy2 - vy1).
    cx = vx1 + (t * (vx2 - vx1)) >> 8  (8x8 multiply).
    """
    if vy1 < NEAR_FP and vy2 < NEAR_FP:
        return None
    if vy1 >= NEAR_FP and vy2 >= NEAR_FP:
        return (vx1, vy1, vx2, vy2)
    dvy = vy2 - vy1
    if dvy == 0:
        return None
    t = fp_div8(NEAR_FP - vy1, dvy)
    dvx = vx2 - vx1
    cx = vx1 + fp_mul8(t, dvx)
    if vy1 < NEAR_FP:
        return (cx, NEAR_FP, vx2, vy2)
    return (vx1, vy1, cx, NEAR_FP)

# -- Cyrus-Beck clipper (8-bit screen coords) ---------------------------------

def fp_clip_to_trap(x1, y1, x2, y2, xlo, xhi, tfn, bfn):
    """Clip line to trapezoid [xlo, xhi) with linear top/bot.

    All screen coords are 8.0 integers.
    tfn/bfn are (slope_8, intercept) pairs.
    Returns clipped (x1, y1, x2, y2) in 8.0, or None.

    Cyrus-Beck with 0.8 parametric t.
    t = (q << 8) / p: 16/8 division -> 0.8.
    Clipped coord: x + (dx * t) >> 8, all 8x8.
    """
    dxs = xhi - xlo
    if dxs < 1:
        return None
    dx = x2 - x1
    dy = y2 - y1
    ta, tb = tfn   # top: y >= ta*x + tb
    ba, bb = bfn   # bot: y <= ba*x + bb

    T_ONE = 1 << FP8  # 1.0 in 0.8 = 256
    t0, t1 = 0, T_ONE

    # Half-plane constraints: (p, q) pairs
    # p and q are in 8.0 screen-coord units
    # Slope-related terms: ta(0.8) * dx(8.0) >> 8 -> 8.0
    ta_dx = fp_mul8(ta, dx)
    ba_dx = fp_mul8(ba, dx)
    ta_x1 = fp_mul8(ta, x1)
    ba_x1 = fp_mul8(ba, x1)

    constraints = (
        (-dx,        x1 - xlo),
        ( dx,        xhi - x1),
        ( ta_dx - dy, y1 - ta_x1 - tb),
        ( dy - ba_dx, ba_x1 + bb - y1),
    )

    for p, q in constraints:
        if abs(p) < 1:
            if q < -1:
                return None
        else:
            # t = (q << 8) / p in 0.8
            t = fp_div8(q, p)
            if p < 0:
                if t > t1:
                    return None
                if t > t0:
                    t0 = t
            else:
                if t < t0:
                    return None
                if t < t1:
                    t1 = t

    if t0 > t1:
        return None

    # Clipped coordinates: x_out = x1 + (t * dx) >> 8
    cx1 = x1 + fp_mul8(t0, dx)
    cy1 = y1 + fp_mul8(t0, dy)
    cx2 = x1 + fp_mul8(t1, dx)
    cy2 = y1 + fp_mul8(t1, dy)
    return (cx1, cy1, cx2, cy2)

# -- Prescaling constants (used by doom_wireframe.py at load time) ------------

MAP_CENTER_X = 1200
MAP_CENTER_Y = -3250
PRESCALE = 8    # divide everything by 8
