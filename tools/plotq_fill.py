"""Does the 256-B plot queue ever fill and stall the producer?

    python3 tools/plotq_fill.py <out.json> [grid.json]

ANSWERED 2026-09-04 over 3,978 poses: NO.  Worst first-field occupancy
37 of 64 entries (58%), at (1056,-3040,64); zero poses fill it.  Re-run
whenever the emit rate changes (art, LOD tiers, a new object class).

The driver arms the queue at frame start (right after a vsync-latched
flip) and DRAINS at the first vsync it sees; pq_pump busy-waits in
pq_force if an append leaves the queue FULL (64 entries) before that
vsync.  So the question is exactly: does a frame dispatch 64 plot lines
within one PAL field of its start?

Cycle offsets are simulated counts from py65, not estimates.
"""
import os, sys, json
ROOT = os.getcwd(); sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw, compare_renders as C
import json as _j
from banked_bsp import BankedBspRender
import span_clip_6502 as scmod

FIELD = 39936          # one PAL field, the drain window (anim_drv T1 period)
CAP = 64               # queue entries
r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc; mpu = sc.mpu; mem = mpu.memory
plot_pcs = sc.PLOT_PCS          # BANKED PCs (banked_bsp overrides the module set)
rz = (scmod.RZ_X0, scmod.RZ_Y0, scmod.RZ_X1, scmod.RZ_Y1)
rows = []
def prof_run(entry, max_cycles=500000):
    mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30; mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
    mpu.processorCycles = 0
    lines = sc.last_lines = []
    offs = []
    for _ in range(max_cycles):
        pc = mpu.pc
        if pc == 0xFF00: break
        if pc in plot_pcs:
            lines.append((mem[rz[0]], mem[rz[1]], mem[rz[2]], mem[rz[3]]))
            offs.append(mpu.processorCycles)
        mpu.step()
    sc.last_cycles = mpu.processorCycles; sc.total_cycles += mpu.processorCycles
    prof_run.offs = offs
    return mpu.processorCycles
sc._run = prof_run
worst = (0, None)
POSES=[tuple(p) for g in _j.load(open(sys.argv[2]))
       for p in _j.load(open(sys.argv[2]))[g]] if len(sys.argv)>2 else list(C.POSITIONS)
for (x, y, ab) in POSES:
    cyc = r.render_frame(x, y, ab, dw.player_floor(x, y))
    offs = prof_run.offs
    in_field = sum(1 for o in offs if o < FIELD)
    # cycles until the 64th line (if it ever gets there)
    to64 = offs[CAP - 1] if len(offs) >= CAP else None
    rows.append((x, y, ab, cyc, len(offs), in_field, to64))
    if in_field > worst[0]: worst = (in_field, (x, y, ab))
    if in_field >= CAP:
        print(f'  WOULD BLOCK ({x},{y},{ab}): {in_field} lines in the first field')
n = len(rows)
print(f'\nPLOTQ: {n} poses, cap {CAP} entries, field {FIELD:,} cyc')
print(f'PLOTQ: worst first-field line count {worst[0]} at {worst[1]} '
      f'({100*worst[0]/CAP:.0f}% of the queue)')
blk = sum(1 for r_ in rows if r_[5] >= CAP)
print(f'PLOTQ: poses that would fill the queue before the drain: {blk}/{n}')
mx = max(r_[4] for r_ in rows)
print(f'PLOTQ: most lines in a whole frame {mx} (cap {CAP}); '
      f'frames whose TOTAL lines exceed the cap: {sum(1 for r_ in rows if r_[4] > CAP)}/{n}')
json.dump(rows, open(sys.argv[1], 'w')) if len(sys.argv) > 1 else None
