#!/usr/bin/env python3
"""Per-source-file cycle attribution for one frame — where to point the
grind.  Same PC->line mapping as heatmap.py, aggregated by file."""
import os, sys, collections
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import re, heatmap as H
from symmap import sym

def all_maps(dbg):
    raw = open(dbg).readlines()
    def f(rest): return dict(re.findall(r'(\w+)=("?[^,"]*"?)', rest))
    segs, spans, files = {}, {}, {}
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k == 'file': d = f(rest); files[d['id']] = d['name'].strip('"')
        elif k == 'seg': d = f(rest); segs[d['id']] = int(d['start'], 0)
        elif k == 'span': d = f(rest); spans[d['id']] = (d['seg'], int(d['start']), int(d['size']))
    a2f = {}
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k != 'line': continue
        d = f(rest); fn = files.get(d.get('file'))
        if not fn: continue
        for sid in re.findall(r'span=([\d+]+)', rest):
            for sp in sid.split('+'):
                if sp not in spans: continue
                sg, st, sz = spans[sp]; base = segs.get(sg)
                if base is None: continue
                for a in range(base + st, base + st + sz): a2f[a] = fn
    return a2f

pos = (1133, -3242, 0x90)
a2f = all_maps(os.path.join(ROOT, 'build', 'engine_b0c0.dbg'))
hot, tot = H.run_frame(*pos)
per = collections.Counter()
for pc, c in hot.items():
    per[os.path.relpath(a2f.get(pc, '?'), ROOT) if a2f.get(pc) else '(unmapped: raster/tables)'] += c
print(f'frame {pos}: {tot:,} cycles\n')
print(f"{'file':34}{'cycles':>10}{'%':>7}")
for f, c in per.most_common(16):
    print(f'  {f:32}{c:10,}{100.0*c/tot:6.1f}%')
