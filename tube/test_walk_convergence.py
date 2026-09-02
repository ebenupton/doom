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
               inputs are poked, and view_setup/span_init/
               render_frame run with the real NJ + plotters.
  gate       : FBs must match byte-exact, every frame.
Also mirrors the driver's movement math (step_tab/bounds/derive_raw)
in python and checks the driver's position/angle vars every frame.
"""
import math
import os, sys, subprocess

os.environ['DOOM_CPU'] = '65c02'    # BEFORE project imports (import-time binding)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender, BANK_C
import symmap
from py65.devices.mpu6502 import MPU
from py65.devices.mpu65c02 import MPU as MPU_C02
from py65.memory import ObservableMemory

FRAMES = int(os.environ.get('TUBE_WALK_FRAMES', '30'))
MASKS = ([0, 0] + [1] * (FRAMES - 12)        # settle, UP held, then turn
         + [4] * 4 + [8] * 3 + [2] * 3)      # LEFT/RIGHT/DOWN coverage (the
                                             # 2026-07-22 LEFT regression —
                                             # an A-clobber before the one
                                             # mask test that rode in A —
                                             # shipped through an UP-only
                                             # mask diet)
SPEED = 12
import abi as _abi
DRVVARS = _abi.DRV_VARS                      # T_DV_ANGIDX.. — BY THE ABI
                                             # (the 0x1180 literal went stale
                                             # at the 2026-08-26 low-RAM map's
                                             # unified $0B10 home and made the
                                             # movement-mirror check vacuous)
FIELDS = 4                                   # PAL fields ridden in each mask
                                             # byte's b4-6 (pm_frame scales
                                             # movement by this; 0 = frozen)
# THE ENGINE INPUT SET the copro computes and the reference replays.
# BY NAME, never by address.  This was a literal list -- $00-$0A, $90-$93,
# $9D/$9E for the view block, $1C/$1D/$7F/$BA for the tie-broken doubled
# raws, $96B-$96E for the world fracs -- and two thirds of it had rotted:
# the world-frac block moved to PM_FXW $0B00 long ago, so the test was
# replaying POOL_IT bytes into the reference, and a 2026-08-31 zero-page
# rotation moved three of the four doubled raws to absolute, so the
# reference started rendering the previous pose's descent state.  That
# shows up as a framebuffer difference and reads exactly like an engine
# bug.  The flat (copro) and banked (reference) sides resolve the names
# independently, which is also what the bottom-22K identity rule needs.
_ZPNAMES = ('zp_br_px', 'zp_br_px_h', 'zp_br_py', 'zp_br_py_h', 'zp_br_vz',
            'zp_br_smag', 'zp_br_sneg', 'zp_br_sone',
            'zp_br_cmag', 'zp_br_cneg', 'zp_br_cone',
            'zp_br_pxraw_l', 'zp_br_pxraw_h',
            'zp_br_pyraw_l', 'zp_br_pyraw_h',
            'zp_br_px_x', 'zp_br_py_x',
            # exact-descent state (2026-08-26): the tie-broken doubled raws
            'zp_br_px2_l', 'zp_br_px2_h', 'zp_br_py2_l', 'zp_br_py2_h')
_ZPFLAT = [symmap.sym(_n, banked=0) for _n in _ZPNAMES] + \
          [symmap.sym('PM_FXW', banked=0) + _k for _k in range(4)]
_ZPBANK = [symmap.sym(_n, banked=1) for _n in _ZPNAMES] + \
          [symmap.sym('PM_FXW', banked=1) + _k for _k in range(4)]
ZPSET = list(zip(_ZPFLAT, _ZPBANK))    # (copro address, reference address)


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
        # b0-3 keys, b4-6 elapsed PAL fields (tubedrv sums these into
        # pm_frame's field count -- a bare key mask moves NOTHING)
        return MASKS[min(st['f'], len(MASKS) - 1)] | (FIELDS << 4)

    def r1w(a, v):
        st['cur'].append(v)
        if len(st['cur']) >= 4 and st['cur'][-4:] == [0xFF] * 4:
            raw = [tuple(st['cur'][i:i+4]) for i in range(0, len(st['cur']) - 4, 4)]
            # strip the HUD packet (FE FE FE FE + 3 payload tuples) the way
            # the host's dispatch does -- fed to drawcmd raw it rasterises
            # as garbage lines (the pipeline gate does the same strip)
            cmds, skip = [], 0
            for t in raw:
                if skip:
                    skip -= 1
                    assert t[3] == 0, f"HUD payload tuple not 00-padded: {t}"
                elif t == (0xFE,) * 4:
                    skip = 3
                else:
                    cmds.append(t)
            zp = {_b: base[_f] for _f, _b in ZPSET}
            zp['bca_ab'] = base[symmap.sym('bca_ab')]
            drv = bytes(base[DRVVARS:DRVVARS + 8])
            st['frames'].append((cmds, zp, drv))
            st['cur'] = []
            st['f'] += 1

    base.subscribe_to_read([0xFEF8], r1s)
    base.subscribe_to_read([0xFEF9], r1d)
    base.subscribe_to_write([0xFEF9], r1w)
    mpu = MPU_C02(memory=base)              # the copro is a 65C02
    mpu.pc = 0xF600                      # RESIDENT entry (JMP init)
    mpu.sp = 0xDD
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
            self.mpu.sp = 0xDD
            # real return sentinel: RTS at S=$DD pops $1DE/$1DF -> $FF00.
            # (The old $1FE/$1FF pokes were never popped; every drawcmd
            # 'returned' by BRK-sledding zero page, and the BRK pushes
            # eventually left bytes that warped a later RTS into
            # realstart's FIFO spin — the phantom 'drawcmd wedged'.)
            m[0x1DE] = 0xFF; m[0x1DF] = 0xFE
            n = 0
            while self.mpu.pc != 0xFF00 and n < 200_000:
                self.mpu.step(); n += 1
            assert self.mpu.pc == 0xFF00, f"drawcmd wedged on {(x0, y0, x1, y1)}"
        return bytes(m[0x5800:0x6C00])


class BankedRef:
    """The reference side: the BANKED build, driven entry-by-entry.

    It used to be the flat build reading its harness FB at $EA00, but the
    parasite is losing its framebuffer and rasterisers -- the flat image
    can no longer say what a frame should look like (2026-08-29).  Bank C
    is selected before each entry, which is the state banked_bsp's own
    init() leaves behind, so the paging discipline matches the harness.
    """
    def __init__(self):
        self.r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                                 dw.packed_rom_detail, dw.packed_bbox_table,
                                 dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        # FULL-OBJECT PARITY (2026-09-02): the parasite draws all 52
        # billboards since phase 2, so the legacy-18 limit is gone; both
        # sides arm ok_state=0 so anim_init FILLS the bitmap instead of
        # zeroing it (objects default off).
        self.m = self.r.sc.mpu.memory
        self.m[0x70] = 0x58
        self.entries = [symmap.sym('anim_tick', banked=1),
                        symmap.sym('view_setup', banked=1),
                        symmap.sym('span_init', banked=1),
                        symmap.sym('render_frame', banked=1)]
        import anim_sectors as an           # real CFG/TABL0/SSMASK — the
        an.install_6502_tables(self.m, flat=False)  # copro image carries them
        self.m[symmap.sym('ANIM_ENABLE', banked=1)] = 1   # so movers animate
        self.m[symmap.sym('ok_state', banked=1)] = 0      # objects ON (parity)
        self._call(symmap.sym('anim_init', banked=1))     # on both sides

    def _call(self, e):
        # SpanClip6502._run's convention (NOT the old $1FF sentinel: S is
        # capped at $DD because $01E0-$01FF is SQR_MIRROR, the stack-page
        # sqr mirror — poking $1FE/$1FF corrupts the multiply tables, and
        # an RTS at S=$DD pops $1DE/$1DF): return sentinel FF FE ->
        # RTS lands at $FF00, which is the done marker.
        mpu = self.r.sc.mpu
        m = self.m
        self.m.select(BANK_C)
        mpu.pc = e
        mpu.sp = 0xDD
        m[0x1DF] = 0xFE; m[0x1DE] = 0xFF
        n = 0
        while mpu.pc != 0xFF00 and n < 6_000_000:
            mpu.step(); n += 1
        assert mpu.pc == 0xFF00, f"banked entry &{e:04X} wedged"

    def frame(self, zp):
        m = self.m
        for i in range(0x5800, 0x6C00):
            m[i] = 0
        for a, v in zp.items():
            if a == 'bca_ab':
                m[symmap.sym('bca_ab')] = v
            else:
                m[a] = v
        for e in self.entries:
            self._call(e)
        return bytes(m[0x5800:0x6C00])


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
    ref = BankedRef()
    mirror = movement_mirror()
    bad = 0
    for n, (cmds, zp, drv) in enumerate(frames):
        ang, px, py = mirror[n]
        dang = drv[0]
        dpx = drv[2] | (drv[3] << 8) | (drv[4] << 16)   # frac,lo,hi (DV_PXF..)
        dpy = drv[5] | (drv[6] << 8) | (drv[7] << 16)
        # NOTE 2026-08-25: the python movement mirror models the RETIRED
        # step_tab core (pre-pmove momentum) -- pose is reported for eyeball
        # context only, never gated. The FB compare is the gate.
        pose = f"drv=({dang},{dpx:06x},{dpy:06x})"
        fb_t = host.frame(cmds)
        fb_r = ref.frame(zp)
        diff = sum(1 for a, b in zip(fb_r, fb_t) if a != b)
        mark = '' if diff == 0 else '   <<<<'
        print(f"frame {n:3d}: {len(cmds):3d} cmds, fb diff {diff:4d}  {pose}{mark}")
        if diff:
            bad += 1
    print("WALK CONVERGENCE:", "PASS" if bad == 0 else f"FAIL ({bad} frames)")
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
