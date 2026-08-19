#!/usr/bin/env python3
"""Corpus study for the horizontal->vertical clip memo (Eben, 2026-07-26).

Question: when a vertex-span vertical is drawn at column x by seg S, did
S's edge-line DCLs already emit segments whose endpoint at column x carries
exactly the vertical's clipped y values?  If yes, the vertical could have
been drawn by a pure 'stage + plot_v' from a 2-slot endpoint memo written
during the edge clips (span state is IDENTICAL: verticals draw before the
seg's mark_solid/tighten).

Method: pure PC-trap instrumentation of the flat engine over the
compare_renders suite positions — no engine changes.
  seg window  = between subsector hg-gate calls (JSR span_has_gap with the
                subsector return address)
  edge emits  = plot_h/plot_v/RASTER_ENTRY events between window start and
                the first vs_fresh call (args from RASTER_ZP_X0/Y0/X1/Y1)
  vertical    = plot_v events after a vs_go entry in the same window
                (X0 == X1 == the vertex column)

Classification per drawn vertical (x, ylo, yhi):
  MEMO-EXACT  both ylo and yhi appear as edge-emit y values AT column x
  SLOT-ONLY   an edge emit touches column x but the y set doesn't cover
              both ends (explicit descriptor heights, partial clips)
  NO-DATA     no edge emit endpoint at column x (edge clipped short /
              flat-span verdict path)
Also counts verticals *attempted* (vs_go) that emitted nothing (clipped
away) — a memo 'culled' flag would skip those earlier than today.
"""
import os, sys, re
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C
from symmap import sym

RZ = [sym('RASTER_ZP_X0'), sym('RASTER_ZP_Y0'), sym('RASTER_ZP_X1'), sym('RASTER_ZP_Y1')]
PLOTS = {sym('plot_h'), sym('plot_v'), sym('RASTER_ENTRY')}
VS_GO = {sym('vs_fresh1'), sym('vs_fresh2')}
HG = sym('span_has_gap')

def main():
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    sc = r.sc
    mpu = sc.mpu
    mem = mpu.memory
    stats = dict(exact=0, contained=0, slot=0, nodata=0, clipped=0, verts=0)

    orig_run = sc._run
    def traced(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        edge_pts = {}          # column -> set(y) from edge emits, this seg
        in_vs = False
        pend_vs = 0            # vs entries seen with no plot yet
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc == HG:
                # subsector gate = new seg window (bca fused exits also
                # pass here, but they carry no plots so the reset is
                # harmless noise either way)
                stats['clipped'] += pend_vs
                edge_pts = {}; in_vs = False; pend_vs = 0
            elif pc in VS_GO:
                stats['clipped'] += pend_vs
                in_vs = True; pend_vs += 1
            elif pc in PLOTS:
                x0, y0, x1, y1 = (mem[a] for a in RZ)
                if not in_vs:
                    edge_pts.setdefault(x0, set()).add(y0)
                    edge_pts.setdefault(x1, set()).add(y1)
                else:
                    pend_vs = max(0, pend_vs - 1)
                    stats['verts'] += 1
                    ys = edge_pts.get(x0, set())
                    if x0 == x1:
                        if y0 in ys and y1 in ys:
                            stats['exact'] += 1
                        elif ys and min(ys) <= y0 and y1 <= max(ys):
                            stats['contained'] += 1   # interval certificate
                        elif ys:
                            stats['slot'] += 1
                        else:
                            stats['nodata'] += 1
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles
    sc._run = traced
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    sc._run = orig_run
    v = stats['verts']
    print(f"verticals drawn: {v}  attempted-and-clipped: {stats['clipped']}")
    if v:
        print(f"  MEMO-EXACT: {stats['exact']} ({stats['exact']/v:.0%})")
        print(f"  CONTAINED : {stats['contained']} ({stats['contained']/v:.0%})")
        print(f"  SLOT-ONLY : {stats['slot']} ({stats['slot']/v:.0%})")
        print(f"  NO-DATA   : {stats['nodata']} ({stats['nodata']/v:.0%})")

if __name__ == '__main__':
    main()
