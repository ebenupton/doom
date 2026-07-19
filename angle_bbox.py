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


# ---- option F (2026-07-17): the BBOX path only uses the log2/atanexp
# approximation, certified exhaustively by tools/atanexp_cert.py
# (EPSILON = max |ta' - ta_exact| in fine units). The seg-side users of
# point_to_angle (angle_seg pack data) stay EXACT. The +-EPSILON role
# bias below makes every bbox verdict a SUPERSET of the exact
# convention's -> the framebuffer is bit-identical, only cycles change.
import json as _json, os as _os
try:
    _FT = _json.load(open(_os.path.join(
        _os.path.dirname(_os.path.abspath(__file__)),
        'tools', 'atanexp_tables.json')))
    _L8, _ATANEXP, _TA0 = _FT['L8'], _FT['ATANEXP'], _FT['TA0']
    EPSILON_F = _FT['EPSILON']
except FileNotFoundError:                  # bootstrap: the cert tool imports
    _L8 = _ATANEXP = None                  # this module to reach _tantoangle
    _TA0 = 0
    EPSILON_F = 0


def _lf(v):
    # >= 256: >>3 with half-bit recovery (2026-07-19): odd half-steps
    # average the two neighbouring L8 entries, round-to-nearest — the
    # 6502 folds the shifted-out carry in as the +1 of (a + b + 1) >> 1.
    # Index 255 has no neighbour: flat (6502 guards identically).
    # MUST match tools/atanexp_cert.py's L() bit for bit.
    if v < 256:
        return _L8[v]
    i = v >> 3
    if (v & 4) and i < 255:
        return ((_L8[i] + _L8[i + 1] + 1) >> 1) + 96
    return _L8[i] + 96


def _ta_f(num, den):
    """tantoangle[slope_div(num,den)] via the F tables (num < den)."""
    if num == 0:
        return _TA0
    k = _lf(den) - _lf(num)
    if k < 0:
        k = 0                    # rounding jitter near num~den (cert: kmin=0)
    elif k > 255:
        k = 255                  # far-ratio tail (cert folds these buckets)
    return _ATANEXP[k]


def point_to_angle_f(dx, dy):
    """point_to_angle with the F ta — 6502 corner_phi's convention."""
    if dx == 0 and dy == 0:
        return 0
    if dx >= 0:
        if dy >= 0:
            if dx > dy:
                return _ta_f(dy, dx)
            if dx == dy:
                return ANG45
            return ANG90 - _ta_f(dx, dy)
        ady = -dy
        if dx > ady:
            return (-_ta_f(ady, dx)) & ANGMASK
        if dx == ady:
            return ANG270 + ANG45
        return ANG270 + _ta_f(dx, ady)
    adx = -dx
    if dy >= 0:
        if adx > dy:
            return ANG180 - _ta_f(dy, adx)
        if adx == dy:
            return ANG90 + ANG45
        return ANG90 + _ta_f(adx, dy)
    ady = -dy
    if adx > ady:
        return ANG180 + _ta_f(ady, adx)
    if adx == ady:
        return ANG180 + ANG45
    return ANG270 - _ta_f(adx, ady)


def _phi(cx, cy, px, py, a_fine):
    """View-relative signed angle phi = a_fine - atan2_F(dy,dx), in
    [-ANG180,ANG180). Same convention as view_col (phi>0 == right of
    centre). F tables since 2026-07-17 (bbox path only).
    """
    phi = (a_fine - point_to_angle_f(cx - px, cy - py)) & ANGMASK
    return phi - FINEANGLES if phi >= ANG180 else phi


def _phi_col(phi):
    """viewangletox centre column for an in-FOV signed phi, clamped to u8
    (the 6502 viewangletox table stores columns as bytes)."""
    idx = phi + ANG90
    c = (_vatox_lo[idx] + _vatox_hi[idx]) // 2
    return 0 if c < 0 else (255 if c > 255 else c)


def bbox_check_angle(top, bot, left, right, px, py, ab):
    """Angle-space bbox visibility (2 silhouette corners, no rotation), in the
    view_col phi-convention. Returns a conservative (ilo,ihi) column extent or
    None. Per corner: 0 muls, 1 divide.

    Faithful DOOM R_CheckBBox in our phi convention (our _phi is the NEGATED
    DOOM view-relative angle, so DOOM angle1=-p1, angle2=-p2). All angular
    arithmetic is UNSIGNED-BAM wraparound, which natively handles a
    silhouette corner behind the view plane — the case the original
    signed-sort logic mis-narrowed (over-culled straddling boxes, drawing
    far rooms through walls; see the 2026-07 angle_race: signed-sort
    diverged 11/68 positions vs the corner reference, this version 0/68
    with equal descend counts).
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
    p1 = _phi(val[cc[0]], val[cc[1]], px, py, a_fine) - EPSILON_F   # left,
    p2 = _phi(val[cc[2]], val[cc[3]], px, py, a_fine) + EPSILON_F   # right —
    # the certified role bias: every verdict is a SUPERSET of the exact
    # convention's (6502: the twin pre-biased afr constants, view.s)
    # REGION-CELL TAIL (2026-07-20): the span + tspan windows were a
    # factored 1-bit approximation of a 3x3 region table over the
    # biased corners; classifying each corner directly kills the span.
    # r'' = (phi_biased + CLIPANGLE) & 4095; F = [0,1024) strictly,
    # R = [1024,2560), L = [2560,4096). Cells:
    #        r2: F           R            L
    #    r1: F  lookups      [col1,255]   [col1,255]
    #        R  [0,col2]     cull         cull
    #        L  [0,col2]     FULL         cull
    # r1-out with r2 in-FOV = the box wraps in from the left edge
    # (coverage [0,col2]) whichever side r1 sits; mirrored for r2-out;
    # (L,R) = viewer inside the box's arc = full; same-side and (R,L)
    # intervals miss the FOV = cull. The ==1024 boundary folds into
    # the out-cells (right: 255, identical to the old constant arm;
    # left: ilo 0, a superset of the old 254). MUST match the 6502's
    # bca_tail cell for cell.
    # REACHABILITY TRIPWIRE (2026-07-20): the cell table (and the
    # 6502's) is exhaustively verified over the band (p2-p1) & 4095 in
    # [0, 2048+2E) u (4096-2E, 4096) — everything the arms can emit
    # (true span < 2048 strictly outside the box; each corner within
    # +-EPSILON_F). Outside the band the 6502 emits inverted (F,F)
    # intervals and this mirror culls — a silent divergence — so any
    # real call landing there means the certificate premise broke.
    _d = (p2 - p1) & ANGMASK
    assert _d < ANG180 + 2 * EPSILON_F or _d > ANGMASK - 2 * EPSILON_F, (
        f'bbox corner pair outside the verified band: span {_d}')
    r1 = (p1 + CLIPANGLE) & ANGMASK
    r2 = (p2 + CLIPANGLE) & ANGMASK
    c1 = 0 if r1 < 1024 else (1 if r1 < 2560 else 2)
    c2 = 0 if r2 < 1024 else (1 if r2 < 2560 else 2)
    if c1 == 0:
        if c2 == 0:
            lo = max(0, _phi_col(p1) - 1)               # conservative +/-1
            hi = min(VIS_W - 1, _phi_col(p2) + 1)
            if lo > hi:
                return None                             # tripwire: unreachable
            return lo, hi
        return max(0, _phi_col(p1) - 1), VIS_W - 1      # (F,R)/(F,L)
    if c2 == 0:
        return 0, min(VIS_W - 1, _phi_col(p2) + 1)      # (R,F)/(L,F)
    if c1 == 2 and c2 == 1:
        return 0, VIS_W - 1                             # (L,R): full
    return None                                         # (R,R)/(L,L)/(R,L)


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
