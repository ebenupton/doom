#!/usr/bin/env python3
"""memmap_html — render the whole address map as one self-contained HTML page.

    python3 tools/memmap_html.py [--mapshuf FILE] [-o build/memmap.html]

Strips: FLAT main+high, BANKED main (+window note), sideways banks 4/6/7.
Sources, all mechanical:
  - ld65 map files (build/engine_b{0,1}c0.map): CLAIMED segments.
  - tools/mapshuf.py output: FREE runs (claimed∩touched complement),
    one-build-only "trap" runs, and the linker-region budget table.
    Pass a captured file with --mapshuf, else mapshuf runs fresh (slow:
    it renders the 19-pose corpus).
  - abi.py + src/layout.inc equates: named landmarks (loader-poked
    planes and runtime state no linker segment claims).
Everything not claimed/free/named renders as untracked runtime space.
"""
import argparse, os, re, subprocess, sys, html, datetime

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

# ---------------------------------------------------------------- sources --
def parse_ld65(path):
    segs, on = [], False
    for line in open(path):
        if line.startswith('Segment list'): on = True; continue
        m = re.match(r'^(\S+)\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})', line)
        if on and m:
            segs.append((m.group(1), int(m.group(2), 16), int(m.group(4), 16)))
    return segs

def parse_mapshuf(text):
    sec, out = None, {}
    regions = {'FLAT': [], 'BANKED': []}
    for line in text.splitlines():
        if line.startswith('FLAT LINKER'): sec = 'RF'; continue
        if line.startswith('BANKED LINKER'): sec = 'RB'; continue
        if line.startswith('SHARED main'): sec = 'shared'; continue
        if line.startswith('FLAT only'): sec = 'flatonly'; continue
        if line.startswith('BANKED only'): sec = 'bankedonly'; continue
        if line.startswith('FLAT $8000'): sec = 'flathigh'; continue
        if line.startswith('BANKED sideways'): sec = 'banks'; continue
        if sec in ('RF', 'RB'):
            m = re.match(r'\s+(\S+)\s+\$([0-9A-F]+)\+(\d+)\s+used\s+(\d+)\s+FREE\s+(\d+)', line)
            if m:
                regions['FLAT' if sec == 'RF' else 'BANKED'].append(
                    (m.group(1), int(m.group(2), 16), int(m.group(3)),
                     int(m.group(4)), int(m.group(5))))
            continue
        m = re.match(r'\s+\$([0-9A-F]{4})-\$([0-9A-F]{4})\s+(\d+) B', line)
        if m and sec:
            out.setdefault(sec, []).append((int(m.group(1), 16), int(m.group(2), 16)))
        m = re.match(r'\s+bank (\d):\s+(.*)', line)
        if m and sec == 'banks':
            runs = [(int(a, 16), int(a, 16) + int(n) - 1) for a, n in
                    re.findall(r'\$([0-9A-F]{4})\+(\d+)', m.group(2))]
            out.setdefault('bank' + m.group(1), []).extend(runs)
    return out, regions

_LM_SKIP = re.compile(r'(_LEN|_SIZE|_STRIDE|_NUM|_DEN|FONT|_MASK)$')
def parse_abi():
    lm = []   # (addr_banked_or_shared, addr_flat_or_None, name)
    for line in open(os.path.join(ROOT, 'abi.py')):
        m = re.match(r'^([A-Z][A-Z0-9_]+) = 0x([0-9A-Fa-f]+)', line)
        if not m or _LM_SKIP.search(m.group(1)): continue
        v = int(m.group(2), 16)
        if 0x100 <= v <= 0xFFFF:
            lm.append((m.group(1), v))
    d = dict(lm)
    out = []
    for n, v in lm:
        if n.endswith('_FLAT'): continue
        out.append((n, v, d.get(n + '_FLAT')))
    return out

def parse_layout():
    src = open(os.path.join(ROOT, 'src/layout.inc')).read()
    out, branch = [], None
    for line in src.splitlines():
        s = line.strip()
        if s.startswith('.if ::BANKED'): branch = 'b'; continue
        if s.startswith('.else'): branch = 'f' if branch == 'b' else branch; continue
        if s.startswith('.endif'): branch = None; continue
        m = re.match(r'^([A-Z][A-Z0-9_]+)\s*=\s*\$([0-9A-F]+)\b', s)
        if m and not _LM_SKIP.search(m.group(1)):
            out.append((m.group(1), int(m.group(2), 16), branch))
    merged = {}
    for n, v, br in out:
        e = merged.setdefault(n, {})
        e['b' if br in (None, 'b') else 'f'] = v
        if br is None: e['f'] = v
    return [(n, e.get('b'), e.get('f')) for n, e in merged.items()
            if (e.get('b') or e.get('f') or 0) >= 0x100]

# ---------------------------------------------------------------- render ---
CLS = {'seg': '#4f83c2', 'segd': '#7a5fa8', 'free': '#3fae62',
       'trap': '#c9973a', 'bg': '#20242b'}
SEG_DATA = {'CLIPF', 'VPLOTF', 'VPLOTC', 'HUD', 'BANKC', 'LDATA', 'SEL', 'PMBF'}

def strip_html(title, lo, hi, blocks, marks, px_per_kb=16.0):
    span = hi - lo + 1
    H = span / 1024.0 * px_per_kb
    out = [f'<div class="strip"><h3>{title}</h3><div class="col" style="height:{H:.0f}px">']
    for a, b, cls, name, tip in sorted(blocks):
        a2, b2 = max(a, lo), min(b, hi)
        if b2 < a2: continue
        top = (a2 - lo) / span * H
        h = max(1.0, (b2 - a2 + 1) / span * H)
        label = html.escape(name) if h >= 9 else ''
        out.append(
            f'<div class="blk {cls}" style="top:{top:.1f}px;height:{h:.1f}px" '
            f'data-tip="{html.escape(tip)}">{label}</div>')
    for k in range(lo, hi + 1, 0x1000):
        top = (k - lo) / span * H
        out.append(f'<div class="tick" style="top:{top:.1f}px"><span>{k >> 12:X}000</span></div>')
    out.append('</div><div class="marks">')
    for a, name in sorted(marks):
        if not (lo <= a <= hi): continue
        top = (a - lo) / span * H
        out.append(f'<div class="mark" style="top:{top:.1f}px" '
                   f'data-tip="{html.escape(f"{name} ${a:04X}")}">'
                   f'<i></i>{html.escape(name)}</div>')
    out.append('</div></div>')
    return ''.join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mapshuf'); ap.add_argument('-o', default='build/memmap.html')
    args = ap.parse_args()
    if args.mapshuf:
        ms_text = open(args.mapshuf).read()
    else:
        ms_text = subprocess.run([sys.executable, os.path.join(ROOT, 'tools/mapshuf.py')],
                                 capture_output=True, text=True).stdout
    runs, regions = parse_mapshuf(ms_text)
    segs = {b: parse_ld65(os.path.join(ROOT, f'build/engine_b{b}c0.map')) for b in (0, 1)}
    lms = parse_abi() + parse_layout()

    def seg_blocks(b):
        out = []
        for name, start, size in segs[b]:
            cls = 'segd' if name in SEG_DATA else 'seg'
            out.append((start, start + size - 1, cls, name,
                        f'{name} ${start:04X}-${start + size - 1:04X}  {size} B (linked)'))
        return out

    def free_blocks(keys, trap=()):
        out = []
        for k in keys:
            for a, b in runs.get(k, []):
                out.append((a, b, 'free', '', f'FREE ${a:04X}-${b:04X}  {b - a + 1} B'))
        for k in trap:
            for a, b in runs.get(k, []):
                out.append((a, b, 'trap', '',
                            f'free THIS BUILD ONLY ${a:04X}-${b:04X}  {b - a + 1} B (trap)'))
        return out

    marks_f = [(f if f is not None else bb, n) for n, bb, f in lms
               if (f if f is not None else bb) is not None]
    marks_b = [(bb, n) for n, bb, f in lms if bb is not None]

    body = ['<div class="row">']
    body.append(strip_html('FLAT $0000-$7FFF', 0x0000, 0x7FFF,
                seg_blocks(0) + free_blocks(['shared'], ['flatonly']),
                [m for m in marks_f if m[0] < 0x8000]))
    body.append(strip_html('FLAT $8000-$FFFF', 0x8000, 0xFFFF,
                seg_blocks(0) + free_blocks(['flathigh']),
                [m for m in marks_f if m[0] >= 0x8000]))
    body.append(strip_html('BANKED $0000-$7FFF', 0x0000, 0x7FFF,
                seg_blocks(1) + free_blocks(['shared'], ['bankedonly']),
                [m for m in marks_b if m[0] < 0x8000]))
    win_marks = [m for m in marks_b if 0x8000 <= m[0] < 0xC000]
    for bank in ('4', '6', '7'):
        fr = runs.get('bank' + bank, [])
        infree = lambda a: any(x <= a <= y for x, y in fr)
        # a window symbol is shown on a bank only when that bank's corpus
        # occupancy doesn't call its address free (cheap bank attribution;
        # a symbol untouched by the corpus may still show on several banks)
        body.append(strip_html(f'BANK {bank} ($8000 window)', 0x8000, 0xBFFF,
                    ([(s, s + z - 1, 'seg', n, f'{n} ${s:04X}+{z} (linked)')
                      for n, s, z in segs[1] if 0x8000 <= s < 0xC000] if bank == '6' else [])
                    + free_blocks([f'bank{bank}']),
                    [m for m in win_marks if not infree(m[0])]))
    body.append('</div>')

    reg_rows = []
    for bld in ('FLAT', 'BANKED'):
        for name, start, budget, used, free in regions[bld]:
            reg_rows.append(f'<tr><td>{bld}</td><td>{name}</td>'
                            f'<td>${start:04X}</td><td>{budget}</td>'
                            f'<td>{used}</td><td class="{ "hot" if free < 16 else "" }">{free}</td></tr>')

    when = datetime.date.today().isoformat()
    page = f"""<!doctype html><html><head><meta charset="utf-8">
<title>doom memory map</title><style>
:root {{ color-scheme: dark }}
body {{ background:#14161a; color:#c8cdd4; font:13px/1.4 "SF Mono",Menlo,monospace;
       margin:20px }}
h1 {{ font-size:16px; letter-spacing:.06em }} h1 small {{ color:#6b7280; font-weight:normal }}
.row {{ display:flex; gap:26px; align-items:flex-start; flex-wrap:wrap }}
.strip h3 {{ font-size:12px; margin:0 0 6px; color:#9aa3ad }}
.strip {{ display:flex; flex-direction:column }}
.strip > div {{ display:flex }} .col {{ position:relative; width:130px; background:{CLS['bg']};
       border:1px solid #333a44; flex:none }}
.blk {{ position:absolute; left:0; right:0; overflow:hidden; font-size:9px;
       padding-left:4px; color:#e8ecf1; border-top:1px solid rgba(0,0,0,.35) }}
.blk.seg {{ background:{CLS['seg']} }} .blk.segd {{ background:{CLS['segd']} }}
.blk.free {{ background:{CLS['free']} }} 
.blk.trap {{ background:repeating-linear-gradient(45deg,{CLS['trap']},{CLS['trap']} 4px,#8a6520 4px,#8a6520 8px) }}
.tick {{ position:absolute; left:-40px; width:36px; text-align:right; color:#5b6470;
       font-size:9px; border-bottom:0 }} .tick span {{ position:relative; top:-6px }}
.marks {{ position:relative; width:120px; flex:none }}
.mark {{ position:absolute; font-size:9px; color:#8fa8c0; white-space:nowrap; left:4px }}
.mark i {{ display:inline-block; width:8px; border-top:1px solid #8fa8c0;
       vertical-align:middle; margin-right:3px }}
.strip .col {{ margin-left:42px }}
table {{ border-collapse:collapse; margin-top:28px }} td,th {{ border:1px solid #333a44;
       padding:3px 10px; font-variant-numeric:tabular-nums }} th {{ color:#9aa3ad;
       text-align:left }}
td.hot {{ color:#e05555; font-weight:bold }}
.legend span {{ display:inline-block; margin-right:18px }}
.legend i {{ display:inline-block; width:12px; height:12px; vertical-align:-2px;
       margin-right:5px }}
#tip {{ position:fixed; display:none; background:#0c0e11; color:#dfe5ec;
       border:1px solid #3c4552; padding:5px 9px; font-size:11px; pointer-events:none;
       z-index:9; white-space:pre }}
</style></head><body>
<h1>DOOM address map <small>— {when}, mechanical (ld65 + mapshuf + abi/layout)</small></h1>
<p class="legend">
 <span><i style="background:{CLS['seg']}"></i>linked code</span>
 <span><i style="background:{CLS['segd']}"></i>linked data/aux region</span>
 <span><i style="background:{CLS['free']}"></i>free (both builds where shared)</span>
 <span><i style="background:{CLS['trap']}"></i>free in ONE build (trap)</span>
 <span><i style="background:{CLS['bg']};border:1px solid #333a44"></i>untracked runtime / loader-poked</span></p>
{''.join(body)}
<table><tr><th>build</th><th>region</th><th>start</th><th>budget</th><th>used</th><th>free</th></tr>
{''.join(reg_rows)}</table>
<div id="tip"></div><script>
const tip = document.getElementById('tip');
document.addEventListener('mousemove', e => {{
  const t = e.target.closest('[data-tip]');
  if (t) {{ tip.style.display = 'block'; tip.textContent = t.dataset.tip;
    tip.style.left = (e.clientX + 14) + 'px'; tip.style.top = (e.clientY + 10) + 'px'; }}
  else tip.style.display = 'none';
}});
</script></body></html>"""
    outp = os.path.join(ROOT, args.o)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    open(outp, 'w').write(page)
    print('wrote', outp)

if __name__ == '__main__':
    main()
