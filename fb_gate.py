#!/usr/bin/env python3
"""Framebuffer byte-exactness gate for rasteriser changes.

The differential regression renders BOTH sides through the same 6502
rasteriser, so a rasteriser change that alters pixels identically on both
sides stays 'green'. This gate pins the actual bytes: capture once before
the change, compare after.

    python3 fb_gate.py capture     # write build/fb_golden/<pos>.bin
    python3 fb_gate.py check       # byte-compare current FBs against them
"""
import os
import sys
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

GOLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'build', 'fb_golden')

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
mode = sys.argv[1] if len(sys.argv) > 1 else 'check'
os.makedirs(GOLD, exist_ok=True)
bad = 0
for (px, py, ab) in C.POSITIONS:
    r.render_frame(px, py, ab, dw.player_floor(px, py))
    fb = bytes(r.sc.mpu.memory[r.sc.SCREEN_START:r.sc.SCREEN_START + r.sc.SCREEN_SIZE])
    path = os.path.join(GOLD, f'{px}_{py}_{ab}.bin')
    if mode == 'capture':
        open(path, 'wb').write(fb)
        print(f'captured {px},{py},{ab}')
    else:
        gold = open(path, 'rb').read()
        n = sum(1 for a, b in zip(gold, fb) if a != b)
        print(f'{px},{py},{ab}: {"IDENTICAL" if n == 0 else f"{n} bytes differ"}')
        bad += (n != 0)
if mode == 'check':
    print('FB GATE:', 'PASS' if not bad else f'FAIL ({bad} positions)')
    sys.exit(1 if bad else 0)
