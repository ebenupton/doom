#!/usr/bin/env python3
"""Verify framebuffer hashes match baseline after ASM changes."""
import os, sys, hashlib
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from fe6502 import Frontend6502

BASELINE = {
    'E':     '779e05755d0d74d8',
    'N':     'c2ffa7eb2b700042',
    'NE':    '227974d94168c33a',
    'SE':    'c21d01f39214535c',
    'moved': '5cf4a84694628314',
}
POSITIONS = [(1056,-3616,64,'E'), (1056,-3616,0,'N'), (1056,-3616,32,'NE'),
             (1056,-3616,96,'SE'), (1200,-3300,64,'moved')]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)
all_pass = True
total_cyc = 0
for px,py,ab,name in POSITIONS:
    fz = dw.player_floor(px,py)
    cyc = fe.render_frame(px, py, ab, fz)
    fb = bytes(fe.mpu.memory[0x5800:0x6C00])
    h = hashlib.sha256(fb).hexdigest()[:16]
    ok = h == BASELINE[name]
    total_cyc += cyc
    status = 'OK' if ok else f'FAIL (got {h})'
    print(f'  {name:6s}  {cyc:>9,} cyc  {status}')
    if not ok: all_pass = False

print(f'\n  Total: {total_cyc:>9,} cyc')
print('  ALL MATCH' if all_pass else '  MISMATCH DETECTED')
sys.exit(0 if all_pass else 1)
