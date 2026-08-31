"""Emit each object's 3D bands and its 2D template as ladder indices."""
import math
exec(open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/armcheck.py').read())
A3v = 2-math.sqrt(3)

def tables(name, lod, D=256.0, ze=EYE):
    cfg(name)
    o=OBJ[name]; st=Stack(o['bands'],o['h'],ze,D,K,lod)
    L=build_lod(st,lod)
    rmax=max(r for r,_,_ in o['bands'])
    q = Q1[0]
    # --- candidate labelled x values -------------------------------------
    xs={}
    for r,z0,z1 in o['bands']:
        a=st.a(r); f=r/rmax
        xs[round(a,6)]=f'+a·{f:.4f}'; xs[round(-a,6)]=f'−a·{f:.4f}'
        for c,cn in ((q,'q'),(A3v,'a₃')) if lod==0 else ((q,'q'),):
            xs[round(c*a,6)]=f'+a·{f*c:.4f}'; xs[round(-c*a,6)]=f'−a·{f*c:.4f}'
    # occlusion cuts land on a neighbour's radius
    for r,z0,z1 in o['bands']:
        a=st.a(r)
        xs[round(a,6)]=xs.get(round(a,6),f'+a·{r/rmax:.4f}')
    # --- candidate labelled y values --------------------------------------
    ys={}
    for r,z0,z1 in o['bands']:
        for z,rn in ((z1,'top'),(z0,'bot')):
            cy=st.R(z); b=st.b(r,z)
            ys[round(cy,6)]=f'r{r:g}@{z:g}'
            for c,cn in ((A3v,'a₃'),(q,'q'),(1.0,'1')):
                ys[round(cy-b*c,6)]=f'r{r:g}@{z:g} − b·{cn}'
                ys[round(cy+b*c,6)]=f'r{r:g}@{z:g} + b·{cn}'
    def lx(v):
        return xs.get(round(v,6), f'{v/st.a(rmax):+.4f}·a')
    def ly(v):
        return ys.get(round(v,6), f'{v:.3f}px')
    XL=sorted({round(p[0],6) for l in L for p in l[:2]})
    YL=sorted({round(p[1],6) for l in L for p in l[:2]})
    xi={v:i for i,v in enumerate(XL)}; yi={v:i for i,v in enumerate(YL)}
    rows=[]
    for (ax,ay),(bx,by),t in L:
        rows.append((xi[round(ax,6)],yi[round(ay,6)],
                     xi[round(bx,6)],yi[round(by,6)], t=='a'))
    return dict(bands=o['bands'], h=o['h'], q=q,
                XL=[(i,lx(v)) for i,v in enumerate(XL)],
                YL=[(i,ly(v)) for i,v in enumerate(YL)],
                lines=rows, nline=len(L),
                flat=sorted(FLATR))
if __name__=='__main__':
    for n in ('pillar','barrel','lamp'):
        for lod in (0,1):
            t=tables(n,lod)
            print(f'\n=== {n} L{lod}: {t["nline"]} lines, {len(t["XL"])} x, {len(t["YL"])} y')
            if lod==0:
                print('  bands (r, z0, z1):', [(round(r,3),z0,z1) for r,z0,z1 in t['bands']])
            print('  X:', ', '.join(f'{i}:{s}' for i,s in t['XL']))
            print('  Y:', ' | '.join(f'{i}:{s}' for i,s in t['YL']))
