import math
import os; _D=os.path.dirname(os.path.abspath(__file__))+'/'
exec(open(_D+'stack.py').read())
K, EYE = 152.0, 41.0
A2_ = math.sqrt(3)-1
# bands read off each sprite's flat runs: (r, z0, z1), bottom-to-top
OBJ = {
 'pillar':  dict(lump='ELECA0', h=128.0, thing=48, n=2, bands=[
     (19.0, 0.0, 4.90), (A2_*19.0, 4.90, 122.83), (19.0, 122.83, 128.0)]),
 'barrel':  dict(lump='BAR1A0', h=32.0,  thing=2035, n=6, bands=[
     (11.5, 0.0, 32.0)]),
 'lamp':    dict(lump='COLUA0', h=48.0,  thing=2028, n=8, bands=[
     (11.5, 0.0, 5.0), (7.5, 5.0, 14.0), (5.5, 14.0, 48.0)]),
 'candelabra': dict(lump='CBRAA0', h=61.0, thing=35, n=2, bands=[
     (11.0, 0.0, 10.0), (2.5, 10.0, 41.0), (13.5, 41.0, 58.0), (2.5, 58.0, 61.0)]),
}
def lines(name, D, ze=EYE):
    o = OBJ[name]
    st = Stack(o['bands'], o['h'], ze, D, K)
    return build(st), st

def check(name, D):
    L, st = lines(name, D)
    pts=[]
    for p,q,_ in L: pts += [p,q]
    near=lambda u,v: abs(u[0]-v[0])<1e-9 and abs(u[1]-v[1])<1e-9
    free=[]
    for i,pt in enumerate(pts):
        if any(near(pt,o) for j,o in enumerate(pts) if j!=i): continue
        on=False
        for (ax,ay),(bx,by),_ in L:
            dx,dy=bx-ax,by-ay; Ln=math.hypot(dx,dy)
            if Ln<1e-12: continue
            t=((pt[0]-ax)*dx+(pt[1]-ay)*dy)/(Ln*Ln)
            if abs((pt[0]-ax)*dy-(pt[1]-ay)*dx)/Ln<1e-9 and 1e-9<t<1-1e-9: on=True;break
        if not on: free.append(pt)
    ys=[p[1] for p in pts]; e=max(ys)-min(ys); want=st.H
    xs=[abs(p[0]) for p in pts]
    mags=sorted({round(v,4) for v in xs})
    return L, st, len(L), e, want, free, mags

print(f'{"object":12s} {"D":>5s} {"lines":>5s} {"extent":>8s} {"want":>8s} '
      f'{"free":>4s}  distinct |x|')
for name in OBJ:
    for D in (128.0, 256.0):
        L,st,n,e,w,free,mags = check(name, D)
        print(f'{name:12s} {D:5.0f} {n:5d} {e:8.3f} {w:8.3f} {len(free):4d}  '
              f'{len(mags):2d}')

import sys
sys.path.insert(0,'/Users/ebenupton/doom/sil')
import extract as E
_d,_l = E.read_wad('/Users/ebenupton/doom/DOOM1.WAD'); _by={l[0]:l for l in _l}

def fit_b(vals, W, a, cx):
    S=[]
    for x,y in enumerate(vals):
        u=(x+0.5-cx)/a
        if abs(u)<=1.0: S.append((math.sqrt(1-u*u), float(y)))
    n=len(S); sx=sum(s for s,_ in S); sy=sum(y for _,y in S)
    sxx=sum(s*s for s,_ in S); sxy=sum(s*y for s,y in S)
    b=(n*sxy-sx*sy)/(n*sxx-sx*sx)
    return abs(b), math.sqrt(sum(((sy-b*sx)/n+b*s-y)**2 for s,y in S)/n)

def sprite_viewpoint(name):
    o=OBJ[name]; W,H,_,_,mask,_ = E.decode_picture(_d,_by[o['lump']])
    top=[];bot=[]
    for x in range(W):
        ys=[y for y in range(H) if mask[y][x]]
        top.append(ys[0] if ys else 0); bot.append((ys[-1]+1) if ys else 0)
    cx=(W-1)/2.0+0.5
    rt=max(r for r,z0,z1 in o['bands'] if z1>=o['h']-1e-9)
    rb=max(r for r,z0,z1 in o['bands'] if z0<=1e-9)
    bt,rt_res = fit_b(top,W,rt,cx)
    bb,rb_res = fit_b(bot,W,rb,cx)
    ratio_t, ratio_b = bt/rt, bb/rb
    ze = o['h']*ratio_b/(ratio_t+ratio_b); D = ze/ratio_b
    return ze, D, bt, bb, ratio_t, ratio_b, rt_res, rb_res

print()
print(f'{"object":12s} {"b_top":>6s} {"b_base":>7s} {"resid":>6s}  '
      f'{"eye z":>7s} {"of":>5s} {"D":>6s}  elevation to centre')
for name in OBJ:
    ze,D,bt,bb,rt,rb,r1,r2 = sprite_viewpoint(name)
    h=OBJ[name]['h']
    ang=math.degrees(math.atan((ze-h/2)/D))
    print(f'{name:12s} {bt:6.2f} {bb:7.2f} {max(r1,r2):6.2f}  '
          f'{ze:7.1f} {h:5.0f} {D:6.0f}  {ang:+6.1f}°')
