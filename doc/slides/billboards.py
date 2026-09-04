import json, sys
sys.path.insert(0,'.')
from darkkit import *
from PIL import Image

A=json.load(open('shot_armour.json')); sh={s['tag']:s for s in A['shots']}
objev=[e for e in A['events'] if e['obj']]
OS=A['objstat']['1']              # template walk: entries incl. the two controls, plain/armed, probe 2
NOUT=OS['plain']-1; NTOP=OS['armed']-1
DCYC=sh['object-done']['cyc']-sh['object-start']['cyc']
spr={n:json.load(open(f'spr_{n}.json')) for n in
     ('armour_near','armour_mid','armour_far_a','helmet_near','helmet_mid','helmet_far_a','helmet_far_b')}
def sprite_img(d,pad=1,fg=(120,255,170)):
    x0,y0,x1,y1=d['box']; w,h=x1-x0+1+2*pad,y1-y0+1+2*pad
    im=Image.new('RGB',(w,h),(9,14,11)); px=im.load()
    for (x,y) in d['px']: px[x-x0+pad,y-y0+pad]=fg
    return im

o=head('Billboards','bbc micro doom · 6502 · objects',
       'flat cut-outs living in a subsector, drawn after its walls, clipped by the same span list, and closing it behind themselves')

# ============== HERO: the armour tightening the list ==============
Y=182
o+=panel(64,Y,1472,470,'the green armour · pose (-104,-3232,128) · the span set as real trapezia, before and after the object',PH)
SW=470; SH=SW*160/256
o.append(t(96,Y+48,'the object is drawn AFTER its subsector\'s walls, and it closes columns like a wall does — only on its BOT side',12,PH_HI,MONO,'bold'))
for i,(tag,cap,col) in enumerate([('object-start','BEFORE · 7 spans open',CYAN),('object-done',f'AFTER · 16 spans, +{DCYC:,} cyc',PH)]):
    s=sh[tag]; x=96+i*(SW+34)
    o.append(t(x,Y+72,cap,12.5,col,MONO,'bold'))
    o+=screen(x,Y+82,SW)
    o+=trapezia(x,Y+82,SW,s['spans'],col,sw=0.8)
    o+=raster(x,Y+82,SW,s['fb'])
    if i==1:
        sx=SW/256.0
        o.append(r_(x+101*sx,Y+82+SH+6,54*sx,7,MAG,'none',rx=1))
        o.append(t(x+128*sx,Y+82+SH+26,'columns 101→155 now bounded by its top edge',10.5,MAG,MONO,anchor='middle'))
o.append(t(96,Y+82+SH+44,'the aperture reaches the floor: one wide trapezium',10.5,CYAN,MONO))
o.append(t(96,Y+82+SH+62,'the billboard is not in the list yet; it is about to put itself there',10.5,MUTE,MONO))
o.append(t(96+SW+34,Y+82+SH+44,f'{NTOP} thin trapezia now trace the armour\'s top edge',10.5,PH,MONO))
# sprite + commands
o.append(t(1100,Y+72,f'{NTOP} tighten commands issued',11,MAG,MONO,'bold'))
for i,e in enumerate(objev):
    o.append(t(1100,Y+94+i*17,f"apply [{e['x0']:3d},{e['x1']:3d})  bot",10.8,MAG,MONO))
for j,l in enumerate(['Every one is BOT side: a cut-out blocks what is below its',
                      'top edge and nothing above it. Only the top edge tightens.',
                      f'The template puts the {NOUT} outline lines FIRST, drawn through',
                      f'the plain clipper; a control entry then arms the walker and',
                      f'the {NTOP} top-edge lines follow, each drawing and applying in one',
                      'walk. Drawn first, the outline is never clipped by its own edge.']):
    o.append(t(1100,Y+270+j*15,l,10.2,TXT,MONO))
for j,(l,c) in enumerate([('Probe 1, before any art: span_has_gap over [101,156).',PH_HI),
                          ('A column is still open, so the slot is built at all;',TXT),
                          ('all closed would retire it before a single line.',TXT),
                          ('Probe 2, after the art ladders: box [101,155]x[76,106]',PH_HI),
                          ('on screen, and every span across it holds it inside',TXT),
                          (f'[IT,IB] with no gap: PASSED, so the {NOUT} outline lines',TXT),
                          ('skip the clipper and go straight to the plotter.',TXT)]):
    o.append(t(1100,Y+372+j*14,l,10.2,c,MONO,'bold' if c==PH_HI else 'normal'))

# ============== STEP CARDS ==============
Y2=666
o+=panel(64,Y2,1472,176,'one billboard, step by step · every count from this frame',MAG)
steps=[('1','any objects?','A 25-byte bitmap, one bit per subsector. No bit, no work.'),
       ('2','where is the run','The table is sorted by subsector; a first-index byte per eight subsectors starts the scan at most seven early.'),
       ('3','stage six','Centre, projected top and bottom, depth: banked into one of six slots.'),
       ('4','sort near first','Front to back, so each closes the columns behind it for the next.'),
       ('5','height + growth','H = yb-yt, then a per-kind 256ths factor, base pinned.'),
       ('6','half width','a = H·k/64, one quarter-square multiply. Width follows height.'),
       ('7','probe 1','span_has_gap over [101,156): a column is open. All closed would retire the slot.'),
       ('8','pick the tier','H=30 vs threshold 24 → NEAR template, a different art list.'),
       ('9','probe 2',f'Box on screen and inside every span it crosses: PASSED, the outline can skip the clipper.'),
       ('10','outline first',f'{NOUT} lines, drawn disarmed. Here they go straight to the plotter.'),
       ('11','then the top edge',f'A control entry arms the walker; {NTOP} lines each clip, plot, apply as BOT.')]
cw=(1400-10*10)/11
for i,(n,ttl,body) in enumerate(steps):
    x=104+i*(cw+10); yy=Y2+40
    o.append(r_(x,yy,cw,126,'#0C1210',EDGE,1,rx=2))
    o.append(t(x+8,yy+18,n,11,MAG,MONO,'bold')); o.append(t(x+8,yy+34,ttl,9.8,HEAD,MONO,'bold'))
    words=body.split(); ls=[]; cl=''
    for w in words:
        if len(cl)+len(w)+1>19: ls.append(cl); cl=w
        else: cl=(cl+' '+w).strip()
    ls.append(cl)
    for j,l in enumerate(ls[:8]): o.append(t(x+8,yy+50+j*12,l,8.9,TXT,MONO))

# ============== BOTTOM: every kind, far and near tier, real captured art ==============
Y3=856
o+=panel(64,Y3,1472,218,'level of detail · both tiers of every kind at one height and one pixel scale · the shape is swapped, not scaled',AMB)
# threshold = obj_lodh (objects.s): H at or above it selects the near template; $FF = single tier
LOD=[('barrel',33),('lamp',None),('potion',None),('helmet',7),('stimpack',24),('medikit',12),('armour',24)]
def lodspr(n):
    try: return json.load(open(f'spr_{n}.json'))
    except FileNotFoundError: return None
BW=(1472-48-6*12)/7; PX=1.5        # 1.5 slide units per engine pixel, the same for every sprite
OUT=2                              # the PNG is rendered at 2 px per slide unit: 3 whole px per engine pixel
for i,(kind,thr) in enumerate(LOD):
    bx=88+i*(BW+12); by=Y3+44
    o.append(r_(bx,by,BW,156,'#0C1210',EDGE,1,rx=2))
    o.append(t(bx+10,by+20,kind,12,HEAD,MONO,'bold'))
    o.append(t(bx+10,by+35,('near at H ≥ %d'%thr) if thr else 'single tier',10,AMB if thr else MUTE,MONO))
    tiers=[('far',lodspr('lod_'+kind+'_far'))]+([('near',lodspr('lod_'+kind+'_near'))] if thr else [])
    x=bx+10; base=by+122
    for tier,d in tiers:
        if d is None:
            o.append(t(x,base-20,f'{tier}: no capture',9.5,MAG,MONO)); x+=80; continue
        im=sprite_img(d,pad=0,fg=(120,255,170) if d['lod'] else (255,190,110))
        w,h=im.width*PX,im.height*PX
        im=im.resize((int(w*OUT),int(h*OUT)),Image.NEAREST)
        o.append(img(x,base-h,w,h,im))
        col=PH if d['lod'] else AMB
        o.append(t(x+w/2,base+16,f"H={d['H']}",10,col,MONO,'bold','middle'))
        o.append(t(x+w/2,base+28,'NEAR' if d['lod'] else ('far' if thr else 'only'),9.5,col,MONO,anchor='middle'))
        x+=w+18
o+=foot('objects are 9.9% of the render suite · six slots a subsector · nearest first · probe 1 can retire a whole slot, probe 2 can free it from the clipper · only the top edge tightens')
open('billboards.svg','w').write(svg(o)); print('ok')
