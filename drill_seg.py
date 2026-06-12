"""Drill one divergent subsector: at visit time, run the 6502 then Python
from the identical pre-state, dumping per-seg clipper calls, AP-skip
decisions (Python side), and post-state spans.

Usage: drill_seg.py px py ab ssid
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
import endpoint_spans as eps
from wad_packed import spans_init_full
import trace_compare as tc
import compare_subsector as cs

ENTRY_BR_RENDER_SUBSECTOR = 0x4818
ENTRY_BR_INIT_FRAME       = 0x481B


def main(px, py, ab, target_ss):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(ENTRY_BR_INIT_FRAME)

    trace_all = []
    cs.install_tracing(sc, trace_all)
    orig_subsector = dw.packed_render_subsector

    orig_above = eps.EndpointClipSpans.line_above_spans
    orig_below = eps.EndpointClipSpans.line_below_spans
    orig_vout = eps.EndpointClipSpans.vertical_outside_spans
    orig_hg = eps.EndpointClipSpans.has_gap

    def differ(idx, clips, ctx, vz, surface, ram):
        mem = sc.mpu.memory
        if idx != target_ss:
            orig_subsector(idx, clips, ctx, vz, surface, ram)
            return
        snap = bytes(mem[0x0000:0x10000])

        # --- ASM run ---
        del trace_all[:]
        print(f'=== ASM ss {target_ss} ===')
        print(f'pre spans: {sc.read_spans()}')
        del trace_all[:]
        mem[0x58] = idx & 0xFF
        mem[0x59] = (idx >> 8) & 0xFF
        sc._run(ENTRY_BR_RENDER_SUBSECTOR)
        for e in trace_all:
            print(f'  {cs.fmt(e)}')
        del trace_all[:]
        print(f'post spans: {sc.read_spans()}')
        del trace_all[:]
        mem[0x0000:0x10000] = snap

        # --- Python run (verbose) ---
        print(f'\n=== PYTHON ss {target_ss} ===')

        def above(self, *a, **k):
            r = orig_above(self, *a, **k)
            print(f'    line_above_spans{tuple(a[:4])} -> {r}')
            return r

        def below(self, *a, **k):
            r = orig_below(self, *a, **k)
            print(f'    line_below_spans{tuple(a[:4])} -> {r}')
            return r

        def vout(self, *a, **k):
            r = orig_vout(self, *a, **k)
            print(f'    vertical_outside_spans{tuple(a)} -> {r}')
            return r

        def hg(self, lo, hi):
            r = orig_hg(self, lo, hi)
            print(f'    py_has_gap({lo},{hi}) -> {r}')
            return r

        eps.EndpointClipSpans.line_above_spans = above
        eps.EndpointClipSpans.line_below_spans = below
        eps.EndpointClipSpans.vertical_outside_spans = vout
        eps.EndpointClipSpans.has_gap = hg
        try:
            orig_subsector(idx, clips, ctx, vz, surface, ram)
        finally:
            eps.EndpointClipSpans.line_above_spans = orig_above
            eps.EndpointClipSpans.line_below_spans = orig_below
            eps.EndpointClipSpans.vertical_outside_spans = orig_vout
            eps.EndpointClipSpans.has_gap = orig_hg
        for e in trace_all:
            print(f'  {cs.fmt(e)}')
        del trace_all[:]
        print(f'post spans: {sc.read_spans()}')
        del trace_all[:]

    dw.packed_render_subsector = differ
    try:
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
        surf = pygame.Surface((256, 160))
        dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                             ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    finally:
        dw.packed_render_subsector = orig_subsector


if __name__ == '__main__':
    main(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
         int(sys.argv[4]))
