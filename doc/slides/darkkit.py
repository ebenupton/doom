import base64, io, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fbdec import decode
W, H = 1600, 1131
BG='#080B09'; PANEL='#101614'; EDGE='#1F2C24'; GRID='#16201B'
PH='#5CE08C'; PH_HI='#A6FFCB'; PH_DIM='#2E7A4E'
AMB='#FFB454'; CYAN='#58D8FF'; MAG='#E86A8A'
TXT='#CBD6CB'; MUTE='#7E8F82'; HEAD='#F2F7F2'
SANS='Helvetica Neue, Helvetica, Arial, sans-serif'
MONO='Menlo, Consolas, monospace'

def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def t(x,y,s,size=14,fill=TXT,font=MONO,weight='normal',anchor='start',ls=0,op=1):
    a=f' text-anchor="{anchor}"' if anchor!='start' else ''
    l=f' letter-spacing="{ls}"' if ls else ''
    o=f' opacity="{op}"' if op!=1 else ''
    return f'<text xml:space="preserve" x="{x}" y="{y}" font-family="{font}" font-size="{size}" font-weight="{weight}" fill="{fill}"{a}{l}{o}>{esc(str(s))}</text>'
def r_(x,y,w,h,fill='none',stroke='none',sw=1,rx=0,op=1,dash=None):
    d=f' stroke-dasharray="{dash}"' if dash else ''
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" rx="{rx}" opacity="{op}"{d}/>'
def ln(x1,y1,x2,y2,stroke=EDGE,sw=1,dash=None,op=1,cap='round'):
    d=f' stroke-dasharray="{dash}"' if dash else ''
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}" opacity="{op}"{d}/>'
def panel(x,y,w,h,label=None,accent=PH):
    o=[r_(x,y,w,h,PANEL,EDGE,1,rx=2)]
    if label:
        o.append(r_(x,y,4,h,accent,rx=0,op=.85))
        o.append(t(x+18,y+26,label.upper(),12,accent,MONO,'bold',ls=2.2))
    return o
def img(x,y,w,h,pil,smooth=False):
    b=io.BytesIO(); pil.save(b,'PNG')
    u=base64.b64encode(b.getvalue()).decode()
    st=' image-rendering="optimizeSpeed"' if not smooth else ''
    return f'<image x="{x}" y="{y}" width="{w}" height="{h}"{st} xlink:href="data:image/png;base64,{u}"/>'
def fb_img(x,y,w,fbhex,fg=(96,240,150),alpha=False):
    im=decode(bytes.fromhex(fbhex),fg=fg,alpha=alpha)
    return img(x,y,w,w*160/256,im)
def spanbar(x,y,w,h,spans,open_col=PH,closed=('#14201A')):
    """Draw the real span list as a 256-column occupancy bar."""
    o=[r_(x,y,w,h,closed,EDGE,1,rx=1)]
    for s in spans:
        a,b=s['XSTART'],s['XEND']
        if b<=a: continue
        o.append(r_(x+a/256*w, y, (b-a)/256*w, h, open_col, op=.55))
        o.append(ln(x+a/256*w, y, x+a/256*w, y+h, PH_HI, .8, op=.9))
    return o
def head(title, kicker, sub):
    o=[r_(0,0,W,H,BG)]
    for gy in range(0,H,42): o.append(ln(0,gy,W,gy,GRID,1,op=.5))
    for gx in range(0,W,42): o.append(ln(gx,0,gx,H,GRID,1,op=.5))
    o.append(r_(0,0,W,4,PH,op=.9))
    o.append(t(64,78,kicker.upper(),12.5,AMB,MONO,'bold',ls=3.2))
    o.append(t(64,124,title,40,HEAD,SANS,'bold'))
    o.append(t(64,152,sub,15,MUTE,MONO))
    o.append(ln(64,172,W-64,172,EDGE,1,cap='butt'))
    return o
def foot(s):
    return [ln(64,H-52,W-64,H-52,EDGE,1,cap='butt'), t(64,H-30,s,12.5,MUTE,MONO,ls=.6)]
def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'width="{W}" height="{H}" viewBox="0 0 {W} {H}">'+''.join(body)+'</svg>')

YBIAS = 48
def _ev(x, xlo, den, yl, yr):
    if den == 0: return yl
    return yl + (yr - yl) * (x - xlo) / den
def mix(c1, c2, t):
    """Blend two #rrggbb colours; t=1 returns c2."""
    a=[int(c1[i:i+2],16) for i in (1,3,5)]; b=[int(c2[i:i+2],16) for i in (1,3,5)]
    return '#%02X%02X%02X' % tuple(int(round(a[i]+(b[i]-a[i])*t)) for i in range(3))

def screen(x, y, w, bg='#060907'):
    """The empty 256x160 view a frame is drawn into."""
    return [r_(x, y, w, w*160/256, bg, EDGE, 1)]

def geom(x, y, w, lines, col=HEAD, sw=1.0, op=1.0):
    """The engine's output geometry as IDEAL lines (never rasterised pixels).
    `lines` are (x0,y0,x1,y1) screen coordinates straight off the raster ZP."""
    s = w/256.0
    return [f'<line x1="{x+x0*s:.2f}" y1="{y+y0*s:.2f}" x2="{x+x1*s:.2f}" y2="{y+y1*s:.2f}" '
            f'stroke="{col}" stroke-width="{sw}" stroke-linecap="round" opacity="{op}"/>'
            for (x0,y0,x1,y1) in lines]

def raster(x, y, w, fbhex, col=HEAD, op=1.0):
    """The engine's ACTUAL pixels: the mode-4 framebuffer as it stood at that
    moment, each horizontal run of lit pixels one rect on the 256x160 grid.
    Where geom() draws the ideal line between the plotter's endpoints, this
    shows what the Bresenham stepper really put on the screen."""
    fb = bytes.fromhex(fbhex); sx = w/256.0
    ph = max(sx, 1.0)      # a pixel row never thinner than one slide unit
    out = []
    for cy in range(20):
        for pr in range(8):
            yy = cy*8 + pr
            if yy >= 160: break
            row = 0
            for c in range(32):
                row = (row << 8) | fb[cy*256 + c*8 + pr]
            bits = format(row, '0256b'); px = 0
            while px < 256:
                if bits[px] == '1':
                    q = px
                    while q < 256 and bits[q] == '1': q += 1
                    out.append(f'<rect x="{x+px*sx:.2f}" y="{y+yy*sx:.2f}" width="{(q-px)*sx:.2f}" '
                               f'height="{ph:.2f}" fill="{col}" opacity="{op}"/>')
                    px = q
                else: px += 1
    return out

def trapezia(x, y, w, spans, stroke, fillop=.13, sw=1.3, label=None, only=None, fill=None):
    """Draw the span set as real trapezia over a 256x160 view at (x,y,w):
    a dark solid body in the span's colour, bordered by the bright colour."""
    sx = w / 256.0; sy = (w * 160 / 256) / 160.0
    out = []
    for s in spans:
        a, b = s['XSTART'], s['XEND']
        if b <= a: continue
        if only is not None and not only(s): continue
        ta = _ev(a, s['TXLO'], s['TDEN'], s['TL'], s['TR']) - YBIAS
        tb = _ev(b, s['TXLO'], s['TDEN'], s['TL'], s['TR']) - YBIAS
        ba = _ev(a, s['BXLO'], s['BDEN'], s['BL'], s['BR']) - YBIAS
        bb = _ev(b, s['BXLO'], s['BDEN'], s['BL'], s['BR']) - YBIAS
        pts = [(x+a*sx, y+ta*sy), (x+b*sx, y+tb*sy), (x+b*sx, y+bb*sy), (x+a*sx, y+ba*sy)]
        p = ' '.join(f'{px:.1f},{py:.1f}' for px, py in pts)
        body = fill if fill else mix(stroke, '#040706', .80)
        out.append(f'<polygon points="{p}" fill="{body}" stroke="{stroke}" '
                   f'stroke-width="{sw}" stroke-linejoin="round"/>')
    return out
def scene_line(x, y, w, xl, xr, yl, yr, col, sw=2.4):
    sx = w / 256.0; sy = (w * 160 / 256) / 160.0
    return (f'<line x1="{x+xl*sx:.1f}" y1="{y+(yl-YBIAS)*sy:.1f}" x2="{x+xr*sx:.1f}" '
            f'y2="{y+(yr-YBIAS)*sy:.1f}" stroke="{col}" stroke-width="{sw}" stroke-linecap="round"/>')
