import sys, math, base64, io
sys.path.insert(0,'/Users/ebenupton/doom/sil'); sys.path.insert(0,'/Users/ebenupton/doom')
exec(open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/lod.py').read())
exec(open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/engine_barrel.py').read())
from PIL import Image
def png(n):
    W,H,_,_,m,p=E.decode_picture(_d,_by[n]); pal=E.load_palette(_d,_by)
    im=Image.new('RGBA',(W,H),(0,0,0,0)); q=im.load()
    for y in range(H):
        for x in range(W):
            if m[y][x]:
                r,g,b=pal[p[y][x]]; q[x,y]=(r,g,b,255)
    bb=io.BytesIO(); im.save(bb,'PNG')
    return W,H,'data:image/png;base64,'+base64.b64encode(bb.getvalue()).decode()
NAMES={'pillar':'Tall techno pillar','barrel':'Barrel','lamp':'Floor lamp'}
# ---- FROZEN viewpoints.  K = D so one pixel is one world unit. -----------
OV={'pillar':(83.2,410.0),'barrel':(41.0,126.0),'lamp':(41.0,152.0)}
NOTE={'pillar':'the viewpoint ELECA0 implies',
      'barrel':"player eye 41 — BAR1A0's own fit puts the eye level with its "
               "middle, where no lid is visible",
      'lamp':'player eye 41 — COLUA0 implies no usable viewpoint'}
def ov_lines(n,lod):
    ze,D = OV[n]; o=OBJ[n]
    cfg(n)                                  # per-object L1 configuration
    return build_lod(Stack(o['bands'],o['h'],ze,D,D,lod),lod), None
# ARMED LINES BOLD: twice the weight of a plain draw, as well as the colour.
def emit(L,X,Y,o):
    for t,col,wd in (('b','var(--line)',1.5),('r','var(--line)',1.5),
                     ('a','var(--armed)',3.4)):
        o.append(f'<g stroke="{col}" stroke-width="{wd}" fill="none" '
                 f'stroke-linecap="round" stroke-linejoin="round">')
        for (ax,ay),(bx,byy),tt in [l for l in L if l[2]==t]:
            o.append(f'<line x1="{X(ax):.2f}" y1="{Y(ay):.2f}" x2="{X(bx):.2f}" y2="{Y(byy):.2f}"/>')
        o.append('</g>')
def draw(L, sc, sprite=None, pad=3):
    xs=[p[0] for l in L for p in l[:2]]; ys=[p[1] for l in L for p in l[:2]]
    lo,hi = min(xs), max(xs)
    if sprite: lo,hi = min(lo,-sprite[0]/2.0), max(hi,sprite[0]/2.0)
    x0,x1,y0 = lo-pad, hi+pad, min(ys)-pad
    h = max(max(ys)-min(ys), sprite[1] if sprite else 0)+2*pad
    W,Hp=(x1-x0)*sc, h*sc
    X=lambda v:(v-x0)*sc; Y=lambda v:(v-y0)*sc
    o=[f'<svg viewBox="0 0 {W:.1f} {Hp:.1f}" width="{W:.0f}" height="{Hp:.0f}" '
       f'role="img" aria-label="art"><rect width="{W:.1f}" height="{Hp:.1f}" fill="none"/>']
    if sprite:
        sw,sh,uri = sprite
        o.append(f'<image href="{uri}" x="{X(-sw/2.0):.2f}" y="{Y(min(ys)):.2f}" '
                 f'width="{sw*sc:.2f}" height="{sh*sc:.2f}" '
                 f'style="image-rendering:pixelated" opacity=".9"/>')
    emit(L,X,Y,o); o.append('</svg>'); return '\n'.join(o)

SC={'pillar':4.2,'barrel':7.6,'lamp':5.6}
def cell(svg,title,sub):
    return (f'<figure><div class="plate">{svg}</div><figcaption><b>{title}</b>'
            f'<span>{sub}</span></figcaption></figure>')
ROWS=''
for n in ('pillar','barrel','lamp'):
    W,H,uri = png(OBJ[n]['lump']); sc=SC[n]; cells=''
    for lod in (0,1):
        L,_ = ov_lines(n,lod)
        mg=len({round(abs(p[0]),4) for l in L for p in l[:2]})
        na=sum(1 for l in L if l[2]=='a')
        cells += cell(draw(L,sc,(W,H,uri)), f'L{lod} on sprite',
                      f'{len(L)} lines · {na} armed · {mg} |x|')
        cells += cell(draw(L,sc), f'L{lod} alone', f'{2*mg} obj_X slots')
    if n=='barrel':
        # The engine templates at the sizes they ACTUALLY run at.  OCT is
        # selected only when a >= OBJ_LOD_A = 12, i.e. H >= 33; H = 85 is a
        # real capture from walking to 48 units off the barrel at (1312,-3264),
        # and this reconstruction is line-for-line identical to what the
        # engine's own obj_X / obj_Y / OBJ_ART produced there.
        cells += cell(draw([(p,q,'a' if t=='r' else 'b') for p,q,t in engine_oct(85)], 2.9), 'engine OCT',
                      'H = 85, a = 31 — 17 lines · 3 |x|')
        cells += cell(draw([(p,q,'a' if t=='r' else 'b') for p,q,t in engine_hex(31)], sc), 'engine HEX',
                      'H = 31, a = 11 — 11 lines · 2 |x|')
    ROWS += (f'<h3 style="margin-top:1.8rem">{NAMES[n]}</h3>'
             f'<p class="muted" style="font-size:.85rem;margin:.2rem 0 .7rem">'
             f'{NOTE[n]} — eye {OV[n][0]:.0f}, D = {OV[n][1]:.0f}, K = D.</p>'
             f'<div class="row">{cells}</div>')

# ---- GEOMETRY TABLES -----------------------------------------------------
exec(open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/tables.py').read().split("if __name__")[0])
BANDS='<table><thead><tr><th>object</th><th>h</th><th>band</th><th>r</th>'\
      '<th>z₀</th><th>z₁</th></tr></thead><tbody>'
for n in ('pillar','barrel','lamp'):
    o=OBJ[n]
    for i,(r,z0,z1) in enumerate(reversed(o['bands'])):
        BANDS+=(f'<tr><td>{NAMES[n] if i==0 else ""}</td>'
                f'<td>{o["h"]:.0f if False else o["h"]:.0f}</td>' if False else
                f'<tr><td>{NAMES[n] if i==0 else ""}</td><td>{o["h"]:.0f}</td>'
                f'<td>{["cap","shaft","plinth"][i] if n=="pillar" else (["column","step","base"][i] if n=="lamp" else "body")}</td>'
                f'<td>{r:.3f}</td><td>{z0:g}</td><td>{z1:g}</td></tr>')
BANDS+='</tbody></table>'
GEO=''
for n in ('pillar','barrel','lamp'):
    for lod in (0,1):
        t=tables(n,lod)
        xr=' · '.join(f'<b>{i}</b> {sx}' for i,sx in t['XL'])
        yr=' · '.join(f'<b>{i}</b> {sy}' for i,sy in t['YL'])
        rows=''.join(f'<tr{" class=arm" if arm else ""}><td>{i+1}</td><td>{x1}</td>'
                     f'<td>{y1}</td><td>{x2}</td><td>{y2}</td>'
                     f'<td>{"ARMED" if arm else ""}</td></tr>'
                     for i,(x1,y1,x2,y2,arm) in enumerate(t['lines']))
        GEO+=(f'<h4 style="margin:1.4rem 0 .4rem">{NAMES[n]} — L{lod}</h4>'
              f'<p class="muted" style="font-size:.8rem;margin:0 0 .5rem">'
              f'{t["nline"]} lines · {len(t["XL"])} x slots · {len(t["YL"])} y slots'
              f'{" · hexagon q = %.4g" % t["q"] if lod==1 else ""}'
              f'{" · flat rims " + str(t["flat"]) if lod==1 and t["flat"] else ""}</p>'
              f'<p style="font:.72rem/1.6 var(--mono);color:var(--muted);max-width:none">'
              f'<b>X</b> &nbsp; {xr}</p>'
              f'<p style="font:.72rem/1.6 var(--mono);color:var(--muted);max-width:none">'
              f'<b>Y</b> &nbsp; {yr}</p>'
              f'<div class="scroll"><table><thead><tr><th>#</th><th>x₁</th><th>y₁</th>'
              f'<th>x₂</th><th>y₂</th><th></th></tr></thead><tbody>{rows}</tbody></table></div>')

CSS=open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/pillar.html').read()
CSS=CSS[CSS.index('<style>'):CSS.index('</style>')+8]
HTML=f'''<title>Billboard art — overlays and bare geometry</title>
{CSS}
<style>.row{{display:flex;gap:1.6rem;flex-wrap:wrap;align-items:flex-end}}
.row figcaption{{text-align:center;align-items:center}}</style>
<div class="wrap">
<header>
  <p class="eyebrow">Billboard art · frozen geometry</p>
  <h1>On the sprite, and on its own</h1>
  <p class="lede">Each object at both levels of detail, overlaid and bare, so
  the geometry can be read without the sprite interfering. Armed lines drawn
  bold. The barrel carries the two templates the engine ships today for
  comparison.</p>
</header>

<section>
  <h2>The lamp’s LOD, pulled in to 20 lines</h2>
  <p>Its L1 hexagon had its inner vertex at the dodecagon’s
  <code>a₂ = 0.7321</code>, which sits <em>outside</em> the base disc’s
  occlusion cut at <code>7.5/11.5 = 0.652</code>. So the cut fell in the
  middle of a segment and split the arc into four pieces per rim instead of
  two — including a pair of 0.9-unit stubs where the curve disappears behind
  the step. Pulling the vertex in to <b>q = 0.65</b>, x and y together so the
  hexagon stays symmetric, puts the cut on the vertex: the middle segment is
  dropped whole and the stubs are gone. That is 24 → 22.</p>
  <p>The last pair is the column’s top rim. It sits seven units above the eye
  and its ellipse is <b>0.15 px deep</b> at the size the LOD comes in, and
  only flatter beyond — so it draws as one line rather than three. Chosen
  once at the switch size and fixed, because the art is a static template and
  the line count must not drift with distance. <b>20 lines, 5 |x|, 10
  slots</b>, down from 24 / 6 / 12.</p>
  <p>Two things had to follow: the rim inset uses <code>q</code> rather than
  a₂ once the hexagon moves, and a flat rim has no vertical edge pair so the
  side meets it at the rim line itself. Both showed up as extent errors of a
  tenth of a pixel, which is exactly what that assertion is for. The pillar
  and barrel are untouched — 30/22 and 17/11 at every distance.</p>
</section>

<section>
  <h2>The armed lines were wrong</h2>
  <p>I had been marking the <em>interior rim</em> lines — where a visible top
  or bottom face meets its wall — as armed. The armed run is the fused
  authority run, and it has to be <b>the topmost line at every x</b>.</p>
  <p>Getting that right is not simply "arm the top rim's upper arc": a band's
  top arc is topmost only across the width that no <em>higher</em> band
  covers, and the covering band need not be the adjacent one. The pillar's
  plinth has a fully exposed top rim, but the cap is the same radius and far
  above it, so none of that arc is topmost and none of it is armed. The lamp
  is the opposite case — its column is the highest band but the narrowest, so
  the armed run is three pieces: the column's top arc across the middle, then
  the step's top-rim stubs, then the base's, each taking over exactly where
  the band above it runs out of width.</p>
  <p>It is asserted now rather than eyeballed: sample x across the figure,
  find the topmost line, require it to be armed. Holds for all three objects
  at both tiers at three distances — and the engine's own OCT and HEX pass
  the same check, which is the cross-validation that the rule is the right
  one.</p>
</section>

<section>
  <h2>Frozen</h2>
  <p>Geometry and viewpoints are fixed and will not move except when you say
  so. Overlays use <code>K = D</code>, so the projection is one pixel per
  world unit and the vectors sit on the sprite at its own scale. <b>Eye
  height is the engine’s 41 throughout</b> — the sprite-derived eye is gone,
  it was measuring nothing. <b>The pillar is unchanged</b> at eye 83.2 /
  D 410; the barrel and lamp are at eye 41, D 126 and 152.</p>
</section>

<section>
  <h2>The rows</h2>
  {ROWS}
  <div class="key">
    <span><i style="background:var(--line);height:.18rem"></i>outline</span>
    <span><i style="background:var(--armed);height:.34rem"></i>armed / recorded</span>
  </div>
</section>

<section>
  <h2>The barrel against what actually ships</h2>
  <p><b>The engine OCT I drew last time was wrong, and the fault was mine
  twice over.</b> I checked it by reading the real thing rather than the
  source: breaking at <code>obj_stamp</code>, pulling <code>obj_X</code>,
  <code>obj_Y</code> and the <code>OBJ_ART</code> bytes out of a live render,
  and walking to 48 units off the barrel at (1312,−3264) to catch a
  high-resolution stamp.</p>
  <p>The reconstruction was structurally right — one arithmetic slip, the
  engine computes <code>a = (H·k + 32) ≫ 6</code>, <b>rounded</b>, where I
  had truncated. Fixed, it is now <b>identical line for line</b> to the
  captured template. The warp came from something else: I evaluated it at
  H = 32, where <code>b = 2</code> makes <code>b₂ = b₃ = 1</code> and the lid
  ladder collapses to <code>[0,1,1,3,3,4]</code> — two pairs of coincident
  vertices. And H = 32 is outside OCT's domain anyway: it is selected only
  when <code>a ≥ OBJ_LOD_A = 12</code>, i.e. H ≥ 33. So I drew the
  high-resolution template at a size where the engine would never use it,
  in arithmetic that degenerates there. At its real operating point it is
  the clean ellipse you describe — lid ladder <code>[0,1,4,6,9,10]</code> at
  H = 85.</p>
  <p>The dubiousness about HEX was warranted for the same reason. It is shown
  at H = 31, inside its own domain.</p>
  <div class="callout">
    <p><b>A finding worth having:</b> across the whole 18-pose corpus,
    <b>no barrel ever reaches OCT</b> — every stamp is HEX, because
    <code>a</code> never gets to 12. The high-resolution template only runs
    within about 64 units of the player.</p>
  </div>
  <p class="muted" style="font-size:.85rem">The two engine figures are drawn
  at their own operating sizes, so they are not to the same scale as the
  four frozen ones. A like-for-like comparison would mean re-rendering the
  new barrel at a = 31, which is a viewpoint change — say the word and I
  will add it.</p>
</section>
<section>
  <h2>The geometry</h2>
  <h3>3D — the objects</h3>
  <p>Each is a stack of coaxial cylinders, read off the sprite's flat runs at
  one pixel per world unit. z measured up from the object's base.</p>
  <div class="scroll">{BANDS}</div>
  <h3 style="margin-top:1.6rem">2D — the templates</h3>
  <p>Every rim's ellipse is <code>b = a·|z − 41|/D</code> with its own z, so
  the y ladder carries one entry per rim per arc depth. Offsets are in units
  of that rim's own b, at the dodecagon's <code>a₃ = 0.268</code>,
  <code>q</code> and <code>1</code>. Entries shown as raw px are occlusion
  cuts that land between vertices.</p>
  {GEO}
  <div class="callout" style="margin-top:1.4rem">
    <p><b>The ladder sizes are the gate on landing this.</b> The engine has
    <code>obj_X</code> = 6 and <code>obj_Y</code> = 12. The barrel fits
    outright (6 and 9). The pillar fits in x but wants <b>18 y</b>. The lamp
    wants <b>18 x and 20 y</b> at L0, 10 and 13 at L1 — because its band
    radii (11.5, 7.5, 5.5) are not on the vertex ladder, so its occlusion
    cuts land between vertices and each one mints a new x value.</p>
    <p>Snapping the lamp's radii to <code>a, q·a, q²·a</code> = 11.5, 7.48,
    4.86 would put every cut on a vertex and cut its L1 to four x
    magnitudes. 7.48 against the sprite's 7.5 is free; 4.86 against 5.5 is a
    12% change to the column. That is a geometry change, so it is yours to
    call rather than mine.</p>
  </div>
</section>

<footer class="muted" style="font-size:.8rem;border-top:1px solid var(--rule);padding-top:1.2rem">
  Overlays at K = D. Engine templates evaluated at H = 32 with k = 23.
</footer>
</div>'''
open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/pillar.html','w').write(HTML)
print('wrote',len(HTML))
