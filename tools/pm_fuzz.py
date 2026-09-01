#!/usr/bin/env python3
"""Movement lockstep fuzz — THE gate for any pmove.s / colmap.py change.

Two suites, both comparing the 6502 against colmap.py (the canonical
rules statement) case for case, in BOTH builds:

  try   pmove_try vs colmap.try_move: stations along every aggregation
        port x normal offsets x heights + random points (the shallow-
        wall-clip drill, 2026-08-14 — it caught the pm_smul missing
        third addend byte and the NT_GEN=2 engine-wide classify bug).
  mom   pm_frame vs colmap.move_frame: multi-frame walks (walk, turn,
        friction, clamp, chunked application, wall projection, the
        axis fallback and D_FWD) from spawn + port-adjacent starts.

Movers are POSED explicitly (rest + halfopen): calling anim_init from a
harness wedges the banked build with mover WS left zero.

  python3 tools/pm_fuzz.py [try|mom|all] [--flat|--banked]
"""
import os
import sys
import math
import random

os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _ROOT)
os.chdir(_ROOT)
import pygame                                                   # noqa: E402
pygame.init()
import doom_wireframe as dw                                     # noqa: E402
import colmap                                                   # noqa: E402
import anim_sectors as an                                       # noqa: E402
import abi                                                      # noqa: E402
from symmap import sym                                          # noqa: E402


def poses():
    """(name, 6 mover pos_hi bytes) — the resting pose and one with a
    door/lift part-open (the live-height arms of every rule)."""
    rest = [dw._prescale_height(an.MOVERS[s].closed if an.MOVERS[s].kind == 'ceil'
                                else an.MOVERS[s].top) & 0xFF
            for s in sorted(dw.ANIM_SECTORS)]
    half = list(rest)
    half[0] = dw._prescale_height((an.MOVERS[4].closed + an.MOVERS[4].open) // 2) & 0xFF
    half[2] = dw._prescale_height(an.MOVERS[68].open) & 0xFF
    return [('rest', rest), ('halfopen', half)]


class Rig:
    """One built engine + the pokes/reads both suites share."""

    def __init__(self, banked):
        self.banked = banked
        if banked:
            import banked_bsp
            self.r = banked_bsp.BankedBspRender(
                dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        else:
            from bsp_render_6502 import BspRender6502
            self.r = BspRender6502(
                dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
            colmap.install(self.r.sc.mpu.memory, flat=True)
            an.install_6502_tables(self.r.sc.mpu.memory, flat=True)
        self.mem = self.r.sc.mpu.memory
        # RECORD-POINTER INVARIANT: every pm_box_vs_seg call must be
        # handed a record INSIDE one of the two packed tables. Comparing
        # verdicts cannot see a violation on its own — an out-of-table
        # read only changes the answer when the stray bytes happen to
        # form a line through the box, which is why the pcs_solid
        # fall-through (7987201) fuzzed clean for a day while the disc,
        # whose $0200-$0E00 carries live OS and engine data, blocked on a
        # phantom record. Poisoning the gap does NOT work: a constant
        # fill is one fixed line and no fixed line crosses every box.
        # Checking the pointer catches the whole class on case 1.
        m = colmap.build()
        A = colmap.blobs(flat=not banked)['addrs']
        self.bvs = sym('pm_box_vs_seg', banked=banked)
        self.rec_ok = (range(A['colseg'], A['colseg'] + len(m['colsegs']) * 9),
                       range(A['colport'], A['colport'] + len(m['ports']) * 12))
        self.vz = sym('pm_vz', banked=banked)
        self.try_e = sym('pmove_try', banked=banked)
        self.frame_e = sym('pm_frame', banked=banked)

    def pose(self, ws):
        _ws = sym('ANIM_WS')                        # BY THE MAP — the literal
        for i, p in enumerate(ws):                  # 0x5EB here went stale the
            self.mem[_ws + i * 3] = 0               # day the scalars moved and
            self.mem[_ws + i * 3 + 1] = p & 0xFF    # silently unposed every door

    def run(self, entry, a=0, x=0, maxc=2_000_000):
        mpu = self.r.sc.mpu
        if self.banked:
            # pm_frame's CODE lives in BANK_WALK; the driver pages it in
            # before the JSR, so the rig must too (pmove_try pages for
            # itself, which is why the try suite never needed this).
            self.mem[0xFE30] = 7
        mpu.pc, mpu.sp, mpu.a, mpu.x = entry, 0xDD, a, x  # SP capped below SQR_MIRROR ($01E0-$01FF, the stack-page mirror)
        self.mem[0x1DF] = 0xFF
        self.mem[0x1DE] = 0xFF
        n = 0
        while mpu.pc != 0 and n < maxc:
            if mpu.pc == self.bvs:
                _ap = sym('zp_anim_p')
                p = self.mem[_ap] | (self.mem[_ap + 1] << 8)
                assert any(p in r for r in self.rec_ok), \
                    f'pm_box_vs_seg handed an out-of-table record at ${p:04X}'
            mpu.step()
            n += 1
        assert n < maxc, f'pm 6502 ran away at {entry:04X}'
        return mpu

    def cold(self):
        # TELEPORT CONTRACT (2026-08-29): a poked position the engine
        # never walked to invalidates every cross-frame continuity
        # cache — exactly what sqr_fill_cold does at driver boot.
        # Suites call this per teleport; CONTINUOUS frames stay warm so
        # the fuzz exercises the certificate/replay/fast-commit paths.
        from symmap import sym as _sy2
        for nm, v in (('pmt_ok', 0), ('pm_lmv', 0), ('pm_okf', 0),
                      ('pmc_fld', 0), ('pmc_dfwd', 0xFF)):
            self.mem[_sy2(nm, banked=self.banked)] = v

    # --- try suite -----------------------------------------------------
    def try_move(self, cx, cy, z):
        self.cold()
        self.mem[sym('zp_br_pxraw_l')] = cx & 0xFF
        self.mem[sym('zp_br_pxraw_h')] = (cx >> 8) & 0xFF
        self.mem[sym('zp_br_pyraw_l')] = cy & 0xFF
        self.mem[sym('zp_br_pyraw_h')] = (cy >> 8) & 0xFF
        # exact-descent state (integer candidates: fracs 0, px2 = raw*2)
        from symmap import sym as _sy
        self.mem[_sy('PM_FXW')] = 0
        self.mem[_sy('PM_FXW') + 2] = 0
        for nm, v in (('zp_br_px2', cx * 2), ('zp_br_py2', cy * 2)):
            self.mem[_sy(nm + '_l')] = v & 0xFF
            self.mem[_sy(nm + '_h')] = (v >> 8) & 0xFF
        self.mem[self.vz] = z & 0xFF
        mpu = self.run(self.try_e)
        vz = self.mem[self.vz]
        return bool(mpu.p & 1), vz - (256 if vz >= 128 else 0)

    # --- momentum suite ------------------------------------------------
    def _w24(self, addr, v):
        v &= 0xFFFFFF
        self.mem[addr] = v & 0xFF
        self.mem[addr + 1] = (v >> 8) & 0xFF
        self.mem[addr + 2] = (v >> 16) & 0xFF

    def _r24(self, addr):
        v = self.mem[addr] | (self.mem[addr + 1] << 8) | (self.mem[addr + 2] << 16)
        return v - (1 << 24) if v >= (1 << 23) else v

    def _w16(self, addr, v):
        v &= 0xFFFF
        self.mem[addr] = v & 0xFF
        self.mem[addr + 1] = (v >> 8) & 0xFF

    def _r16(self, addr):
        v = self.mem[addr] | (self.mem[addr + 1] << 8)
        return v - 65536 if v >= 32768 else v

    def frame(self, st, fields, inbits):
        px88, py88, z, angidx, turnrem = st
        self._w24(abi.DV_PXF, px88)
        self._w24(abi.DV_PYF, py88)
        self.mem[abi.DV_ANGIDX] = angidx & 0xFF
        self.mem[self.vz] = z & 0xFF
        self.mem[abi.PM_TURNREM] = turnrem
        self.mem[abi.D_FWD] = 0xEE                  # poison: must be written
        self.run(self.frame_e, a=fields, x=inbits)
        # (the retired-momentum stay-zero assert died with the slots
        # themselves — the 2026-08-26 low-RAM map deleted PM_MOMX/Y)
        vz = self.mem[self.vz]
        return ((self._r24(abi.DV_PXF), self._r24(abi.DV_PYF),
                 vz - (256 if vz >= 128 else 0),
                 self.mem[abi.DV_ANGIDX],
                 self.mem[abi.PM_TURNREM]), self.mem[abi.D_FWD])


def suite_try(rig, verbose):
    m = colmap.build()
    bad = cases = 0
    for _, ws in poses():
        rig.pose(ws)
        for pi, p in enumerate(m['ports']):
            x1, y1, dx, dy = p[:4]
            ln = math.hypot(dx, dy) or 1
            nx, ny = -dy / ln, dx / ln
            for t in (0.3, 0.7):
                bx, by = x1 + dx * t, y1 + dy * t
                for off in (-20, -16, -12, 0, 12, 16, 20):
                    cx, cy = int(round(bx + nx * off)), int(round(by + ny * off))
                    if not (colmap.RAWX_MIN <= cx < colmap.RAWX_MIN + 36 * 128 and
                            colmap.RAWY_MIN <= cy < colmap.RAWY_MIN + 22 * 128):
                        continue
                    for z in (6, 0, 18):
                        a = colmap.try_move(0, 0, cx, cy, z, ws)
                        b = rig.try_move(cx, cy, z)
                        cases += 1
                        if (a[0], a[1] if a[0] else None) != (b[0], b[1] if b[0] else None):
                            bad += 1
                            if verbose and bad <= 4:
                                print(f'  port{pi} ({cx},{cy},z={z}) py={a} 65={b}')
        random.seed(4)
        for _ in range(600):
            cx = random.randint(colmap.RAWX_MIN, colmap.RAWX_MIN + 36 * 128 - 1)
            cy = random.randint(colmap.RAWY_MIN, colmap.RAWY_MIN + 22 * 128 - 1)
            a = colmap.try_move(0, 0, cx, cy, 6, ws)
            b = rig.try_move(cx, cy, 6)
            cases += 1
            if (a[0], a[1] if a[0] else None) != (b[0], b[1] if b[0] else None):
                bad += 1
                if verbose and bad <= 4:
                    print(f'  rnd ({cx},{cy}) py={a} 65={b}')
    return cases, bad


def _starts(ws):
    """(px88, py88, vz) seeds: the spawn, plus points 40 units off the
    outward normal of every 6th port (door/step faces are where the
    chunked application meets the aggregation rules).

    Every seed must be a position the player could actually STAND in —
    try_move onto itself passes. An unreachable seed (inside geometry,
    or in the void behind a wall) is not a state the game can produce,
    and walks from there just measure two implementations agreeing
    about nonsense."""
    m = colmap.build()
    cands = [(1056 - 1200, -3616 + 3248)]
    for p in m['ports'][::6]:
        x1, y1, dx, dy = p[:4]
        ln = math.hypot(dx, dy) or 1
        cands.append((int(round(x1 + dx * 0.5 - dy / ln * 40)),
                      int(round(y1 + dy * 0.5 + dx / ln * 40))))
    out = []
    for rx, ry in cands:
        ss = colmap.find_ss(rx, ry)
        vz = m['ss_vz'][ss]
        vz -= 256 if vz >= 128 else 0
        if not colmap.try_move(rx, ry, rx, ry, vz, ws)[0]:
            continue                            # not a standable spot
        out.append((rx * 32, ry * 32, vz))
    return out


def suite_mom(rig, verbose):
    """Multi-frame walks: each start x heading x key script, 12 frames,
    comparing EVERY frame's full state (a divergence that cancels out
    would still be a bug).  Input bits: b0 fwd, b1 back, b2 left, b3
    right.  The scripts exercise the turn accumulator's carry (a run of
    short frames must turn as far as the same time in long ones) and the
    turn-while-walking case, which is what makes the walk direction
    change mid-script."""
    F, B, L, R = 1, 2, 4, 8
    bad = cases = 0
    random.seed(11)
    scripts = [
        ('hold-fwd',    [(7, F)] * 12),
        ('hold-back',   [(7, B)] * 12),
        ('tap-stop',    [(7, F)] * 3 + [(7, 0)] * 9),
        ('both-keys',   [(7, F | B)] * 6 + [(7, F)] * 6),
        ('slow-frames', [(23, F)] * 6 + [(3, F)] * 6),
        ('stutter',     [(1, F), (14, F), (2, 0), (9, F)] * 3),
        ('turn-left',   [(7, L)] * 12),
        ('turn-right',  [(4, R)] * 12),
        ('turn-carry',  [(1, L)] * 8 + [(2, L)] * 4),
        ('turn-cancel', [(7, L | R)] * 6 + [(7, L)] * 6),
        ('walk-turn',   [(5, F | L)] * 6 + [(5, B | R)] * 6),
        ('turn-stutter', [(1, F | R), (13, F | R), (3, R), (8, F)] * 3),
    ]
    for pname, ws in poses():
        rig.pose(ws)
        for si, (px88, py88, vz) in enumerate(_starts(ws)):
            for ang in (0, 4, 8, 13, 32, 47):
                for sname, script in scripts:
                    py_st = (px88, py88, vz, ang, 0)
                    a_st = py_st
                    rig.cold()                   # teleport to the start
                    for fi, (fields, bits) in enumerate(script):
                        a = colmap.move_frame(a_st[0], a_st[1], a_st[2],
                                              a_st[3], a_st[4], fields,
                                              bool(bits & F), bool(bits & B),
                                              bool(bits & L), bool(bits & R),
                                              ws)
                        a_st, a_fwd = a[:5], a[5]
                        b_st, b_fwd = rig.frame(py_st, fields, bits)
                        py_st = b_st
                        cases += 1
                        if a_st != b_st or a_fwd != b_fwd:
                            bad += 1
                            if verbose and bad <= 6:
                                print(f'  {pname}/start{si}/ang{ang}/{sname} f{fi} '
                                      f'({fields}f,bits={bits})')
                                print(f'    py={a_st} dfwd={a_fwd}')
                                print(f'    65={b_st} dfwd={b_fwd}')
                            a_st = b_st          # resync: report each frame's
                                                 # own divergence, not an echo
                            rig.cold()           # (the resync itself is a
                                                 #  teleport for the caches)
    return cases, bad


def main():
    which = 'all'
    builds = [0, 1]
    for arg in sys.argv[1:]:
        if arg in ('try', 'mom', 'all'):
            which = arg
        elif arg == '--flat':
            builds = [0]
        elif arg == '--banked':
            builds = [1]
    total = 0
    for banked in builds:
        rig = Rig(banked)
        tag = 'banked' if banked else 'flat'
        for name, fn in (('try', suite_try), ('mom', suite_mom)):
            if which not in ('all', name):
                continue
            cases, bad = fn(rig, verbose=True)
            print(f'{tag:6s} {name}: {cases:6d} cases, {bad} divergent')
            total += bad
    print('TOTAL divergences:', total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
