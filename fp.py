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
mul_dupes = 0        # count of repeated (a,b) pairs
_mul_cat = "other"
_mul_memo = {}       # (a, b, shift) -> result; for dupe detection

def mul_reset():
    """Reset all multiply counters and memo."""
    global mul_dupes
    for k in mul_counts: mul_counts[k] = 0
    mul_dupes = 0
    _mul_memo.clear()

def mul_cat(cat):
    """Set the current multiply category."""
    global _mul_cat; _mul_cat = cat

def _memo_mul(a, b, shift):
    """Record a multiply, detect duplicates. Returns a*b >> shift."""
    global mul_dupes
    mul_counts[_mul_cat] += 1
    key = (a, b, shift)
    result = (a * b) >> shift
    if key in _mul_memo:
        mul_dupes += 1
    else:
        _mul_memo[key] = result
    return result

def m8(a, b):
    """Count and perform an 8x8 multiply (no shift). Returns a*b."""
    return _memo_mul(a, b, 0)

def fp_mul8(a, b):
    """Counted 8x8 signed multiply, shift right by 8."""
    return _memo_mul(a, b, 8)

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

# -- Sin/cos: 8-bit unsigned magnitude + sign/unity flags --------------------
#
# 64-entry table covering one quadrant (0..90deg exclusive).
# Each entry is unsigned 0..255, where 255 ~= 1.0 (0.8 format).
# Cardinal angles (0, 64, 128, 192) are exact unity — the multiply
# is skipped and the delta used directly.
#
# For angle_byte 0..255:
#   quadrant = angle_byte >> 6           (0..3)
#   index    = angle_byte & 63           (0..63)
#   For quadrants 1,3: index = 64 - index (mirror)
#   sign from quadrant: sin is negative in Q2,Q3; cos in Q1,Q2

_SIN_QUADRANT = [0] * 65  # 0..64 inclusive
_SIN_UNITY = [False] * 65  # True where round(sin*256) >= 256
for _i in range(1, 65):
    _rad = _i * math.pi / 128.0   # 0..pi/2
    _raw = round(math.sin(_rad) * 256)
    if _raw >= 256:
        _SIN_QUADRANT[_i] = 0  # unused — unity path skips the multiply
        _SIN_UNITY[_i] = True
    else:
        _SIN_QUADRANT[_i] = _raw
        _SIN_UNITY[_i] = False
_SIN_QUADRANT[0] = 0
_SIN_UNITY[0] = False


def _sin_mag_sign(a):
    """For angle byte a, return (magnitude 0..255, is_negative, is_unity).

    Unity covers all entries where round(sin*256) >= 256 (angles 62-66
    and equivalents in each quadrant).  These skip the multiply entirely.
    """
    a = a & 0xFF
    q = a >> 6
    idx = a & 63
    if q & 1:  # Q1 or Q3: mirror
        idx = 64 - idx
    if idx == 0:
        return 0, False, False
    neg = (q >= 2)
    if _SIN_UNITY[idx]:
        return 0, neg, True
    return _SIN_QUADRANT[idx], neg, False

def fp_sincos(angle_byte):
    """Returns (sin_mag, sin_neg, sin_unity, cos_mag, cos_neg, cos_unity)."""
    s_mag, s_neg, s_unity = _sin_mag_sign(angle_byte)
    c_mag, c_neg, c_unity = _sin_mag_sign(angle_byte + 64)
    return s_mag, s_neg, s_unity, c_mag, c_neg, c_unity

# Keep fp_sin/fp_cos for backward compatibility (back-face test doesn't need this)
_SIN_TABLE_SIGNED = []
for _i in range(256):
    _rad = _i * 2.0 * math.pi / 256.0
    _val = round(math.sin(_rad) * 256)
    _val = max(-256, min(255, _val))
    _SIN_TABLE_SIGNED.append(_val)

def fp_sin(angle_byte):
    """8-bit angle -> signed sin (for back-face test only, not for view transform)."""
    return _SIN_TABLE_SIGNED[angle_byte & 0xFF]

def fp_cos(angle_byte):
    """8-bit angle -> signed cos (for back-face test only)."""
    return _SIN_TABLE_SIGNED[(angle_byte + 64) & 0xFF]

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
FP_FOCAL_X = FP_RENDER_W // 2   # 128
HALF_W = FP_RENDER_W // 2       # 128
HALF_H = FP_RENDER_H // 2       # 80
# Aspect ratio (1.2x) is baked into height prescaling, not the focal length.
# This allows a single reciprocal table for both X and Y projection.
ASPECT_NUM = 6    # 6/5 = 1.2
ASPECT_DEN = 5

# Reciprocal table (2026-07-08, quarter-pixel rework): FOCAL/vy is stored
# as a NORMALIZED FLOATING MANTISSA instead of 8.8 fixed point. For the
# 10-bit 9.1 index (vy in half-units, clamped [2, 1023]):
#
#   R = 256/idx  ≈  (256 + M8[idx]) / 2^S,   S = bit_length(idx - 1)
#
# m9 = 256+M8 is a 9-bit mantissa with implicit leading 1 (256..511 for
# every idx — bit_length(idx-1) always normalizes, no S table needed).
# Relative error <= 2^-10: an on-screen coordinate is localized to
# <= 1/8 px. Anything finer than ~1/4 px is wasted effort, so the 16-bit
# recip was paying a multiply per byte for precision nobody consumed:
#   proj_y   1 mul (was 2)      proj_x narrow  2 muls (was 3)
#   proj_x wide 3 muls (was 5)  recip lookup   direct byte read (no
#   16-bit averaging), and recip(NEAR) = (M8=0, S=1) projects the
#   near-plane crossing with pure shifts.
RECIP_FRAC_BITS = 1   # 1 fractional bit of vy in the index
RECIP_TABLE_SIZE = 512  # in whole vy units; table has 2*512 entries

_RECIP_M8 = [0] * 1024
for _i in range(2, 1024):
    _s = (_i - 1).bit_length()                    # S in [1, 10]
    _m9 = ((256 << (_s + 1)) + _i) // (2 * _i)    # round-to-nearest, exact
    # no ties: 2^(8+S)/idx is never exactly x.5 (idx has an odd factor
    # unless it is a power of two, which divides exactly)
    assert 256 <= _m9 <= 511, (_i, _m9, _s)
    _RECIP_M8[_i] = _m9 - 256
_RECIP_M8[0] = _RECIP_M8[1] = _RECIP_M8[2]        # unreachable (clamp >= 2)

def fp_recip(vy_idx):
    """Returns (M8, S): FOCAL_X / vy ≈ (256 + M8) / 2^S.

    Single table for both X and Y projection — the 1.2 aspect ratio
    correction is baked into height prescaling instead.
    vy_idx: 9.1 index (1 fractional bit from vy), clamped to [2, 1023].
    """
    vy_idx = max(2, min((RECIP_TABLE_SIZE << 1) - 1, vy_idx))
    return _RECIP_M8[vy_idx], (vy_idx - 1).bit_length()


def rns(p, s):
    """floor((p + 2^(s-1)) >> s) — round-to-nearest arithmetic shift.

    s >= 1 always (S ranges [1,10], and proj_x uses S+8). The 6502
    mirrors this exactly: add the half constant, then arithmetic
    shifts (right shifts, or left-shift-then-drop-a-byte — both are
    exact floor((p+half)/2^s) implementations)."""
    return (p + (1 << (s - 1))) >> s

# Backwards-compatible aliases
fp_recip_x = fp_recip
fp_recip_y = fp_recip

# -- Projection helpers (two 8x8 multiplies each) ----------------------------

def fp_project_x(vx, vx_frac, recip_m8, recip_s):
    # (the truncating fp_project_x was GC'd 2026-07-12: it was exactly
    #  this with vx_frac=0 — rns(256a, S+8) == rns(a, S) identically)
    """Project with sub-pixel correction from fractional view-space X.

    sx = 128 + rns(X88 * m9, S+8),  X88 = vx*256 + vx_frac (8.8 view x)
    decomposed so every product is an 8x8 partial on the 6502:
      X88*m9 = frac*M8 + ((vx*M8 + frac) << 8) + (vx << 16)
    Two 8x8 multiplies (was 3; the old third mul carried recip bits
    below quarter-pixel significance).
    """
    return HALF_W + rns(m8(vx_frac, recip_m8)
                        + ((m8(vx, recip_m8) + vx_frac) << 8)
                        + (vx << 16), recip_s + 8)

def fp_project_y(height_delta, recip_m8, recip_s):
    """Project height delta to screen Y (integer).

    sy = 80 - rns(h * m9, S)  with m9 = 256 + M8:
      h*m9 = h*M8 + (h << 8)
    ONE 8x8 multiply (was 2). The 6502 mirror (br_project_y_raw) builds
    the same s24 product and feeds the shared RNS shifter; with the
    crossing reciprocal (M8=0, S=1) this degenerates to sy = 80 - (h<<7),
    exact, no multiplies.
    """
    return HALF_H - rns(m8(height_delta, recip_m8) + (height_delta << 8),
                        recip_s)

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
    if slope_8 == 0:
        return (0, y1)
    # intercept in 8.0: compute from whichever endpoint has smaller |x|
    # to minimise slope quantisation error compounding over off-screen distance
    if abs(sx1) <= abs(sx2):
        intercept = y1 - fp_mul8(slope_8, sx1)
    else:
        intercept = y2 - fp_mul8(slope_8, sx2)
    return (slope_8, intercept)

def fp_eval(fn, x):
    """Evaluate slope-intercept at screen X (8.0) -> screen Y (8.0).

    fn = (slope_8, intercept).
    Short-circuits when slope is 0 (flat spans — very common).
    """
    if fn[0] == 0: return fn[1]
    return fp_mul8(fn[0], x) + fn[1]

def fp_eval_88(fn, x):
    """Evaluate slope-intercept at screen X (8.0) -> screen Y (8.8).

    Same as fp_eval but keeps the full 8.8 product instead of truncating.
    No extra multiplies — the m8() product is 16-bit anyway.
    Used for precise vertical clipping.
    """
    if fn[0] == 0: return fn[1] << 8
    return m8(fn[0], x) + (fn[1] << 8)

# -- View transform (8x8 multiplies) -----------------------------------------

def _frac_rot_term(lo, mag, neg, unity):
    """Compute the fractional rotation term: lo * trig_component.

    lo: unsigned 8-bit fractional delta (0.8).
    mag: unsigned magnitude 0..255 (0.8).
    neg: True if the trig value is negative.
    unity: True if |trig| == 1.0 (skip multiply).
    Returns result in 0.8 format (unsigned, with sign applied).
    """
    if unity:
        val = lo
    elif mag == 0 or lo == 0:
        return 0
    else:
        val = (m8(lo, mag) + 128) >> 8
    return -val if neg else val

def fp_view_context(vx_88, vy_88, sc):
    """Precompute per-frame view context: player integer pos + fractional rotation.

    vx_88, vy_88: 8.8 signed prescaled player position.
    sc: tuple from fp_sincos(angle_byte).

    Returns (px_int, py_int, sc, frac_vx, frac_vy) where frac_vx/frac_vy
    are the precomputed fractional rotation contributions in 0.8 format.

    4 multiplies max (fewer when unity/zero). Computed once per frame.
    """
    px_int = vx_88 >> 8
    py_int = vy_88 >> 8
    s_mag, s_neg, s_unity, c_mag, c_neg, c_unity = sc

    # Vertex fraction is always 0, so frac = -player_frac
    dx_lo = (-vx_88) & 0xFF
    dy_lo = (-vy_88) & 0xFF

    # frac_vx = frac(dx_lo, sin) - frac(dy_lo, cos)
    # frac_vy = frac(dx_lo, cos) + frac(dy_lo, sin)
    frac_vx = (_frac_rot_term(dx_lo, s_mag, s_neg, s_unity)
               - _frac_rot_term(dy_lo, c_mag, c_neg, c_unity))
    frac_vy = (_frac_rot_term(dx_lo, c_mag, c_neg, c_unity)
               + _frac_rot_term(dy_lo, s_mag, s_neg, s_unity))

    return (px_int, py_int, sc, frac_vx, frac_vy)

def _rot_int(d_hi, mag, neg, unity):
    """Compute integer-part rotation term: d_hi * trig_component.

    d_hi: integer delta (8-bit signed).
    mag: unsigned magnitude 0..255 (0.8).
    neg: True if the trig value is negative.
    unity: True if |trig| == 1.0 (skip multiply).
    Returns result in 8.8 format (16-bit signed).
    """
    if unity:
        val = d_hi << 8
    else:
        if mag == 0:
            return 0
        val = m8(d_hi, mag)
    return -val if neg else val

def fp_to_view(wx, wy, ctx):
    """Prescaled world to view space using precomputed context.

    wx, wy: 8.0 signed prescaled vertex coords.
    ctx: tuple from fp_view_context(vx_88, vy_88, sc).

    Uses 8-bit unsigned magnitude with sign/unity override:
    - Unity (cardinal angles): exact, zero multiplies
    - Non-unity: 8x8 unsigned mul with full 0..255 range (vs old 0..127)
    Returns (vx_trunc, vx_round, vy, vx_frac, vy_idx).
    4 multiplies max (integer part only; fractional precomputed in context).
    """
    px_int, py_int, sc, frac_vx, frac_vy = ctx
    dx_hi = wx - px_int
    dy_hi = wy - py_int
    s_mag, s_neg, s_unity, c_mag, c_neg, c_unity = sc

    # Integer part: 4 x _rot_int calls (4 muls max)
    # vx = dx * sin - dy * cos  (each term in 8.8)
    # vy = dx * cos + dy * sin
    t_dx_sin = _rot_int(dx_hi, s_mag, s_neg, s_unity)
    t_dy_cos = _rot_int(dy_hi, c_mag, c_neg, c_unity)
    t_dx_cos = _rot_int(dx_hi, c_mag, c_neg, c_unity)
    t_dy_sin = _rot_int(dy_hi, s_mag, s_neg, s_unity)
    int_vx = t_dx_sin - t_dy_cos
    int_vy = t_dx_cos + t_dy_sin

    # Add precomputed fractional rotation from context
    total_vx = int_vx + frac_vx
    total_vy = int_vy + frac_vy

    evx_trunc = total_vx >> 8          # truncated (for sub-pixel mode)
    evx_round = (total_vx + 128) >> 8  # rounded (for non-sub-pixel mode)
    evy = (total_vy + 128) >> 8        # always round vy
    evx_frac = total_vx & 0xFF         # fractional vx (consistent with truncation)
    evy_idx = max(2, total_vy >> (8 - RECIP_FRAC_BITS))
    return evx_trunc, evx_round, evy, evx_frac, evy_idx

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

# -- Prescaling constants (used by doom_wireframe.py at load time) ------------

MAP_CENTER_X = 1200
MAP_CENTER_Y = -3250

# Prescale factor — divides all world coordinates at load time so view
# deltas fit in s8 arithmetic.  Default is 8; setting the DOOM_PRESCALE
# environment variable selects a different factor at startup.  A factor
# of 16 halves all spatial quantities relative to 8 and makes every
# multiply operand fit strictly in s8 (eliminating the wide-mul paths
# exercised by the tiny s9 tail under 8×prescale), at the cost of
# halving world-space precision to 16-unit boundaries.
import os as _os
PRESCALE = int(_os.environ.get('DOOM_PRESCALE', '8'))
if PRESCALE not in (8, 16):
    raise ValueError(f"DOOM_PRESCALE must be 8 or 16, got {PRESCALE}")
