import json, sys
sys.path.insert(0,'.')
from darkkit import *

T=json.load(open('trace_window.json')); L=T['line']
SH=json.load(open('shot_window.json')); sh={s['tag']:s for s in SH['shots']}
GHOST=sh['final']['lines']   # the finished frame, drawn dim behind the live geometry
DIM=mix(HEAD,'#060907',.88)
CLIP={2,3,4,5,6}          # slots that needed the trapezoid clip
CHG={11,6,7}              # slots the tighten actually changed

o=head('The span clipper','bbc micro doom · 6502 · 256×160 mode 4 · one 8-bit column index',
       'the visible surface is a list of open trapezoidal spans; every wall draws through that list and closes it behind itself, in a single walk')

# ---------------- HERO: one line, before and after, on the real frame ----------------
Y=182
o+=panel(64,Y,964,440,'one line that tightens · spawn-room window, looking out into the courtyard',MAG)
IW=440; IH=IW*160/256; XA=88; XB=552; IY=Y+80
o.append(t(XA,Y+52,f"the line: x {L['xl']}→{L['xr']}, y {L['yl']}→{L['yr']}, BOT side — the foot of the wall behind the barrel",11.6,MAG,MONO,'bold'))
o.append(t(XA,Y+72,f"BEFORE · {len(T['before'])} spans open",12,CYAN,MONO,'bold'))
o.append(t(XB,Y+72,f"AFTER · {len(T['after'])} spans, three with a new bottom",12,PH,MONO,'bold'))
o+=screen(XA,IY,IW)
o+=trapezia(XA,IY,IW,T['before'],CYAN,only=lambda s: s['slot'] not in CLIP)
o+=trapezia(XA,IY,IW,T['before'],AMB,only=lambda s: s['slot'] in CLIP)
o+=geom(XA,IY,IW,GHOST,col=DIM,sw=.85)
o+=geom(XA,IY,IW,T['lines_before'],col=HEAD,sw=1.575)
o.append(scene_line(XA,IY,IW,L['xl'],L['xr'],L['yl'],L['yr'],MAG,2.6))
o+=screen(XB,IY,IW)
o+=trapezia(XB,IY,IW,T['after'],PH,only=lambda s: s['slot'] not in CHG)
o+=trapezia(XB,IY,IW,T['after'],MAG,sw=1.6,only=lambda s: s['slot'] in CHG)
o+=geom(XB,IY,IW,GHOST,col=DIM,sw=.85)
o+=geom(XB,IY,IW,T['lines_after'],col=HEAD,sw=1.575)
sx=IW/256.0
for (a,b) in ((208,227),(248,255)):
    o.append(r_(XA+a*sx,IY+IH+6,(b-a)*sx,7,PH,'none',rx=1))
o.append(t(XA,IY+IH+30,'two visible runs, [208,227) and [248,255); between them the barrel',10.3,PH_HI,MONO))
o.append(t(XA,IY+IH+44,'already owns the columns, so five spans hide the line entirely',10.3,PH_HI,MONO))
o.append(t(XA,IY+IH+62,'cyan settled on two compares · amber needed the trapezoid clip',10.3,MUTE,MONO))
o.append(t(XB,IY+IH+30,'magenta: the three spans the tighten reached. [208,227) keeps its own',10.3,MAG,MONO))
o.append(t(XB,IY+IH+44,'columns; [248,251) and [251,255) end up sharing ONE line record, and',10.3,MAG,MONO))
o.append(t(XB,IY+IH+62,'grey: the rest of the finished frame, not plotted yet at this moment.',10.3,MUTE,MONO))

# ---------------- WHAT A SPAN IS ----------------
PX=1044; PW=492
o+=panel(PX,Y,PW,440,'what a span is · 15 bytes',CYAN)
rows=[('NEXT','next slot; the list is sorted by XSTART'),
      ('XSTART XEND','the columns it owns, half-open [lo,hi)'),
      ('TXLO TDEN TL TR','the TOP line: own anchor, own run, own ends'),
      ('OT IT','top extremes: outer rejects, inner accepts'),
      ('BXLO BDEN BL BR','the BOTTOM line, the same four fields'),
      ('OB IB','bottom extremes, the same pair')]
for i,(f,d) in enumerate(rows):
    yy=Y+52+i*20
    o.append(t(PX+24,yy,f,10.6,AMB,MONO,'bold')); o.append(t(PX+180,yy,d,10.2,TXT,MONO))
o.append(ln(PX+24,Y+180,PX+PW-24,Y+180,EDGE,1,cap='butt'))
o.append(t(PX+24,Y+198,'A boundary is stored as the WHOLE line it came from, not as',10.4,PH_HI,MONO))
o.append(t(PX+24,Y+212,'the piece this span can see. Only XSTART/XEND are the span.',10.4,PH_HI,MONO))

# --- the diagram ---
DX,DY,DW,DH=PX+24,Y+228,PW-48,150
def dx(u): return DX+u*DW
def dy(v): return DY+v*DH
tl,tr=(0.03,0.22),(0.70,0.32)          # top line, its own anchor and run
bl,br=(0.10,0.80),(0.97,0.68)          # bottom line, a different anchor and run
xs,xe=0.40,0.66                        # the span's own columns
def evd(u,a,b): return a[1]+(b[1]-a[1])*(u-a[0])/(b[0]-a[0])
poly=[(dx(xs),dy(evd(xs,tl,tr))),(dx(xe),dy(evd(xe,tl,tr))),
      (dx(xe),dy(evd(xe,bl,br))),(dx(xs),dy(evd(xs,bl,br)))]
o.append('<polygon points="'+' '.join(f'{a:.1f},{b:.1f}' for a,b in poly)+
         f'" fill="{CYAN}" fill-opacity=".16" stroke="{CYAN}" stroke-width="1.4"/>')
o.append(ln(dx(tl[0]),dy(tl[1]),dx(tr[0]),dy(tr[1]),PH,1.8))
o.append(ln(dx(bl[0]),dy(bl[1]),dx(br[0]),dy(br[1]),PH,1.8))
for u in (xs,xe):
    o.append(ln(dx(u),dy(0.10),dx(u),dy(0.92),MUTE,1,dash='3 3'))
o.append(f'<circle cx="{dx(tl[0]):.1f}" cy="{dy(tl[1]):.1f}" r="3.4" fill="{AMB}"/>')
o.append(f'<circle cx="{dx(bl[0]):.1f}" cy="{dy(bl[1]):.1f}" r="3.4" fill="{AMB}"/>')
o.append(t(dx(tl[0])-4,dy(tl[1])-8,'TL',9.4,PH_HI,MONO,'bold'))
o.append(t(dx(tr[0])+5,dy(tr[1])+3,'TR',9.4,PH_HI,MONO,'bold'))
o.append(t(dx(tl[0])-2,dy(tl[1])+13,'TXLO',9.4,AMB,MONO,'bold'))
o.append(t(dx(bl[0])-2,dy(bl[1])+14,'BXLO',9.4,AMB,MONO,'bold'))
o.append(t(dx(bl[0])-4,dy(bl[1])-7,'BL',9.4,PH_HI,MONO,'bold'))
o.append(t(dx(br[0])+5,dy(br[1])+3,'BR',9.4,PH_HI,MONO,'bold'))
o.append(ln(dx(tl[0]),dy(0.05),dx(tr[0]),dy(0.05),AMB,1))
o.append(t(dx((tl[0]+tr[0])/2),dy(0.02),'TDEN',9.4,AMB,MONO,'bold',anchor='middle'))
o.append(ln(dx(bl[0]),dy(0.99),dx(br[0]),dy(0.99),AMB,1))
o.append(t(dx((bl[0]+br[0])/2),dy(0.96),'BDEN',9.4,AMB,MONO,'bold',anchor='middle'))
o.append(t(dx(xs)-4,dy(0.08),'XSTART',9.4,CYAN,MONO,'bold',anchor='end'))
o.append(t(dx(xe)+4,dy(0.08),'XEND',9.4,CYAN,MONO,'bold'))
o.append(t(dx(xs)+6,dy(evd(xs,tl,tr))+12,'IT',9,MUTE,MONO))
o.append(t(dx(xe)-16,dy(evd(xe,bl,br))-6,'IB',9,MUTE,MONO))
o.append(t(PX+24,Y+396,'Above, slots 6 [248,251) and 7 [251,255) both carry BXLO=208',10.2,TXT,MONO))
o.append(t(PX+24,Y+410,'BDEN=47 BL=148 BR=144: an anchor forty columns outside them.',10.2,TXT,MONO))
o.append(t(PX+24,Y+426,'y = BL + (BR−BL)·(x−BXLO)/BDEN — a split copies it verbatim.',10.2,AMB,MONO,'bold'))

# ---------------- STEP CARDS ----------------
Y2=636
o+=panel(64,Y2,1472,176,'what the walk actually did, span by span',PH)
steps=[('1','the line arrives','x 208→255, y 148→144, den 47: one wall edge, already projected, already clipped to columns. Its global extremes are 144 and 148, and they are the only y values the cheap path ever looks at.'),
       ('2','walk in order','The list is sorted by XSTART and the walker never restarts, so the four spans that end left of column 208 are stepped over without one field being read.'),
       ('3','[208,227) ACCEPT','Inner top IT=48, inner bottom IB=207, the whole screen. 144..148 lies inside that band, so the overlap is visible in full. Two compares, no arithmetic at all.'),
       ('4','a run OPENS','Still nothing plotted. The run records its first column and waits, because a contiguous visible stretch must leave as ONE fragment; splitting it would change the pixels.'),
       ('5','[227,230) straddles','This span is the barrel front: IB=145, and the line covers 144..148. The extremes overlap, so neither compare settles it and fw_cb clips the line against the real trapezium.'),
       ('6','hidden → close','The clip returns nothing visible: the line runs under this span bottom. That ends the stretch, so [208,227) is plotted as one fragment and only THEN is the tighten applied.'),
       ('7','three more clips','[230,236), [236,242) and [242,248) straddle in the same way and hide it too. Five trapezoid clips in this walk, and not a single pixel comes out of them.'),
       ('8','[248,255) again','The clip finds a visible piece, [251,255) accepts on IB=207 and extends the run to the screen edge. Closing it plots one fragment and hands the line to both spans.')]
cw=(1424-7*12)/8
for i,(n,ttl,body) in enumerate(steps):
    x=88+i*(cw+12); yy=Y2+40
    o.append(r_(x,yy,cw,124,'#0C1210',EDGE,1,rx=2))
    o.append(t(x+10,yy+19,n,12,MAG,MONO,'bold')); o.append(t(x+26,yy+19,ttl,10.2,HEAD,MONO,'bold'))
    words=body.split(); lsx=[]; cl=''
    for w in words:
        if len(cl)+len(w)+1>27: lsx.append(cl); cl=w
        else: cl=(cl+' '+w).strip()
    lsx.append(cl)
    for j,l in enumerate(lsx[:9]): o.append(t(x+10,yy+37+j*11.6,l,9.3,TXT,MONO))

# ---------------- BOTTOM: the list across a whole frame ----------------
Y3=826
o+=panel(64,Y3,1472,240,'the same list, across the whole frame — every span drawn as the trapezium it really is, over what has been plotted so far',CYAN)
picks=[('start','the screen'),('close-1','wall 1'),('close-2','wall 2'),('close-4','wall 4'),
       ('close-6','wall 6'),('close-8','wall 8'),('close-10','wall 10'),('final','end of frame')]
fw=169; fh=fw*160/256
for i,(tag,cap) in enumerate(picks):
    s=sh[tag]; x=88+i*(fw+10); yy=Y3+56
    o+=screen(x,yy,fw)
    o+=trapezia(x,yy,fw,s['spans'],PH,sw=1.0)
    o+=geom(x,yy,fw,GHOST,col=mix(HEAD,'#060907',.90),sw=.7)
    o+=geom(x,yy,fw,s['lines'],col=HEAD,sw=1.2)
    o.append(t(x,yy-10,cap,10.4,HEAD,MONO,'bold'))
    o.append(t(x,yy+fh+16,f"{len(s['spans'])} span"+('' if len(s['spans'])==1 else 's'),10.2,PH_HI,MONO,'bold'))
    note=(f"closed [{s['lo']},{s['hi']})" if 'lo' in s else ('one span, 0..256' if tag=='start' else 'nothing open'))
    o.append(t(x,yy+fh+30,f"{s['cyc']//1000}k cyc · {note}",9.5,MUTE,MONO))
o.append(t(88,Y3+212,'It is born as one span, the whole screen. Portals cut it into pieces, solid walls delete the pieces behind them, equal neighbours merge back together. Twelve wall',10.4,TXT,MONO))
o.append(t(88,Y3+228,'closes and one object pass later there is nothing open left, so the traversal stops early: 293,676 cycles for this view, and the rest of the tree is never visited.',10.4,TXT,MONO))

o+=foot('half-open [lo,hi) everywhere · two compares settle most spans · the trapezoid clip runs only when a boundary genuinely crosses the line · equal neighbours merge once per wall')
open('clipper.svg','w').write(svg(o)); print('ok')
