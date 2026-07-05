import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp, angle_bbox as A
from fp import fp_to_view, PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY, NEAR_FP
px,py,ab=1056,-3616,137
node=dw.nodes[100]; side=1
base=4+side*4; rt,rb,rl,rr=node[base],node[base+1],node[base+2],node[base+3]
top=(rt-MCY)//PRESCALE; bot=(rb-MCY)//PRESCALE; left=(rl-MCX)//PRESCALE; right=(rr-MCX)//PRESCALE
pxi=int((px-MCX)//PRESCALE); pyi=int((py-MCY)//PRESCALE)
px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab))
print(f"node 100 side 1 box (prescaled): top={top} bot={bot} left={left} right={right}  viewer=({pxi},{pyi})")
print(f"NEAR_FP={NEAR_FP}")
print("corner view-space (evx sideways, evy forward) and angle phi:")
for nm,(wx,wy) in [('TL',(left,top)),('TR',(right,top)),('BR',(right,bot)),('BL',(left,bot))]:
    _,evx,evy,_,_=fp_to_view(wx,wy,ctx)
    a_fine=(ab*(A.FINEANGLES//256))&A.ANGMASK
    phi=A._phi(wx,wy,pxi,pyi,a_fine)
    behind = "BEHIND EYE" if evy<0 else ("<NEAR" if evy<NEAR_FP else "in front")
    print(f"  {nm} world=({wx},{wy})  evx={evx:6d} evy={evy:6d} [{behind:10s}]  phi={phi:+5d} ({phi*90/A.ANG90:+6.1f} deg)")
r_angle=A.bbox_check_angle(top,bot,left,right,pxi,pyi,ab)
print(f"\nangle method result: {r_angle}   (None == REJECT/discard)")
