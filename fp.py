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

# Reciprocal tables: 512 entries, 1 entry per integer vy (0..512).
# A fractional bit is resolved by averaging adjacent 16-bit values
# (add + shift, no multiply), giving 1024 effective resolution.
# The 16-bit average is reconstructed from hi/lo bytes to avoid the
# catastrophic error that separate byte averaging produces when the
# hi byte changes between adjacent entries.
RECIP_FRAC_BITS = 1   # 1 bit extracted from vy; LSB triggers averaging
RECIP_TABLE_BITS = 0   # table indexed directly by integer vy
RECIP_TABLE_SIZE = 512  # covers vy 1..512 (prescaled; 8..4096 world units)

_RECIP_X_HI = [0] * (RECIP_TABLE_SIZE + 1)  # +1 for averaging guard
_RECIP_X_LO = [0] * (RECIP_TABLE_SIZE + 1)
for _i in range(1, RECIP_TABLE_SIZE + 1):
    _rx = min((FP_FOCAL_X << (8 + RECIP_TABLE_BITS)) // _i, 0x7FFF)
    _RECIP_X_HI[_i] = _rx >> 8;  _RECIP_X_LO[_i] = _rx & 0xFF
_RECIP_X_HI[0] = 0x7F; _RECIP_X_LO[0] = 0xFF

def fp_recip(vy_idx):
    """Returns (hi, lo) of 8.8 reciprocal (FOCAL_X / vy).

    Single table for both X and Y projection — the 1.2 aspect ratio
    correction is baked into height prescaling instead.

    vy_idx: 9.1 index (1 fractional bit from vy).
    Integer part indexes the 512-entry table.  LSB averages with next
    entry using full 16-bit reconstruction (not separate byte averaging).
    """
    vy_idx = max(2, min((RECIP_TABLE_SIZE << 1) - 1, vy_idx))
    i = vy_idx >> 1                           # integer table index
    if vy_idx & 1:                            # LSB set: average with next
        val1 = (_RECIP_X_HI[i] << 8) | _RECIP_X_LO[i]
        val2 = (_RECIP_X_HI[i + 1] << 8) | _RECIP_X_LO[i + 1]
        avg = (val1 + val2) >> 1
        return avg >> 8, avg & 0xFF
    return _RECIP_X_HI[i], _RECIP_X_LO[i]

# Backwards-compatible aliases
fp_recip_x = fp_recip
fp_recip_y = fp_recip

# -- Projection helpers (two 8x8 multiplies each) ----------------------------

def fp_project_x(vx, recip_hi, recip_lo):
    """Project view-space X to screen X (integer).

    sx = 128 + vx * recip_hi + ((vx * recip_lo + 128) >> 8)
    Two 8x8 multiplies.  The fractional term ROUNDS TO NEAREST
    (2026-07-08): the old floor truncation gave a 0..1 column leftward
    bias which (stacked with fp_project_x_subpx's second truncated
    term) pushed drawn segs outside the angle-space bbox gate extents.
    """
    return HALF_W + m8(vx, recip_hi) + ((m8(vx, recip_lo) + 128) >> 8)

def fp_project_x_subpx(vx, vx_frac, recip_hi, recip_lo):
    """Project with sub-pixel correction from fractional view-space X.

    sx = 128 + vx*recip_hi + ((vx*recip_lo + vx_frac*recip_hi + 128) >> 8)
    Three 8x8 multiplies.  The two fractional terms are SUMMED and
    rounded to nearest ONCE (2026-07-08) — per-term floor truncation
    lost up to 2 columns leftward (see fp_project_x note).
    """
    return (HALF_W + m8(vx, recip_hi)
            + ((m8(vx, recip_lo) + m8(vx_frac, recip_hi) + 128) >> 8))

def fp_project_y(height_delta, recip_hi, recip_lo):
    """Project height delta to screen Y (integer).

    sy = 80 - (height_delta * recip_hi + (height_delta * recip_lo >> 8))
    Two 8x8 multiplies.  No sub-pixel needed for Y (heights are integer).

    OPTIMISATION OPPORTUNITY — eliminate both muls via shift-add chains:

    height_delta is prescaled (ch-vz or fh-vz), range ±31 (6 bits), and is
    constant per front sector.  This means h * recip_hi can be expressed as
    shifts and adds of recip_hi based on the set bits of |h|.  Example for
    h=11 (0b1011): (recip_hi<<3) + (recip_hi<<1) + recip_hi.  Max cost:
    5 adds + 4 shifts for h=31, vs ~50-100 cycles for an 8x8 multiply.

    Per-sector setup (once):
      - Precompute shift-add recipe: list of bit positions in |h_ceil|, |h_floor|
      - Precompute recip_lo skip threshold: 256 // max(|h|, 1)
        (skip the fractional correction when |h| * recip_lo < 256, i.e. < 1px)
      - Special-case h==0 (result=HALF_H), |h|==1 (copy), |h|==pow2 (shift)

    Per-vertex (replaces current 2 muls per call, 4 per vertex):
      - Apply shift-add chain to recip_hi (0 muls)
      - If recip_lo > threshold: apply chain to recip_lo, >>8 for correction
      - Typical savings: 50% of floor projections skip recip_lo (|h|≈2-5)

    Threshold analysis (% of vertices where recip_lo correction < 1px):
      |h|=2 → 50%,  |h|=5 → 20%,  |h|=11 → 9%,  |h|=16 → 6%

    Net effect: Y projection drops from 4 muls/vertex to 0, leaving only
    view transform (4) and X projection (2) = 6 muls/vertex total.
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
    # Short-circuit slope muls when slope is 0 (flat spans — very common)
    ta_dx = fp_mul8(ta, dx) if ta else 0
    ba_dx = fp_mul8(ba, dx) if ba else 0
    ta_x1 = fp_mul8(ta, x1) if ta else 0
    ba_x1 = fp_mul8(ba, x1) if ba else 0

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

    # Integer division truncation can place endpoints outside the trapezoid.
    # Clamp X to [xlo, xhi-1].
    if cx1 < xlo:
        cx1 = xlo
    if cx2 >= xhi:
        cx2 = xhi - 1
    if cx1 > cx2:
        return None

    # Clamp Y to top/bot boundaries for vertical lines (dx==0).  The X
    # coordinate is unchanged, so boundary values at x1 are exact — reuse
    # ta_x1/ba_x1 already computed above (zero extra multiplies).
    if dx == 0:
        top_y = ta_x1 + tb
        bot_y = ba_x1 + bb
        cy1 = max(cy1, top_y)
        cy1 = min(cy1, bot_y)
        cy2 = max(cy2, top_y)
        cy2 = min(cy2, bot_y)

    return (cx1, cy1, cx2, cy2)

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
