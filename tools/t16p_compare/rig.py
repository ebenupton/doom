import os,sys
sys.path.insert(0,'/Users/ebenupton/doom'); sys.path.insert(0,'/Users/ebenupton/doom/tools')
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw, compare_renders as C
from banked_bsp import BankedBspRender
from symmap import sym

r=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                  dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; mpu=sc.mpu; mem=mpu.memory
ROT=sym('rot_w_pages',banked=1); E=sym('render_frame',banked=1)
SITES={n:sym(n,banked=1) for n in
 ['rwp_s1l','rwp_s2l','rwp_fs1l','rwp_fs2l','rwp_o1s','rwp_o1l','rwp_o2s','rwp_o2l',
  'rwp_o3s','rwp_o3l','rwp_o4s','rwp_o4l']}
SQR_L=0x200
def word(a): return mem[a+1]|mem[a+2]<<8   # operand of abs,X op at label a

cases=[]; epochs={}; ecur=None
orig=sc._run
def wrap(entry,max_cycles=10_000_000):
    global ecur
    if entry!=E: return orig(entry,max_cycles)
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30
    mem[0x1DF]=0xFE; mem[0x1DE]=0xFF
    mpu.processorCycles=0
    while mpu.pc!=0xFF00:
        if mpu.pc==ROT:
            sp=mpu.sp; ret=((mem[0x101+sp]|mem[0x102+sp]<<8)+1)&0xFFFF
            ox,oy,pg=mem[0x28],mem[0x10],mem[0x2C]
            ekey=bytes(mem[a] for a in range(0x1FC6,0x2110))+bytes(mem[a] for a in range(0x0A80,0x0AC0))
            if ekey not in epochs:
                Ms=8*(word(SITES['rwp_s1l'])-SQR_L)+(word(SITES['rwp_fs1l'])-SQR_L)
                Mc=8*(word(SITES['rwp_s2l'])-SQR_L)+(word(SITES['rwp_fs2l'])-SQR_L)
                ops=tuple(mem[SITES['rwp_o%d%s'%(i,k)]] for i in (1,2,3,4) for k in ('s','l'))
                pb=bytes(mem[a] for a in range(0x0A80,0x0AC0))
                epochs[ekey]=(len(epochs),Ms,Mc,ops,pb)
            eid=epochs[ekey][0]
            c0=mpu.processorCycles
            while mpu.pc!=ret:
                mpu.step()
            cases.append((eid,ox,oy,pg,mpu.processorCycles-c0,
                          mem[0x11]|mem[0x12]<<8, mem[0x13]|mem[0x14]<<8))
            continue
        mpu.step()
    return mpu.processorCycles
sc._run=wrap
for (px,py,ab) in C.POSITIONS:
    r.render_frame(px,py,ab,dw.player_floor(px,py))
print('calls',len(cases),'epochs',len(epochs),'eps_cyc',sum(c[4] for c in cases))

# ---- python expectation ----
elist=sorted(epochs.values())
def sgn(op): return 1 if op in (0x65,0x69,0x18) else -1
bad=0
for eid,ox,oy,pg,cyc,vx,vy in cases:
    _,Ms,Mc,ops,pb=elist[eid]
    s1,s2,s3,s4=sgn(ops[1]),sgn(ops[3]),sgn(ops[5]),sgn(ops[7])
    PBX=pb[pg]|pb[16+pg]<<8; PBY=pb[32+pg]|pb[48+pg]<<8
    ex=(PBX+((s1*ox*Ms+s2*oy*Mc+4)>>3))&0xFFFF
    ey=(PBY+((s3*ox*Mc+s4*oy*Ms+4)>>3))&0xFFFF
    if (ex,ey)!=(vx,vy): bad+=1
print('eps mismatches vs python:',bad)

# ---- bare-MPU t16p replay ----
from py65.devices.mpu6502 import MPU
lbl={}
for ln in open('tools/t16p_compare/t16p.lbl'):
    p=ln.split()
    if len(p)>=3: lbl[p[2].lstrip('.')]=int(p[1],16)
bmem=[0]*65536
for a in range(0x200,0x600): bmem[a]=mem[a]
img=open('tools/t16p_compare/t16p.bin','rb').read()
bmem[0x2000:0x2000+len(img)]=list(img)
b=MPU(memory=bmem)
def poke_epoch(Ms,Mc,ops,pb):
    for i,v in enumerate(pb): bmem[0x0A80+i]=v
    def prod(mp,sl,sh,M):
        bmem[lbl[mp]+1]=M
        bmem[lbl[sl]+1]=(0x200+M)&0xFF; bmem[lbl[sl]+2]=(0x200+M)>>8
        bmem[lbl[sh]+1]=(0x400+M)&0xFF; bmem[lbl[sh]+2]=(0x400+M)>>8
    # combine sign ops: (s,l) pairs per term; byte2 op follows l
    for term,(so,lo) in zip(('x1','x2','y1','y2'),
                            ((ops[0],ops[1]),(ops[2],ops[3]),(ops[4],ops[5]),(ops[6],ops[7]))):
        bmem[lbl[term+'s']]=so
        bmem[lbl[term+'l']]=lo
        bmem[lbl[term+'h']]=lo
        bmem[lbl[term+'b']]=0x69 if lo==0x65 else 0xE9
    if Ms==256:
        prod('u3m','u3sl','u3sh',Mc); prod('u2m','u2sl','u2sh',Mc)
        return lbl['t16p_suni']
    if Mc==256:
        prod('v1m','v1sl','v1sh',Ms); prod('v4m','v4sl','v4sh',Ms)
        return lbl['t16p_cuni']
    prod('p1m','p1sl','p1sh',Ms); prod('p4m','p4sl','p4sh',Ms)
    prod('p2m','p2sl','p2sh',Mc); prod('p3m','p3sl','p3sh',Mc)
    return lbl['t16p_gen']

tot=0; bad2=0; cur=-1; entry=None
for eid,ox,oy,pg,cyc,vx,vy in cases:
    if eid!=cur:
        _,Ms,Mc,ops,pb=elist[eid]
        assert not (Ms==256 and Mc==256)
        entry=poke_epoch(Ms,Mc,ops,pb); cur=eid
    bmem[0x28]=ox; bmem[0x10]=oy; bmem[0x2C]=pg
    b.sp=0xFD; bmem[0x1FE]=0xFF; bmem[0x1FF]=0xFE
    b.pc=entry; b.p=0x30; b.processorCycles=0
    n=0
    while b.pc!=0xFF00:
        b.step(); n+=1
        assert n<3000,'runaway'
    tot+=b.processorCycles
    if (bmem[0x11]|bmem[0x12]<<8, bmem[0x13]|bmem[0x14]<<8)!=(vx,vy): bad2+=1
print('t16p mismatches:',bad2,' t16p_cyc',tot)
# ---- variant 2: mirrored diff tables ----
for i in range(1,511):
    v=(abs(i-256)**2)//4
    bmem[0x600+i]=v&0xFF; bmem[0x800+i]=v>>8
def poke_epoch2(Ms,Mc,ops,pb):
    for i,v in enumerate(pb): bmem[0x0A80+i]=v
    def prod(sl,dl,sh,dh,M):
        for base,site in ((0x200+M,sl),(0x600+256-M,dl),(0x400+M,sh),(0x800+256-M,dh)):
            bmem[lbl[site]+1]=base&0xFF; bmem[lbl[site]+2]=base>>8
    for term,(so,lo) in zip(('x1','x2','y1','y2'),
                            ((ops[0],ops[1]),(ops[2],ops[3]),(ops[4],ops[5]),(ops[6],ops[7]))):
        bmem[lbl[term+'s']]=so; bmem[lbl[term+'l']]=lo
        bmem[lbl[term+'h']]=lo; bmem[lbl[term+'b']]=0x69 if lo==0x65 else 0xE9
    if Ms==256 or Mc==256:
        return None   # unity: fall back to variant-1 bodies (same in both worlds)
    prod('q1sl','q1dl','q1sh','q1dh',Ms); prod('q4sl','q4dl','q4sh','q4dh',Ms)
    prod('q2sl','q2dl','q2sh','q2dh',Mc); prod('q3sl','q3dl','q3sh','q3dh',Mc)
    return lbl['t16p2_gen']
tot2=0; bad3=0; cur=-1; entry=None
for eid,ox,oy,pg,cyc,vx,vy in cases:
    if eid!=cur:
        _,Ms,Mc,ops,pb=elist[eid]
        entry=poke_epoch2(Ms,Mc,ops,pb); cur=eid
        assert entry is not None
    bmem[0x28]=ox; bmem[0x10]=oy; bmem[0x2C]=pg
    b.sp=0xFD; bmem[0x1FE]=0xFF; bmem[0x1FF]=0xFE
    b.pc=entry; b.p=0x30; b.processorCycles=0
    n=0
    while b.pc!=0xFF00:
        b.step(); n+=1
        assert n<3000
    tot2+=b.processorCycles
    if (bmem[0x11]|bmem[0x12]<<8, bmem[0x13]|bmem[0x14]<<8)!=(vx,vy): bad3+=1
print('t16p2 mismatches:',bad3,' t16p2_cyc',tot2,' per-call %.1f'%(tot2/len(cases)),
      ' delta/frame vs eps %+d'%((tot2-eps if False else tot2-sum(c[4] for c in cases))//18))
eps=sum(c[4] for c in cases)
print('per-call: eps %.1f  t16p %.1f  delta/frame %+d'%(eps/len(cases),tot/len(cases),(tot-eps)//18))
uni=sum(1 for c in cases if elist[c[0]][1]==256 or elist[c[0]][2]==256)
print('unity-epoch calls:',uni,'of',len(cases))
