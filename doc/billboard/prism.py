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

The medikit and stimpack carry a flat painted cross on the front face.
A decal's four ends are legitimately free: they are paint, not geometry,
for the same reason the potion's stem terminus is allowed to end in air.

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
        self.bt, self.bb = self.b(h), self.b(0.0)
        self.k = (self.H - self.bt - self.bb)/h
    def a(self, x):    return self.K*x/self.D
    def b(self, z):    return self.K*self.d*abs(z-self.ze)/(self.D*self.D)
    def R(self, z):    return self.bt + (self.h - z)*self.k
    def F(self, x, z): return (self.a(x), self.R(z) + self.b(z))
    def B(self, x, z): return (self.a(x)*self.xr, self.R(z) - self.b(z))

class _Flat:
    """H-carrier for the icon objects (no depth model)."""
    def __init__(self, h, D, K2): self.H = K2*h/D

# ---- the objects ---------------------------------------------------------
POBJ = {
 'stim':    dict(lump='STIMA0', thing=2011, n=1, kind='box',
                 h=15.0, w=7.0, d=5.0, cross=(3.5, 3.5)),
 'medikit': dict(lump='MEDIA0', thing=2012, n=3, kind='box',
                 h=19.0, w=14.0, d=7.0, cross=(5.5, 5.5)),
 'potion':  dict(lump='BON1A0', thing=2014, n=13, kind='potion',
                 h=18.0, r=7.0),
 'helmet':  dict(lump='BON2A0', thing=2015, n=25, kind='helmet',
                 h=15.0, prof=[(8.0, 0.0), (8.0, 10.0), (6.0, 13.0), (3.0, 15.0)]),
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
    L = [(p.B(-w, h), p.B(w, h), 'a'),          # rear top edge -- ARMED
         (p.F(-w, h), p.B(-w, h), 'a'),         # top-face diagonals: the
         (p.F( w, h), p.B( w, h), 'a'),         #   topmost line outboard of
                                                #   the rear edge, so ARMED
         (p.F(-w, h), p.F(w, h), 'r'),          # front top edge (interior)
         (p.F(-w, h), p.F(-w, 0), 'b'),         # front face sides
         (p.F( w, h), p.F( w, 0), 'b'),
         (p.F(-w, 0), p.F(w, 0), 'b')]          # bottom
    if lod == 0 and o.get('cross'):
        cw, ch = o['cross']
        zc = h/2.0                              # centred on the front face
        L += [(p.F(-cw, zc), p.F(cw, zc), 'b'),
              (p.F(0, zc-ch), p.F(0, zc+ch), 'b')]
    return L

def vest_lines(o, ze, D, K2, lod):
    p = Prism(o['h'], o['d'], ze, D, K2)
    h, wa = o['h'], o['waist']
    (px_, pz), (ax_, az) = o['pit'], o['arm']
    st, so, si, sz = o['side_top'], o['sh_out'], o['sh_in'], o['scoop_z']
    L = [(p.F(-wa, 0), p.F(wa, 0), 'b')]                     # bottom
    if lod == 0:
        for s in (-1, 1):
            L += [(p.F(s*wa, 0),  p.F(s*px_, pz), 'b'),      # waist slant
                  (p.F(s*px_, pz), p.F(s*ax_, az), 'b'),     # armpit flare
                  (p.B(s*ax_, st), p.F(s*ax_, az), 'b'),     # side, extended
                                                             # up to the REAR
                  (p.F(s*ax_, st), p.F(s*so, h), 'b'),       # corner slant
                  (p.B(s*ax_, st), p.B(s*so, h), 'a'),       #   rear: ARMED
                  (p.F(s*so, h),  p.F(s*si, h), 'b'),        # shoulder top
                  (p.B(s*so, h),  p.B(s*si, h), 'a'),        #   rear: ARMED
                  (p.F(s*si, h),  p.F(s*si, sz), 'b'),       # scoop side
                  (p.B(s*si, h),  p.B(s*si, sz), 'b')]       #   rear stub
    else:
        for s in (-1, 1):
            L += [(p.F(s*wa, 0),  p.F(s*ax_, az), 'b'),      # waist, straight
                  (p.B(s*ax_, h), p.F(s*ax_, az), 'b'),      # side to rear top
                  (p.F(s*ax_, h), p.F(s*si, h), 'b'),        # shoulder top
                  (p.B(s*ax_, h), p.B(s*si, h), 'a'),        #   rear: ARMED
                  (p.F(s*si, h),  p.F(s*si, sz), 'b'),       # scoop side
                  (p.B(s*si, h),  p.B(s*si, sz), 'b')]       #   rear stub
    L += [(p.F(-si, sz), p.F(si, sz), 'b'),                  # scoop bottom
          (p.B(-si, sz), p.B(si, sz), 'a')]                  #   rear: ARMED
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
    L  = [(up[i], up[i+1], 'a') for i in range(len(up)-1)]
    L += [(dn[i], dn[i+1], 'b') for i in range(len(dn)-1)]
    L += [((-a, cy - a*A3), (-a, cy + a*A3), 'b'),
          (( a, cy - a*A3), ( a, cy + a*A3), 'b'),
          ((0.0, cy - reach), (0.0, 0.0), 'a')]  # the stem: topmost at x=0,
                                                 # its terminus the one
                                                 # allowed free end
    return L

def helmet_lines(o, ze, D, K2, lod):
    k = K2/D
    y = lambda z: (o['h'] - z)*k
    P = o['prof']
    L = [((-P[0][0]*k, y(P[0][1])), (P[0][0]*k, y(P[0][1])), 'b')]   # base
    for s in (-1, 1):
        for i in range(len(P)-1):
            (x0, z0), (x1, z1) = P[i], P[i+1]
            L.append(((s*x0*k, y(z0)), (s*x1*k, y(z1)),
                      'b' if i == 0 else 'a'))   # sides plain, dome ARMED
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

def tables_prism(name, lod, D=256.0):
    """same dict shape as tables(): ladder-indexed lines for the page."""
    L, p = prism_lines(name, D, lod)
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
