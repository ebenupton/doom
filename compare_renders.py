"""Compare K-mode (bsp_render.bin) output vs Python packed_render_bsp."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from bsp_render_6502 import BspRender6502

W, H = 256, 160
SCALE = 3

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
    # far-from-spawn but in-spec (player pos is s16 8.8: integer part must
    # fit s8 after prescale, i.e. within +/-1023 world units of MAP_CENTER)
    (2112, -2368, 35),
    (192, -2368, 99),
    (1984, -2496, 67),
    (1856, -2368, 3),
    # beyond the old +/-1023-unit box (s16 player int, 2026-07-06)
    (3648, -2368, 35),
    (2500, -2600, 67),
    (3648, -4800, 131),
]


def render_python(px, py, ab):
    """Render via Python packed_render_bsp."""
    surf = pygame.Surface((W, H))
    surf.fill((0, 0, 0))
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    sc = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(px_88, py_88, sc)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    from wad_packed import spans_init_full
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(
        len(dw.nodes) - 1, dw.Instrumented6502Spans(),
        ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    return surf


def render_6502(renderer, px, py, ab):
    cyc = renderer.render_frame(px, py, ab, dw.player_floor(px, py))
    surf = pygame.Surface((W, H))
    renderer.blit_framebuffer_to(surf)
    return surf, cyc


def make_diff(py_surf, k_surf):
    diff = pygame.Surface((W, H))
    diff.fill((0, 0, 0))
    for y in range(H):
        for x in range(W):
            p = py_surf.get_at((x, y))[:3] != (0, 0, 0)
            k = k_surf.get_at((x, y))[:3] != (0, 0, 0)
            if p and k:
                diff.set_at((x, y), (180, 180, 180))   # both = grey
            elif p:
                diff.set_at((x, y), (255, 80, 80))     # py only = red
            elif k:
                diff.set_at((x, y), (80, 80, 255))     # 6502 only = blue
    return diff


def main():
    renderer = BspRender6502(
        dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)

    # 3 columns (Python, 6502, diff) × N rows
    PAD = 8
    LABEL_H = 18
    COL_W = W * SCALE + PAD
    ROW_H = H * SCALE + PAD + LABEL_H
    sheet = pygame.Surface((COL_W * 3, ROW_H * len(POSITIONS)))
    sheet.fill((30, 30, 30))
    font = pygame.font.SysFont(None, 16)

    for i, (px, py, ab) in enumerate(POSITIONS):
        py_surf = render_python(px, py, ab)
        k_surf, cyc = render_6502(renderer, px, py, ab)
        d = make_diff(py_surf, k_surf)

        py_count = sum(1 for x in range(W) for y in range(H)
                       if any(py_surf.get_at((x, y))[:3]))
        k_count = sum(1 for x in range(W) for y in range(H)
                      if any(k_surf.get_at((x, y))[:3]))

        for col, (s, lbl) in enumerate([
                (py_surf, f"Py: {py_count}px"),
                (k_surf,  f"6502: {k_count}px {cyc//1000}k"),
                (d,       "diff (red=py-only blue=6502-only)")]):
            big = pygame.transform.scale(s, (W * SCALE, H * SCALE))
            ox = col * COL_W + PAD // 2
            oy = i * ROW_H + PAD // 2
            sheet.blit(big, (ox, oy))
            label = font.render(
                f"({px},{py},{ab})  {lbl}", True, (220, 220, 220))
            sheet.blit(label, (ox, oy + H * SCALE + 2))

    out = sys.argv[1] if len(sys.argv) > 1 else 'compare.png'
    pygame.image.save(sheet, out)
    print(f"Saved {out}  ({sheet.get_width()}x{sheet.get_height()})")


if __name__ == '__main__':
    main()
