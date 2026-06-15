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

# FINEANGLES sized for the 6502 table budget (~4.6 KB free at $E93A+):
#   viewangletox = ANG180+1 bytes (~2 KB), tantoangle = SLOPERANGE+1 entries.
FINEANGLES = 4096
ANGMASK = FINEANGLES - 1
ANG45 = FINEANGLES // 8      # 512
ANG90 = FINEANGLES // 4      # 1024
ANG180 = FINEANGLES // 2
ANG270 = 3 * ANG90
SLOPERANGE = 1024
SLOPEBITS = 10

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


CLIPANGLE = ANG45        # half-FOV (45 deg)

# DOOM checkcoord: per viewer box-region, the two silhouette corners as indices
# into (top,bot,left,right) == DOOM bspcoord order (TOP=0,BOT=1,LEFT=2,RIGHT=3).
_CHECKCOORD = [
    [3, 0, 2, 1], [3, 0, 2, 0], [3, 1, 2, 0], None,
    [2, 0, 2, 1], None,         [3, 1, 3, 0], None,
    [2, 0, 3, 1], [2, 1, 3, 1], [2, 1, 3, 0],
]


def _phi(cx, cy, px, py, a_fine):
    """View-relative signed angle phi = a_fine - atan2(dy,dx), in [-ANG180,ANG180).
    Same convention as view_col (phi>0 == right of centre). Validated vs float.
    """
    phi = (a_fine - point_to_angle(cx - px, cy - py)) & ANGMASK
    return phi - FINEANGLES if phi >= ANG180 else phi


def _phi_col(phi):
    """viewangletox centre column for an in-FOV signed phi."""
    idx = phi + ANG90
    return (_vatox_lo[idx] + _vatox_hi[idx]) // 2


def bbox_check_angle(top, bot, left, right, px, py, ab):
    """Angle-space bbox visibility (2 silhouette corners, no rotation), in the
    view_col phi-convention. Returns a conservative (ilo,ihi) column extent or
    None. Per corner: 0 muls, 1 divide.
    """
    if left <= px <= right and bot <= py <= top:
        return 0, VIS_W - 1
    boxx = 0 if px <= left else (1 if px < right else 2)
    boxy = 0 if py >= top else (1 if py > bot else 2)
    cc = _CHECKCOORD[(boxy << 2) + boxx]
    if cc is None:
        return 0, VIS_W - 1
    val = (top, bot, left, right)
    a_fine = (ab * (FINEANGLES // 256)) & ANGMASK
    p1 = _phi(val[cc[0]], val[cc[1]], px, py, a_fine)
    p2 = _phi(val[cc[2]], val[cc[3]], px, py, a_fine)
    lo_phi, hi_phi = (p1, p2) if p1 <= p2 else (p2, p1)
    # viewer is outside the box, so it subtends <180deg; if the signed span
    # exceeds 180 the short arc wraps through behind -> not visible.
    if hi_phi - lo_phi > ANG180:
        return None
    if hi_phi < -CLIPANGLE or lo_phi > CLIPANGLE:
        return None                                # wholly outside the FOV
    lo_phi = max(lo_phi, -CLIPANGLE)
    hi_phi = min(hi_phi, CLIPANGLE)
    lo = max(0, _phi_col(lo_phi) - 1)              # conservative +/-1
    hi = min(VIS_W - 1, _phi_col(hi_phi) + 1)
    if lo > hi:
        return None
    return lo, hi


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
