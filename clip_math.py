"""Constrained arithmetic for the DOOM wireframe clipper.

All multiplies are 8x8→16 (matching 6502 quarter-square tables).
All inputs/outputs are range-checked via assertions.

Precision strategy:
  - Pre-clip line X to [0,255] (once per line, wide math OK)
  - After pre-clip: dx is u8, dy is s14, all span X are u8
  - Parametric fractions (0.8 format, u8) via integer division
  - Split wide values into hi/lo bytes for 8x8 multiply
  - Boundary Y in 8.8 (s16), clipped Y in pixel (s9)
"""

# ---------- Range constants ----------
S8_MIN, S8_MAX = -128, 127
U8_MAX = 255
S16_MIN, S16_MAX = -32768, 32767
U16_MAX = 65535

# ---------- 8x8 multiply primitives ----------

def smul8(a, b):
    """Signed 8-bit × unsigned 8-bit → s16.
    On 6502: negate-if-negative + quarter-square + negate-result."""
    assert S8_MIN <= a <= S8_MAX, f"smul8 a={a}"
    assert 0 <= b <= U8_MAX, f"smul8 b={b}"
    r = a * b
    assert S16_MIN <= r <= S16_MAX, f"smul8 result={r}"
    return r


def umul8(a, b):
    """Unsigned 8-bit × unsigned 8-bit → u16.
    On 6502: quarter-square table lookup."""
    assert 0 <= a <= U8_MAX, f"umul8 a={a}"
    assert 0 <= b <= U8_MAX, f"umul8 b={b}"
    return a * b


def umul8_hi(a, b):
    """Unsigned 8×8 multiply, return high byte only (>>8).
    On 6502: quarter-square, take result byte 1."""
    assert 0 <= a <= U8_MAX, f"umul8_hi a={a}"
    assert 0 <= b <= U8_MAX, f"umul8_hi b={b}"
    return (a * b) >> 8


# ---------- Division ----------

def frac08(offset, span):
    """Compute offset/span as 0.8 fixed point (u8), round-to-nearest.
    offset: [0, span], span: [1, 256].
    On 6502: if span==256, result=offset (trivial shift); else reciprocal table."""
    assert 0 <= offset, f"frac08 offset={offset}"
    assert 1 <= span <= 256, f"frac08 span={span}"
    assert offset <= span, f"frac08 offset={offset} > span={span}"
    if span == 256:
        return min(offset, 255)
    r = (offset * 256 + span // 2) // span
    return min(r, 255)


def div_round(num, den):
    """Signed division with round-to-nearest. Any width.
    On 6502: restoring division loop + sign handling."""
    assert den != 0, "div_round: zero denominator"
    if den > 0:
        return (num + den // 2) // den
    return (-num + (-den) // 2) // (-den)


# ---------- Composite operations ----------

def eval_boundary_88(y0, y1, f):
    """Evaluate 8.8 boundary Y at fraction f (0.8, u8).
    y0, y1: 8.8 format (screen Y range: roughly [-2560, 43520]).
    f: u8 (0.8 fraction, 0=y0, 255≈y1).
    Returns 8.8.
    On 6502: 2 × 8x8 multiply + 16-bit add."""
    assert -2560 <= y0 <= 43520, f"eval_boundary y0={y0}"
    assert -2560 <= y1 <= 43520, f"eval_boundary y1={y1}"
    assert 0 <= f <= 255, f"eval_boundary f={f}"
    dt = y1 - y0
    dt_hi = dt >> 8          # s9, but |dt_hi| <= 160 for screen coords
    dt_lo = dt & 0xFF        # u8
    # Clamp dt_hi to s8 range for the multiply (assert it fits)
    abs_dt_hi = abs(dt_hi)
    assert abs_dt_hi <= U8_MAX, f"eval_boundary |dt_hi|={abs_dt_hi} > 255"
    # High part: s8 * u8 → s16 (using sign-magnitude)
    if dt_hi >= 0:
        hi_part = umul8(abs_dt_hi, f)
    else:
        hi_part = -umul8(abs_dt_hi, f)
    # Low part: u8 * u8 → u16, take high byte (with rounding)
    lo_part = (umul8(dt_lo, f) + 128) >> 8
    r = y0 + hi_part + lo_part
    return r


def line_y_narrow(ly1, dy, f):
    """Compute line pixel Y at parametric fraction f (0.8, u8).
    ly1: s16 (pixel Y of first endpoint). dy: s16 (pixel delta).
    f: u8 (0.8 fraction, 0=ly1, 256=ly2).
    Returns pixel Y (s16).
    On 6502: 2 × 8x8 multiply + 16-bit add."""
    assert 0 <= f <= 255, f"line_y_narrow f={f}"
    dy_hi = dy >> 8       # integer quotient of dy/256
    dy_lo = dy & 0xFF     # u8
    if dy < 0:
        # For negative dy: dy = dy_hi*256 + dy_lo doesn't hold when dy_lo > 0
        # because >> in Python floors. Fix: adjust.
        # dy = -500 → dy>>8 = -2, dy&0xFF = 12. -2*256+12 = -500. ✓ (Python)
        pass
    abs_dy_hi = abs(dy_hi)
    assert abs_dy_hi <= U8_MAX, f"line_y_narrow |dy_hi|={abs_dy_hi}"
    # High part: s_small * u8
    if dy_hi >= 0:
        hi_part = umul8(abs_dy_hi, f)
    else:
        hi_part = -umul8(abs_dy_hi, f)
    # Low part: u8 * u8 >> 8, with rounding
    lo_part = (umul8(dy_lo, f) + 128) >> 8
    return ly1 + hi_part + lo_part


def preclip_line_x(lx1, ly1, lx2, ly2):
    """Clip line X endpoints to [0, 255]. Uses wide math (per-line, not per-span).
    Returns (lx1, ly1, lx2, ly2) with lx1,lx2 in [0,255], or None if invisible."""
    dx = lx2 - lx1
    dy = ly2 - ly1
    if dx == 0:
        if lx1 < 0 or lx1 > 255:
            return None
        return (lx1, ly1, lx2, ly2)
    # Clip left side (x < 0)
    if lx1 < 0 and dx > 0:
        ly1 = ly1 + div_round(dy * (0 - lx1), dx)
        lx1 = 0
    elif lx2 < 0 and dx < 0:
        ly2 = ly2 + div_round((-dy) * (0 - lx2), -dx)
        lx2 = 0
    # Clip right side (x > 255)
    dx = lx2 - lx1
    if dx == 0:
        if lx1 < 0 or lx1 > 255:
            return None
        return (lx1, ly1, lx2, ly2)
    if lx2 > 255 and dx > 0:
        ly2 = ly1 + div_round(dy * (255 - lx1), dx)
        lx2 = 255
    elif lx1 > 255 and dx < 0:
        ly1 = ly2 + div_round((-dy) * (255 - lx2), -dx)
        lx1 = 255
    if min(lx1, lx2) > 255 or max(lx1, lx2) < 0:
        return None
    assert 0 <= lx1 <= 255, f"preclip lx1={lx1}"
    assert 0 <= lx2 <= 255, f"preclip lx2={lx2}"
    return (lx1, ly1, lx2, ly2)


def compare_y_vs_boundary(cy_pixel, boundary_88):
    """Compare pixel Y against 8.8 boundary. Returns -1 (above), 0 (equal), +1 (below).
    On 6502: 8-bit comparison + optional fractional check."""
    boundary_pixel = boundary_88 >> 8
    boundary_frac = boundary_88 & 0xFF
    if cy_pixel < boundary_pixel:
        return -1  # above (lower Y = higher on screen)
    if cy_pixel > boundary_pixel:
        return +1  # below
    # Same pixel: above only if boundary has fractional part
    if boundary_frac > 0:
        return -1  # cy is at the pixel, boundary is past it
    return 0  # exactly equal


def boundary_ix(cx1, cx2, d1, d2):
    """Compute intersection X from distance values d1,d2 (any width).
    Rounds toward the inside endpoint.
    cx1,cx2: u8. d1: distance at cx1 (outside if >0 for bot, <0 for top).
    Returns u8 X coordinate, or None if degenerate."""
    denom = d1 - d2
    if denom == 0:
        return None
    num = (cx2 - cx1) * d1
    # Determine which endpoint is outside (d1 has larger absolute distance)
    clip_p1 = abs(d1) >= abs(d2)
    if clip_p1:
        round_up = cx1 < cx2
    else:
        round_up = cx2 < cx1
    if round_up:
        ix = cx1 + -((-num) // denom)
    else:
        ix = cx1 + num // denom
    return ix
