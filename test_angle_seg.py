"""Self-test for angle_seg.seg_2b vs true geometry (the option-2b reference)."""
import os, math, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw, angle_seg as S
FOCAL=128;HW=128;HH=80;VZ=10
def true_col(dx,dy,va):
    vy=dx*math.cos(va)+dy*math.sin(va); vx=dx*math.sin(va)-dy*math.cos(va)
    return HW+FOCAL*vx/vy if vy>0 else None
def true_depth(xc,v1,v2,px,py,va):
    phi=math.atan((xc-HW)/FOCAL);wa=va-phi;ux,uy=math.cos(wa),math.sin(wa)
    ex,ey=v2[0]-v1[0],v2[1]-v1[1];den=ux*(-ey)-uy*(-ex)
    if den==0:return None
    r=((v1[0]-px)*(-ey)-(v1[1]-py)*(-ex))/den
    if r<=0:return None
    wx,wy=px+r*ux,py+r*uy;d=(wx-px)*math.cos(va)+(wy-py)*math.sin(va);return d if d>0 else None
nX=eX=x1=0; nY=eY=y2=0
for (px,py,ab) in [(1056,-3616,a) for a in range(0,256,8)]+[(1024,-3500,65),(800,-3400,96),(1500,-3700,1)]:
    pxi=int((px-dw.MAP_CENTER_X)/dw.PRESCALE);pyi=int((py-dw.MAP_CENTER_Y)/dw.PRESCALE)
    va=ab/256*2*math.pi
    for svwh in dw.fp_segs_vwh:
        sg=svwh[0];v1=dw.fp_vertexes[sg[0]];v2=dw.fp_vertexes[sg[1]];ch=svwh[4];fh=svwh[3]
        ldx,ldy=v2[0]-v1[0],v2[1]-v1[1]; na,L=S.seg_consts(ldx,ldy)
        r=S.seg_2b(v1[0],v1[1],v2[0],v2[1],ldx,ldy,pxi,pyi,ab,na,L)
        if r is None: continue
        for (v,(sx,depth)) in zip((v1,v2),r):
            ft=S.proj_y(ch,depth,VZ)
            dx,dy=v[0]-pxi,v[1]-pyi; tc=true_col(dx,dy,va)
            if tc is not None and 0<=tc<=255: nX+=1; e=abs(sx-tc); eX+=e; x1+=(e<=1)
            td=true_depth(sx,v1,v2,pxi,pyi,va)
            if td is not None: tyt=HH-(ch-VZ)*FOCAL/td; nY+=1; e=abs(ft-tyt); eY+=e; y2+=(e<=2)
okX = eX/nX < 0.6 and x1/nX > 0.98
# c = (cross<<4)/L (exact /len) -- accuracy-equivalent to rlen (depth err vs
# true 41.155 vs 41.152), chosen for 6502 cost (u24/u8 divide, no wide mul).
okY = eY/nY < 0.7 and y2/nY > 0.96   # 256-cos + /L: ~0.51px, 96.5% within 2px
print(f"X vs true: mean {eX/nX:.2f}col within1 {100*x1/nX:.1f}%  {'OK' if okX else 'FAIL'}")
print(f"Y vs true: mean {eY/nY:.2f}px within2 {100*y2/nY:.1f}%  {'OK' if okY else 'FAIL'}")
print("PASS" if okX and okY else "FAIL")
sys.exit(0 if okX and okY else 1)
