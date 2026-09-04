"""Step-by-step trace of ONE armed line: every span visited, its verdict,
the runs opened and closed, and what the apply did to each span."""
import os, sys, json
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(),'tools'))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
S=lambda n: sym(n, banked=1)
WALK=S('fw_walk_staged'); CS=S('fw_clip_span'); CB=S('fw_cb')
RVIS=S('fw_run_visible'); RA=S('cs_rej_above'); RB=S('cs_rej_below')
RVO=S('rv_open'); RVE=S('rv_extend'); CLOSE=S('fw_close_run')
APPLY=S('fused_apply_run'); SPLIT=S('fw_split_r'); MERGE=S('fused_merge_range')
FWL={n:S('fwl_'+n) for n in ('xl','xr','yl','yr','dx','lo','hi','zx0','zx1','run','rend')}
SLOT=S('FW_SLOT'); SIDE=S('FW_SIDE'); AX0=S('fw_ax0'); AX1=S('fw_ax1')
P={n:S('POOL_'+n) for n in ('NEXT','XSTART','XEND','TXLO','TDEN','TL','TR','OT','IT','BXLO','BDEN','BL','BR','OB','IB')}
HEAD=S('zp_head')
RZ={n:S('RASTER_ZP_'+n) for n in ('X0','Y0','X1','Y1')}
r=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,
                  dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; mpu=sc.mpu; mem=mpu.memory
PLOTTED=[]                      # every line the engine has rastered so far
def snap(): return list(PLOTTED)  # ideal endpoints, not pixels
FB, FBLEN = 0x5800, 0x1400
def fb(): return bytes(mem[FB:FB+FBLEN]).hex()   # the real raster at this moment
def spans():
    out=[]; s=mem[HEAD]; n=0
    while s and n<40:
        out.append({k:mem[a+s] for k,a in P.items()}|{'slot':s}); s=mem[P['NEXT']+s]; n+=1
    return out
POSE=(float(sys.argv[1]),float(sys.argv[2]),int(sys.argv[3]))
lines=[]
def prof(entry,max_cycles=900000):
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30; mem[0x01DF]=0xFE; mem[0x01DE]=0xFF
    mpu.processorCycles=0; sc.last_lines=[]; plot=sc.PLOT_PCS
    cur=None; ap=None; wsp=None
    for _ in range(max_cycles):
        pc=mpu.pc
        if pc==0xFF00: break
        if pc in plot:
            sc.last_lines.append((0,0,0,0))
            PLOTTED.append((mem[RZ['X0']],mem[RZ['Y0']],mem[RZ['X1']],mem[RZ['Y1']]))
        if cur is not None and wsp is not None and mpu.sp >= wsp+2:
            cur['after']=spans(); cur['lines_after']=snap(); cur['fb_after']=fb(); lines.append(cur); cur=None; wsp=None
        if pc==WALK:
            if cur:
                cur['after']=spans(); cur['lines_after']=snap(); cur['fb_after']=fb(); lines.append(cur)
            wsp=mpu.sp
            cur=dict(line={k:mem[v] for k,v in FWL.items() if k in ('xl','xr','yl','yr','dx','lo','hi')},
                     side=('bot' if mem[SIDE]&0x80 else 'top'), steps=[], before=spans(),
                     lines_before=snap(), fb_before=fb(), cyc0=mpu.processorCycles)
        elif cur is not None:
            if pc==CS:
                x=mem[SLOT]
                cur['steps'].append(dict(t='span', slot=x, xs=mem[P['XSTART']+x], xe=mem[P['XEND']+x],
                                         it=mem[P['IT']+x], ot=mem[P['OT']+x], ib=mem[P['IB']+x], ob=mem[P['OB']+x]))
            elif pc==RVIS and cur['steps'] and cur['steps'][-1]['t']=='span' and 'v' not in cur['steps'][-1]:
                cur['steps'][-1]['v']='accept'
            elif pc==RA and cur['steps']: cur['steps'][-1]['v']='reject-above'
            elif pc==RB and cur['steps']: cur['steps'][-1]['v']='reject-below'
            elif pc==CB and cur['steps']: cur['steps'][-1]['v']='trapezoid'
            elif pc==RVO: cur['steps'].append(dict(t='run-open', x0=mem[FWL['zx0']], x1=mem[FWL['zx1']]))
            elif pc==RVE: cur['steps'].append(dict(t='run-extend', to=mem[FWL['zx1']]))
            elif pc==CLOSE: cur['steps'].append(dict(t='run-close', x0=mem[FWL['run']], x1=mem[FWL['rend']]))
            elif pc==APPLY:
                cur['steps'].append(dict(t='apply', x0=mem[AX0], x1=mem[AX1])); ap=len(cur['steps'])-1
            elif pc==SPLIT and ap is not None: cur['steps'].append(dict(t='split'))
        mpu.step()
        if cur is not None and 'after' not in cur and pc==CLOSE:
            pass
    if cur:
        cur['after']=spans(); cur['lines_after']=snap(); cur['fb_after']=fb(); lines.append(cur)
    sc.last_cycles=mpu.processorCycles; sc.total_cycles+=mpu.processorCycles
    return mpu.processorCycles
sc._run=prof
cyc=r.render_frame(POSE[0],POSE[1],POSE[2],dw.player_floor(POSE[0],POSE[1]))
summary=[]
for i,L in enumerate(lines):
    sp=[x for x in L['steps'] if x['t']=='span']
    v={}
    for x in sp: v[x.get('v','?')]=v.get(x.get('v','?'),0)+1
    runs=sum(1 for x in L['steps'] if x['t']=='run-close')
    splits=sum(1 for x in L['steps'] if x['t']=='split')
    summary.append((i,len(sp),v,runs,splits,L))
    print(f"{i:3d}  x {L['line']['xl']:3d}->{L['line']['xr']:3d}  y {L['line']['yl']:3d}->{L['line']['yr']:3d}  "
          f"{L['side']:3s}  spans {len(sp):2d}  runs {runs}  splits {splits}  {v}")
if len(sys.argv)>5 and sys.argv[5]=='all':
    json.dump(lines, open(sys.argv[4],'w')); print(f'wrote all {len(lines)} lines'); raise SystemExit
if len(sys.argv)>5:
    best=lines[int(sys.argv[5])]
else:
    def score(z):
        i,n,v,runs,splits,L=z
        return (len(v)*10 + runs*8 + splits*3 + n)
    summary.sort(key=lambda z: -score(z)); best=summary[0][5]
print(f"CHOSEN: x {best['line']['xl']}->{best['line']['xr']} y {best['line']['yl']}->{best['line']['yr']} side={best['side']}")
for st in best['steps']: print('  ', st)
json.dump(best, open(sys.argv[4],'w'))
