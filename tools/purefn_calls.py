#!/usr/bin/env python3
"""Which subroutines are a pure function of ONE byte?

The straight-line scan (tools/purefn_scan.py) only sees branch-free code,
and the byte functions worth tabling are usually the branchy ones -- clamps,
sign handling, saturating steps.  This finds them by behaviour instead:

  pass 1  record every address the corpus ever WRITES.  Anything else the
          code reads is constant (level data, trig and reciprocal tables),
          and reading a constant does not stop a routine being a pure
          function of its arguments.
  pass 2  for every JSR, record what the callee reads before writing
          (registers + mutable memory = its INPUTS) and what it leaves
          (its OUTPUTS), plus the cycles it took.

A callee whose inputs are one byte is exactly what a 256-entry table
replaces.  The bar it has to clear: on a 6502 a zero-page byte function
costs 10 cycles as a table (LDX zp 3, LDA tab,X 4, STA zp 3), so only
routines above that can win, and they have to win enough to be worth 256
bytes in a map with no 256-byte holes going spare.
"""
import os, sys, collections, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)


def engine():
    os.chdir(ROOT)
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
    import pygame
    pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from banked_bsp import BankedBspRender
    import compare_renders as C
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    return r, dw, C


# operand decode: (reads, writes) effective addresses per opcode, enough for
# the classes this engine uses
def eff(mem, pc, a, x, y):
    op = mem[pc]
    def zp():   return mem[pc + 1]
    def zpx():  return (mem[pc + 1] + x) & 0xFF
    def zpy():  return (mem[pc + 1] + y) & 0xFF
    def ab():   return mem[pc + 1] | (mem[pc + 2] << 8)
    def abx():  return (ab() + x) & 0xFFFF
    def aby():  return (ab() + y) & 0xFFFF
    def izx():  b = (mem[pc + 1] + x) & 0xFF; return mem[b] | (mem[(b + 1) & 0xFF] << 8)
    def izy():  b = mem[pc + 1]; return (mem[b] | (mem[(b + 1) & 0xFF] << 8)) + y
    R, W = [], []
    if op in (0xA5, 0x25, 0x05, 0x45, 0x65, 0xE5, 0xC5, 0x24, 0xA6, 0xA4,
              0xE4, 0xC4):
        R = [zp()]
    elif op in (0x85, 0x86, 0x84, 0x64):
        W = [zp()]
    elif op in (0x06, 0x46, 0x26, 0x66, 0xE6, 0xC6, 0x04, 0x14):
        R = [zp()]; W = [zp()]
    elif op in (0xB5, 0x35, 0x15, 0x55, 0x75, 0xF5, 0xD5, 0xB4, 0x34):
        R = [zpx()]
    elif op in (0x95, 0x94):
        W = [zpx()]
    elif op in (0x16, 0x56, 0x36, 0x76, 0xF6, 0xD6):
        R = [zpx()]; W = [zpx()]
    elif op in (0xB6,):
        R = [zpy()]
    elif op in (0x96,):
        W = [zpy()]
    elif op in (0xAD, 0x2D, 0x0D, 0x4D, 0x6D, 0xED, 0xCD, 0x2C, 0xAE, 0xAC,
                0xEC, 0xCC):
        R = [ab()]
    elif op in (0x8D, 0x8E, 0x8C, 0x9C):
        W = [ab()]
    elif op in (0x0E, 0x4E, 0x2E, 0x6E, 0xEE, 0xCE, 0x1C, 0x0C):
        R = [ab()]; W = [ab()]
    elif op in (0xBD, 0x3D, 0x1D, 0x5D, 0x7D, 0xFD, 0xDD, 0xBC, 0x3C):
        R = [abx()]
    elif op in (0x9D, 0x9E):
        W = [abx()]
    elif op in (0x1E, 0x5E, 0x3E, 0x7E, 0xFE, 0xDE):
        R = [abx()]; W = [abx()]
    elif op in (0xB9, 0x39, 0x19, 0x59, 0x79, 0xF9, 0xD9, 0xBE):
        R = [aby()]
    elif op in (0x99,):
        W = [aby()]
    elif op in (0xA1, 0x21, 0x01, 0x41, 0x61, 0xE1, 0xC1):
        R = [izx()]
    elif op in (0x81,):
        W = [izx()]
    elif op in (0xB1, 0x31, 0x11, 0x51, 0x71, 0xF1, 0xD1, 0xB2, 0x32, 0x12,
                0x52, 0x72, 0xF2, 0xD2):
        R = [izy()]
    elif op in (0x91, 0x92):
        W = [izy()]
    return R, W


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--top', type=int, default=25)
    ap.add_argument('--minbytes', type=int, default=0)
    a = ap.parse_args()
    r, dw, C = engine()
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory

    # ---- pass 1: what does the corpus ever write? ----
    written = set()
    frame = [0]

    def p1(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        while mpu.pc != 0xFF00:
            pc = mpu.pc
            _, W = eff(mem, pc, mpu.a, mpu.x, mpu.y)
            written.update(W)
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        frame[0] += mpu.processorCycles
        return mpu.processorCycles
    sc._run = p1
    for (px, py, ab_) in C.POSITIONS:
        r.render_frame(px, py, ab_, dw.player_floor(px, py))
    nfr = len(C.POSITIONS)
    print(f'pass 1: {len(written):,} mutable addresses, '
          f'frame MEAN {frame[0] / nfr:,.0f} cyc', flush=True)

    # ---- pass 2: per-callee input/output signature ----
    stats = collections.defaultdict(
        lambda: dict(n=0, cyc=0, ins=set(), outs=set(), regin=set(),
                     regout=set(), pairs=collections.defaultdict(set)))
    stack = []

    def p2(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        while mpu.pc != 0xFF00:
            pc = mpu.pc
            op = mem[pc]
            R, W = eff(mem, pc, mpu.a, mpu.x, mpu.y)
            for fr in stack:
                for addr in R:
                    if addr in written and addr not in fr['w']:
                        fr['r'].add(addr)
                for addr in W:
                    fr['w'].add(addr)
            if op == 0x20:                              # JSR
                tgt = mem[pc + 1] | (mem[pc + 2] << 8)
                stack.append(dict(tgt=tgt, sp=mpu.sp, c0=mpu.processorCycles,
                                  r=set(), w=set(),
                                  a=mpu.a, x=mpu.x, y=mpu.y))
            mpu.step()
            while stack and mpu.sp > stack[-1]['sp']:
                fr = stack.pop()
                s = stats[fr['tgt']]
                s['n'] += 1
                s['cyc'] += mpu.processorCycles - fr['c0']
                s['ins'] |= fr['r']
                s['outs'] |= fr['w']
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles
    sc._run = p2
    stack.clear()
    for (px, py, ab_) in C.POSITIONS:
        r.render_frame(px, py, ab_, dw.player_floor(px, py))

    import symmap
    tbl, _ = symmap._load(banked=1, c02=0)
    name = {v: k for k, v in tbl.items() if isinstance(v, int)}
    rows = []
    for tgt, s in stats.items():
        if not s['n']:
            continue
        rows.append((s['cyc'], tgt, s))
    rows.sort(reverse=True)
    print(f'\n{len(rows)} distinct JSR targets\n')
    print(f'{"cyc/fr":>8} {"calls/fr":>9} {"cyc":>6} {"in":>3} {"out":>4}  routine')
    for c, tgt, s in rows[:a.top]:
        print(f'{c / nfr:8,.0f} {s["n"] / nfr:9.1f} {c / s["n"]:6.1f} '
              f'{len(s["ins"]):3} {len(s["outs"]):4}  '
              f'{name.get(tgt, hex(tgt))}')
    print('\n--- PURE FUNCTIONS OF ONE MUTABLE BYTE (table candidates) ---')
    print(f'{"cyc/fr":>8} {"calls/fr":>9} {"cyc":>6}  in    out      routine')
    cand = [(c, t, s) for c, t, s in rows if len(s['ins']) <= 1]
    for c, tgt, s in cand[:a.top]:
        ins = ' '.join(f'${x:04X}' for x in sorted(s['ins'])) or '(regs only)'
        outs = ' '.join(f'${x:04X}' for x in sorted(s['outs']))[:24] or '(regs)'
        print(f'{c / nfr:8,.0f} {s["n"] / nfr:9.1f} {c / s["n"]:6.1f}  '
              f'{ins:12} {outs:24} {name.get(tgt, hex(tgt))}')
    tot = sum(c for c, _, _ in cand)
    print(f'\n{len(cand)} such routines, {tot / nfr:,.0f} cyc/frame '
          f'({tot / frame[0]:.2%} of the frame)')


if __name__ == '__main__':
    main()
