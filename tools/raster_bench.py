#!/usr/bin/env python3
"""Standalone cycle testbench for the NJ rasteriser blob.

No engine: the blob is loaded at its real ORG into a bare py65 MPU and fed
the canned workload captured from the engine (tools/raster_capture.py).
That makes a layout experiment a ~2 s measurement instead of a full render
suite, and it isolates the rasteriser's own cycles from everything else.

py65 models both layout-dependent 6502 penalties exactly:
  - a TAKEN relative branch costs +1 more when the target is on a different
    page from the byte after the branch (BranchRelAddr)
  - an absolute-indexed READ costs +1 more when base_lo + index carries
so a single-step census of per-instruction cycle deltas attributes every
layout-dependent cycle to its site with no decoding guesswork: a branch
delta of 2 = not taken, 3 = taken, 4 = taken across a page.

Usage:
    python3 tools/raster_bench.py [--flat] [--blob PATH] [--org ADDR]
"""
import os, sys, json, hashlib, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from py65.devices.mpu6502 import MPU

BANKED = dict(blob='linedraw_or_reloc.bin', org=0xA200, budget=0x0C00)
# FLAT retired 2026-09-05: the flat blob was dead output (see
# asmbuild._build_raster).  The second live layout is the tube HOST's.
FLAT = dict(blob='linedraw_or_reloc.bin', org=0xA200, budget=0x0C00)
# The tube HOST carries its own copy: hostg.s .includes the same raster
# sources, so HOSTT is a THIRD layout of this code and the one that draws
# every pixel in the copro build.  Here the image is the whole program and
# the entry is linedraw4 inside it.

# the blob's ZP interface (src/boot/linedraw_or.s)
ZP = dict(scr=0x74, scrstrt=0x70, cnt=0x79, err=0x76, errs=0x7A,
          dx=0x80, dy=0x81, x0=0x82, y0=0x83, x1=0x84, y1=0x85,
          ls=0x86, b=0x87)
HALT = 0xFF00
BRANCH_OPS = frozenset((0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0))
IDX_READ = frozenset((0xBD, 0xB9, 0xBC, 0xBE, 0x1D, 0x19, 0x3D, 0x39,
                      0x5D, 0x59, 0x7D, 0x79, 0xDD, 0xD9, 0xFD, 0xF9,
                      0x3C, 0x1C))
ABSY = frozenset((0xB9, 0xBE, 0x19, 0x39, 0x59, 0x79, 0xD9, 0xF9))


def load_workload(path=None):
    """The canned engine workload.  Tracked at the repo root so the gate is
    deterministic and fast; build/ is where a fresh capture lands."""
    for p in ([path] if path else [os.path.join(ROOT, 'raster_workload.json'),
                                   os.path.join(ROOT, 'build',
                                                'raster_workload.json')]):
        if p and os.path.exists(p):
            return json.load(open(p))
    sys.exit('raster_workload.json missing — run tools/raster_capture.py')


class Bench:
    def __init__(self, blob=None, org=None, flat=False, image=None,
                 entry=None, budget=None, name=None):
        cfg = FLAT if flat else BANKED
        self.org = org if org is not None else cfg['org']
        self.entry = entry if entry is not None else self.org
        self.path = os.path.join(ROOT, blob or cfg['blob'])
        self.budget = budget or cfg['budget']
        self.name = name or os.path.basename(self.path)
        self.reload(image)

    def reload(self, image=None):
        self.image = image if image is not None else open(self.path, 'rb').read()
        self.entry = getattr(self, 'entry', self.org)
        assert len(self.image) <= self.budget, \
            f'blob {len(self.image)} B overruns its {self.budget} B budget'
        self.mpu = MPU()
        m = self.mpu.memory
        m[self.org:self.org + len(self.image)] = list(self.image)
        m[HALT] = 0x00                      # BRK: the return lands here
        self.pristine = bytes(self.image)   # SMC restore point

    def clear_fb(self, scrstrt=0x58):
        base = scrstrt << 8
        self.mpu.memory[base:base + 5120] = [0] * 5120

    def run_line(self, x0, y0, x1, y1, scrstrt=0x58, census=None):
        """One JSR into the blob.  Returns cycles.  `census`, if given, is a
        dict updated with per-site layout-dependent costs."""
        mpu = self.mpu
        m = mpu.memory
        m[ZP['x0']], m[ZP['y0']] = x0, y0
        m[ZP['x1']], m[ZP['y1']] = x1, y1
        m[ZP['scrstrt']] = scrstrt
        mpu.pc = self.entry
        mpu.sp = 0xDD
        mpu.p = 0x30
        # return address for the cores' RTS -> HALT
        m[0x01DD] = (HALT - 1) >> 8
        m[0x01DC] = (HALT - 1) & 0xFF
        mpu.sp = 0xDB
        mpu.processorCycles = 0
        n = 0
        while mpu.pc != HALT:
            pc = mpu.pc
            op = m[pc]
            ix = (mpu.y if op in ABSY else mpu.x) if op in IDX_READ else 0
            pre = mpu.processorCycles
            mpu.step()
            if census is not None:
                d = mpu.processorCycles - pre
                if op in BRANCH_OPS:
                    s = census.setdefault(pc, dict(kind='branch', op=op,
                                                   n=0, taken=0, cross=0))
                    s['n'] += 1
                    if d >= 3:
                        s['taken'] += 1
                        if d >= 4:
                            s['cross'] += 1
                elif d and self.org <= pc < self.org + len(self.image):
                    # absolute-indexed reads: 4 cycles, 5 across a page.  Only
                    # sites whose BASE is inside the blob are layout-dependent
                    # (framebuffer (scr),Y is data, and never counted here).
                    if op in IDX_READ:
                        base = m[pc + 1] | (m[pc + 2] << 8)
                        if self.org <= base < self.org + len(self.image):
                            s = census.setdefault(pc, dict(kind='indexed',
                                                           op=op, n=0,
                                                           taken=0, cross=0,
                                                           idx={}))
                            s['n'] += 1
                            s['taken'] += 1
                            # the index value decides the carry at ANY base,
                            # so keep its histogram: the layout model needs
                            # P(base_lo + index > 255), not just today's rate
                            s['idx'][ix] = s['idx'].get(ix, 0) + 1
                            if d >= 5:
                                s['cross'] += 1
            n += 1
            if n > 200000:
                raise RuntimeError(f'runaway from ({x0},{y0})-({x1},{y1})')
        return mpu.processorCycles

    def run_workload(self, wl, census=None, fb_hash=True):
        """Replay the canned workload.  Returns (total_cycles, fb_digest)."""
        self.mpu.memory[self.org:self.org + len(self.pristine)] = \
            list(self.pristine)                      # undo the previous SMC
        self.clear_fb()
        total = 0
        for (x0, y0, x1, y1), scr in zip(wl['lines'], wl['scrstrt']):
            total += self.run_line(x0, y0, x1, y1, scr, census)
        dig = None
        if fb_hash:
            base = 0x58 << 8
            dig = hashlib.sha256(
                bytes(self.mpu.memory[base:base + 5120])).hexdigest()[:16]
        return total, dig


def measure(bench, wl):
    """(total_cycles, fb_digest, weights, idx_hist) keyed by BLOB OFFSET —
    offsets are layout-invariant identities, PCs are not."""
    census = {}
    total, dig = bench.run_workload(wl, census)
    w = {pc - bench.org: s['taken'] for pc, s in census.items()
         if s['kind'] == 'branch'}
    ih = {pc - bench.org: s['idx'] for pc, s in census.items()
          if s['kind'] == 'indexed'}
    return total, dig, w, ih


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--flat', action='store_true')
    ap.add_argument('--blob'); ap.add_argument('--org', type=lambda s: int(s, 0))
    ap.add_argument('--top', type=int, default=20)
    a = ap.parse_args()
    wl = load_workload()
    b = Bench(a.blob, a.org, a.flat)
    census = {}
    total, dig = b.run_workload(wl, census)
    nfr = len(wl['frames'])
    print(f'blob {b.name} at ${b.org:04X}, '
          f'{len(b.image)} B (budget {b.budget}, slack {b.budget - len(b.image)})')
    print(f'{len(wl["lines"])} lines over {nfr} frames')
    print(f'TOTAL {total:,} cyc   MEAN {total / nfr:,.1f} cyc/frame   fb {dig}')
    bx = sum(s['cross'] for s in census.values() if s['kind'] == 'branch')
    ix = sum(s['cross'] for s in census.values() if s['kind'] == 'indexed')
    print(f'layout-dependent: {bx:,} branch page-crossings + {ix:,} indexed '
          f'= {bx + ix:,} cyc ({(bx + ix) / total:.2%} of the blob), '
          f'{(bx + ix) / nfr:,.1f} cyc/frame')
    rows = sorted(census.values(), key=lambda s: -s['cross'])
    print(f'\n{"site":>7} {"kind":8} {"exec":>8} {"taken":>8} {"cross":>8}')
    for s in rows[:a.top]:
        if not s['cross']:
            break
        pc = [k for k, v in census.items() if v is s][0]
        print(f'${pc:04X}  {s["kind"]:8} {s["n"]:8,} {s["taken"]:8,} '
              f'{s["cross"]:8,}')


if __name__ == '__main__':
    main()
