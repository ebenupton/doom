"""Prototype: DOOM-style angle-space screen-column for our 256-wide, 90-deg-FOV
projection — the basis for an angle-space bbox visibility test.

Per corner: octant compares (0 muls) + one SlopeDiv divide + tantoangle lookup
+ an angle subtract + viewangletox lookup = 0 muls, 1 divide, depth ~2.
No rotation (folded into the angle subtract), no recip, no project_x.

This module validates the core numeric claim: that a CONSERVATIVE angle-space
column brackets the perspective column (fp_to_view + fp_project_x) for every
(world-delta, view-angle), so a bbox extent built from it is a superset of the
perspective extent — has_gap can only over-descend, never under-cull.
"""
import math

FINEANGLES = 8192
ANGMASK = FINEANGLES - 1
ANG45 = FINEANGLES // 8      # 1024
ANG90 = FINEANGLES // 4      # 2048
ANG180 = FINEANGLES // 2
ANG270 = 3 * ANG90
SLOPERANGE = 2048
SLOPEBITS = 11

HALF_W = 128
FOCAL = 128
VIS_W = 256

# tantoangle[s] = fine angle whose tan == s/SLOPERANGE, s in [0,SLOPERANGE];
# covers the first octant 0..45deg == 0..ANG45.
_tantoangle = [int(round(math.atan(s / SLOPERANGE) / (math.pi / 2) * ANG90))
               for s in range(SLOPERANGE + 1)]

# viewangletox: conservative bracket [lo,hi] of the screen column for a point
# whose view-relative angle is (idx - ANG90), idx in [0, ANG180].
def _col(view_fine):
    return HALF_W + FOCAL * math.tan(view_fine / FINEANGLES * 2 * math.pi)

_vatox_lo = [0] * (ANG180 + 1)
_vatox_hi = [0] * (ANG180 + 1)
for _f in range(ANG180 + 1):
    _va = _f - ANG90
    if _va <= -ANG90:
        _vatox_lo[_f] = _vatox_hi[_f] = -1
    elif _va >= ANG90:
        _vatox_lo[_f] = _vatox_hi[_f] = VIS_W
    else:
        _c0, _c1 = _col(_va - 0.5), _col(_va + 0.5)
        _vatox_lo[_f] = math.floor(min(_c0, _c1))
        _vatox_hi[_f] = math.ceil(max(_c0, _c1))


def slope_div(num, den):
    """num/den scaled to [0,SLOPERANGE]; caller guarantees num <= den."""
    if den == 0:
        return SLOPERANGE
    ans = (num << SLOPEBITS) // den
    return ans if ans <= SLOPERANGE else SLOPERANGE


def point_to_angle(dx, dy):
    """World fine-angle of (dx,dy) == atan2(dy,dx), in [0,FINEANGLES)."""
    if dx == 0 and dy == 0:
        return 0
    if dx >= 0:
        if dy >= 0:
            return _tantoangle[slope_div(dy, dx)] if dx > dy \
                else ANG90 - _tantoangle[slope_div(dx, dy)]
        ady = -dy
        return (-_tantoangle[slope_div(ady, dx)]) & ANGMASK if dx > ady \
            else ANG270 + _tantoangle[slope_div(dx, ady)]
    adx = -dx
    if dy >= 0:
        return ANG180 - _tantoangle[slope_div(dy, adx)] if adx > dy \
            else ANG90 + _tantoangle[slope_div(adx, dy)]
    ady = -dy
    return ANG180 + _tantoangle[slope_div(ady, adx)] if adx > ady \
        else ANG270 - _tantoangle[slope_div(adx, ady)]


def view_col(vx, vy):
    """Screen column for a VIEW-SPACE point (vx sideways, vy forward).
    Angle-table projection: phi = atan2(vx,vy) -> viewangletox. 0 muls, 1 divide.
    Returns -1 (off left), 256 (off right), or an on-screen column [0,255].
    Caller must have near-clipped (vy >= NEAR), so phi in (-90,+90)deg.
    """
    phi = point_to_angle(vy, vx)            # atan2(vx, vy) in fine units
    if phi >= ANG180:
        phi -= FINEANGLES
    idx = phi + ANG90
    if idx < 0:
        return -1
    if idx > ANG180:
        return VIS_W
    return (_vatox_lo[idx] + _vatox_hi[idx]) // 2


def view_column(dx, dy, ab):
    """Conservative (lo,hi) screen-column bracket for world delta (dx,dy) at
    view angle byte ab, via world-angle minus view-angle. None if behind/outside.
    """
    a_fine = (ab * (FINEANGLES // 256)) & ANGMASK     # view angle in fine units
    psi = point_to_angle(dx, dy)                       # world angle of delta
    phi = (a_fine - psi) & ANGMASK                     # view-relative angle
    if phi >= ANG180:
        phi -= FINEANGLES                              # signed [-ANG180, ANG180)
    idx = phi + ANG90
    if idx < 0 or idx > ANG180:
        return None
    return _vatox_lo[idx], _vatox_hi[idx]
