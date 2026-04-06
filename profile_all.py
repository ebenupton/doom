#!/usr/bin/env python3
"""Profile all 5 verify_exact positions and report top cycle consumers."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502, format_profile, PROFILE_CATEGORIES

POSITIONS = [
    (1056, -3616, 64, "spawn East"),
    (1056, -3616, 0,  "spawn North"),
    (1056, -3616, 32, "spawn NE"),
    (1056, -3616, 96, "spawn SE"),
    (1200, -3300, 64, "moved East"),
]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)

total_buckets = {}
total_cycles_all = 0
for px, py, ab, name in POSITIONS:
    fz = dw.player_floor(px, py)
    cmds, cyc, prof = fe.profile_frame(px, py, ab, fz)
    total_cycles_all += cyc
    for n, c in prof:
        total_buckets[n] = total_buckets.get(n, 0) + c
    print(f"  {name:15s}  cmds={len([c for c in cmds if c[0] in 'SP']):>3d}  cyc={cyc:>8d}")

print(f"\nTotal across {len(POSITIONS)} positions: {total_cycles_all} cycles\n")

ranked = sorted(total_buckets.items(), key=lambda kv: -kv[1])
print("Top 20 functions by total cycles:")
for name, cyc in ranked[:20]:
    pct = 100.0 * cyc / total_cycles_all
    print(f"  {name:30s} {cyc:>9d}  {pct:>5.1f}%")
