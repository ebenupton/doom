"""Snapshot the framebuffer AND the whole span list at every wall close, so a
slide can show the list evolving as real trapezia over the real frame."""
import os, sys, json
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(),'tools'))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
S = lambda n: sym(n, banked=1)
MS, OBJSLOT, WALK = S('span_mark_solid'), S('obj_draw_slot'), S('fw_walk_staged')
IL, IH = S('zp_i_l'), S('zp_i_h')
P = {n: S('POOL_'+n) for n in ('NEXT','XSTART','XEND','TXLO','TDEN','TL','TR','OT','IT','BXLO','BDEN','BL','BR','OB','IB')}
HEAD = S('zp_head')
RZ={n:S('RASTER_ZP_'+n) for n in ('X0','Y0','X1','Y1')}
r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc; mpu = sc.mpu; mem = mpu.memory
PLOTTED=[]
def spans():
    out=[]; s=mem[HEAD]; n=0
    while s and n < 40:
        out.append({k: mem[a+s] for k,a in P.items()} | {'slot': s}); s = mem[P['NEXT']+s]; n+=1
    return out
def snap(): return list(PLOTTED)   # ideal endpoints, not pixels
POSE = (float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]))
shots=[]
def prof(entry, max_cycles=900000):
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30; mem[0x01DF]=0xFE; mem[0x01DE]=0xFF
    mpu.processorCycles=0; sc.last_lines=[]; plot=sc.PLOT_PCS
    nms=0; obj=False; first=True
    for _ in range(max_cycles):
        pc=mpu.pc
        if pc==0xFF00: break
        if pc in plot:
            sc.last_lines.append((0,0,0,0))
            PLOTTED.append((mem[RZ['X0']],mem[RZ['Y0']],mem[RZ['X1']],mem[RZ['Y1']]))
        if pc==WALK and first:
            first=False
            shots.append(dict(tag='start', n=0, obj=False, lines=snap(), spans=spans(), cyc=mpu.processorCycles))
        if pc==OBJSLOT: obj=True
        if pc==MS:
            nms += 1
            shots.append(dict(tag=f'close-{nms}', n=nms, obj=obj, lo=mem[IL], hi=mem[IH],
                              lines=snap(), spans=spans(), cyc=mpu.processorCycles))
        mpu.step()
    sc.last_cycles=mpu.processorCycles; sc.total_cycles+=mpu.processorCycles
    return mpu.processorCycles
sc._run=prof
cyc = r.render_frame(POSE[0], POSE[1], POSE[2], dw.player_floor(POSE[0], POSE[1]))
shots.append(dict(tag='final', n=999, obj=True, lines=snap(), spans=spans(), cyc=cyc))
json.dump(dict(pose=POSE, cyc=cyc, shots=shots), open(sys.argv[4], 'w'))
print(f'{cyc:,} cyc, {len(shots)} snapshots')
for s in shots: print(f"  {s['tag']:10s} {len(s['spans']):2d} spans  cyc {s['cyc']:7,}")
