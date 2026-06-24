#!/usr/bin/env python3
"""Pure PC cycle histogram (no label bucketing). Renders 3 reference frames,
accumulates cycles per executed PC, and maps the hottest PCs to their listing
instruction. Also groups cycles into coarse address regions."""
import os, re, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

# addr -> (instr_text, enclosing_label) from listings
instr = {}; label_at = {}
for asm in ('bsp_render.asm', 'span_clip.asm'):
    out = subprocess.run(['./beebasm', '-i', asm, '-D', 'BANKED=0', '-D', 'C02=0', '-v'],
                         capture_output=True, text=True).stdout
    cur = '?'
    for line in out.splitlines():
        lm = re.match(r'\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
        if lm: cur = lm.group(1); continue
        m = re.match(r'\s*([0-9A-F]{4})\s+([0-9A-F ]+?)\s{2,}(\S.*)$', line)
        if m:
            a = int(m.group(1), 16)
            instr.setdefault(a, (m.group(3).strip(), cur))

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc
pc_cyc = {}
def prof_run(entry, max_cycles=10_000_000):
    m = sc.mpu; m.pc = entry; m.sp = 0xFD; m.p = 0x30
    mem = m.memory; mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF; m.processorCycles = 0
    for _ in range(max_cycles):
        if m.pc == 0xFF00: break
        pc = m.pc; c0 = m.processorCycles; m.step()
        pc_cyc[pc] = pc_cyc.get(pc, 0) + (m.processorCycles - c0)
    sc.last_cycles = m.processorCycles; sc.total_cycles += m.processorCycles
    return m.processorCycles
sc._run = prof_run

tot = 0
for (px, py, ab) in C.POSITIONS[:3]:
    tot += r.render_frame(px, py, ab, dw.player_floor(px, py))

# group by enclosing label (from listing, accurate)
bylabel = {}
for pc, c in pc_cyc.items():
    lab = instr.get(pc, ('?', '?'))[1]
    bylabel[lab] = bylabel.get(lab, 0) + c
print(f"total cycles (3 frames): {tot:,}\n")
print("== top routines (by listing label) ==")
for n, c in sorted(bylabel.items(), key=lambda kv: -kv[1])[:16]:
    print(f"  {n:26s}{c:>11,}{100*c/tot:>7.1f}%")
print("\n== top single instructions ==")
for pc, c in sorted(pc_cyc.items(), key=lambda kv: -kv[1])[:15]:
    t, lab = instr.get(pc, ('???', '?'))
    print(f"  ${pc:04X} {100*c/tot:>5.1f}%  [{lab}] {t}")
