"""Extruded-profile billboards: the pickup boxes and the armour vest.

A prism is a closed profile polygon (x, z), symmetric about x = 0, extruded
to half-depth d.  Under the SAME linearized perspective as the cylinder
stacks, a profile point at height z projects twice:

    front copy   y = R(z) + b(z)
    rear  copy   y = R(z) - b(z)        b(z) = K*d*|z - ze| / D^2

-- the box's top face opens by exactly the law that opens a rim ellipse.
Every object here sits wholly below the eye, so the REAR top envelope is
the topmost boundary at every x: that is the armed run.  Sides merge with
the top face's side stubs (both sit at the same |x| in this model), which
is the box equivalent of the lamp's pulled-in hexagon killing its stubs.

The medikit and stimpack carry a flat painted cross on the front face --
the only non-silhouette lines in any object so far.  A decal's four ends
are legitimately free: they are paint, not geometry, and they join nothing
for the same reason the shaft/stem termini are allowed to run into a face.
"""
import math

class Prism:
    def __init__(self, h, d, ze, D, K):
        self.h, self.d, self.ze, self.D, self.K = h, d, ze, D, K
        self.H = K*h/D
        self.bt, self.bb = self.b(h), self.b(0.0)
        self.k = (self.H - self.bt - self.bb)/h
    def a(self, x):    return self.K*x/self.D
    def b(self, z):    return self.K*self.d*abs(z-self.ze)/(self.D*self.D)
    def R(self, z):    return self.bt + (self.h - z)*self.k
    def F(self, x, z): return (self.a(x), self.R(z) + self.b(z))
    def B(self, x, z): return (self.a(x), self.R(z) - self.b(z))

# ---- the objects ---------------------------------------------------------
# Boxes: (w, d, h) half-width/half-depth/height, one px per world unit off
# the sprite.  Depths are the physically reasonable case footprints -- the
# sprites are drawn from a much steeper viewpoint than the engine's, so the
# apparent top-face depth is theirs, not ours (physical-not-sprite-fit).
POBJ = {
 'stim':    dict(lump='STIMA0', thing=2011, n=1, kind='box',
                 h=15.0, w=7.0, d=5.0, cross=(3.5, 3.5)),
 'medikit': dict(lump='MEDIA0', thing=2012, n=3, kind='box',
                 h=19.0, w=14.0, d=7.0, cross=(5.5, 5.5)),
 # The vest: an extruded shell, half-depth 3.5.  Profile off ARM1A0's
 # silhouette EXCEPT the neck scoop, deepened to 4 units: the sprite's
 # alpha only dips one pixel there (the neckline lives in its shading),
 # and a one-unit scoop is not a physically reasonable vest.  Same rule
 # as the barrel lid: the sprite is designer intent, the object is real.
 'armour':  dict(lump='ARM1A0', thing=2018, n=2, kind='vest',
                 h=17.0, d=3.5, waist=5.5, pit=(10.5, 10.0), arm=(15.5, 12.0),
                 side_top=16.0, sh_out=13.5, sh_in=3.0, scoop_z=13.0),
}

def box_lines(o, ze, D, K, lod):
    p = Prism(o['h'], o['d'], ze, D, K)
    w, h = o['w'], o['h']
    L = [(p.B(-w, h), p.B(w, h), 'a'),          # rear top edge -- ARMED
         (p.F(-w, h), p.F(w, h), 'r'),          # front top edge (interior)
         (p.B(-w, h), p.F(-w, 0), 'b'),         # sides: rear-top down to
         (p.B( w, h), p.F( w, 0), 'b'),         #        front-bottom
         (p.F(-w, 0), p.F(w, 0), 'b')]          # bottom
    if lod == 0 and o.get('cross'):
        cw, ch = o['cross']
        zc = h/2.0                              # centred on the front face
        L += [(p.F(-cw, zc), p.F(cw, zc), 'b'),
              (p.F(0, zc-ch), p.F(0, zc+ch), 'b')]
    return L

def vest_lines(o, ze, D, K, lod):
    p = Prism(o['h'], o['d'], ze, D, K)
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

def prism_lines(name, D, lod, ze=EYE, K_=None):
    o = POBJ[name]
    K2 = K_ if K_ is not None else K
    f = box_lines if o['kind'] == 'box' else vest_lines
    return f(o, ze, D, K2, lod), Prism(o['h'], o['d'], ze, D, K2)

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
    amax = p.a(o['w'] if o['kind'] == 'box' else o['arm'][0])
    XV = sorted({round(q[0], 6) for l in L for q in l[:2]})
    YV = sorted({round(q[1], 6) for l in L for q in l[:2]})
    xi = {v: i for i, v in enumerate(XV)}; yi = {v: i for i, v in enumerate(YV)}
    rows = [(xi[round(a2[0],6)], yi[round(a2[1],6)],
             xi[round(b2[0],6)], yi[round(b2[1],6)], t == 'a') for a2, b2, t in L]
    return dict(XL=[(i, f'{v/amax:+.4f}·a') for i, v in enumerate(XV)],
                YL=[(i, f'{v/p.H:.4f}·H') for i, v in enumerate(YV)],
                lines=rows, nline=len(L), q=None, flat=[])
