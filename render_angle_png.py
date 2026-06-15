"""Render the Python packed renderer to PNGs, perspective vs angle-space, so
the angle-space conversion (M1 + M2-bbox) can be eyeballed.

Usage: python3 render_angle_png.py
Writes persp_<pos>.png and angle_<pos>.png (4x scale, green-on-black).
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import compare_angle_frames as C

W, H, S = 256, 160, 4
START = 0x5800


def save_fb(path):
    mem = dw._span_clip_6502.mpu.memory
    img = pygame.Surface((W * S, H * S)); img.fill((0, 0, 0))
    lit = 0
    for y in range(H):
        for x in range(W):
            addr = START + (y // 8) * 256 + (x // 8) * 8 + (y & 7)
            if mem[addr] & (0x80 >> (x & 7)):
                lit += 1
                pygame.draw.rect(img, (0, 255, 0), (x * S, y * S, S, S))
    pygame.image.save(img, path)
    return lit


POS = [(1056, -3616, 65), (1500, -3700, 1), (800, -3400, 96), (1024, -3500, 65)]
if len(sys.argv) >= 4:
    POS = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]

for px, py, ab in POS:
    tag = f"{px}_{py}_{ab}"
    C.render_lines(px, py, ab, False, False)
    lp = save_fb(f"persp_{tag}.png")
    C.render_lines(px, py, ab, True, True)
    la = save_fb(f"angle_{tag}.png")
    print(f"({px},{py},{ab}): persp_{tag}.png ({lp}px)  angle_{tag}.png ({la}px)")
