#!/usr/bin/env python3
"""Frame-by-frame Tube convergence along a forward walk.

Per frame N of a scripted mask sequence (stand, then UP held):
  copro side : the real COPROT driver + parasite image run in py65; at
               each EOF the frame's line commands AND the engine-input
               ZP set the driver wrote ($00-$0A, $90-$93, $9D/$9E,
               bca_ab) are snapshotted.
  host side  : the real HOSTT rasterizes the frame's commands (drawcmd
               entry) into a cleared $5800 buffer.
  reference  : ONE persistent flat BspRender6502 instance walks the
               same frames — per frame its FB is cleared, the SAME ZP
               inputs are poked, and br_view_setup/span_init/
               br_render_frame run with the real NJ + plotters.
  gate       : FBs must match byte-exact, every frame.
Also mirrors the driver's movement math (step_tab/bounds/derive_raw)
in python and checks the driver's position/angle vars every frame.
"""
import math
import os, sys, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import symmap
from py65.devices.mpu6502 import MPU
from py65.devices.mpu65c02 import MPU as MPU_C02
from py65.memory import ObservableMemory

FRAMES = int(os.environ.get('TUBE_WALK_FRAMES', '30'))
MASKS = [0, 0] + [1] * (FRAMES - 2)          # settle, then UP held
SPEED = 12
DRVVARS = 0xEA06                             # angidx..pyh (after the two JMPs)
ZPSET = list(range(0x00, 0x0B)) + [0x90, 0x91, 0x92, 0x93, 0x9D, 0x9E]


def copro_walk():
    src = open('tube/test_copro_py65.py').read()
    ns = {'__name__': 'lib', '__file__': os.path.abspath('tube/test_copro_py65.py')}
    exec(compile(src.replace("if __name__ == '__main__':\n    main()", ""),
                 'tcp', 'exec'), ns)
    img = ns['build_image']()
    base = ObservableMemory()
    base[0:0x10000] = img
    st = {'avail': False, 'polls': 0, 'cur': [], 'frames': [], 'f': 0}

    def r1s(a):
        if st['avail']:
            return 0xC0
        st['polls'] += 1
        if st['polls'] >= 500:
            st['polls'] = 0
            st['avail'] = True
            return 0xC0
        return 0x40

    def r1d(a):
        st['avail'] = False
        return MASKS[min(st['f'], len(MASKS) - 1)]

    def r1w(a, v):
        st['cur'].append(v)
        if len(st['cur']) >= 4 and st['cur'][-4:] == [0xFF] * 4:
            cmds = [tuple(st['cur'][i:i+4]) for i in range(0, len(st['cur']) - 4, 4)]
            zp = {a2: base[a2] for a2 in ZPSET}
            zp['bca_ab'] = base[symmap.sym('bca_ab')]
            drv = bytes(base[DRVVARS:DRVVARS + 8])
            st['frames'].append((cmds, zp, drv))
            st['cur'] = []
            st['f'] += 1

    base.subscribe_to_read([0xFEF8], r1s)
    base.subscribe_to_read([0xFEF9], r1d)
    base.subscribe_to_write([0xFEF9], r1w)
    mpu = MPU_C02(memory=base)              # the copro is a 65C02
    mpu.pc = 0xEA03
    mpu.sp = 0xFD
    steps = 0
    while len(st['frames']) < FRAMES and steps < 3_000_000 * FRAMES:
        for _ in range(50000):
            mpu.step()
        steps += 50000
    assert len(st['frames']) >= FRAMES, f"only {len(st['frames'])} frames"
    return st['frames'][:FRAMES]           # a fast copro can overshoot the
                                           # final step burst by a frame


class HostRaster:
    def __init__(self):
        subprocess.run(['./beebasm', '-i', 'tube/hostg.asm'], check=True,
                       capture_output=True)
        host = open('HOSTT', 'rb').read()
        os.remove('HOSTT')
        self.mpu = MPU()
        self.mpu.memory[0x1900:0x1900 + len(host)] = list(host)
        self.mpu.memory[0x70] = 0x58  # HOST fb

    def frame(self, cmds):
        m = self.mpu.memory
        for i in range(0x5800, 0x6C00):
            m[i] = 0
        for x0, y0, x1, y1 in cmds:
            m[0x82], m[0x83], m[0x84], m[0x85] = x0, y0, x1, y1
            self.mpu.pc = 0x1903
            self.mpu.sp = 0xFD
            m[0x1FF] = 0xFF; m[0x1FE] = 0xFF
            n = 0
            while self.mpu.pc != 0 and n < 200_000:
                self.mpu.step(); n += 1
            assert self.mpu.pc == 0, f"drawcmd wedged on {(x0, y0, x1, y1)}"
        return bytes(m[0x5800:0x6C00])


class FlatRef:
    def __init__(self):
        self.r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                               dw.packed_rom_detail, dw.packed_bbox_table,
                               dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        self.m = self.r.sc.mpu.memory
        self.m[0x70] = 0xEA
        self.entries = [symmap.sym('anim_tick'), symmap.sym('br_view_setup'),
                        symmap.sym('span_init'), symmap.sym('br_render_frame')]
        self.m[symmap.sym('ANIM_ENABLE')] = 1
        self._call(symmap.sym('anim_init'))

    def _call(self, e):
        mpu = self.r.sc.mpu
        m = self.m
        mpu.pc = e
        mpu.sp = 0xFD
        m[0x1FF] = 0xFF; m[0x1FE] = 0xFF
        n = 0
        while mpu.pc != 0 and n < 3_000_000:
            mpu.step(); n += 1
        assert mpu.pc == 0, f"flat entry &{e:04X} wedged"

    def frame(self, zp):
        m = self.m
        for i in range(0xEA00, 0xFE00):
            m[i] = 0
        for a, v in zp.items():
            if a == 'bca_ab':
                m[symmap.sym('bca_ab')] = v
            else:
                m[a] = v
        for e in self.entries:
            self._call(e)
        return bytes(m[0xEA00:0xFE00])


def movement_mirror():
    """python replica of the driver's step/bounds/VZ-free position core."""
    step = []
    for i in range(64):
        dx = int(SPEED * 32 * math.cos(i * math.pi / 32) + 65536.5) & 0xFFFF
        dy = int(SPEED * 32 * math.sin(i * math.pi / 32) + 65536.5) & 0xFFFF
        step.append((dx, dy))
    px = int((1056 - dw.MAP_CENTER_X) * 256 / dw.PRESCALE) & 0xFFFFFF
    py = int((-3616 - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE) & 0xFFFFFF
    ang = 16
    seq = []

    def s24(v):
        return v - 0x1000000 if v & 0x800000 else v

    def raws(v):
        return (s24(v) >> 5) & 0xFFFF

    def s16(v):
        return v - 0x10000 if v & 0x8000 else v

    def inb(x88, y88):
        rx, ry = s16(raws(x88)), s16(raws(y88))
        return -1936 <= rx <= 2576 and -1582 <= ry <= 1170

    for mask in MASKS:
        if mask & 4:
            ang = (ang + 1) & 63
        if mask & 8:
            ang = (ang - 1) & 63
        if mask & 1:
            dx, dy = step[ang]
            nx = (px + (dx | (0xFF0000 if dx & 0x8000 else 0))) & 0xFFFFFF
            ny = (py + (dy | (0xFF0000 if dy & 0x8000 else 0))) & 0xFFFFFF
            if inb(nx, ny):
                px, py = nx, ny
        if mask & 2:
            dx, dy = step[ang]
            nx = (px - (dx | (0xFF0000 if dx & 0x8000 else 0))) & 0xFFFFFF
            ny = (py - (dy | (0xFF0000 if dy & 0x8000 else 0))) & 0xFFFFFF
            if inb(nx, ny):
                px, py = nx, ny
        seq.append((ang, px, py))
    return seq


def main():
    frames = copro_walk()
    host = HostRaster()
    ref = FlatRef()
    mirror = movement_mirror()
    bad = 0
    for n, (cmds, zp, drv) in enumerate(frames):
        ang, px, py = mirror[n]
        dang = drv[0]
        dpx = drv[2] | (drv[3] << 8) | (drv[4] << 16)
        dpy = drv[5] | (drv[6] << 8) | (drv[7] << 16)
        pose = 'ok'
        if (dang, dpx, dpy) != (ang, px, py):
            pose = f"POSE MISMATCH drv=({dang},{dpx:06x},{dpy:06x}) py=({ang},{px:06x},{py:06x})"
        fb_t = host.frame(cmds)
        fb_r = ref.frame(zp)
        diff = sum(1 for a, b in zip(fb_r, fb_t) if a != b)
        mark = '' if diff == 0 and pose == 'ok' else '   <<<<'
        print(f"frame {n:3d}: {len(cmds):3d} cmds, fb diff {diff:4d}  {pose}{mark}")
        if diff or pose != 'ok':
            bad += 1
    print("WALK CONVERGENCE:", "PASS" if bad == 0 else f"FAIL ({bad} frames)")
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
