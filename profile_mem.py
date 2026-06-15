#!/usr/bin/env python3
"""Memory-access profiler for the optimization grind.
Wraps mpu.memory with a counting proxy, runs the reference frames, and ranks
addresses by read+write count. Flags hot absolute scalars (promote->ZP) and
cold ZP scalars (demote->absolute)."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C

class Counting(list):
    def __init__(self, base):
        super().__init__(base)
        self.rd = [0]*0x10000
        self.wr = [0]*0x10000
        self.on = False
    def __getitem__(self, i):
        if self.on and type(i) is int and i < 0x10000:
            self.rd[i] += 1
        return list.__getitem__(self, i)
    def __setitem__(self, i, v):
        if self.on and type(i) is int and i < 0x10000:
            self.wr[i] += 1
        list.__setitem__(self, i, v)

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
prox = Counting(r.sc.mpu.memory)
r.sc.mpu.memory = prox
prox.on = True
for (px, py, ab) in C.POSITIONS:
    r.render_frame(px, py, ab, dw.player_floor(px, py))
prox.on = False

rd, wr = prox.rd, prox.wr
tot = [rd[a] + wr[a] for a in range(0x10000)]

def is_codeish(a):
    # rough: heavy-read low-count-write addresses in code regions are instr fetches
    return False

print("== ZP ($00-$FF) access counts (read+write) ==")
zp = [(a, tot[a], rd[a], wr[a]) for a in range(0x100)]
print("  HOT ZP (top 24):")
for a, t, rr, ww in sorted(zp, key=lambda x: -x[1])[:24]:
    print(f"    ${a:02X}: {t:>9,}  (r{rr:,} w{ww:,})")
print("  COLD/UNUSED ZP (count <= 64, candidates to demote):")
cold = [f"${a:02X}({t})" for a, t, rr, ww in zp if t <= 64]
print("    " + " ".join(cold))

print("\n== HOT ABSOLUTE scalars ($0100+) — candidates to promote to ZP ==")
# scalar heuristic: high count AND neighbours much lower (not a swept array),
# and not in an obvious instruction-fetch code region (>$2000 code, >$4700).
def neighbour_max(a):
    return max(tot[a-1] if a > 0x100 else 0, tot[a+1] if a < 0xFFFF else 0)
cands = []
for a in range(0x100, 0x10000):
    t = tot[a]
    if t < 2000:
        continue
    # writes present => data, not pure code fetch; or read-heavy data
    if wr[a] == 0 and rd[a] > 0 and neighbour_max(a) > t*0.6:
        continue  # looks like contiguous code/array reads
    cands.append((a, t, rd[a], wr[a], neighbour_max(a)))
for a, t, rr, ww, nb in sorted(cands, key=lambda x: -x[1])[:40]:
    tag = "scalar?" if nb < t*0.5 else "array/code?"
    print(f"    ${a:04X}: {t:>9,}  (r{rr:,} w{ww:,}) nbr={nb:,}  {tag}")
