"""Hybrid: Python BSP traversal + 6502 seg processor.

Isolates BSP-traversal vs seg-processor divergence. If the hybrid
framebuffer matches the pure-Python reference, BSP traversal is the
problem. If it differs, the 6502 seg processor diverges.

Python's packed_render_subsector is replaced with a wrapper that
writes zp_node_chlo:hi and calls into 6502 br_render_subsector.
The 6502's mark_solid (deferred at end of br_render_subsector)
updates the shared clipper instance that Python's BSP then queries
via has_gap / is_full.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from wad_packed import spans_init_full
import trace_compare as tc

ENTRY_BR_RENDER_SUBSECTOR = 0x4818
ENTRY_BR_INIT_FRAME       = 0x481B


def hybrid_render_subsector(idx, clips, ctx, vz, surface, ram):
    """Replacement for dw.packed_render_subsector — calls 6502 br_render_subsector."""
    sc = dw._span_clip_6502
    mem = sc.mpu.memory
    mem[0x58] = idx & 0xFF        # zp_node_chlo
    mem[0x59] = (idx >> 8) & 0xFF # zp_node_chhi (subsector flag $80 already cleared)
    sc._run(ENTRY_BR_RENDER_SUBSECTOR)
    # Optionally blit the 6502 framebuffer into surface, but we'll compare
    # the 6502 framebuffer directly at the end.


def render_hybrid(px, py, ab):
    # Force creation of the shared 6502 clipper instance.
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(ENTRY_BR_INIT_FRAME)  # clear vcache valid bitmap

    # Replace the seg processor in Python's BSP with the 6502 hybrid.
    orig_subsector = dw.packed_render_subsector
    dw.packed_render_subsector = hybrid_render_subsector

    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    sc_t = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(px_88, py_88, sc_t)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)

    spans = dw.Instrumented6502Spans()
    # spans must be reset for this frame; constructor handles that
    surf = pygame.Surface((256, 160))   # ignored — 6502 framebuffer is the truth
    dw.packed_render_bsp(len(dw.nodes) - 1, spans, ctx, vz, px, py,
                         cos_f, sin_f, surf, p_ram)
    dw.packed_render_subsector = orig_subsector  # restore

    # Extract 6502 framebuffer as the result.
    fb = pygame.Surface((256, 160))
    mem = sc.mpu.memory
    pxa = pygame.surfarray.pixels3d(fb)
    for cy in range(20):
        for col in range(32):
            for pr in range(8):
                y = cy * 8 + pr
                if y >= 160: break
                byte = mem[0x5800 + cy * 256 + col * 8 + pr]
                for bit in range(8):
                    if byte & (0x80 >> bit):
                        pxa[col * 8 + bit, y] = (255, 255, 255)
    del pxa
    return fb


def render_python(px, py, ab):
    """Pure Python reference."""
    surf = pygame.Surface((256, 160))
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    sc_t = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(px_88, py_88, sc_t)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    return surf


def render_asm(px, py, ab):
    """Pure 6502."""
    from bsp_render_6502 import BspRender6502
    renderer = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                             dw.packed_rom_detail, dw.packed_bbox_table,
                             dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    renderer.render_frame(px, py, ab, dw.player_floor(px, py))
    fb = pygame.Surface((256, 160))
    renderer.blit_framebuffer_to(fb)
    return fb


def pixel_compare(a, b):
    W, H = 256, 160
    both = pa = bb = 0
    for y in range(H):
        for x in range(W):
            ap = a.get_at((x, y))[:3] != (0, 0, 0)
            bp = b.get_at((x, y))[:3] != (0, 0, 0)
            if ap and bp: both += 1
            elif ap: pa += 1
            elif bp: bb += 1
    return both, pa, bb


if __name__ == '__main__':
    POSITIONS = [
        (1056, -3616, 0), (1056, -3616, 32), (1056, -3616, 64),
        (1056, -3616, 128), (1056, -3616, 192), (1056, -3616, 224),
        (1024, -3500, 64), (1500, -3700, 0),  (800, -3400, 96),
        (1200, -3000, 128),
    ]

    print(f'{"pos":>20s}   py-vs-hybrid       py-vs-asm          hybrid-vs-asm')
    print(f'{"":>20s}   both/py-/h-/agr    both/py-/a-/agr    both/h-/a-/agr')

    py_h_t = py_a_t = h_a_t = (0, 0, 0)
    for px, py, ab in POSITIONS:
        py_surf  = render_python(px, py, ab)
        asm_surf = render_asm(px, py, ab)
        hyb_surf = render_hybrid(px, py, ab)

        py_h = pixel_compare(py_surf,  hyb_surf)
        py_a = pixel_compare(py_surf,  asm_surf)
        h_a  = pixel_compare(hyb_surf, asm_surf)

        def agr(t):
            s = sum(t)
            return f'{t[0]:4d}/{t[1]:4d}/{t[2]:4d}/{100*t[0]/s if s else 0:5.1f}%'

        py_h_t = tuple(a + b for a, b in zip(py_h_t, py_h))
        py_a_t = tuple(a + b for a, b in zip(py_a_t, py_a))
        h_a_t  = tuple(a + b for a, b in zip(h_a_t,  h_a))

        print(f'  ({px:>5d},{py:>5d},{ab:>3d})  {agr(py_h)}  {agr(py_a)}  {agr(h_a)}')

    print()
    print(f'  {"TOTAL":>20s}  {agr(py_h_t)}  {agr(py_a_t)}  {agr(h_a_t)}')
