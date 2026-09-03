"""Extruded-profile billboards (the boxes, the vest) and the icon pickups.

A prism is a closed profile polygon (x, z), symmetric about x = 0, extruded
to half-depth d.  Under the SAME linearized perspective as the cylinder
stacks, a profile point at height z projects twice:

    front copy   y = R(z) + b(z)
    rear  copy   y = R(z) - b(z)        b(z) = K*d*|z - ze| / D^2

-- the box's top face opens by exactly the law that opens a rim ellipse.
Every object here sits wholly below the eye, so the REAR top boundary is
the topmost line at every x: that is the armed run.

THE TOP-FACE DIAGONALS (Eben, 2026-08-31): true perspective scales x by
1/(D - t), and anchoring the FRONT face at the sprite's width makes the
rear edge (D-d)/(D+d) of it -- so the top face is a trapezoid and its
diagonal side slopes are real geometry, not sprite decoration.  The
diagonals are the topmost line outboard of the rear edge, so they are
armed too.  The vest keeps xr = 1: at its depth the shave is sub-pixel
and its armed set is built on aligned front/rear edges.

The medikit and stimpack carry the painted cross as a 12-line OUTLINE
(Eben, 2026-08-31), a closed plus-sign polygon CENTRED on the front face
(Eben again: the sprites park theirs off-centre -- row 11 of 15 on the
stimpack, row 8 of 19 on the medikit -- but the box's face is the design
surface, not the sprite's framing).  Proportions measured off the
red-dominant sprite pixels: both are 6 x 6 with 2-px bars.  Closed means
no free ends -- the potion's stem terminus is the only free end left
anywhere.

THE ICONS (Eben, 2026-08-31): the potion is a SPHERE (bulb r on the
ground) plus its neck seen edge-on -- a sphere projects to a circle and
an edge-on cylinder to a line, so the billboard is literally a circle
with a stem.  The helmet is JUST its 2D outline: base, sides, two dome
segments per side, flat top; no ellipses, one tier.
"""
import math

class Prism:
    def __init__(self, h, d, ze, D, K, xpersp=False):
        self.h, self.d, self.ze, self.D, self.K = h, d, ze, D, K
        self.xr = (D - d)/(D + d) if xpersp else 1.0
        self.H = K*h/D
        # GROUNDED, FRONT-ANCHORED (2026-08-31 lid-fit pass).  The bottom
        # face sits ON the floor: the front-bottom edge IS the ground
        # contact and the rear-bottom edge is self-occluded, so the frame
        # anchors to the front face -- front points map z linearly from
        # the contact, and the rear copy of a point sits 2*b(z) ABOVE its
        # front copy (near drops b, far rises b, and only the difference
        # is drawable).  The whole lid depth 2*b(h) is allocated at the
        # top; the old symmetric-inset form wasted b(0) of the extent
        # under the front face (3.5 of 15 px at the stimpack's viewpoint).
        self.bt = 2.0*self.b(h)
        self.k = (self.H - self.bt)/h
    def a(self, x):    return self.K*x/self.D
    def b(self, z):    return self.K*self.d*abs(z-self.ze)/(self.D*self.D)
    def F(self, x, z): return (self.a(x), self.H - z*self.k)
    def B(self, x, z): return (self.a(x)*self.xr, self.H - z*self.k - 2.0*self.b(z))

class _Flat:
    """H-carrier for the icon objects (no depth model)."""
    def __init__(self, h, D, K2): self.H = K2*h/D

# ---- the objects ---------------------------------------------------------
POBJ = {
 # BOX DESIGN VIEWPOINTS ARE LID-IMPLIED (Eben 2026-08-31: "fit the lids
 # better").  The lid is the light band in the sprite's luma: STIMA0 rows
 # 0-2 with the bright front rim at row 2, MEDIA0 rows 0-3 with the rim
 # at row 3 -- and the lid LINE sits one pixel below the rim row (Eben,
 # second pass), so the depths are 3 and 4 px.  Rear edges 10 of 14 and
 # 22 of 28.  Two measurements, two unknowns:
 #     taper = (D-d)/(D+d)          depth = 2*(d/D)*(ze-h)
 # with the physical d fixed, so stim: d/D = 1/6 -> D = 30, ze = 24;
 # medikit: d/D = 3/25 -> D = 58.3, ze = 35.7.  Same precedent as the
 # pillar's ELECA0-implied viewpoint; at the engine eye the lid is a
 # two-pixel sliver and the box reads as a plain rectangle.
 'stim':    dict(lump='STIMA0', thing=2011, n=1, kind='box',
                 h=15.0, w=7.0, d=5.0, crosspx=(3, 3, 1), view=(24.0, 30.0)),
 'medikit': dict(lump='MEDIA0', thing=2012, n=3, kind='box',
                 h=19.0, w=14.0, d=7.0, crosspx=(3, 3, 1), view=(35.7, 58.3)),
 'potion':  dict(lump='BON1A0', thing=2014, n=13, kind='potion',
                 h=18.0, r=7.0, wn=2.0),        # wn = neck half-width (the
                                                # sprite's neck is 4 px)
 'helmet':  dict(lump='BON2A0', thing=2015, n=25, kind='helmet',
                 h=15.0, prof=[(8.0, 0.0), (8.0, 10.0), (6.0, 13.0), (3.0, 15.0)],
                 # the rim's two indentations, off BON2A0 rows 13-14: gaps
                 # at cols 4-5 and 10-11 = x in +-[2,4], two rows deep
                 notch=(2.0, 4.0, 2.0)),
 # The vest: an extruded shell, half-depth 3.5.  Profile off ARM1A0's
 # silhouette EXCEPT the neck scoop, deepened to 4 units: the sprite's
 # alpha only dips one pixel there (the neckline lives in its shading),
 # and a one-unit scoop is not a physically reasonable vest.  Same rule
 # as the barrel lid: the sprite is designer intent, the object is real.
 'armour':  dict(lump='ARM1A0', thing=2018, n=2, kind='vest',
                 h=17.0, d=3.5, waist=5.5, pit=(10.5, 10.0), arm=(15.5, 12.0),
                 side_top=16.0, sh_out=13.5, sh_in=3.0, scoop_z=13.0),
}

def box_lines(o, ze, D, K2, lod):
    p = Prism(o['h'], o['d'], ze, D, K2, xpersp=True)
    w, h = o['w'], o['h']
    if lod == 1:
        # L1 (Eben, 2026-08-31): just the rectangle with the lid line.
        # The trapezoid's diagonals are sub-pixel at L1 sizes; the lid
        # line keeps the box reading as a box.  5 lines, 1 armed.
        a, yl = p.a(w), 2.0*p.b(h)              # the lid's front rim
        return [((-a, 0.0), (a, 0.0), 'a'),     # top edge -- ARMED
                ((-a, yl),  (a, yl),  'r'),     # the lid line
                ((-a, 0.0), (-a, p.H), 'b'),
                (( a, 0.0), ( a, p.H), 'b'),
                ((-a, p.H), (a, p.H), 'b')]
    L = [(p.B(-w, h), p.B(w, h), 'a'),          # rear top edge -- ARMED
         (p.F(-w, h), p.B(-w, h), 'a'),         # top-face diagonals: the
         (p.F( w, h), p.B( w, h), 'a'),         #   topmost line outboard of
                                                #   the rear edge, so ARMED
         (p.F(-w, h), p.F(w, h), 'r'),          # front top edge (interior)
         (p.F(-w, h), p.F(-w, 0), 'b'),         # front face sides
         (p.F( w, h), p.F( w, 0), 'b'),
         (p.F(-w, 0), p.F(w, 0), 'b')]          # bottom
    if lod == 0 and o.get('crosspx'):
        # The cross outline, sized in SPRITE PIXELS (half-width,
        # half-height, bar half-thickness) and CENTRED on the front face:
        # the face runs from the lid's front rim (bt) to the ground line
        # (H), so its middle is their mean.  Other views scale the decal
        # with the figure.
        cw, ch2, t = (v*p.H/h for v in o['crosspx'])
        yc = (p.bt + p.H)/2.0
        C = [(-t, -ch2), (t, -ch2), (t, -t), (cw, -t), (cw, t), (t, t),
             (t, ch2), (-t, ch2), (-t, t), (-cw, t), (-cw, -t), (-t, -t)]
        pts = [(x, yc + dy) for x, dy in C]
        L += [(pts[i], pts[(i+1) % 12], 'b') for i in range(12)]
    return L

def vest_lines(o, ze, D, K2, lod):
    # OUTLINE tracing (Eben 2026-09-02, round 2): the old L0 outline IS
    # the L1 now; the new L0 doubles the line count with curved
    # refinements of every run.  Both tiers close the NECK HOLE into a
    # LOOP: the front scoop bottom, two depth stubs, and the BACK OF THE
    # NECK -- the rear rim seen through the hole from the raised eye
    # (armed: it is the topmost line across the opening).
    p = Prism(o['h'], o['d'], ze, D, K2)
    h, wa = o['h'], o['waist']
    (px_, pz), (ax_, az) = o['pit'], o['arm']
    st, so, si, sz = o['side_top'], o['sh_out'], o['sh_in'], o['scoop_z']
    mid = lambda A, B, ox, oz: ((A[0]+B[0])/2.0+ox, (A[1]+B[1])/2.0+oz)
    L = []
    if lod == 0:
        # DOUBLED outline: each straight run becomes two segments through
        # a nudged midpoint (gentle curvature, sprite-side bulges).
        # LADDER-FEASIBLE FORM (2026-09-02): the engine's y ladder is
        # syt + f*H with f in [0,255], so nothing may sit above the top
        # or below the ground -- the hem curves ENDS-UP (+0.8) instead
        # of centre-down, and the shoulder crown rides AT the top with
        # the ends dipped 0.3.
        he = 0.8                                             # hem end lift
        L += [(p.F(-wa, he), p.F(0, 0), 'b'), (p.F(0, 0), p.F(wa, he), 'b')]
        shd = h - 0.3                                        # shoulder ends
        for s in (-1, 1):
            w1 = mid((s*wa, he), (s*px_, pz), s*0.7, 0)      # waist bows out
            f1 = mid((s*px_, pz), (s*ax_, az), s*0.5, 0)     # flare bows out
            L += [(p.F(s*wa, he),  p.F(*w1), 'b'),
                  (p.F(*w1),      p.F(s*px_, pz), 'b'),
                  (p.F(s*px_, pz), p.F(*f1), 'b'),
                  (p.F(*f1),      p.F(s*ax_, az), 'b')]
            sm = mid((s*ax_, az), (s*ax_, st), 0, 0)         # side: split at the
            L += [(p.F(s*ax_, az), p.B(*sm), 'b'),           # F->B seam only (an
                  (p.B(*sm),      p.B(s*ax_, st), 'b')]      # x-bulge here pokes
                                                             # past the armed
                                                             # corner: rule FAIL
            c1 = mid((s*ax_, st), (s*so, shd), s*0.4, 0.4)   # rounded corner
            L += [(p.B(s*ax_, st), p.B(*c1), 'a'),
                  (p.B(*c1),      p.B(s*so, shd), 'a')]
            s1 = ((s*so + s*si)/2.0, h)                      # crown AT the top
            L += [(p.B(s*so, shd), p.B(*s1), 'a'),
                  (p.B(*s1),    p.B(s*si, shd), 'a'),
                  (p.B(s*si, shd), p.B(s*si, sz), 'b')]      # scoop side
        bz = (sz + h)/2.0                    # back of neck: halfway from
                                             # the old rim up to the top
        fb = mid((-si, sz), (si, sz), 0, -0.6)               # front rim sags
        bb = mid((-si, bz), (si, bz), 0, -0.3)               # rear rim, gentler
        L += [(p.F(-si, sz), p.F(*fb), 'b'), (p.F(*fb), p.F(si, sz), 'b'),
              (p.B(-si, bz), p.B(*bb), 'a'), (p.B(*bb), p.B(si, bz), 'a'),
              (p.F(-si, sz), p.B(-si, bz), 'b'),             # hole depth stubs
              (p.F( si, sz), p.B( si, bz), 'b')]
    else:
        # L1 = the old L0 outline, plus the neck loop.
        L += [(p.F(-wa, 0), p.F(wa, 0), 'b')]                # bottom
        for s in (-1, 1):
            L += [(p.F(s*wa, 0),  p.F(s*px_, pz), 'b'),      # waist slant
                  (p.F(s*px_, pz), p.F(s*ax_, az), 'b'),     # armpit flare
                  (p.B(s*ax_, st), p.F(s*ax_, az), 'b'),     # side
                  (p.B(s*ax_, st), p.B(s*so, h), 'a'),       # corner slant: ARMED
                  (p.B(s*so, h),  p.B(s*si, h), 'a'),        # shoulder: ARMED
                  (p.B(s*si, h),  p.B(s*si, sz), 'b')]       # scoop side
        bz = (sz + h)/2.0                    # back of neck: halfway up
        L += [(p.F(-si, sz), p.F(si, sz), 'b'),              # neck: front rim
              (p.B(-si, bz), p.B(si, bz), 'a'),              #   back of neck: ARMED
              (p.F(-si, sz), p.B(-si, bz), 'b'),             #   hole depth stubs
              (p.F( si, sz), p.B( si, bz), 'b')]
    return L

def potion_lines(o, ze, D, K2, lod):
    h, r = o['h'], o['r']
    k = K2/D
    H = h*k
    a = r*k
    # b = a always (the bulb IS a sphere); what changes per tier is the
    # REACH -- L0's arc attains the full a, L1's only q*a (the same
    # flattening a rim ellipse suffers).  The centre rides the reach so
    # the bulb still fills its share of the extent, and the stem joins
    # the arc's top segment at either tier.
    reach = a if lod == 0 else A2*a
    cy = H - reach                               # bulb bottom ON the ground
    if lod == 0:
        up = [(XF[i]*a, cy - a*YF[i]) for i in range(6)]
        dn = [(XF[i]*a, cy + a*YF[i]) for i in range(6)]
    else:
        q = A2
        up = [(-a, cy - a*A3), (-q*a, cy - a*q), (q*a, cy - a*q), (a, cy - a*A3)]
        dn = [(u, 2*cy - v) for u, v in up]
    # The upper arc is armed ONLY where it is exposed: under the stem the
    # topmost line is the stem's top edge, and an armed line that is not
    # topmost would over-tighten if this ever lands (authority = the
    # topmost silhouette, the lamp/pillar rule).  Split each segment at
    # +-wn and classify the pieces; the stem feet land exactly on the
    # split points.
    wn = o['wn']*k
    L = []
    for p0, p1 in zip(up, up[1:]):
        pieces, cur = [], (p0, p1)
        for xc in (-wn, wn):
            (u, v) = cur
            if min(u[0], v[0]) + 1e-9 < xc < max(u[0], v[0]) - 1e-9:
                t = (xc - u[0])/(v[0] - u[0])
                m = (xc, u[1] + t*(v[1]-u[1]))
                pieces.append((u, m)); cur = (m, v)
        pieces.append(cur)
        for u, v in pieces:
            xm = (u[0] + v[0])/2.0
            if abs(xm) < wn:
                continue        # the under-stem piece is OMITTED (Eben
                                # 2026-09-02): it closed off the neck of
                                # the bottle -- the bulb opens into the stem
            L.append((u, v, 'a'))
    L += [(dn[i], dn[i+1], 'b') for i in range(len(dn)-1)]
    L += [((-a, cy - a*A3), (-a, cy + a*A3), 'b'),
          (( a, cy - a*A3), ( a, cy + a*A3), 'b')]
    # The stem is WIDE (Eben, 2026-08-31): the neck drawn at its true
    # half-width, two sides rooted ON the arc (interpolated along the
    # polygon, so the joins audit holds at both tiers) and an armed top
    # edge -- the topmost line across the neck's width.  No free ends
    # remain anywhere in the object set.
    def arc_y(x):
        for (x0, y0), (x1, y1) in zip(up, up[1:]):
            if min(x0, x1) - 1e-9 <= x <= max(x0, x1) + 1e-9 and abs(x1-x0) > 1e-12:
                return y0 + (y1-y0)*(x-x0)/(x1-x0)
        raise ValueError('stem foot off the arc')
    L += [((-wn, 0.0), (-wn, arc_y(-wn)), 'b'),
          (( wn, 0.0), ( wn, arc_y( wn)), 'b'),
          ((-wn, 0.0), ( wn, 0.0), 'a')]
    return L

def helmet_lines(o, ze, D, K2, lod):
    k = K2/D
    y = lambda z: (o['h'] - z)*k
    P = o['prof']
    w0 = P[0][0]
    xi, xo, nz = o['notch']
    b0, bn = y(P[0][1]), y(P[0][1] + nz)
    if lod == 0:
        # THE HOPLITE CUT (Eben 2026-09-02): BON2A0's outer feet taper --
        # the bottom corners are DIAGONALS (side comes down to z=3, then
        # cuts in to the foot at x=5.5) -- and the base gaps trace UP
        # into proper EYEHOLES: walls rising to z=4, closed with a
        # two-segment almond arch, open at the bottom edge like the
        # sprite's slits.
        dz, dxf = 3.0, 5.5                       # diagonal: (±8,3) -> (±5.5,0)
        # EYEHOLE PATH (Eben 2026-09-02): on the LHS go N, NW, E, S --
        # up the outer wall, FLARE up-and-out toward the temple, roof
        # straight across, down the nasal wall.  Mirrored on the right.
        wz, fz, fx = 3.5, 5.5, 5.2               # wall top / flare top / flare x
                                                 # (+1 sprite px 2026-09-02:
                                                 # the eyepieces sit further
                                                 # up the helmet)
        L = [((-xi*k, b0), (xi*k, b0), 'b')]     # nasal foot
        for sgn in (-1, 1):
            L += [((sgn*dxf*k, b0), (sgn*xo*k, b0), 'b'),      # outer foot
                  ((sgn*w0*k, y(dz)), (sgn*dxf*k, b0), 'b'),   # DIAGONAL corner
                  ((sgn*xo*k, b0), (sgn*xo*k, y(wz)), 'b'),    # N: outer wall
                  ((sgn*xo*k, y(wz)), (sgn*fx*k, y(fz)), 'b'), # NW: temple flare
                  ((sgn*fx*k, y(fz)), (sgn*xi*k, y(fz)), 'b'), # E: roof
                  ((sgn*xi*k, y(fz)), (sgn*xi*k, b0), 'b')]    # S: nasal wall
        for sgn in (-1, 1):
            L += [((sgn*w0*k, y(dz)), (sgn*P[1][0]*k, y(P[1][1])), 'b')]  # side
            for i in range(1, len(P)-1):
                (x0, z0), (x1, z1) = P[i], P[i+1]
                L.append(((sgn*x0*k, y(z0)), (sgn*x1*k, y(z1)), 'a'))     # dome
    else:
        # L1 (Eben 2026-09-02): no base indentations -- one straight
        # bottom -- and the top in THREE lines, not five: each dome side
        # collapses to a single diagonal, plus the flat top.
        L = [((-w0*k, b0), (w0*k, b0), 'b')]         # bottom
        for sgn in (-1, 1):
            L += [((sgn*w0*k, b0), (sgn*w0*k, y(P[1][1])), 'b'),       # side
                  ((sgn*w0*k, y(P[1][1])), (sgn*P[-1][0]*k, y(P[-1][1])), 'a')]
                                                     # dome diagonal: ARMED
    xt, zt = P[-1]
    L.append(((-xt*k, y(zt)), (xt*k, y(zt)), 'a'))                   # top
    return L

_KINDF = dict(box=box_lines, vest=vest_lines,
              potion=potion_lines, helmet=helmet_lines)

def prism_lines(name, D, lod, ze=EYE, K_=None):
    o = POBJ[name]
    K2 = K_ if K_ is not None else K
    L = _KINDF[o['kind']](o, ze, D, K2, lod)
    if 'd' in o:
        return L, Prism(o['h'], o['d'], ze, D, K2, xpersp=(o['kind'] == 'box'))
    return L, _Flat(o['h'], D, K2)

def prism_check(name, D, lod):
    """extent + free-end audit, mirroring objects.check()."""
    L, p = prism_lines(name, D, lod)
    pts = [q for l in L for q in l[:2]]
    ys = [q[1] for q in pts]
    ext, want = max(ys)-min(ys), p.H
    near = lambda u, v: abs(u[0]-v[0]) < 1e-9 and abs(u[1]-v[1]) < 1e-9
    free = []
    for i, pt in enumerate(pts):
        if any(near(pt, o2) for j, o2 in enumerate(pts) if j != i): continue
        on = False
        for (ax2, ay), (bx, by), _ in L:
            dx, dy = bx-ax2, by-ay; Ln = math.hypot(dx, dy)
            if Ln < 1e-12: continue
            t = ((pt[0]-ax2)*dx + (pt[1]-ay)*dy)/(Ln*Ln)
            if abs((pt[0]-ax2)*dy - (pt[1]-ay)*dx)/Ln < 1e-9 and 1e-9 < t < 1-1e-9:
                on = True; break
        if not on: free.append(pt)
    return L, ext, want, free

def tables_prism(name, lod, D=None):
    """same dict shape as tables(): ladder-indexed lines for the page,
    at the object's DESIGN viewpoint when it declares one."""
    o0 = POBJ[name]
    ze, D = o0.get('view', (EYE, D or 256.0))
    L, p = prism_lines(name, D, lod, ze=ze, K_=D)
    o = POBJ[name]
    wmax = o.get('w') or o.get('r') or \
           (max(x for x, _ in o['prof']) if 'prof' in o else o['arm'][0])
    amax = wmax*K/D
    XV = sorted({round(q[0], 6) for l in L for q in l[:2]})
    YV = sorted({round(q[1], 6) for l in L for q in l[:2]})
    xi = {v: i for i, v in enumerate(XV)}; yi = {v: i for i, v in enumerate(YV)}
    rows = [(xi[round(a2[0],6)], yi[round(a2[1],6)],
             xi[round(b2[0],6)], yi[round(b2[1],6)], t == 'a') for a2, b2, t in L]
    return dict(XL=[(i, f'{v/amax:+.4f}·a') for i, v in enumerate(XV)],
                YL=[(i, f'{v/p.H:.4f}·H') for i, v in enumerate(YV)],
                lines=rows, nline=len(L), q=None, flat=[])
