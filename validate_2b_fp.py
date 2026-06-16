"""Option 2b, fixed-point precision check (the last gap before 6502).

Mirrors the 6502 arithmetic for the angle-space seg depth/Y:
  worldangle = point_to_angle(dx,dy)         [4096-fine, the angle module]
  phi  = clamp(va_fine - worldangle, +/-ANG45)    (view-rel, clamped to FOV)
  depth = (c * COS[phi]) / COS[va_fine-phi-na]     8-bit cos tables, int divide
  yt    = HALF_H - ((h-vz)*FOCAL)//depth
c (signed perp distance) and na (seg normal, static) are per-seg constants.

Reports vs true float geometry, incl. clamped/behind columns.
"""
import os, math
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw, angle_bbox as A, fp
FINE=A.FINEANGLES; MASK=A.ANGMASK; ANG45=A.ANG45
FOCAL=128; HALF_W=128; HALF_H=80; VZ=10
RFB=getattr(fp,'RECIP_FRAC_BITS',0)
COS=[round(256*math.cos(f/FINE*2*math.pi)) for f in range(FINE)]   # 8-bit cos table
def rdiv(num,den):       # rounded integer divide (den>0)
    return (num + (den//2 if num>=0 else -(den//2)))//den

def s(a):  # fine angle -> signed [-FINE/2, FINE/2)
    a&=MASK
    return a-FINE if a>=FINE//2 else a

def true_depth(xc, v1, v2, px, py, va):
    phi=math.atan((xc-HALF_W)/FOCAL); wa=va-phi
    ux,uy=math.cos(wa),math.sin(wa); ex,ey=v2[0]-v1[0],v2[1]-v1[1]
    den=ux*(-ey)-uy*(-ex)
    if den==0: return None
    r=((v1[0]-px)*(-ey)-(v1[1]-py)*(-ex))/den
    if r<=0: return None
    wx,wy=px+r*ux,py+r*uy
    d=(wx-px)*math.cos(va)+(wy-py)*math.sin(va)
    return d if d>0 else None

def main():
    views=[(1056,-3616,a) for a in range(0,256,8)]+[(1024,-3500,65),(800,-3400,96),(1500,-3700,1),(1200,-3000,129)]
    n=eT=w1=w2=0; ncl=clok=0
    npy=epy=pyw1=0          # project_y (current) vs true, on unclamped
    for (px,py,ab) in views:
        pxi=int((px-dw.MAP_CENTER_X)/dw.PRESCALE); pyi=int((py-dw.MAP_CENTER_Y)/dw.PRESCALE)
        va=ab/256*2*math.pi; ca,sa=math.cos(va),math.sin(va); va_fine=(ab*16)&MASK
        for svwh in dw.fp_segs_vwh:
            sg=svwh[0]; v1=dw.fp_vertexes[sg[0]]; v2=dw.fp_vertexes[sg[1]]
            ch=svwh[4]; hd=ch-VZ
            ex,ey=v2[0]-v1[0],v2[1]-v1[1]; L=math.hypot(ex,ey)
            if L==0: continue
            nx,ny=-ey/L,ex/L
            CF=16                                              # 4 frac bits on c
            c=round(CF*((v1[0]-pxi)*nx+(v1[1]-pyi)*ny))        # per-seg const (s16.4)
            na=round(math.atan2(ny,nx)/(2*math.pi)*FINE)&MASK  # per-seg const (fine)
            for v in (v1,v2):
                dx,dy=v[0]-pxi,v[1]-pyi
                vy=dx*ca+dy*sa; vx=dx*sa-dy*ca
                col=HALF_W+FOCAL*vx/vy if vy>0 else None
                onscreen=col is not None and 0<=col<=255
                xc=(min(255,max(0,col)) if col is not None else (0 if vx<0 else 255))
                # --- fixed-point depth ---
                wa_fine=A.point_to_angle(dx,dy)
                phi=s(va_fine-wa_fine)
                phi=max(-ANG45,min(ANG45,phi))                  # clamp to FOV
                cph=COS[phi&MASK]
                cden=COS[(va_fine-phi-na)&MASK]
                num=c*cph; den=cden
                if den<0: num,den=-num,-den              # depth>0: c,cden share sign
                if den==0: continue
                depth=rdiv(num,den)            # = CF * true_depth
                if depth<=0: continue
                ys=HALF_H-rdiv(hd*FOCAL*CF,depth)
                td=true_depth(xc,v1,v2,pxi,pyi,va)
                if td is None: continue
                yt=HALF_H-(hd*FOCAL/td)
                n+=1; e=abs(ys-yt); eT+=e; w1+=(e<=1); w2+=(e<=2)
                if not onscreen: ncl+=1; clok+=(e<=2)
                # current path: project_y from the rotated integer depth vy
                if onscreen and vy>=1:
                    rxh,rxl=fp.fp_recip((round(vy)<<RFB) if RFB else round(vy))
                    pyy=fp.fp_project_y(hd,rxh,rxl)
                    npy+=1; ep=abs(pyy-yt); epy+=ep; pyw1+=(ep<=1)
    print(f"FIXED-POINT 2b Y vs true: {n} samples, mean {eT/n:.2f}px, within1 {100*w1/n:.1f}%, within2 {100*w2/n:.1f}%")
    print(f"  clamped/off-screen ({ncl}): within2 {100*clok/max(1,ncl):.1f}%")
    print(f"current project_y vs true (unclamped, the BAR): {npy} samples, mean {epy/max(1,npy):.2f}px, within1 {100*pyw1/max(1,npy):.1f}%")

if __name__=='__main__': main()
