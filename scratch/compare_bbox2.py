import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp, angle_bbox as A
from fp import PRESCALE,MAP_CENTER_X as MCX,MAP_CENTER_Y as MCY
def ang_br(node,side,ctx,ab):
    base=4+side*4; rt,rb,rl,rr=node[base],node[base+1],node[base+2],node[base+3]
    top=(rt-MCY)//PRESCALE; bot=(rb-MCY)//PRESCALE; left=(rl-MCX)//PRESCALE; right=(rr-MCX)//PRESCALE
    return A.bbox_check_angle(top,bot,left,right,ctx[0],ctx[1],ab)
def real_diff(t,a):
    # tolerate +/-1 column aliasing; None must match None
    if (t is None) != (a is None): return True
    if t is None: return False
    return abs(t[0]-a[0])>1 or abs(t[1]-a[1])>1
def sweep(label):
    bad=0; total=0; samples=[]
    for px in range(900,1300,50):
        for py in range(-3800,-3300,50):
            for ab in range(0,256,8):
                px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
                ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab))
                for nid in range(len(dw.nodes)):
                    node=dw.nodes[nid]
                    for side in (0,1):
                        truth=dw.fp_bbox_visible_fixed(node,side,ctx)
                        ang=ang_br(node,side,ctx,ab); total+=1
                        if real_diff(truth,ang):
                            bad+=1
                            if len(samples)<8: samples.append((px,py,ab,nid,side,truth,ang))
    print(f"{label}: {bad} REAL divergences / {total}")
    for s in samples: print("   ",s)
A._STRADDLE_FULL=False; sweep("UNGUARDED")
A._STRADDLE_FULL=True;  sweep("GUARDED(XOR)")
