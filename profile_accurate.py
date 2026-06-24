#!/usr/bin/env python3
"""Accurate per-routine frame profile: bucket each executed instruction by the
nearest preceding label of ANY kind (top-level OR local), using the beebasm -v
listing for addresses. Also reports how many times vwhc_clear actually runs."""
import os, re, subprocess, bisect
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

# all labels (any indentation) -> address, from the -v listings
syms = {}
for asm in ('bsp_render.asm', 'span_clip.asm'):
    out = subprocess.run(['./beebasm', '-i', asm, '-D', 'BANKED=0', '-D', 'C02=0', '-v'],
                         capture_output=True, text=True).stdout
    for m in re.finditer(r'\.([A-Za-z_][A-Za-z0-9_]*)\s*\n\s+([0-9A-F]{4})', out):
        a = int(m.group(2), 16)
        syms.setdefault(a, m.group(1))
addrs = sorted(syms); names = [syms[a] for a in addrs]
VWHC = next((a for a, n in syms.items() if n == 'vwhc_clear'), None)

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
mpu = r.sc.mpu
# wrap step to accumulate cycles per bucket
buckets = {}; vwhc_hits = [0]
import types
def render_profiled(px, py, ab):
    import fp
    r._setup_zp(px, py, ab, dw.player_floor(px, py)) if hasattr(r, '_setup_zp') else None

# simplest: re-run render_frame but single-step with profiling via a patched _run
sc = r.sc
orig_run = sc._run
def prof_run(entry, max_cycles=10_000_000):
    m = sc.mpu; m.pc = entry; m.sp = 0xFD; m.p = 0x30
    mem = m.memory; mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF; m.processorCycles = 0
    for _ in range(max_cycles):
        if m.pc == 0xFF00: break
        pc = m.pc
        if pc == VWHC: vwhc_hits[0] += 1
        i = bisect.bisect_right(addrs, pc) - 1
        c0 = m.processorCycles
        m.step()
        buckets[names[i]] = buckets.get(names[i], 0) + (m.processorCycles - c0)
    sc.last_cycles = m.processorCycles; sc.total_cycles += m.processorCycles
    return m.processorCycles

sc._run = prof_run
tot = 0
for (px, py, ab) in C.POSITIONS[:3]:
    tot += r.render_frame(px, py, ab, dw.player_floor(px, py))

print(f"vwhc_clear ($%04X) entries over 3 frames: {vwhc_hits[0]}" % VWHC)
print(f"total cycles (3 frames): {tot:,}\n")
print(f"{'routine':28s}{'cycles':>12}{'%':>8}")
for n, c in sorted(buckets.items(), key=lambda kv: -kv[1])[:18]:
    print(f"{n:28s}{c:>12,}{100*c/tot:>7.1f}%")
