"""Test BSP walker — verify the visited-subsector set matches the
Python reference walk at several positions.

(Historic version expected 237/237 with the stub subsector renderer;
the walk now culls invisible/occluded subtrees exactly like Python's
packed_render_bsp, so the reference is the Python visit list.)
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
import trace_compare as tc
from wad_packed import spans_init_full

ENTRY_BR_RENDER_FRAME = 0x4815
ENTRY_BR_INIT_FRAME   = 0x481B
SS_VISITED_BITMAP = 0x0A80


def asm_visited(px, py, ab):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(ENTRY_BR_INIT_FRAME)
    mem = sc.mpu.memory
    for i in range(30):   # 237 subsectors = 30 bytes; $0AA0+ is the B-region CODE
        mem[SS_VISITED_BITMAP + i] = 0
    sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=40_000_000)
    out = set()
    for i in range(len(dw.nodes) + 1):
        if mem[SS_VISITED_BITMAP + (i >> 3)] & (1 << (i & 7)):
            out.add(i)
    return out


def py_visited(px, py, ab):
    seen = set()
    orig = dw.packed_render_subsector

    def logger(idx, *a):
        seen.add(idx)
        orig(idx, *a)

    dw.packed_render_subsector = logger
    try:
        _ = dw.Instrumented6502Spans()
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        ctx = fp.fp_view_context(px_88, py_88, fp.fp_sincos(ab))
        vz = dw._prescale_height(dw.player_floor(px, py) + 41)
        cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
        sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
        p_ram = bytearray(dw.packed_layout['ram_size'])
        spans_init_full(p_ram, dw.packed_layout['ram_spans'],
                        dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
        surf = pygame.Surface((256, 160))
        dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                             ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    finally:
        dw.packed_render_subsector = orig
    return seen


if __name__ == '__main__':
    POSITIONS = [(1056, -3616, 0), (1024, -3500, 64), (1500, -3700, 0),
                 (800, -3400, 96)]
    fails = 0
    for px, py, ab in POSITIONS:
        a = asm_visited(px, py, ab)
        p = py_visited(px, py, ab)
        ok = a == p
        if not ok:
            fails += 1
        print(f'({px},{py},{ab}): asm {len(a)} vs py {len(p)} '
              f'{"OK" if ok else f"MISMATCH asm-only={sorted(a-p)} py-only={sorted(p-a)}"}')
    print('All positions match.' if not fails else f'{fails} position(s) FAILED')
