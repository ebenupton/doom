"""Render all test positions and tile them into a single PNG."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from test_bsp_render_frame import setup_wad, setup_view, init_pool, clear_screen, count_pixels
from span_clip_6502 import SpanClip6502

W, H = 256, 160
ENTRY = 0x4815

POSITIONS = [
    (1056, -3616, 0),
    (1056, -3616, 32),
    (1056, -3616, 64),
    (1056, -3616, 128),
    (1056, -3616, 192),
    (1056, -3616, 224),
    (1024, -3500, 64),
    (1500, -3700, 0),
    (800, -3400, 96),
    (1200, -3000, 128),
]

SCALE = 2
COLS = 5
ROWS = (len(POSITIONS) + COLS - 1) // COLS
PAD = 8
LABEL_H = 20

cell_w = W * SCALE + PAD
cell_h = H * SCALE + PAD + LABEL_H

sheet = pygame.Surface((cell_w * COLS, cell_h * ROWS))
sheet.fill((30, 30, 30))
font = pygame.font.SysFont(None, 16)

for i, (px, py, ab) in enumerate(POSITIONS):
    sc = SpanClip6502()
    setup_wad(sc); setup_view(sc, px, py, ab); init_pool(sc); clear_screen(sc)
    cyc = sc._run(ENTRY, max_cycles=10000000)
    n = count_pixels(sc)

    mem = sc.mpu.memory
    start = sc.SCREEN_START
    cell = pygame.Surface((W * SCALE, H * SCALE))
    cell.fill((0, 0, 0))
    for y in range(H):
        for x in range(W):
            addr = start + (y // 8) * 256 + (x // 8) * 8 + (y & 7)
            if mem[addr] & (0x80 >> (x & 7)):
                pygame.draw.rect(cell, (0, 255, 0),
                                 (x * SCALE, y * SCALE, SCALE, SCALE))

    col = i % COLS; row = i // COLS
    ox = col * cell_w + PAD // 2
    oy = row * cell_h + PAD // 2
    sheet.blit(cell, (ox, oy))
    label = font.render(
        f"({px},{py},{ab})  {n}px {cyc//1000}k cyc",
        True, (220, 220, 220))
    sheet.blit(label, (ox, oy + H * SCALE + 2))

out = sys.argv[1] if len(sys.argv) > 1 else 'contact_sheet.png'
pygame.image.save(sheet, out)
print(f"Saved {len(POSITIONS)} frames to {out}  ({sheet.get_width()}x{sheet.get_height()})")
