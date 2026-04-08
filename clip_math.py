"""Arithmetic helpers for the DOOM wireframe clipper.

Line Y computation uses real division: ly1 + dy*(x-lx1)/dx.
For short lines (common case: both endpoints on-screen), the operands
fit in 8 bits and the multiply/divide collapse to 8x8 and 16/8.
For long lines (rare: extending far off-screen), the operands are wider
but the computation is the same — just with more bytes.

No pre-clip needed.  No parametric fractions.  No split-byte multiply.
"""


def div_round(num, den):
    """Signed division with round-to-nearest.
    On 6502: adaptive width — 16/8 for small operands, 32/16 for large."""
    assert den != 0, "div_round: zero denominator"
    if den > 0:
        return (num + den // 2) // den
    return (-num + (-den) // 2) // (-den)


def compare_y_vs_boundary(cy_pixel, boundary_88):
    """Compare pixel Y against 8.8 boundary. Returns -1 (above), 0 (equal), +1 (below).
    On 6502: 8-bit comparison + optional fractional check."""
    boundary_pixel = boundary_88 >> 8
    boundary_frac = boundary_88 & 0xFF
    if cy_pixel < boundary_pixel:
        return -1  # above
    if cy_pixel > boundary_pixel:
        return +1  # below
    if boundary_frac > 0:
        return -1  # cy is at the pixel, boundary is past it
    return 0


def boundary_ix(cx1, cx2, d1, d2, clip_p1):
    """Compute intersection X from distance values d1,d2 (any width).
    Rounds toward the inside endpoint.
    clip_p1: True if P1 (cx1) is the outside point to be clipped.
    Returns X coordinate, or None if degenerate."""
    denom = d1 - d2
    if denom == 0:
        return None
    num = (cx2 - cx1) * d1
    if clip_p1:
        round_up = cx1 < cx2
    else:
        round_up = cx2 < cx1
    if round_up:
        ix = cx1 + -((-num) // denom)
    else:
        ix = cx1 + num // denom
    return ix
