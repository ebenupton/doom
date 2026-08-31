"""LOD tiers, defined as reductions of the SAME dodecagon ladder.
import os; _D=os.path.dirname(os.path.abspath(__file__))+'/'

L0  5-segment arcs, vertices at ±a, ±a₂, ±a₃      3 |x| per cylinder
L1  3-segment arcs, the ±a₃ pair dropped          2 |x| per cylinder
L2  the staircase: every rim one flat segment     1 |x| per cylinder

The error each tier introduces is the arc depth it throws away:
  L1 loses (1 − a₂)·b = 0.268 b   (the innermost dip)
  L2 loses b                      (the whole arc)
so the switch points are where those fall below half a pixel.
"""
import math
exec(open(_D+'objects.py').read())
A3_=2-math.sqrt(3)

# L1's inner vertex ratio, PER OBJECT.  The dodecagon's a2 = 0.7321 is the
# default and nothing else may move -- pulling it IN (x and y together, so
# the hexagon stays symmetric) lets an occluding neighbour's radius land on
# or outside the vertex, turning a partial clip of the middle segment into
# a clean drop.
Q1 = [math.sqrt(3)-1]
# FLAT RIMS are decided ONCE, at the tier's switch size, and then hold at
# every distance -- the art is a static template, so the line count cannot
# be allowed to drift with D.  A rim qualifies when its ellipse is under
# half a pixel deep at the size where the tier comes in; below that it only
# gets flatter, so the decision never needs revisiting.
FLATR = set()
def flat_key(r,z): return (round(r,4), round(z,4))
def arc_pts_lod(cy,a,b,upper,lod,key=None):
    s=-1 if upper else 1
    if lod==1:
        if key is not None and key in FLATR:
            # sub-pixel ellipse: the arc IS a line, and drawing it as three
            # segments only costs two more clipped lines for nothing.
            return [(-a, cy), (a, cy)]
        q=Q1[0]
        return [(-a, cy+s*b*A3_), (-q*a, cy+s*b*q),
                ( q*a, cy+s*b*q), ( a, cy+s*b*A3_)]
    return [(XF[i]*a, cy+s*b*YF[i]) for i in [0,1,2,3,4,5]]


def build_lod(st, lod):
    if lod==2: return staircase(st)
    import types
    L=[]
    for i,(r,z0,z1) in enumerate(st.bands):
        a=st.a(r); Rt,bt=st.R(z1),st.b(r,z1); Rb,bb=st.R(z0),st.b(r,z0)
        at,ab = z1>st.ze, z0>st.ze
        r_up=max([b_[0] for b_ in st.bands if abs(b_[1]-z1)<1e-9] or [0.0])
        r_dn=max([b_[0] for b_ in st.bands if abs(b_[2]-z0)<1e-9] or [0.0])
        r_over=max([b_[0] for b_ in st.bands if b_[1]>=z1-1e-9] or [0.0])
        ct=st.a(min(r_up,r)) if r_up<r else 0.0
        cb=st.a(min(r_dn,r)) if r_dn<r else 0.0
        if r_up<r-1e-9:
            arm_cut = max(ct, st.a(r_over)) if r_over>0 else ct
            armed = arm_cut < a-1e-9
            if at:
                L+=[(p,q,'a' if armed else 'b')
                    for p,q in cut(arc_pts_lod(Rt,a,bt,True,lod,flat_key(r,z1)), arm_cut if armed else 0.0)]
                if armed and arm_cut>0:
                    L+=[(p,q,'b') for p,q in cut(arc_pts_lod(Rt,a,bt,True,lod,flat_key(r,z1)),0.0)
                        if abs(p[0])<=arm_cut+1e-9 and abs(q[0])<=arm_cut+1e-9]
            else:
                L+=[(p,q,'a' if armed else 'b')
                    for p,q in cut(arc_pts_lod(Rt,a,bt,True,lod,flat_key(r,z1)), max(ct,arm_cut) if armed else ct)]
                L+=[(p,q,'b') for p,q in cut(arc_pts_lod(Rt,a,bt,False,lod,flat_key(r,z1)),0.0)]
        if r_dn<r-1e-9:
            if ab:
                L+=[(p,q,'r') for p,q in cut(arc_pts_lod(Rb,a,bb,True,lod,flat_key(r,z0)),0.0)]
                L+=[(p,q,'b') for p,q in cut(arc_pts_lod(Rb,a,bb,False,lod,flat_key(r,z0)),cb)]
            else: L+=[(p,q,'b') for p,q in cut(arc_pts_lod(Rb,a,bb,False,lod,flat_key(r,z0)),0.0)]
        # a FLAT rim has no vertical edge pair, so the side meets it at the
        # rim line itself, not b*a3 beyond it
        ft = flat_key(r,z1) in FLATR
        fb = flat_key(r,z0) in FLATR
        yt = Rt if (ft or r_up>=r-1e-9) else (Rt-bt*A3_)
        yb = Rb if (fb or r_dn>=r-1e-9) else (Rb+bb*A3_)
        L+=[((-a,yt),(-a,yb),'b'), ((a,yt),(a,yb),'b')]
    return L

def staircase(st):
    """L2: every rim collapses to a flat segment, so the object is its own
    stepped silhouette -- sides, steps, and one line at each end."""
    L=[]; B=st.bands
    for i,(r,z0,z1) in enumerate(B):
        a=st.a(r)
        yt,yb = st.R(z1), st.R(z0)
        L+=[((-a,yt),(-a,yb),'b'), ((a,yt),(a,yb),'b')]
    for i,(r,z0,z1) in enumerate(B):
        r_up=max([b_[0] for b_ in B if abs(b_[1]-z1)<1e-9] or [0.0])
        if r_up < r-1e-9:                       # step in (or the very top)
            a,au = st.a(r), st.a(r_up)
            y=st.R(z1)
            if au>0: L+=[((-a,y),(-au,y),'b'), ((au,y),(a,y),'b')]
            else:    L+=[((-a,y),(a,y),'b')]
    for i,(r,z0,z1) in enumerate(B):
        r_dn=max([b_[0] for b_ in B if abs(b_[2]-z0)<1e-9] or [0.0])
        if r_dn < r-1e-9:
            a,ad = st.a(r), st.a(r_dn)
            y=st.R(z0)
            if ad>0: L+=[((-a,y),(-ad,y),'b'), ((ad,y),(a,y),'b')]
            else:    L+=[((-a,y),(a,y),'b')]
    return L

def set_flat(name, D_ref, ze=EYE, tol=0.5):
    """Choose the flat rims once, at the tier's switch size."""
    FLATR.clear()
    o=OBJ[name]; st=Stack(o['bands'],o['h'],ze,D_ref,K,1)
    for r,z0,z1 in o['bands']:
        for z in (z0,z1):
            if st.b(r,z) < tol: FLATR.add(flat_key(r,z))
    return set(FLATR)

# PER-OBJECT L1 configuration.  Only the lamp deviates: its hexagon is
# pulled in so the base's occlusion cut lands on the vertex, and its column
# top rim -- 0.15 px deep at the switch size and flatter beyond -- is one
# line.  The pillar and barrel keep the dodecagon's a2 and no flat rims.
L1CFG = {'lamp': dict(q=0.65, flat_ref=196.0)}
def cfg(name):
    c = L1CFG.get(name)
    Q1[0] = c['q'] if c else math.sqrt(3)-1
    FLATR.clear()
    if c: set_flat(name, c['flat_ref'])

def lod_lines(name,D,lod,ze=EYE):
    cfg(name)
    o=OBJ[name]; st=Stack(o['bands'],o['h'],ze,D,K,lod)
    return build_lod(st,lod), st

def bmax(name,H):
    """the deepest rim ellipse at projected height H"""
    o=OBJ[name]; h=o['h']; best=0.0
    for r,z0,z1 in o['bands']:
        for z in (z0,z1):
            best=max(best, r*abs(z-EYE)*H*H/(K*h*h))
    return best

def threshold(name, loss, tol=0.5):
    o=OBJ[name]; h=o['h']; worst=max(r*abs(z-EYE) for r,z0,z1 in o['bands'] for z in (z0,z1))
    return math.sqrt(tol*K*h*h/(worst*loss))

print(f'{"object":10s} {"tier":5s} {"lines":>5s} {"|x|":>4s} {"slots":>5s}   '
      f'switch below H =   (distance)')
for name in ('pillar','barrel','lamp'):
    for lod,loss,lbl in ((0,None,'L0'),(1,1-(math.sqrt(3)-1),'L1'),(2,1.0,'L2')):
        L,st=lod_lines(name,256.0,lod)
        mags=len({round(abs(p[0]),4) for l in L for p in l[:2]})
        if loss is None: sw='—'
        else:
            H=threshold(name,loss); D=K*OBJ[name]['h']/H
            sw=f'{H:6.1f} px      {D:6.0f} u'
        print(f'{name:10s} {lbl:5s} {len(L):5d} {mags:4d} {2*mags:5d}   {sw}')
    print()
