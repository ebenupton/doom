#!/usr/bin/env python3
"""Per-label cycle histogram of the engine, for diffing two builds.

Buckets every executed PC's cycles by the nearest engine symbol at or
below it (merged ld65 dbg symbols, CODE-region labels only), prints
`LABEL cycles` lines sorted by address so two runs can be diffed by
label name.
"""
import os, sys, bisect, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import symmap

POSITIONS = [(1500, -3700, 0), (1200, -3000, 128), (2112, -2368, 35),
             (3648, -4800, 131)]

# addr -> label from the merged symbol table (labels only: skip ZP/small)
table, _ambig = symmap._load(banked=0)
addrs, names = [], {}
for name, val in table.items():
    if val < 0x0200 or val > 0xFDFF:
        continue
    if name.startswith('zp_') or name.startswith('__'):
        continue
    # prefer the shortest name at an address (usually the routine label)
    if val in names and len(names[val]) <= len(name):
        continue
    names[val] = name
addrs = sorted(names)

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                  dw.PRESCALE)
sc = r.sc
lab_cyc = {}

def prof_run(entry, max_cycles=20_000_000):
    m = sc.mpu
    mem = m.memory
    m.pc = entry; m.sp = 0xFD; m.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    m.processorCycles = 0
    for _ in range(max_cycles):
        if m.pc == 0xFF00:
            break
        pc = m.pc
        c0 = m.processorCycles
        m.step()
        i = bisect.bisect_right(addrs, pc) - 1
        lab = names[addrs[i]] if i >= 0 else f'${pc:04X}'
        lab_cyc[lab] = lab_cyc.get(lab, 0) + (m.processorCycles - c0)
    sc.last_cycles = m.processorCycles
    sc.total_cycles += m.processorCycles
    return m.processorCycles

sc._run = prof_run

for px, py, ab in POSITIONS:
    r.render_frame(px, py, ab, dw.player_floor(px, py))

json.dump(lab_cyc, open(sys.argv[1] if len(sys.argv) > 1 else 'histo.json', 'w'))
print('total', sum(lab_cyc.values()), 'labels', len(lab_cyc))
