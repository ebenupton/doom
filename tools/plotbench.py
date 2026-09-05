#!/usr/bin/env python3
"""Freestanding testbench for the FROZEN pixel-plumbing layer in bank C.

WHY BANK C, AND WHY FREESTANDING.  The plot layer -- the NJ rasteriser, the
run plotter plot_h, the unrolled vertical columns and plot_v, the fused
rectangle, the framebuffer clears -- is finished code.  It is not being
edited, so alignment work on it holds, which is exactly what makes it worth
attacking: a page-crossing branch costs a cycle every time it is taken, and
that cost is bought purely by where the code sits.  The layer lives entirely
in bank C, so bank C's page alignment AS BUILT is the baseline.

This bench lifts bank C out of the engine and runs it on a bare 6502:
  capture   run the banked engine over the standard corpus and record, for
            every call into a frozen entry, the complete input state (zero
            page + registers) and the cycles the engine spent in it
  replay    restore each call on a bare MPU with bank C mapped at $8000 and
            re-run it, asserting the cycle count matches the engine EXACTLY

That equality is the whole point: it proves the freestanding rig is the
engine for this code, so a layout experiment costs seconds instead of a
render suite, and any cycle it reports is a cycle the engine would pay.

Usage:
    python3 tools/plotbench.py capture     # -> build/plot_workload.npz
    python3 tools/plotbench.py replay      # freestanding, vs the engine
    python3 tools/plotbench.py census      # where the layout tax sits
"""
import os, sys, json, argparse, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

BANKC_BIN = os.path.join(ROOT, 'build', 'bankc_image.bin')
LOWRAM_BIN = os.path.join(ROOT, 'build', 'plotbench_lowram.bin')
WORKLOAD = os.path.join(ROOT, 'build', 'plot_workload.npz')

# The frozen entries, by symbol.  Each is a leaf: it touches zero page, the
# framebuffer and bank C tables, and returns.  (vplot's unrolled columns are
# reached from plot_v, not called directly.)
ENTRIES = ('RASTER_ENTRY', 'plot_h', 'plot_v', 'fused_above_raw',
           'fused_below_raw', 'fb_clr0', 'fb_clr1', 'fb_clr_back')
FB_BASE, FB_SIZE = 0x5800, 5120
HALT = 0xFF00
BRANCH_OPS = frozenset((0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0))
IDX_READ = frozenset((0xBD, 0xB9, 0xBC, 0xBE, 0x1D, 0x19, 0x3D, 0x39,
                      0x5D, 0x59, 0x7D, 0x79, 0xDD, 0xD9, 0xFD, 0xF9))


def _engine():
    os.chdir(ROOT)
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
    import pygame
    pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from banked_bsp import BankedBspRender
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    return r, dw


def cmd_capture(a):
    import numpy as np
    import compare_renders as C
    import symmap
    from banked_bsp import BANK_C
    r, dw = _engine()
    sym = {n: symmap.sym(n, banked=1) for n in ENTRIES}
    pc2name = {v: k for k, v in sym.items()}
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory

    # bank C exactly as the engine built it -- code, tables and all
    bankc = bytes(r.bm._banks[BANK_C])
    os.makedirs(os.path.dirname(BANKC_BIN), exist_ok=True)
    open(BANKC_BIN, 'wb').write(bankc)

    # STATE FIDELITY.  These are not pure zero-page leaves: fused_below_raw
    # reads span-pool and column state out of low RAM, and the vertical
    # columns SMC-arm an RTS in bank C that survives between calls.  So the
    # capture carries the FULL machine state at every entry, as a delta.
    #
    # The delta is measured from the RETURN of the previous call, not from
    # its entry.  That is the state the bench actually holds when it gets
    # there, and the difference is not academic: the clipper writes the
    # rasteriser's zero-page scratch between calls and often restores it, so
    # an entry-to-entry delta omits exactly the bytes the bench got wrong
    # and the vertical columns then ran off the end of the unrolled block.
    names = list(ENTRIES)
    recs = []                      # (entry_idx, cycles, a, x, y, p)
    didx, dval, dlen = [], [], []
    zps = []
    prev = None

    def traced(entry, max_cycles=10_000_000):
        nonlocal prev
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        pend = None
        while mpu.pc != HALT:
            pc = mpu.pc
            if pend is None and pc in pc2name:
                zps.append(bytes(mem[0:256]))
                cur = np.array(mem[0:0xC000], dtype=np.uint8)
                if prev is None:
                    d = np.arange(0xC000, dtype=np.int32)
                else:
                    d = np.nonzero(cur != prev)[0].astype(np.int32)
                d = d[(d < FB_BASE) | (d >= FB_BASE + FB_SIZE)]
                didx.append(d); dval.append(cur[d]); dlen.append(len(d))
                prev = cur
                pend = (names.index(pc2name[pc]), mpu.processorCycles, mpu.sp,
                        mpu.a, mpu.x, mpu.y, mpu.p)
            mpu.step()
            if pend is not None and mpu.sp > pend[2]:
                recs.append((pend[0], mpu.processorCycles - pend[1],
                             pend[3], pend[4], pend[5], pend[6], pend[2]))
                pend = None
                prev = np.array(mem[0:0xC000], dtype=np.uint8)
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles

    sc._run = traced
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    np.savez_compressed(
        WORKLOAD,
        entry=np.array([x[0] for x in recs], dtype=np.uint8),
        cycles=np.array([x[1] for x in recs], dtype=np.int32),
        regs=np.array([[x[2], x[3], x[4], x[5], x[6]] for x in recs],
                      dtype=np.uint8),      # a, x, y, p, sp
        didx=np.concatenate(didx), dval=np.concatenate(dval),
        dlen=np.array(dlen, dtype=np.int32),
        # Zero page in FULL at every entry, not just as a delta.  A delta is
        # measured against the engine's own residue, and a layout experiment
        # changes what the code under test leaves behind: the rasteriser
        # reuses x1/y1 as its jump vector, so a moved block left a different
        # value there, the delta had no reason to overwrite it, and the NEXT
        # call was handed a different line.  256 bytes a call removes the
        # whole class.
        zp=np.frombuffer(b''.join(zps), dtype=np.uint8).reshape(-1, 256),
        names=np.array(names), frames=np.array([len(C.POSITIONS)]))
    print(f'state deltas: {sum(dlen):,} bytes over {len(dlen)} calls '
          f'(mean {sum(dlen)/max(1,len(dlen)):.0f})')
    from collections import Counter
    cnt = Counter(names[x[0]] for x in recs)
    tot = sum(x[1] for x in recs)
    n = len(C.POSITIONS)
    print(f'bank C image  -> {os.path.relpath(BANKC_BIN, ROOT)} ({len(bankc)} B)')
    print(f'low RAM       -> {os.path.relpath(LOWRAM_BIN, ROOT)}')
    print(f'{len(recs):,} calls over {n} frames, {tot:,} cyc '
          f'({tot / n:,.0f}/frame)')
    for k, v in cnt.most_common():
        c = sum(x[1] for x in recs if names[x[0]] == k)
        print(f'   {k:16s} {v / n:6.1f} calls/frame  {c / n:8,.0f} cyc/frame')
    print(f'wrote {os.path.relpath(WORKLOAD, ROOT)}')


class PlotBench:
    """Bare 6502 with bank C mapped at $8000 and the plot layer's low RAM."""

    def __init__(self, bankc=None):
        from py65.devices.mpu6502 import MPU
        self.mpu = MPU()
        self.bankc = bytearray(bankc if bankc is not None
                               else open(BANKC_BIN, 'rb').read())
        self.overlay = {}          # {addr: byte} re-asserted after each delta
        self.reset()

    def reset(self):
        m = self.mpu.memory
        m[0:0xC000] = [0] * 0xC000
        m[HALT] = 0x00                       # BRK ends a call

    def apply(self, idx, val):
        """Restore the engine's state at this call (delta since the last)."""
        m = self.mpu.memory
        for i, v in zip(idx, val):
            m[int(i)] = int(v)

    def call(self, entry, regs, census=None):
        """Run one call with the engine's own stack pointer.

        The routines are entered by tail-JMP and some read the stack the
        caller left (the rasteriser's direction flag is a PHP/PLP pair, and
        the vertical columns arm an RTS), so the captured SP has to be
        restored and the sentinel return pushed BELOW it -- planting it at a
        fixed address instead sent plot_v into a 500k-step runaway."""
        mpu = self.mpu; m = mpu.memory
        a, x, y, p, sp0 = (int(v) for v in regs)
        mpu.a, mpu.x, mpu.y, mpu.p = a, x, y, p
        m[0x0100 + sp0] = (HALT - 1) >> 8
        m[0x0100 + ((sp0 - 1) & 0xFF)] = (HALT - 1) & 0xFF
        mpu.sp = (sp0 - 2) & 0xFF
        mpu.pc = entry
        mpu.processorCycles = 0
        n = 0
        while mpu.pc != HALT:
            pc = mpu.pc
            op = m[pc]
            pre = mpu.processorCycles
            mpu.step()
            if census is not None and 0x8000 <= pc < 0xC000:
                d = mpu.processorCycles - pre
                if op in BRANCH_OPS:
                    s = census.setdefault(pc, dict(kind='branch', n=0,
                                                   taken=0, cross=0))
                    s['n'] += 1
                    if d >= 3:
                        s['taken'] += 1
                        if d >= 4:
                            s['cross'] += 1
                elif op in IDX_READ:
                    base = m[pc + 1] | (m[pc + 2] << 8)
                    s = census.setdefault(pc, dict(kind='indexed', n=0,
                                                   taken=0, cross=0,
                                                   base=base))
                    s['n'] += 1
                    if d >= 5:
                        s['cross'] += 1
            n += 1
            if n > 500000:
                raise RuntimeError(f'runaway in ${entry:04X}')
        return mpu.processorCycles


def load_workload():
    import numpy as np
    if not os.path.exists(WORKLOAD):
        sys.exit('build/plot_workload.npz missing — run '
                 'tools/plotbench.py capture')
    return np.load(WORKLOAD, allow_pickle=False)


def run_all(bench, wl, census=None, entries=None):
    """Replay every captured call.  Returns (total_cycles, mismatches, fb)."""
    import symmap
    names = [str(x) for x in wl['names']]
    sym = {n: symmap.sym(n, banked=1) for n in names}
    addrs = [sym[n] for n in names]
    bench.reset()
    total = 0
    bad = []
    off = 0
    dlen, didx, dval = wl['dlen'], wl['didx'], wl['dval']
    for i in range(len(wl['entry'])):
        n = int(dlen[i])
        bench.apply(didx[off:off + n], dval[off:off + n])
        off += n
        bench.mpu.memory[0:256] = [int(v) for v in wl['zp'][i]]
        # An experiment's edits are re-asserted AFTER the delta.  The delta
        # carries the engine's own bank C state (anim patches, the vplot
        # arm), so it cannot simply be skipped for bank C -- but it would
        # otherwise undo the layout under test on every call.
        if bench.overlay:
            m = bench.mpu.memory
            for k, v in bench.overlay.items():
                m[k] = v
        e = int(wl['entry'][i])
        if entries and names[e] not in entries:
            continue
        c = bench.call(addrs[e], wl['regs'][i], census)
        total += c
        if c != int(wl['cycles'][i]):
            bad.append((i, names[e], int(wl['cycles'][i]), c))
    fb = hashlib.sha256(
        bytes(bench.mpu.memory[FB_BASE:FB_BASE + FB_SIZE])).hexdigest()[:16]
    return total, bad, fb


def cmd_replay(a):
    wl = load_workload()
    b = PlotBench()
    census = {}
    total, bad, fb = run_all(b, wl, census)
    nfr = int(wl['frames'][0])
    eng = int(wl['cycles'].sum())
    print(f'{len(wl["entry"]):,} calls replayed freestanding')
    print(f'  engine      {eng:,} cyc ({eng / nfr:,.0f}/frame)')
    print(f'  freestanding {total:,} cyc ({total / nfr:,.0f}/frame)')
    print(f'  per-call cycle mismatches: {len(bad)}')
    for i, n, want, got in bad[:8]:
        print(f'    call {i} {n}: engine {want} vs bench {got}')
    print(f'  framebuffer {fb}')
    ok = not bad and total == eng
    print('PLOTBENCH: ' + ('FAITHFUL' if ok else 'DIVERGENT'))
    return 0 if ok else 1


def cmd_census(a):
    import symmap
    wl = load_workload()
    b = PlotBench()
    census = {}
    total, bad, fb = run_all(b, wl, census)
    nfr = int(wl['frames'][0])
    tbl, _ = symmap._load(banked=1, c02=0)
    items = sorted((v, k) for k, v in tbl.items() if isinstance(v, int))

    def near(x):
        lo, hi = 0, len(items)
        while lo < hi:
            mid = (lo + hi) // 2
            if items[mid][0] <= x:
                lo = mid + 1
            else:
                hi = mid
        return items[lo - 1] if lo else (0, '?')
    bx = sum(s['cross'] for s in census.values() if s['kind'] == 'branch')
    ix = sum(s['cross'] for s in census.values() if s['kind'] == 'indexed')
    print(f'bank C frozen plot layer: {total:,} cyc over {nfr} frames '
          f'({total / nfr:,.0f}/frame)')
    print(f'  layout tax {bx + ix} cyc = {(bx + ix) / nfr:.1f}/frame '
          f'({bx} branch + {ix} indexed, {(bx + ix) / total:.2%} of the layer)')
    rows = sorted((s['cross'], pc, s) for pc, s in census.items() if s['cross'])
    print(f'\n{"cyc":>6} {"/frame":>7} {"site":>6} {"kind":8} {"rate":>6}  symbol')
    for c, pc, s in sorted(rows, reverse=True)[:20]:
        v, k = near(pc)
        extra = f'  -> ${s["base"]:04X}' if s['kind'] == 'indexed' else ''
        print(f'{c:6,} {c / nfr:7.1f} ${pc:04X} {s["kind"]:8} '
              f'{c / s["n"]:6.0%}  {k}+{pc - v}{extra}')


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    for n, f in (('capture', cmd_capture), ('replay', cmd_replay),
                 ('census', cmd_census)):
        p = sub.add_parser(n); p.set_defaults(fn=f)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == '__main__':
    main()
