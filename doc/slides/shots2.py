"""Real engine frames + genuine part-way clip state, snapshotted mid-render."""
import os, sys, json
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(),'tools'))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
S = lambda n: sym(n, banked=1)
MS, APPLY, OBJSLOT, KILL = S('span_mark_solid'), S('fused_apply_run'), S('obj_draw_slot'), S('fused_kill')
AX0, AX1, FW_SIDE = S('fw_ax0'), S('fw_ax1'), S('FW_SIDE')
FWL = {n: S('fwl_'+n) for n in ('xl','xr','yl','yr','dx','lo','hi')}
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
FB, FBLEN = 0x5800, 0x1400
def fb(): return bytes(mem[FB:FB+FBLEN]).hex()   # the real raster at this moment
STAMP, OFAST, OFUSED = S('obj_stamp'), S('obj_fast'), S('obj_fused')
objstat={}
POSE = (float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]))
TAG = sys.argv[4]
shots=[]; ev=[]
def prof(entry, max_cycles=900000):
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30; mem[0x01DF]=0xFE; mem[0x01DE]=0xFF
    mpu.processorCycles=0; sc.last_lines=[]; plot=sc.PLOT_PCS
    obj_sp=None; pend=None; nms=0
    for _ in range(max_cycles):
        pc=mpu.pc
        if pc==0xFF00: break
        if pc in plot:
            sc.last_lines.append((0,0,0,0))
            PLOTTED.append((mem[RZ['X0']],mem[RZ['Y0']],mem[RZ['X1']],mem[RZ['Y1']]))
        if obj_sp is not None and mpu.sp >= obj_sp+2:
            shots.append(dict(tag='object-done', lines=snap(), fb=fb(), spans=spans(), cyc=mpu.processorCycles)); obj_sp=None
        if pend is not None and mpu.sp >= pend[1]+2:
            pend[0]['after']=spans(); pend=None
        if pc == STAMP and obj_sp is not None:
            st=objstat.setdefault(len([s for s in shots if s['tag']=='object-start']), dict(entries=0, plain=0, armed=0, fast=None))
            st['entries']+=1
            if st['fast'] is None: st['fast']=mem[OFAST]
            st['armed' if mem[OFUSED] else 'plain']+=1
        if pc == OBJSLOT and obj_sp is None:
            obj_sp = mpu.sp
            shots.append(dict(tag='object-start', lines=snap(), fb=fb(), spans=spans(), cyc=mpu.processorCycles))
        if pc in (MS, APPLY, KILL):
            inobj = obj_sp is not None
            if pc == APPLY:
                e=dict(kind='apply', obj=inobj, x0=mem[AX0], x1=mem[AX1],
                       side=('bot' if mem[FW_SIDE]&0x80 else 'top'),
                       line={k: mem[v] for k,v in FWL.items()}, before=spans(), cyc=mpu.processorCycles)
            elif pc == KILL:
                e=dict(kind='kill', obj=inobj, x0=mpu.a, x1=mpu.y, before=spans(), cyc=mpu.processorCycles)
            else:
                e=dict(kind='mark_solid', obj=inobj, lo=mem[IL], hi=mem[IH], before=spans(), cyc=mpu.processorCycles)
                nms += 1
                if nms in (1, 3, 6, 10, 14):
                    shots.append(dict(tag=f'walls-{nms}', lines=snap(), fb=fb(), spans=spans(), cyc=mpu.processorCycles))
            ev.append(e); pend=[e, mpu.sp]
        mpu.step()
    sc.last_cycles=mpu.processorCycles; sc.total_cycles+=mpu.processorCycles
    return mpu.processorCycles
sc._run=prof
cyc = r.render_frame(POSE[0], POSE[1], POSE[2], dw.player_floor(POSE[0], POSE[1]))
shots.append(dict(tag='final', lines=snap(), fb=fb(), spans=spans(), cyc=cyc))
json.dump(dict(pose=POSE, cyc=cyc, shots=shots, events=ev, objstat=objstat), open(f'{sys.argv[5]}', 'w'))
print('OBJSTAT', objstat)
print(f'SHOT {TAG} {cyc:,} cyc  shots={[s["tag"] for s in shots]}  events={len(ev)}')
