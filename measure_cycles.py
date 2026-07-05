#!/usr/bin/env python3
"""Quick suite cycle measure: rebuild + render the 10 baseline positions.
The fast inner loop of the perf grind (full regression before each commit)."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import json
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
tot = 0
per = {}
for (px, py, ab) in C.POSITIONS:
    cyc = r.render_frame(px, py, ab, dw.player_floor(px, py))
    per[f'{px},{py},{ab}'] = cyc
    tot += cyc
try:
    base = json.load(open('baseline.json'))
    old = base.get('total_cycles', 0)
    print(f'TOTAL {tot:,}  ({(tot-old)/old:+.3%} vs baseline {old:,})')
    for k, v in per.items():
        ov = base.get('cycles', {}).get(k)
        if ov and abs(v - ov) > 500:
            print(f'  {k}: {ov:,} -> {v:,} ({(v-ov)/ov:+.2%})')
except FileNotFoundError:
    print(f'TOTAL {tot:,}')
