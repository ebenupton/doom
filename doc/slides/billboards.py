import json, sys
sys.path.insert(0,'.')
from darkkit import *
from PIL import Image

A=json.load(open('shot_armour.json')); sh={s['tag']:s for s in A['shots']}
objev=[e for e in A['events'] if e['obj']]
spr={n:json.load(open(f'spr_{n}.json')) for n in
     ('armour_near','armour_mid','armour_far_a','helmet_near','helmet_mid','helmet_far_a','helmet_far_b')}
def sprite_img(d,pad=1,fg=(120,255,170)):
    x0,y0,x1,y1=d['box']; w,h=x1-x0+1+2*pad,y1-y0+1+2*pad
    im=Image.new('RGB',(w,h),(9,14,11)); px=im.load()
    for (x,y) in d['px']: px[x-x0+pad,y-y0+pad]=fg
    return im

o=head('Billboards','bbc micro doom · 6502 · objects',
       'flat cut-outs living in a subsector, drawn after its walls, clipped by the same span list — and closing it behind themselves')

# ============== HERO: the armour tightening the list ==============
Y=182
o+=panel(64,Y,1472,470,'the green armour · pose (-104,-3232,128) · the span set as real trapezia, before and after the object',PH)
SW=470; SH=SW*160/256
o.append(t(96,Y+48,'the object is drawn AFTER its subsector\'s walls, and it closes columns like a wall does — only on its BOT side',12,PH_HI,MONO,'bold'))
for i,(tag,cap,col) in enumerate([('object-start','BEFORE · 7 spans open',CYAN),('object-done','AFTER · 16 spans, +29,502 cyc',PH)]):
    s=sh[tag]; x=96+i*(SW+34)
    o.append(t(x,Y+72,cap,12.5,col,MONO,'bold'))
    o+=screen(x,Y+82,SW)
    o+=trapezia(x,Y+82,SW,s['spans'],col)
    o+=geom(x,Y+82,SW,s['lines'],col=HEAD,sw=1.575)
    if i==1:
        sx=SW/256.0
        o.append(r_(x+101*sx,Y+82+SH+6,54*sx,7,MAG,'none',rx=1))
        o.append(t(x+128*sx,Y+82+SH+26,'columns 101→155 now bounded by the lid arc',10.5,MAG,MONO,anchor='middle'))
o.append(t(96,Y+82+SH+26,'the aperture reaches the floor: one wide trapezium',10.5,CYAN,MONO))
o.append(t(96,Y+82+SH+44,'the billboard is not in the list yet — it is about to put itself there',10.5,MUTE,MONO))
o.append(t(96+SW+34,Y+82+SH+44,'ten thin trapezia now trace the armour\'s own silhouette',10.5,PH,MONO))
# sprite + commands
d=spr['armour_near']; im=sprite_img(d)
o.append(t(1100,Y+72,'its own pixels',11,AMB,MONO,'bold'))
o.append(img(1100,Y+82,150,150*im.height/im.width,im)); o.append(r_(1100,Y+82,150,150*im.height/im.width,'none',AMB,1))
o.append(t(1100,Y+180,f"H={d['H']}  a={d['a']}  55x31",10.5,TXT,MONO))
o.append(t(1280,Y+72,'the ten commands it emits',11,MAG,MONO,'bold'))
for i,e in enumerate(objev):
    o.append(t(1280,Y+94+i*17,f"apply [{e['x0']:3d},{e['x1']:3d})  bot",10.8,MAG,MONO))
o.append(t(1100,Y+286,'Every one is BOT side: a cut-out blocks what is below',10.5,TXT,MONO))
o.append(t(1100,Y+302,'its top edge and nothing above it. Only the lid arc is',10.5,TXT,MONO))
o.append(t(1100,Y+318,'allowed to tighten; the outline draws with it switched off,',10.5,TXT,MONO))
o.append(t(1100,Y+334,'so the figure can never clip itself.',10.5,TXT,MONO))
o.append(t(1100,Y+362,'occlusion probe first: span_has_gap(101,156)',10.8,PH_HI,MONO,'bold'))
o.append(t(1100,Y+378,'→ a gap remains, so the object is built at all',10.8,PH_HI,MONO,'bold'))

# ============== STEP CARDS ==============
Y2=666
o+=panel(64,Y2,1472,176,'one billboard, step by step · every count from this frame',MAG)
steps=[('1','any objects?','A 25-byte bitmap, one bit per subsector. No bit, no work.'),
       ('2','where is the run','A per-octet byte gives the first object index, so no scan walks the 50-entry table.'),
       ('3','stage six','Centre, projected top and bottom, depth: banked into one of six slots.'),
       ('4','sort near first','Front to back, so each closes the columns behind it for the next.'),
       ('5','height + growth','H = yb-yt, then a per-kind 256ths factor, base pinned.'),
       ('6','half width','a = H·k/64, one quarter-square multiply. Width follows height.'),
       ('7','occlusion probe','span_has_gap(101,156): gap found. All solid would skip the slot.'),
       ('8','pick the tier','H=30 vs threshold 24 → NEAR template. A different art list.'),
       ('9','walk the art','32 template entries; ten of them tighten — the lid arc.'),
       ('10','apply as you go','Each of those ten clips, plots its runs, applies as BOT.'),
       ('11','outline only draws','The other 22 lines plot with the tighten switched off.'),
       ('12','merge once','Equal neighbours coalesce: 7 spans in, 16 out.')]
cw=(1400-11*10)/12
for i,(n,ttl,body) in enumerate(steps):
    x=104+i*(cw+10); yy=Y2+40
    o.append(r_(x,yy,cw,126,'#0C1210',EDGE,1,rx=2))
    o.append(t(x+8,yy+18,n,11,MAG,MONO,'bold')); o.append(t(x+8,yy+34,ttl,9.8,HEAD,MONO,'bold'))
    words=body.split(); ls=[]; cl=''
    for w in words:
        if len(cl)+len(w)+1>16: ls.append(cl); cl=w
        else: cl=(cl+' '+w).strip()
    ls.append(cl)
    for j,l in enumerate(ls[:8]): o.append(t(x+8,yy+50+j*12,l,8.9,TXT,MONO))

# ============== BOTTOM ==============
Y3=856
o+=panel(64,Y3,900,218,'level of detail · real art at real sizes · the shape is SWAPPED, not scaled',AMB)
for ri,(kind,thr,names) in enumerate([('armour','threshold 24',['armour_near','armour_mid','armour_far_a']),
                                      ('helmet','threshold 7',['helmet_near','helmet_mid','helmet_far_a','helmet_far_b'])]):
    yy=Y3+46+ri*84
    o.append(t(88,yy+20,kind,12,HEAD,MONO,'bold')); o.append(t(88,yy+36,thr,10.5,AMB,MONO))
    x=196
    for n in names:
        d=spr[n]; im=sprite_img(d,fg=(120,255,170) if d['lod'] else (255,190,110))
        h=48; w=h*im.width/im.height
        o.append(img(x,yy-4,w,h,im))
        col=PH if d['lod'] else AMB
        o.append(t(x+w/2,yy+56,f"H={d['H']}",10.5,col,MONO,'bold','middle'))
        o.append(t(x+w/2,yy+68,'NEAR' if d['lod'] else 'far',9.5,col,MONO,anchor='middle'))
        x+=w+36
o.append(t(88,Y3+206,'One byte per kind sets the switch. Doubling the distance at which a hoplite gains detail was a one-byte edit: 15 → 7.',10.8,TXT,MONO))

o+=panel(988,Y3,548,218,'the numbers',CYAN)
o.append(t(1012,Y3+46,'kind        k   lodh',11,CYAN,MONO,'bold'))
for i,(k,kv,lo) in enumerate([('barrel',23,'33'),('lamp',15,'—'),('potion',25,'—'),('helmet',34,'7'),
                              ('stimpack',30,'24'),('medikit',47,'12'),('armour',58,'24')]):
    o.append(t(1012,Y3+66+i*17,f'{k:<12s}{kv:<4d}{lo}',10.8,TXT,MONO))
o.append(t(1240,Y3+66,'k = 64·radius/height, baked',10.5,MUTE,MONO))
o.append(t(1240,Y3+83,'at pack time and asserted',10.5,MUTE,MONO))
o.append(t(1240,Y3+100,'against the python mirror',10.5,MUTE,MONO))
o.append(t(1240,Y3+126,'lodh is a projected height:',10.5,MUTE,MONO))
o.append(t(1240,Y3+143,'a distance in disguise',10.5,MUTE,MONO))
o.append(t(1012,Y3+188,'17 of 37 stamped billboards over the corpus were fully occluded:',10.8,AMB,MONO))
o.append(t(1012,Y3+204,'53,816 cycles that drew nothing. That is why step 7 exists.',10.8,AMB,MONO))
o+=foot('objects are 9.9% of the render suite · six slots a subsector · nearest first · one occlusion question can retire a whole slot · only the lid arc tightens')
open('billboards.svg','w').write(svg(o)); print('ok')
