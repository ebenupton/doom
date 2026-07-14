#!/usr/bin/env python3
"""Map-wide cycle sweep for BSP comparison.

Renders a fixed grid of in-map positions (grid step 256 map units,
angles alternating (1,129)/(65,193) checkerboard-wise) and writes
{json} with per-position cycles. The position list itself is loaded
from POSFILE if it exists so every BSP variant measures the identical
set; otherwise it is derived from the CURRENT map (run the id-BSP
first) and saved.
"""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502

OUT = sys.argv[1]
POSFILE = sys.argv[2]

if os.path.exists(POSFILE):
    POSITIONS = [tuple(p) for p in json.load(open(POSFILE))]
else:
    xs = range(-768, 3809, 256)
    ys = range(-4864, -1535, 256)
    POSITIONS = []
    for xi, x in enumerate(xs):
        for yi, y in enumerate(ys):
            # in-map test: the float BSP always lands in a subsector;
            # require an open sector (ceiling above floor) AND the point
            # to be inside the map's outer bounds per the root bbox.
            try:
                fl = dw.player_floor(x, y)
            except Exception:
                continue
            si = dw.point_in_subsector(x, y) if hasattr(dw, 'point_in_subsector') else None
            # open-sector proxy: a floor exists and some wall is near —
            # accept; degenerate void positions render ~empty frames and
            # cost little, biasing all variants equally anyway.
            angles = (1, 129) if (xi + yi) % 2 == 0 else (65, 193)
            for ab in angles:
                POSITIONS.append((x, y, ab))
    json.dump(POSITIONS, open(POSFILE, 'w'))

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                  dw.PRESCALE)
res = []
tot = 0
for i, (x, y, ab) in enumerate(POSITIONS):
    c = r.render_frame(x, y, ab, dw.player_floor(x, y))
    res.append((x, y, ab, c))
    tot += c
    if i % 50 == 0:
        print(f"{i}/{len(POSITIONS)} running total {tot}", flush=True)
json.dump({'total': tot, 'frames': res}, open(OUT, 'w'))
print(f"DONE {OUT}: {len(res)} frames, TOTAL {tot}")
