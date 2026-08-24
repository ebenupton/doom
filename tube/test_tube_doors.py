#!/usr/bin/env python3
"""Every use line, through the REAL tubedrv loop: does the door open?

The existing copro gate presses SPACE on ONE door line and passes if any
ceil mover moves. That is enough to catch "the parasite has no use path
at all" (which it once didn't) and nothing finer. It is not enough:

  2026-08-24 -- half the doors on the map stopped opening on the tube.
  The trigger was fine, pmove_use was fine, the driver's SPACE plumbing
  was fine. The bbox angle cache's psi planes had been placed on top of
  colmap's flat tables, and every armed frame sprayed cached bytes over
  the TAIL of USETAB. Use lines 0-4 survived, 7 and 8 did not -- which
  door died depended on which node ids the cache had armed, so it read
  as intermittent. A single-door check cannot see that, and neither can
  a check that accepts "some mover moved": the lifts self-cycle, so
  something is always moving.

So: every use line, and the specific mover that line names, each from a
FRESHLY BOOTED machine. Resetting ANIM_WS between attempts is NOT a real
reset -- two use lines can name the same door (7 and 8 both drive mover
4) and the lazy table patcher keeps state outside the workspace, so a
workspace-only reset lets line 7 mask line 8.

tools/test_table_overlap.py gates the placement arithmetic directly.
This gates the behaviour, which is what actually shipped broken.
"""
import math, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
from py65.memory import ObservableMemory
from py65.devices.mpu65c02 import MPU
import colmap, symmap, anim_sectors as an, doom_wireframe as dw

STANDOFF = 20            # raw units in front of the line (USE_TRACE is 60)
SETTLE = 3               # frames with SPACE low, so the press is an EDGE
HOLD = 25                # frames with SPACE held


def build_image():
    path = os.path.join(ROOT, 'tube/test_copro_py65.py')
    head = open(path).read().split('def main():')[0]
    mod = type(sys)('tc')
    mod.__dict__['__file__'] = path
    exec(compile(head, 'tc', 'exec'), mod.__dict__)
    return mod.build_image()


def machine(img):
    """A freshly booted parasite: (memory, state, run-n-frames)."""
    base = ObservableMemory()
    base[0:0x10000] = img
    st = {'avail': False, 'polls': 0, 'eofs': 0, 'hudleft': 0,
          'space': 0, 'out': []}

    def r1s(a):
        if st['avail']:
            return 0xC0
        st['polls'] += 1
        if st['polls'] >= 2000:
            st['polls'] = 0
            st['avail'] = True
            return 0xC0
        return 0x40

    def r1dr(a):
        st['avail'] = False
        return st['space']

    def r1dw(a, v):
        st['out'].append(v)
        if len(st['out']) % 4:
            return
        c = st['out'][-4:]
        if st['hudleft']:
            st['hudleft'] -= 1
        elif c == [0xFE] * 4:
            st['hudleft'] = 3
        elif c == [0xFF] * 4:
            st['eofs'] += 1

    base.subscribe_to_read([0xFEF8], r1s)
    base.subscribe_to_read([0xFEF9], r1dr)
    base.subscribe_to_write([0xFEF9], r1dw)
    mpu = MPU(memory=base)
    mpu.pc, mpu.sp = 0xEA03, 0xDD

    def run(frames, cap=8_000_000):
        tgt, n = st['eofs'] + frames, 0
        while st['eofs'] < tgt and n < cap:
            mpu.step()
            n += 1
        return n < cap

    return base, st, run


def attempt(img, T, AW, NW, x1, y1, dx, dy, act, side):
    """Boot, stand STANDOFF units off the line facing it, press SPACE."""
    mx, my = x1 + dx / 2, y1 + dy / 2
    L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L, dx / L
    px = int(mx + nx * STANDOFF * side)
    py = int(my + ny * STANDOFF * side)
    ang = math.atan2(-ny * side, -nx * side)
    ai = int(round(ang / (math.pi / 32))) % 64

    base, st, run = machine(img)
    if not run(2):
        return None, ai
    st['space'] = 0
    run(SETTLE)
    for nm, raw in (('PX', px), ('PY', py)):
        v = (raw * 256 // dw.PRESCALE) & 0xFFFFFF
        base[T['DV_' + nm + 'F']] = v & 0xFF
        base[T['DV_' + nm + 'L']] = (v >> 8) & 0xFF
        base[T['DV_' + nm + 'H']] = (v >> 16) & 0xFF
    base[T['DV_ANGIDX']] = ai
    before = bytes(base[AW:AW + NW])
    st['space'] = 0x80
    run(HOLD)
    after = bytes(base[AW:AW + NW])
    return before[3 * act:3 * act + 3] != after[3 * act:3 * act + 3], ai


def main():
    img = build_image()
    T = {}
    for l in open(os.path.join(ROOT, 'tube/tube_syms.inc')):
        m = re.match(r'T_(\w+) = &([0-9A-F]+)', l.strip())
        if m:
            T[m.group(1)] = int(m.group(2), 16)
    AW = symmap.sym('ANIM_WS', banked=0, c02=1)
    NW = 3 * len(an.MOVERS)
    lines = colmap.build()['use_lines']

    ok = True
    for li, (x1, y1, dx, dy, act) in enumerate(lines):
        if act == 0xFE:
            # The exit switch names no mover, and the tube has no respawn
            # to port it to (walk_drv's `CMP #&FE : JSR respawn` has no
            # counterpart). Checking "did anything move" would pass on a
            # self-cycling lift, so say plainly that it is unchecked
            # rather than bank a false green.
            print(f'  use line {li}: action {act:#04x} -> SKIPPED '
                  f'(exit switch; not ported to the tube)')
            continue
        fired = None
        for side in (+1, -1):
            moved, ai = attempt(img, T, AW, NW, x1, y1, dx, dy, act, side)
            if moved is None:
                print(f'  use line {li}: the parasite never booted')
                break
            if moved:
                fired = (side, ai)
                break
        if fired:
            print(f'  use line {li}: action {act:#04x} -> mover moved '
                  f'(side {fired[0]:+d}, angidx {fired[1]})')
        else:
            ok = False
            print(f'  use line {li}: action {act:#04x} -> '
                  f'*** NOTHING MOVED from either side ***')

    print('TUBEDOORS: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
