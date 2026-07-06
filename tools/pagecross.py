#!/usr/bin/env python3
"""Attribute page-cross and taken-branch-cross penalty cycles per instruction.

py65 models both penalties (verified: LDA abs,X across a page = 5 cyc; taken
branch across a page = +1) and they land in the measured baseline, so fixing
them shows up in run_regression. This tool ranks WHERE the penalty cycles go:
by routine + operand table (for indexed reads) and by branch site.

    python3 tools/pagecross.py            # default 6-position off-axis suite
"""
import os, re, bisect, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import asmbuild

asmbuild.build('engine', banked=0, c02=0)
syms = {}
with open('build/engine_b0c0.dbg') as f:
    for line in f:
        if not line.startswith('sym'):
            continue
        fields = dict(kv.split('=', 1) for kv in line.split('\t')[1].strip().split(','))
        if fields.get('type') != 'lab' or 'val' not in fields:
            continue
        a = int(fields['val'], 16)
        syms.setdefault(a, fields['name'].strip('"'))
import subprocess as _sp
_out = _sp.run(['./beebasm', '-i', 'linedraw_or_reloc.asm', '-v'],
               capture_output=True, text=True).stdout
for m in re.finditer(r'\.([A-Za-z_][A-Za-z0-9_]*)\s*\n\s*([0-9A-F]{4})', _out):
    a = int(m.group(2), 16)
    if 0xA900 <= a < 0xB600:
        syms.setdefault(a, 'NJ_' + m.group(1))
addrs = sorted(syms); names = [syms[a] for a in addrs]


def routine(pc):
    return names[bisect.bisect_right(addrs, pc) - 1]


ABX = {0x1d, 0x3d, 0x5d, 0x7d, 0xbc, 0xbd, 0xdd, 0xfd}
ABY = {0x19, 0x39, 0x59, 0x79, 0xb9, 0xbe, 0xd9, 0xf9}
IZY = {0x11, 0x31, 0x51, 0x71, 0xb1, 0xd1, 0xf1}
BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xb0, 0xd0, 0xf0}

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc
idx_pen = {}     # (routine, table_base) -> [cross_count, total_count]
br_pen = {}      # (routine, branch_pc) -> [cross_count, taken_count]


def prof_run(entry, max_cycles=20_000_000):
    m = sc.mpu; mem = m.memory
    m.pc = entry; m.sp = 0xFD; m.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF; m.processorCycles = 0
    for _ in range(max_cycles):
        pc = m.pc
        if pc == 0xFF00:
            break
        op = mem[pc]
        if op in ABX or op in ABY:
            base = mem[pc + 1] | (mem[pc + 2] << 8)
            idxr = m.x if op in ABX else m.y
            eff = (base + idxr) & 0xFFFF
            crossed = (base & 0xFF00) != (eff & 0xFF00)
            k = (routine(pc), base)
            e = idx_pen.setdefault(k, [0, 0]); e[1] += 1; e[0] += crossed
        elif op in IZY:
            zp = mem[pc + 1]
            base = mem[zp] | (mem[(zp + 1) & 0xFF] << 8)
            eff = (base + m.y) & 0xFFFF
            crossed = (base & 0xFF00) != (eff & 0xFF00)
            k = (routine(pc), 'zp$%02X' % zp)
            e = idx_pen.setdefault(k, [0, 0]); e[1] += 1; e[0] += crossed
        elif op in BRANCH:
            flag = {0x10: 0x80, 0x30: 0x80, 0x50: 0x40, 0x70: 0x40,
                    0x90: 0x01, 0xb0: 0x01, 0xd0: 0x02, 0xf0: 0x02}[op]
            want = op in (0x30, 0x70, 0xb0, 0xf0)   # BMI/BVS/BCS/BEQ = set
            taken = bool(m.p & flag) == want
            if taken:
                rel = mem[pc + 1]
                after = (pc + 2) & 0xFFFF
                tgt = (after + (rel - 256 if rel >= 128 else rel)) & 0xFFFF
                crossed = (after & 0xFF00) != (tgt & 0xFF00)
                k = (routine(pc), pc)
                e = br_pen.setdefault(k, [0, 0]); e[1] += 1; e[0] += crossed
        m.step()
    sc.last_cycles = m.processorCycles; sc.total_cycles += m.processorCycles
    return m.processorCycles


sc._run = prof_run
POS = [(1056, -3616, 65), (1500, -3700, 1), (1024, -3500, 65),
       (800, -3400, 96), (1200, -3000, 129), (1056, -3616, 129)]
tot = 0
for (px, py, ab) in POS:
    tot += r.render_frame(px, py, ab, dw.player_floor(px, py))

idx_cross = sum(v[0] for v in idx_pen.values())
br_cross = sum(v[0] for v in br_pen.values())
print(f"suite total cycles (6 frames): {tot:,}")
print(f"indexed-read page crosses: {idx_cross:,} cyc  ({100*idx_cross/tot:.2f}%)")
print(f"taken-branch page crosses: {br_cross:,} cyc  ({100*br_cross/tot:.2f}%)")
print(f"TOTAL penalty cycles: {idx_cross+br_cross:,}  ({100*(idx_cross+br_cross)/tot:.2f}%)\n")


def tbl_name(base):
    if isinstance(base, str):
        return base
    i = bisect.bisect_right(addrs, base) - 1
    off = base - addrs[i]
    return f"{names[i]}+{off}" if off else names[i]


print("== indexed-read crosses (routine | table | crosses/total) ==")
for (rt, base), (cr, tot_c) in sorted(idx_pen.items(), key=lambda kv: -kv[1][0])[:20]:
    if cr:
        print(f"  {rt:24s} {tbl_name(base):22s} {cr:6,}/{tot_c:<7,}")
print("\n== taken-branch crosses (routine | branch pc | crosses/taken) ==")
for (rt, pc), (cr, tk) in sorted(br_pen.items(), key=lambda kv: -kv[1][0])[:20]:
    if cr:
        print(f"  {rt:24s} ${pc:04X}  {cr:6,}/{tk:<7,}")
