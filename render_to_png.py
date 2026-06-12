"""Render via bsp_render and save the framebuffer as a PNG."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from test_bsp_render_frame import setup_wad, setup_view, init_pool, clear_screen, count_pixels
from span_clip_6502 import SpanClip6502

ENTRY_BR_RENDER_FRAME = 0x4815

px = int(sys.argv[1]) if len(sys.argv) > 1 else 1056
py = int(sys.argv[2]) if len(sys.argv) > 2 else -3616
ab = int(sys.argv[3]) if len(sys.argv) > 3 else 64
out = sys.argv[4] if len(sys.argv) > 4 else 'frame.png'

sc = SpanClip6502()
setup_wad(sc)
setup_view(sc, px, py, ab)
init_pool(sc)
clear_screen(sc)
sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)

mem = sc.mpu.memory
start = sc.SCREEN_START
W, H = 256, 160
SCALE = 4
img = pygame.Surface((W * SCALE, H * SCALE))
img.fill((0, 0, 0))
for y in range(H):
    for x in range(W):
        addr = start + (y // 8) * 256 + (x // 8) * 8 + (y & 7)
        if mem[addr] & (0x80 >> (x & 7)):
            pygame.draw.rect(img, (0, 255, 0),
                             (x * SCALE, y * SCALE, SCALE, SCALE))
pygame.image.save(img, out)
print(f"Saved {count_pixels(sc)} pixels to {out} ({W*SCALE}x{H*SCALE})")
