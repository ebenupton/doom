#!/usr/bin/env python3
"""Cycle profiler v3: per-instruction PC attribution to the nearest JSR-target
(real function entry). Accurate (PC-based) and clean (sub-labels roll up into
their function). Over the reference frames."""
import os, sys, subprocess, re, bisect, collections
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

def labels(asm):
    out = subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', asm, '-v'], capture_output=True, text=True).stdout
    return {int(m.group(2), 16): m.group(1)
            for m in re.finditer(r'^\.([A-Za-z_][A-Za-z0-9_]*)\n\s+([0-9A-F]{4})', out, re.M)}
sym = {}
for f in ('span_clip.asm', 'bsp_render.asm', 'slope_div.asm'):
    sym.update(labels(f))

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
mpu = r.sc.mpu

# Pass 1: collect JSR targets (function entries) + per-PC cycles.
jsr_tgt = set()
pc_cyc = [0] * 0x10000
def run(entry, max_cycles=20_000_000):
    mpu.pc = entry; mpu.sp = 0xFD; mpu.p = 0x30
    mem = mpu.memory; mem[0x1FF] = 0xFE; mem[0x1FE] = 0xFF; mpu.processorCycles = 0
    for _ in range(max_cycles):
        pc = mpu.pc
        if pc == 0xFF00: break
        op = mem[pc]; c0 = mpu.processorCycles
        if op == 0x20:
            jsr_tgt.add(mem[(pc+1) & 0xFFFF] | (mem[(pc+2) & 0xFFFF] << 8))
        mpu.step()
        pc_cyc[pc] += mpu.processorCycles - c0
    return mpu.processorCycles
r.sc._run = run
for (px, py, ab) in C.POSITIONS:
    r.render_frame(px, py, ab, dw.player_floor(px, py))

entries = sorted(jsr_tgt | {0x4815, 0xA900})
def fname(a):
    if 0xA900 <= a < 0xC000: return 'RASTERISER'
    return sym.get(a, f'sub_{a:04X}')
ea = entries
agg = collections.Counter()
for pc in range(0x10000):
    if pc_cyc[pc]:
        i = bisect.bisect_right(ea, pc) - 1
        agg[fname(ea[i]) if i >= 0 else f'<{pc:04X}>'] += pc_cyc[pc]
total = sum(agg.values())
print(f"total cycles (10 frames): {total:,}")
print("top functions by cycles (PC-attributed to nearest JSR entry):")
for n, c in agg.most_common(30):
    print(f"  {n:<26} {c:>10,}  {100*c/total:4.1f}%")
