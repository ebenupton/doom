#!/usr/bin/env python3
"""Where does a basic block get entered FROM, and how often?

For every JMP target in the engine, record the distribution of the PC that
preceded each entry.  An entry from a JMP costs 3 cycles, from a taken
branch 3, from a fall-through 0 — so a target whose hottest predecessor is
a JMP while something colder falls through is worth reordering, and the win
is 3 x (hot JMP entries - current fall-through entries).

Usage: jump_census.py [n_top]
"""
import os, sys, json
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(), 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
import symmap

POSES = [(1230, -3120, 242), (1200, -3000, 129), (1056, -3616, 32), (1500, -3700, 1),
         (-219.586, -3243.544, 252), (800, -3400, 96), (2112, -2368, 35), (1984, -2496, 67)]
BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0}

d = json.load(open(symmap.dump(banked=1)))
syms = sorted(((int(v[1:], 16), k) for k, v in d.items()
               if isinstance(v, str) and v.startswith('$') and int(v[1:], 16) >= 0x1000),
              key=lambda t: t[0])
def near(a):
    lo = None
    for addr, k in syms:
        if addr <= a: lo = (addr, k)
        else: break
    return f'{lo[1]}+{a - lo[0]}' if lo else f'${a:04X}'

r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc; mpu = sc.mpu; mem = mpu.memory
anyb = symmap.sym('OBJ_ANYB', banked=1)
bits = dw.packed_layout['off_obj'] + 7 * dw.packed_layout['n_obj']
for i in range(dw.packed_layout['obj_bits_len']):
    mem[anyb + i] = dw.packed_rom_main[bits + i]

targets = {}                      # target -> {pred_pc: count}
def prof(entry, max_cycles=3000000):
    mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30; mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
    mpu.processorCycles = 0; sc.last_lines = []; plot = sc.PLOT_PCS
    prev = None
    for _ in range(max_cycles):
        pc = mpu.pc
        if pc == 0xFF00: break
        if pc in plot: sc.last_lines.append((0, 0, 0, 0))
        if prev is not None and mem[prev] == 0x4C:           # a JMP ran: pc is a target
            targets.setdefault(pc, {})
        if pc in targets:
            targets[pc][prev] = targets[pc].get(prev, 0) + 1
        prev = pc
        mpu.step()
    sc.last_cycles = mpu.processorCycles; sc.total_cycles += mpu.processorCycles
    return mpu.processorCycles
sc._run = prof
for p in POSES:
    r.render_frame(p[0], p[1], p[2], dw.player_floor(p[0], p[1]))
n = len(POSES)

rows = []
for t, preds in targets.items():
    kinds = {}
    _t = t
    for pc, c in preds.items():
        op = mem[pc]
        if op == 0x4C:
            kind = 'jmp'
        elif op == 0x20:
            kind = 'call'                      # JSR: not reorderable
        elif op == 0x60 or op == 0x40:
            kind = 'ret'
        elif op in BRANCH:
            # NOT taken means it fell through into the target
            kind = 'fall' if pc + 2 == _t else 'branch'
        else:
            kind = 'fall'
        kinds.setdefault(kind, []).append((pc, c))
    jmps = sorted(kinds.get('jmp', []), key=lambda t2: -t2[1])
    fall = sum(c for _, c in kinds.get('fall', []))
    if not jmps: continue
    hot_pc, hot_c = jmps[0]
    gain = (hot_c - fall) * 3 / n
    rows.append((gain, t, hot_pc, hot_c / n, fall / n,
                 sum(c for _, c in jmps) / n, len(jmps),
                 sum(c for _, c in kinds.get('call', [])) / n))
rows.sort(reverse=True)
print(f'{"gain":>7s} {"target":26s} {"hot JMP from":24s} {"hot/fr":>7s} {"fall/fr":>8s} {"jsr":>6s}')
for gain, t, hot_pc, hot, fall, alljmp, njmp, calls in rows[:int(sys.argv[1]) if len(sys.argv) > 1 else 20]:
    print(f'{gain:7.1f} {near(t):26s} {near(hot_pc):24s} {hot:7.1f} {fall:8.1f} {calls:6.1f}')
print(f'\ntotal JMP entries {sum(r2[5] for r2 in rows):.0f}/frame over {len(rows)} targets')
