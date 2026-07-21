#!/usr/bin/env python3
"""banked-vs-FLAT framebuffer gate.

Every other banked gate compares the banked engine against ITSELF
(lockstep = model vs bare machine, both banked; vxcache/rotcache = the
same build with a cache on/off) — a banked-vs-flat divergence sails
through all of them. This gate renders the same frames on BOTH builds
and byte-compares the framebuffers.

Born 2026-07-18 from the mask_done fall-through landmine: the flat
build's .segment "ANGX" diversion hid that, in the BANKED link, the
sign-class corner entries sat between mask_done and cp_havepsi — the
load-bearing fall-through entered corner_phi_pp, and once the sd/pa
alias mutated the deltas in place, every N-class miss returned a
wrong-class psi. Flat exact, disc badly under-drawing, EVERY gate
green. (1056,-3244,64) is that reproducer, kept in the list forever.
"""
import os, sys
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from banked_bsp import BankedBspRender

POSITIONS = [
    (1056, -3616, 64),    # spawn
    (1056, -3244, 64),    # the mask_done fall-through reproducer (see banner)
    (1056, -3392, 64),    # mid-walk, past the window line
    (1500, -3700, 0),     # heavy scene
    (1200, -3000, 128),
    (2112, -2368, 35),
    (-486, -3307, 243),   # zero-record portal reproducer
]

rf = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                   dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
rb = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                     dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)

fails = 0
for (px, py, ab) in POSITIONS:
    fz = dw.player_floor(px, py)
    rf.render_frame(px, py, ab, fz)
    rb.render_frame(px, py, ab, fz)
    fb_f = bytes(rf.sc.mpu.memory[0xEA00:0xFE00])
    fb_b = bytes(rb.bm[0x5800:0x6C00])
    diff = sum(1 for a, b in zip(fb_f, fb_b) if a != b)
    tag = 'OK' if diff == 0 else 'MISMATCH'
    print(f'  ({px},{py},{ab}): flat {sum(1 for b in fb_f if b)} lit, '
          f'banked {sum(1 for b in fb_b if b)} lit, {diff} differ  {tag}')
    if diff:
        fails += 1

print(f'BANKEDCMP: {len(POSITIONS)} positions, {fails} mismatched — '
      + ('PASS' if fails == 0 else 'FAIL'))
sys.exit(1 if fails else 0)
