"""Generic billboard art: an object is a STACK OF COAXIAL CYLINDERS.

Every rim is a circle; under perspective it is an ellipse with b/a = |z-ze|/D.
A rim's visibility follows from its height relative to the eye, and a rim is
occluded over |x| < r of whichever neighbouring cylinder covers it.
"""
import math
A2, A3 = math.sqrt(3)-1, 2-math.sqrt(3)
XF = [-1.0, -A2, -A3, A3, A2, 1.0]
YF = [ A3,   A2,  1.0, 1.0, A2,  A3]

def arc_pts(cy, a, b, upper):
    s = -1 if upper else 1
    return [(XF[i]*a, cy + s*b*YF[i]) for i in range(6)]

def cut(pts, rcut):
    """Keep only the parts of an arc with |x| >= rcut; the rest is behind a
    narrower neighbour.

    CLIP BY |x| ON MONOTONE PIECES, do not test endpoints.  A 3-segment LOD
    arc's middle segment runs -a2 -> +a2, so BOTH its ends sit exactly ON
    the cut when the neighbour's radius is a2 -- an "are both ends outside?"
    test keeps it, and the pillar's LOD kept an un-trimmed back arc on each
    disc.  Splitting at x = 0 first makes |x| monotone on every piece, and
    then the whole thing is a 1-D interval clip.
    """
    segs = [(pts[i], pts[i+1]) for i in range(len(pts)-1)]
    if rcut <= 0: return segs
    eps = 1e-9*max(abs(x) for x,_ in pts)
    out = []
    for (p, q) in segs:
        pieces = [(p, q)]
        if p[0]*q[0] < 0:                      # straddles the axis
            t = -p[0]/(q[0]-p[0])
            m = (0.0, p[1] + t*(q[1]-p[1]))
            pieces = [(p, m), (m, q)]
        for (u, v) in pieces:
            hi, lo = (u, v) if abs(u[0]) >= abs(v[0]) else (v, u)
            if abs(lo[0]) >= rcut-eps:         # wholly visible
                out.append((u, v)); continue
            if abs(hi[0]) <= rcut+eps:         # wholly occluded
                continue
            t = (rcut - abs(lo[0]))/(abs(hi[0]) - abs(lo[0]))
            m = (lo[0] + t*(hi[0]-lo[0]), lo[1] + t*(hi[1]-lo[1]))
            if math.hypot(m[0]-hi[0], m[1]-hi[1]) > eps:
                out.append((hi, m))
    return out


class Stack:
    """bands: [(r, z0, z1)] bottom-to-top, contiguous, radii need not be
    monotone.  h = the object's world height."""
    # How deep each tier's extreme vertex actually goes, as a fraction of b:
    # L0 reaches the a3 vertex at 1.0 b, L1 only the a2 vertex at 0.732 b,
    # L2 is flat.  The rims must be inset by the TIER's depth or the object
    # stops filling its own projected height.
    # L1's depth is whatever its inner vertex ratio is -- pulling the
    # hexagon in changes how far the arc reaches, and the inset must
    # follow or the object stops filling its projected height.
    DEPTH = {0: 1.0, 1: A2, 2: 0.0}
    def __init__(self, bands, h, ze, D, K, lod=0):
        self.bands, self.h, self.ze, self.D, self.K = bands, h, ze, D, K
        self.lod = lod
        self.H = K*h/D
        rt = max(r for r,z0,z1 in bands if z1 >= h-1e-9)
        rb = max(r for r,z0,z1 in bands if z0 <= 1e-9)
        d = Stack.DEPTH[lod]
        if lod == 1: d = globals().get('Q1', [A2])[0]
        # A FLATTENED extreme rim has no arc to overhang with, so its inset
        # is zero -- otherwise the object stops filling its projected height.
        import builtins
        fl = globals().get('FLATR', set()) if lod == 1 else set()
        kf = globals().get('flat_key', lambda r,z:(r,z))
        dt = 0.0 if kf(rt,h)   in fl else d
        db = 0.0 if kf(rb,0.0) in fl else d
        self.bt, self.bb = self.b(rt, h)*dt, self.b(rb, 0.0)*db
        self.k = (self.H - self.bt - self.bb)/h
    def a(self, r):     return self.K*r/self.D
    def b(self, r, z):  return self.a(r)*abs(z-self.ze)/self.D
    def R(self, z):     return self.bt + (self.h - z)*self.k
    def rad_at(self, z, skip):
        """widest radius of any OTHER band spanning z"""
        w = 0.0
        for j,(r,z0,z1) in enumerate(self.bands):
            if j == skip: continue
            if z0-1e-9 <= z <= z1+1e-9: w = max(w, r)
        return w

def build(st):
    L = []
    for i,(r,z0,z1) in enumerate(st.bands):
        a = st.a(r)
        Rt, bt = st.R(z1), st.b(r,z1)
        Rb, bb = st.R(z0), st.b(r,z0)
        above_t, above_b = z1 > st.ze, z0 > st.ze
        # neighbours that cover each rim
        r_up   = max([rr for rr,zz0,zz1 in st.bands if abs(zz0-z1)<1e-9] or [0.0])
        r_dn   = max([rr for rr,zz0,zz1 in st.bands if abs(zz1-z0)<1e-9] or [0.0])
        cut_t  = st.a(min(r_up, r)) if r_up < r else 0.0
        cut_b  = st.a(min(r_dn, r)) if r_dn < r else 0.0
        # --- TOP RIM ---
        # ONLY THE FAR HALF IS OCCLUDED by a narrower neighbour: the near
        # half bulges toward the viewer and passes in front of it.  A rim
        # below the eye has its far half UPPERMOST; above the eye, lowermost.
        if r_up < r - 1e-9:                       # this rim is exposed
            if above_t:                            # top face hidden
                L += [(p,q,'b') for p,q in cut(arc_pts(Rt,a,bt,True), 0.0)]
            else:                                  # top face visible
                L += [(p,q,'b') for p,q in cut(arc_pts(Rt,a,bt,True), cut_t)]
                L += [(p,q,'r') for p,q in cut(arc_pts(Rt,a,bt,False), 0.0)]
        # --- BOTTOM RIM ---
        if r_dn < r - 1e-9:
            if above_b:                            # underside visible
                L += [(p,q,'r') for p,q in cut(arc_pts(Rb,a,bb,True), 0.0)]
                L += [(p,q,'b') for p,q in cut(arc_pts(Rb,a,bb,False), cut_b)]
            else:                                  # underside hidden
                L += [(p,q,'b') for p,q in cut(arc_pts(Rb,a,bb,False), 0.0)]
        # --- SIDES ---  from the top rim's upper vertex to the bottom rim's lower
        yt = Rt - bt*A3 if (r_up < r-1e-9) else Rt + bt*A3
        yb = Rb + bb*A3 if (r_dn < r-1e-9) else Rb - bb*A3
        # extend into a covering neighbour by half its face, as the pillar does
        if r_up >= r - 1e-9: yt = Rt
        if r_dn >= r - 1e-9: yb = Rb
        L += [((-a,yt),(-a,yb),'b'), ((a,yt),(a,yb),'b')]
    return L
