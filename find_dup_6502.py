#!/usr/bin/env python3
"""Find duplicate lines emitted by the 6502."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502

SCENES = [
    ("S1 E", (1056, -3616, 64)),
    ("N",    (1056, -3616, 0)),
    ("S2 NE",(1056, -3616, 32)),
    ("SE",   (1056, -3616, 96)),
    ("T",    (1200, -3300, 64)),
]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)

def norm(r):
    x1, y1, x2, y2 = r
    if (x1, y1) <= (x2, y2):
        return r
    return (x2, y2, x1, y1)

for name, (px, py, ab) in SCENES:
    fz = dw.player_floor(px, py)
    hw_lines, cyc = fe.render_frame(px, py, ab, fz, capture_lines=True)
    unique = set(map(norm, hw_lines))
    dup_count = len(hw_lines) - len(unique)
    print(f"{name:10s}  drawn={len(hw_lines):3d}  unique={len(unique):3d}  dups={dup_count}")
    if dup_count:
        from collections import Counter
        c = Counter(map(norm, hw_lines))
        for line, count in sorted(c.items()):
            if count > 1:
                print(f"    DUP {line} × {count}")
