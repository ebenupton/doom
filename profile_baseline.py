#!/usr/bin/env python3
"""Capture the 6502 front-end cycle profile at a fixed test position.

Used as the baseline regression check across the optimisation phases.
Outputs a single-line summary plus the full per-function breakdown.
"""
import os, sys, time
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502, format_profile

# Standard test positions (E1M1)
POSITIONS = [
    (1056, -3616, 64, "E1M1 start East"),
    (1056, -3616, 0,  "E1M1 start North"),
    (1056, -3616, 32, "E1M1 start NE"),
    (1056, -3616, 96, "E1M1 start SE"),
    (1200, -3300, 64, "moved East"),
]

def main():
    fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                       dw.packed_bbox_table, dw.packed_layout)

    total_cycles = 0
    for px, py, ab, name in POSITIONS:
        fz = dw.player_floor(px, py)
        t0 = time.time()
        cmds, cycles, profile = fe.profile_frame(px, py, ab, fz)
        t1 = time.time()
        n_segs = sum(1 for c in cmds if c[0] in 'SP')
        total_cycles += cycles
        print(f"{name:25s} {cycles:>10} cyc  {n_segs:3d} segs  {t1-t0:.1f}s wall")

    print(f"\n{'TOTAL':25s} {total_cycles:>10} cyc across {len(POSITIONS)} positions")

    # Detailed profile of the first position
    print("\n" + "=" * 60)
    print(f"Detailed: {POSITIONS[0][3]}")
    print("=" * 60)
    fz = dw.player_floor(POSITIONS[0][0], POSITIONS[0][1])
    _, cycles, profile = fe.profile_frame(POSITIONS[0][0], POSITIONS[0][1],
                                            POSITIONS[0][2], fz)
    print(format_profile(profile, cycles))

if __name__ == '__main__':
    main()
