"""Subsystem-level cycle attribution via the 6502 call stack.

A flat PC-bucket profile mis-attributes shared leaf routines (umul8 lives in
the span_clip module but is called from every subsystem). Instead we track
"gateway" entry points and charge every cycle to the subsystem whose gateway
frame is currently on the stack:

  VERTEX  = br_seg_xform_vertex / reproject_at_crossing (per-seg vertex xform)
  CLIP    = span_clip jump-table entries (mark_solid/tighten/has_gap/is_full/
            draw_clipped_line/clip_line_records/tighten_from_records/...)
  RASTER  = NJ linedraw backend ($A900-$B55F), by PC range
  BSP     = everything else (walk + node setup + bbox visibility + bv_* +
            the rotation cache + the recip/projection primitives used for
            bbox corners + the seg-processor glue)

Gateways are detected at JSR/JMP to a gateway address and stay active until
the stack pops back past the call frame (handles the bbox tail-JMP to has_gap).
"""
import os, bisect, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import trace_compare as tc

VERTEX = {0x55D7, 0x1B40}
CLIP   = {0x2003, 0x2006, 0x2009, 0x200C, 0x200F, 0x2012,
          0x2015, 0x2018, 0x201B, 0x201E}
BBOX   = {0x4EB7}            # br_bbox_visible (sub-slice of BSP traversal)
GATE = {a: 'VERTEX' for a in VERTEX}
GATE.update({a: 'CLIP' for a in CLIP})
GATE.update({a: 'BBOX' for a in BBOX})
RASTER_LO, RASTER_HI = 0xA900, 0xB560

POS = [(1056,-3616,65),(1500,-3700,1),(1024,-3500,65),
       (800,-3400,96),(1200,-3000,129),(1056,-3616,129)]


def profile(px, py, ab):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init(); sc.clear_screen(); sc._run(0x481B)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    mpu.processorCycles = 0
    buckets = {'VERTEX': 0, 'BSP': 0, 'BBOX': 0, 'CLIP': 0, 'RASTER': 0}
    gw = []                      # stack of (threshold_sp, subsystem)
    prev = 0
    while mpu.pc != 0xFF00:
        pc = mpu.pc; sp = mpu.sp; op = mem[pc]
        # pop gateway frames that have returned
        while gw and sp > gw[-1][0]:
            gw.pop()
        # current subsystem for this instruction
        if RASTER_LO <= pc < RASTER_HI:
            sub = 'RASTER'
        elif gw:
            sub = gw[-1][1]
        else:
            sub = 'BSP'
        # detect a gateway call to push after stepping
        push = None
        if op == 0x20:           # JSR abs
            tgt = mem[(pc+1) & 0xffff] | (mem[(pc+2) & 0xffff] << 8)
            if tgt in GATE:
                push = ((sp - 2) & 0xff, GATE[tgt])   # frame sp after JSR
        elif op == 0x4C:         # JMP abs (tail call)
            tgt = mem[(pc+1) & 0xffff] | (mem[(pc+2) & 0xffff] << 8)
            if tgt in GATE:
                push = (sp, GATE[tgt])
        mpu.step()
        c = mpu.processorCycles
        buckets[sub] += c - prev
        prev = c
        if push is not None:
            gw.append(push)
    return buckets, mpu.processorCycles


if __name__ == '__main__':
    total = {'VERTEX': 0, 'BSP': 0, 'BBOX': 0, 'CLIP': 0, 'RASTER': 0}
    grand = 0
    for px, py, ab in POS:
        b, cyc = profile(px, py, ab)
        for k in total: total[k] += b[k]
        grand += cyc
    print(f'\n{"subsystem":36s} {"cycles":>11s} {"%":>7s}')
    bsp_all = total['BSP'] + total['BBOX']
    print(f'{"Vertex transform & cache":36s} {total["VERTEX"]:11d} {100*total["VERTEX"]/grand:6.2f}%')
    print(f'{"BSP traversal (total)":36s} {bsp_all:11d} {100*bsp_all/grand:6.2f}%')
    print(f'{"  - bbox visibility":36s} {total["BBOX"]:11d} {100*total["BBOX"]/grand:6.2f}%')
    print(f'{"  - walk + seg-processor glue":36s} {total["BSP"]:11d} {100*total["BSP"]/grand:6.2f}%')
    print(f'{"Windowed clipped renderer":36s} {total["CLIP"]:11d} {100*total["CLIP"]/grand:6.2f}%')
    print(f'{"NJ rasteriser backend":36s} {total["RASTER"]:11d} {100*total["RASTER"]/grand:6.2f}%')
    print(f'{"TOTAL":36s} {grand:11d} {100*(total["VERTEX"]+bsp_all+total["CLIP"]+total["RASTER"])/grand:6.2f}%')
