#!/usr/bin/env python3
"""Triage a soak FB mismatch: diff the raster segments the ENGINE drew
(PC-watch on plot_h/plot_v/RASTER_ENTRY, reading RASTER_ZP_X0/Y0/X1/Y1)
against the segments the Python reference emitted (SpanClip6502.capture).

Usage: tools/soak_triage.py px py ab
"""
import os, sys
from collections import Counter
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from symmap import sym
import pyref_render

PLOT_SITES = (sym('plot_h'), sym('plot_v'), 0xA900)
ZX0, ZY0, ZX1, ZY1 = (sym('RASTER_ZP_X0'), sym('RASTER_ZP_Y0'),
                      sym('RASTER_ZP_X1'), sym('RASTER_ZP_Y1'))


def engine_segments(px, py, ab):
    eng = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = eng.sc
    segs = []
    orig_run = sc._run

    def traced_run(entry, max_cycles=30_000_000):
        mpu = sc.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xFD
        mpu.p = 0x30
        mem[0x01FF] = 0xFE
        mem[0x01FE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            if mpu.pc == 0xFF00:
                break
            if mpu.pc in PLOT_SITES:
                segs.append((mem[ZX0], mem[ZY0], mem[ZX1], mem[ZY1]))
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += sc.last_cycles
        return sc.last_cycles

    sc._run = traced_run
    fz = dw.player_floor(px, py)
    eng.render_frame(px, py, ab, fz)
    sc._run = orig_run
    done = eng.sc.mpu.pc == 0xFF00
    fb = bytes(sc.mpu.memory[sc.SCREEN_START:sc.SCREEN_START + sc.SCREEN_SIZE])
    return segs, fb, done


def main():
    px, py, ab = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    eng_segs, eng_fb, done = engine_segments(px, py, ab)
    ref_fb, clip_ok = pyref_render.render_ref_fb(px, py, ab)
    # re-render reference to grab its capture list
    sc = dw._span_clip_6502
    ref_fb2, _ = pyref_render.render_ref_fb(px, py, ab)
    assert ref_fb2 == ref_fb
    # capture was cleared by render_ref_fb; patch: re-run with capture kept
    import nj_raster
    clips = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    sc.capture = []
    import fp
    from wad_packed import spans_init_full
    dw._USE_ANGLE_BBOX, dw._VIEW_AB = True, ab
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    ctx = fp.fp_view_context(px_88, py_88, fp.fp_sincos(ab))
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    ram = bytearray(dw.packed_layout['ram_size'])
    spans_init_full(ram, dw.packed_layout['ram_spans'],
                    dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    dw.packed_render_bsp(len(dw.nodes) - 1, clips, ctx, vz, px, py,
                         cos_f, sin_f, surf, ram)
    ref_segs = list(sc.capture)
    sc.capture = None

    ndiff = sum(1 for a, b in zip(ref_fb, eng_fb) if a != b)
    print(f'({px},{py},{ab}): fb ndiff={ndiff} eng_done={done} '
          f'model_ok={clip_ok}')
    print(f'engine segments: {len(eng_segs)}, reference: {len(ref_segs)}')
    ce, cr = Counter(eng_segs), Counter(ref_segs)
    only_eng = list((ce - cr).elements())
    only_ref = list((cr - ce).elements())
    print(f'only-engine ({len(only_eng)}):')
    for s in only_eng[:20]:
        print('   ', s)
    print(f'only-reference ({len(only_ref)}):')
    for s in only_ref[:20]:
        print('   ', s)


if __name__ == '__main__':
    main()
