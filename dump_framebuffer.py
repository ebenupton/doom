"""Render via bsp_render and dump the framebuffer as ASCII."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from test_bsp_render_frame import setup_wad, setup_view, init_pool, clear_screen, count_pixels
from span_clip_6502 import SpanClip6502

ENTRY_BR_RENDER_FRAME = 0x4815

sc = SpanClip6502()
setup_wad(sc)
setup_view(sc, 1056, -3616, 64)
init_pool(sc)
clear_screen(sc)
sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)

mem = sc.mpu.memory
start = sc.SCREEN_START

# BBC mode 4 framebuffer: 32 columns × 20 char rows × 8 scanlines per row.
# Pixel at (x, y) is at addr = start + (y // 8) * 256 + (x // 8) * 8 + (y & 7).
# Bit (0x80 >> (x & 7)) of that byte.
print(f"Framebuffer ({count_pixels(sc)} pixels):")
for y in range(160):
    row = ""
    for x in range(256):
        addr = start + (y // 8) * 256 + (x // 8) * 8 + (y & 7)
        if mem[addr] & (0x80 >> (x & 7)):
            row += '#'
        else:
            row += ' '
    print(row.rstrip())
