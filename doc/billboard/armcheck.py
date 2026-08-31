"""ASSERT the armed rule: at every x, the topmost line must be armed."""
import os; _D=os.path.dirname(os.path.abspath(__file__))+'/'
import math
exec(open(_D+'lod.py').read())
def topmost_ok(L, n=2000):
    xs=[p[0] for l in L for p in l[:2]]
    lo,hi=min(xs),max(xs); bad=[]
    for i in range(n+1):
        x=lo+(hi-lo)*i/n
        best=None
        for (ax,ay),(bx,by),t in L:
            if min(ax,bx)-1e-9<=x<=max(ax,bx)+1e-9:
                y = ay if abs(bx-ax)<1e-12 else ay+(by-ay)*(x-ax)/(bx-ax)
                if abs(bx-ax)<1e-12: y=min(ay,by)
                if best is None or y<best[0]-1e-9: best=(y,t)
                elif abs(y-best[0])<=1e-9 and t=='a': best=(y,'a')
        if best and best[1]!='a': bad.append((round(x,3),round(best[0],3),best[1]))
    return bad
print(f'{"object":10s} {"tier":4s} {"lines":>5s} {"armed":>5s}  topmost-is-armed')
ok=True
for n in ('pillar','barrel','lamp'):
    for lod in (0,1):
        for D in (128.,256.,512.):
            L,_=lod_lines(n,D,lod)
            bad=topmost_ok(L)
            if D==128.:
                na=sum(1 for l in L if l[2]=='a')
                print(f'{n:10s} L{lod:<3d} {len(L):5d} {na:5d}  '
                      f'{"OK" if not bad else "FAIL at x="+str(bad[:3])}')
            if bad: ok=False
print('\n  ARMED RULE HOLDS' if ok else '\n  ARMED RULE VIOLATED')
