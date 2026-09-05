#!/usr/bin/env python3
"""Capture the NJ rasteriser's REAL workload out of the engine.

The rasteriser is 6502 code with a fixed algorithm: for a given line its
executed instruction trace does not depend on where the code sits.  What
DOES depend on the layout is the page-crossing penalty on taken branches
(+1 cycle) and on absolute-indexed reads of the blob's own tables.  To
optimise those we need the frequency-weighted workload, not a synthetic
sweep -- hence this: every (x0,y0,x1,y1) the engine hands to RASTER_ENTRY
over the standard corpus, in order, with frame boundaries kept.

Output: build/raster_workload.json
    {"poses": [[px,py,ab], ...], "lines": [[x0,y0,x1,y1], ...],
     "frames": [n_lines_frame0, ...], "scrstrt": [...]}

The correctness oracle for any layout change is NOT this file, it is
build/raster_ab.json (the 42,462-line golden corpus); this one carries the
distribution that decides which branches are worth aligning.
"""
import os, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender     # the BANKED rig is the render
import compare_renders as C                # reference AND the only one that
from symmap import sym                     # actually runs the blob at $A200

OUT = os.path.join(ROOT, 'raster_workload.json')   # tracked: the
                                                   # gate needs it


def capture(positions=None, objects=None):
    positions = positions or C.POSITIONS
    ENTRY = sym('RASTER_ENTRY', banked=1)
    RZ = [sym('RASTER_ZP_X0'), sym('RASTER_ZP_Y0'),
          sym('RASTER_ZP_X1'), sym('RASTER_ZP_Y1')]
    SCR = sym('RASTER_ZP_SCRSTRT')

    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = r.sc
    mpu = sc.mpu
    mem = mpu.memory
    lines, scrs = [], []

    orig_run = sc._run

    def traced(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc == ENTRY:
                lines.append([mem[a] for a in RZ])
                scrs.append(mem[SCR])
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles

    sc._run = traced
    frames = []
    for (px, py, ab) in positions:
        n = len(lines)
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        frames.append(len(lines) - n)
    sc._run = orig_run
    return dict(poses=[list(p) for p in positions], lines=lines,
                frames=frames, scrstrt=scrs)


def main():
    d = capture()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(d, open(OUT, 'w'))
    n = len(d['lines'])
    uniq = len(set(map(tuple, d['lines'])))
    print(f'{n} raster calls over {len(d["frames"])} frames '
          f'({n / len(d["frames"]):.1f}/frame), {uniq} distinct lines')
    print(f'wrote {OUT}')


if __name__ == '__main__':
    main()
