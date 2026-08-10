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

# -- TRIG5 prototype (2026-08-10): 5-bit trig magnitudes. mode 0 = off
# (8-bit table, THE pipeline); 1 = each magnitude rounded to a multiple
# of 8 (5 significant bits, emulated in the 8.8 pipeline — the t16
# RN>>3 then rounds nothing, exactly equivalent to computing counts
# with mag5 = mag/8 directly); 2 = per-angle OPTIMIZED (sin5, cos5)
# pair: joint search over +-1 candidates minimizing screen-space
# impact (angle error dominates x — weight 128 = focal; gain error
# shows only in y heights — weight 60 ~= max height offset).
TRIG5 = 0
_T5_PAIRS = None

def _t5_build_pairs():
    pairs = []
    for a in range(256):
        rad = a * 2.0 * math.pi / 256.0
        sv, cv = math.sin(rad), math.cos(rad)
        best = None
        s0 = int(math.floor(sv * 32)); c0 = int(math.floor(cv * 32))
        for s5 in range(max(-32, s0 - 1), min(32, s0 + 2) + 1):
            for c5 in range(max(-32, c0 - 1), min(32, c0 + 2) + 1):
                ds, dc = s5 / 32.0 - sv, c5 / 32.0 - cv
                cost = 128.0 * abs(cv * ds - sv * dc) + 60.0 * abs(sv * ds + cv * dc)
                if best is None or cost < best[0]:
                    best = (cost, s5, c5)
        pairs.append((best[1], best[2]))
    return pairs

def _t5_pack(v):
    # signed 5-bit value -> (mag_88, neg, unity) in the 8.8 emulation
    m = abs(v)
    if m >= 32:
        return 0, v < 0, True
    return m * 8, v < 0, False

def fp_sincos(angle_byte):
    """Returns (sin_mag, sin_neg, sin_unity, cos_mag, cos_neg, cos_unity)."""
    if TRIG5 == 2:
        global _T5_PAIRS
        if _T5_PAIRS is None:
            _T5_PAIRS = _t5_build_pairs()
        s5, c5 = _T5_PAIRS[angle_byte & 0xFF]
        return _t5_pack(s5) + _t5_pack(c5)
    s_mag, s_neg, s_unity = _sin_mag_sign(angle_byte)
    c_mag, c_neg, c_unity = _sin_mag_sign(angle_byte + 64)
    if TRIG5:
        if not s_unity:
            m = (s_mag + 4) >> 3
            s_mag, s_unity = (0, True) if m >= 32 else (m * 8, False)
        if not c_unity:
            m = (c_mag + 4) >> 3
            c_mag, c_unity = (0, True) if m >= 32 else (m * 8, False)
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

    SHRINK (2026-07-13, mirrors br_project_x's px_shrink): an s16 vx is
    halved in 8.8 (arithmetic — Python >> is floor, same as the 6502
    CMP/ROR chain) with S decremented (floor 1) until it fits s8. Screen
    error <= |vx|/(256*vy) px (corpus max 0.008px); below the S floor
    (near-plane crossings) the shrink is uncompensated — endpoints
    >= 64 screens off-screen keep sign and ordering only. The 3-mul
    full-width wide path this replaces is deleted on both sides.
    """
    X88 = vx * 256 + vx_frac
    deficit = 0
    while not (-128 <= (X88 >> 8) <= 127):
        if recip_s >= 2:
            recip_s -= 1
        else:
            deficit += 1     # DOMAIN: <= 3 in-engine (map diagonal);
                             # beyond it the 6502 indexes garbage
        X88 >>= 1
    vx, vx_frac = X88 >> 8, X88 & 0xFF
    B = (m8(vx_frac, recip_m8)
         + ((m8(vx, recip_m8) + vx_frac) << 8)
         + (vx << 16))
    if deficit:
        # net shift <= 0: the deficit kernels take P = B>>8 with NO
        # rounding stage (single quantisation, the shrink's truncations)
        return HALF_W + ((B >> 8) << (deficit - 1))
    return HALF_W + rns(B, recip_s + 8)

def fp_project_y(height_delta, recip_m8, recip_s):
    """Project height delta to screen Y (integer).

    sy = 80 - rns(h * m9, S)  with m9 = 256 + M8:
      h*m9 = h*M8 + (h << 8)
    ONE 8x8 multiply (was 2). The 6502 mirror (br_project_y's raw body) builds
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

    # V16 (2026-08-09): the pipeline is total := widen(q64(rot(w))) + ref,
    # where ref = rot(N_int) + frac is the per-frame origin term (the
    # 6502's vxc_ref, staged once by vxc_frame), N = -p_88.
    #
    # OFF-BY-ONE FIX (2026-08-10, Eben's quantised-jumping report): the
    # frac bytes above are (N & 255) — the UNSIGNED low byte of the
    # NEGATED position — so the integer term they pair with must be the
    # arithmetic N >> 8 (= -px_int - 1 when the frac is nonzero), NOT
    # -px_int. The old pairing rendered from a viewpoint one full unit
    # (8 world units) off per fractional axis, snapping at every
    # integer crossing — an invisible error on the integer suite grid,
    # a violent per-axis lurch when walking through fractional
    # positions. N = 256*(N>>8) + (N&255) is exact by construction.
    nx_int = (-vx_88) >> 8
    ny_int = (-vy_88) >> 8
    ref_vx = (_rot_int(nx_int, s_mag, s_neg, s_unity)
              - _rot_int(ny_int, c_mag, c_neg, c_unity) + frac_vx)
    ref_vy = (_rot_int(nx_int, c_mag, c_neg, c_unity)
              + _rot_int(ny_int, s_mag, s_neg, s_unity) + frac_vy)

    return (px_int, py_int, sc, frac_vx, frac_vy, ref_vx, ref_vy)

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
    px_int, py_int, sc, frac_vx, frac_vy, ref_vx, ref_vy = ctx
    s_mag, s_neg, s_unity, c_mag, c_neg, c_unity = sc

    # V16 base: pure rotation of the VERTEX (position-independent) —
    # exactly what the 6502 VXC memoizes — quantized RN to 1/64
    # prescaled (s16 storage), then the per-frame ref carries ALL the
    # position terms (integer + fractional) at full precision.
    base_vx = (_rot_int(wx, s_mag, s_neg, s_unity)
               - _rot_int(wy, c_mag, c_neg, c_unity))
    base_vy = (_rot_int(wx, c_mag, c_neg, c_unity)
               + _rot_int(wy, s_mag, s_neg, s_unity))
    total_vx = (((base_vx + 2) >> 2) << 2) + ref_vx
    total_vy = (((base_vy + 2) >> 2) << 2) + ref_vy

    evx_trunc = total_vx >> 8          # truncated (for sub-pixel mode)
    evx_round = (total_vx + 128) >> 8  # rounded (for non-sub-pixel mode)
    evy = (total_vy + 128) >> 8        # always round vy
    evx_frac = total_vx & 0xFF         # fractional vx (consistent with truncation)
    evy_idx = max(2, total_vy >> (8 - RECIP_FRAC_BITS))
    return evx_trunc, evx_round, evy, evx_frac, evy_idx


def fp_to_view_totals(wx, wy, ctx):
    """EV16: the full s24 view totals only (position-independent V16
    pipeline — recomputation is bit-identical to the original fetch;
    the 6502 recovers the same values through the VXC serve)."""
    px_int, py_int, sc, frac_vx, frac_vy, ref_vx, ref_vy = ctx
    s_mag, s_neg, s_unity, c_mag, c_neg, c_unity = sc
    base_vx = (_rot_int(wx, s_mag, s_neg, s_unity)
               - _rot_int(wy, c_mag, c_neg, c_unity))
    base_vy = (_rot_int(wx, c_mag, c_neg, c_unity)
               + _rot_int(wy, s_mag, s_neg, s_unity))
    return ((((base_vx + 2) >> 2) << 2) + ref_vx,
            (((base_vy + 2) >> 2) << 2) + ref_vy)

# -- Near clip (8-bit view coords) -------------------------------------------

NEAR_FP = 1  # 8.0
NEAR_88 = 256  # 8.8


# -- TRUE16 (2026-08-10): s16 count-scale pipeline, K16 = 32 counts per
# prescaled unit. The v2 formulation: operands stay UNIT scale (the
# rotation's 87%-zero hi partial is load-bearing — measured), and the
# count scale is applied as ONE RN >>3 at the rotation output:
#   rns(rot_88(w), 3) == rns(rot_88(32*w), 8) identically (32 = 2^5).
# base (per epoch, cached s16) and ref (per frame, fracs summed in
# BEFORE the shift) each round ONCE. Totals are s16 counts; NEAR
# verdict = 16 counts (0.5 unit); crossing plane = 32 counts (1.0);
# recip idx = vy>>4 (same half-unit table semantics); projection via
# X88 = counts<<3 EXACTLY (the 8.8 form br_project_x consumes).

T16_K = 32
T16_NEAR_VERDICT = 16          # 0.5 unit, mirrors evy<=0 / vy_88<128
T16_NEAR_CROSS = 32            # 1.0 unit, mirrors NEAR_88=256

def fp_to_view_totals_t16(wx, wy, ctx):
    """s16 count totals — the TRUE16 twin of fp_to_view_totals."""
    px_int, py_int, sc, frac_vx, frac_vy, ref_vx, ref_vy = ctx
    s_mag, s_neg, s_unity, c_mag, c_neg, c_unity = sc
    base_vx = (_rot_int(wx, s_mag, s_neg, s_unity)
               - _rot_int(wy, c_mag, c_neg, c_unity))
    base_vy = (_rot_int(wx, c_mag, c_neg, c_unity)
               + _rot_int(wy, s_mag, s_neg, s_unity))
    # per-epoch RN to counts (the VXC plane store); per-frame ref RN to
    # counts (ctx ref already carries ints + fracs at full 8.8)
    bx = rns(base_vx, 3)
    by = rns(base_vy, 3)
    rx = rns(ref_vx, 3)
    ry = rns(ref_vy, 3)
    return bx + rx, by + ry

def fp_to_view_t16(wx, wy, ctx):
    """TRUE16 twin of fp_to_view: same 5-tuple interface, count-derived.
    ex/frac come from X88 = counts<<3 (exact); evy token = the count vy
    (only ever compared for identity/near); vy_idx = vy>>4."""
    tvx, tvy = fp_to_view_totals_t16(wx, wy, ctx)
    X88 = tvx << 3
    evx_trunc = X88 >> 8
    evx_round = (X88 + 128) >> 8
    evx_frac = X88 & 0xFF
    evy = tvy                       # identity token + near verdict source
    evy_idx = max(2, tvy >> 4)
    return evx_trunc, evx_round, evy, evx_frac, evy_idx

def fp_cross_t16(vx1, vy1, vx2, vy2):
    """TRUE16 crossing at vy = 32 counts (1.0 unit). Same structure as
    fp_cross_88; returns cx in COUNTS. v1 = the clipped endpoint."""
    d = vy2 - vy1
    n = T16_NEAR_CROSS - vy1
    if d <= 0:
        return None
    while d > 255:
        d >>= 1
        n >>= 1
    if d == 0:
        return vx2
    t = ((n << 8) + (d >> 1)) // d
    if t >= 256:
        return vx2
    dvx = vx2 - vx1
    if dvx >= 0:
        return vx1 + ((t * dvx + 128) >> 8)
    return vx1 - ((t * (-dvx) + 128) >> 8)

def fp_cross_88(vx1, vy1, vx2, vy2):
    """Full-precision (8.8) near-plane crossing (EV16 prototype,
    2026-08-09). Caller guarantees vy1 < 128 <= ... exactly one side
    clipped; v1 is the CLIPPED endpoint (caller swaps). Returns cx
    (s16 8.8) at vy = NEAR_88. Mirrors the planned 6502 exactly:
      d = vy2 - vy1; n = 256 - vy1        (0 <= n <= d)
      normalize d to u8 (floor-shift n and d together)
      t = (n<<8 + d>>1) // d              (0.8, RN)
      t == 256 -> cx = vx2 exactly
      cx = vx1 + sign(dvx) * ((t*|dvx| + 128) >> 8)
    """
    d = vy2 - vy1
    n = NEAR_88 - vy1
    if d <= 0:
        return None
    while d > 255:
        d >>= 1
        n >>= 1
    if d == 0:
        return vx2
    t = ((n << 8) + (d >> 1)) // d
    if t >= 256:
        return vx2
    dvx = vx2 - vx1
    if dvx >= 0:
        return vx1 + ((t * dvx + 128) >> 8)
    return vx1 - ((t * (-dvx) + 128) >> 8)

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
    # Round-to-nearest t AND product (2026-07-19, near-clip precision):
    # num/den always share sign here, so t is the unsigned RN quotient
    # (den/2 dividend bias — the 6502 stages |den|>>1 in zp_div_l), and
    # the crossing adds (t*dvx + 128) >> 8 (the 6502 folds the product's
    # bit 7 in as ADC carry). Characterised over 380 corpus crossings:
    # mean |cx err| 0.905 -> 0.543 view units, mean visible column
    # error 1.06 -> 0.39, max 202 -> 74. num == den (v2 exactly on the
    # plane) still yields cx == vx2 exactly on both sides.
    n = abs(NEAR_FP - vy1) << 8
    d = abs(dvy)
    t = (n + (d >> 1)) // d
    dvx = vx2 - vx1
    cx = vx1 + ((t * dvx + 128) >> 8)
    if vy1 < NEAR_FP:
        return (cx, NEAR_FP, vx2, vy2)
    return (vx1, vy1, cx, NEAR_FP)

# -- Cyrus-Beck clipper (8-bit screen coords) ---------------------------------

# -- Prescaling constants (used by doom_wireframe.py at load time) ------------

MAP_CENTER_X = 1200
MAP_CENTER_Y = -3248    # 8-ALIGNED (2026-08-10, was -3250): a non-8-aligned
                        # center adds a fractional offset to every packed
                        # unit coordinate before rounding — free precision
                        # loss. Keep BOTH components multiples of PRESCALE.

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
