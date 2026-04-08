"""Arithmetic helpers for the DOOM wireframe clipper.

All span Y values are integer pixels. Line Y computed by real division.
Boundary intersection uses pixel-scale d values (s8/s9).
"""


def div_round(num, den):
    """Signed division with round-to-nearest.
    On 6502: adaptive width — 16/8 for small operands, 32/16 for large."""
    assert den != 0, "div_round: zero denominator"
    if den > 0:
        return (num + den // 2) // den
    return (-num + (-den) // 2) // (-den)


def boundary_ix(cx1, cx2, d1, d2, clip_p1):
    """Compute intersection X from pixel-scale distance values d1,d2.
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
