#!/usr/bin/env python3
"""Find pure functions of a byte that a 256-byte table could replace.

THE QUESTION (Eben): anywhere we compute a pure function of a byte where a
256-byte lookup would meet the cycle/byte goal?

METHOD.  A run of instructions that touches NO memory except immediates is
a pure function of the register file by construction -- there is nothing
else for it to depend on.  So:

  1. trace the banked engine over the standard corpus and record every
     executed PC with its count and cycles.  The trace also gives exact
     instruction boundaries, which a linear disassembly of a code/data mix
     cannot (data misparses silently).
  2. find maximal straight-line runs of register-only instructions
     (implied / immediate / accumulator addressing).  Branches, loads and
     stores end a run.
  3. cost each run: cycles it spends per frame today, against what the
     table form would cost at the same site.

A table costs 4 cycles (LDA tab,X with no page cross) plus whatever it
takes to get the byte into X and the answer where it is wanted.  The run
has to beat that by enough to be worth 256 bytes -- and this map has no
256-byte holes going spare, so the bar is high.
"""
import os, sys, json, argparse, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

# opcode -> (mnemonic, size, mode).  Only what we need: the register-only
# set in full, and sizes for everything else so the run-walk can step.
IMPL = {0x0A: 'ASL A', 0x4A: 'LSR A', 0x2A: 'ROL A', 0x6A: 'ROR A',
        0x18: 'CLC', 0x38: 'SEC', 0xB8: 'CLV', 0xD8: 'CLD', 0xF8: 'SED',
        0xAA: 'TAX', 0xA8: 'TAY', 0x8A: 'TXA', 0x98: 'TYA',
        0xE8: 'INX', 0xCA: 'DEX', 0xC8: 'INY', 0x88: 'DEY',
        0xEA: 'NOP', 0x9A: 'TXS', 0xBA: 'TSX', 0x1A: 'INC A', 0x3A: 'DEC A'}
IMMED = {0x69: 'ADC', 0x29: 'AND', 0xC9: 'CMP', 0xE0: 'CPX', 0xC0: 'CPY',
         0x49: 'EOR', 0xA9: 'LDA', 0xA2: 'LDX', 0xA0: 'LDY', 0x09: 'ORA',
         0xE9: 'SBC', 0x89: 'BIT'}
# sizes for the whole map, so the walk can step over anything
SIZE = {}
for o in range(256):
    SIZE[o] = 1
for o in (0x69, 0x29, 0xC9, 0xE0, 0xC0, 0x49, 0xA9, 0xA2, 0xA0, 0x09, 0xE9,
          0x89, 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0,
          0x65, 0x25, 0xC5, 0xE4, 0xC4, 0x45, 0xA5, 0xA6, 0xA4, 0x05, 0xE5,
          0x24, 0x85, 0x86, 0x84, 0x06, 0x46, 0x26, 0x66, 0xE6, 0xC6,
          0x75, 0x35, 0xD5, 0x55, 0xB5, 0xB4, 0x15, 0xF5, 0x95, 0x94,
          0x16, 0x56, 0x36, 0x76, 0xF6, 0xD6, 0xB6, 0x96, 0x61, 0x21, 0xC1,
          0x41, 0xA1, 0x01, 0xE1, 0x81, 0x71, 0x31, 0xD1, 0x51, 0xB1, 0x11,
          0xF1, 0x91, 0x74, 0x64, 0x14, 0x04, 0x12, 0x32, 0xD2, 0x52, 0xB2,
          0x72, 0xF2, 0x92, 0x34, 0x89):
    SIZE[o] = 2
for o in (0x6D, 0x2D, 0xCD, 0xEC, 0xCC, 0x4D, 0xAD, 0xAE, 0xAC, 0x0D, 0xED,
          0x2C, 0x8D, 0x8E, 0x8C, 0x0E, 0x4E, 0x2E, 0x6E, 0xEE, 0xCE,
          0x7D, 0x3D, 0xDD, 0x5D, 0xBD, 0xBC, 0x1D, 0xFD, 0x9D,
          0x79, 0x39, 0xD9, 0x59, 0xB9, 0xBE, 0x19, 0xF9, 0x99,
          0x1E, 0x5E, 0x3E, 0x7E, 0xFE, 0xDE, 0x4C, 0x20, 0x6C, 0x7C,
          0x9C, 0x9E, 0x1C, 0x3C):
    SIZE[o] = 3

REGONLY = set(IMPL) | set(IMMED)
# zero-page loads and stores: a run may read ONE zp byte (its input) and
# write zp, and still be a pure function of that byte
ZPLOAD = {0xA5: 'LDA', 0xA6: 'LDX', 0xA4: 'LDY'}
ZPSTORE = {0x85: 'STA', 0x86: 'STX', 0x84: 'STY'}
ZPRMW = {0x06: 'ASL', 0x46: 'LSR', 0x26: 'ROL', 0x66: 'ROR'}
ZPALU = {0x65: 'ADC', 0x25: 'AND', 0xC5: 'CMP', 0x45: 'EOR', 0x05: 'ORA',
         0xE5: 'SBC', 0x24: 'BIT', 0xE4: 'CPX', 0xC4: 'CPY'}
WIDE = REGONLY | set(ZPLOAD) | set(ZPSTORE) | set(ZPRMW) | set(ZPALU)
# these end a run even though they are register-only: they leave the
# straight line or change control
TERM = {0x4C, 0x6C, 0x20, 0x60, 0x40, 0x00}


def trace(poses=None):
    """(count, cycles) per executed PC over the corpus, plus the memory."""
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
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory
    cnt = collections.Counter(); cyc = collections.Counter()
    frame = [0]

    def traced(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        while mpu.pc != 0xFF00:
            pc = mpu.pc
            pre = mpu.processorCycles
            mpu.step()
            cnt[pc] += 1
            cyc[pc] += mpu.processorCycles - pre
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        frame[0] += mpu.processorCycles
        return mpu.processorCycles

    sc._run = traced
    for (px, py, ab) in (poses or C.POSITIONS):
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    return cnt, cyc, frame[0], len(poses or C.POSITIONS), bytes(mem[0:0xC000])


# what each register-only opcode reads and writes (C = carry)
RW = {
 0x0A: ('A', 'AC'), 0x4A: ('A', 'AC'), 0x2A: ('AC', 'AC'), 0x6A: ('AC', 'AC'),
 0x18: ('', 'C'), 0x38: ('', 'C'), 0xB8: ('', ''), 0xD8: ('', ''), 0xF8: ('', ''),
 0xAA: ('A', 'X'), 0xA8: ('A', 'Y'), 0x8A: ('X', 'A'), 0x98: ('Y', 'A'),
 0xE8: ('X', 'X'), 0xCA: ('X', 'X'), 0xC8: ('Y', 'Y'), 0x88: ('Y', 'Y'),
 0xEA: ('', ''), 0x9A: ('X', ''), 0xBA: ('', 'X'),
 0x1A: ('A', 'A'), 0x3A: ('A', 'A'),
 0x69: ('AC', 'AC'), 0x29: ('A', 'A'), 0xC9: ('A', 'C'), 0xE0: ('X', 'C'),
 0xC0: ('Y', 'C'), 0x49: ('A', 'A'), 0xA9: ('', 'A'), 0xA2: ('', 'X'),
 0xA0: ('', 'Y'), 0x09: ('A', 'A'), 0xE9: ('AC', 'AC'), 0x89: ('A', ''),
}


def liveness(seq, mem):
    """(live_in, written) register sets for a register-only run."""
    live_in, written = set(), set()
    for pc in seq:
        rd, wr = RW[mem[pc]]
        for c in rd:
            if c not in written:
                live_in.add(c)
        for c in wr:
            written.add(c)
    return live_in, written


def disasm(pc, mem):
    op = mem[pc]
    if op in IMPL:
        return IMPL[op]
    return f'{IMMED[op]} #${mem[pc + 1]:02X}'


def wide_runs(cnt, mem, minlen=4):
    """Straight-line runs that touch only registers and zero page.

    Such a run is a pure function of the zero-page bytes it READS before
    writing, plus the live-in registers.  When that set is a single byte,
    the whole run is exactly what a 256-entry table replaces.
    """
    ispc = set(cnt)
    starts = set()
    for pc in ispc:
        if mem[pc] not in WIDE or mem[pc] in TERM:
            continue
        prev = [q for q in range(pc - 3, pc) if q in ispc
                and q + SIZE[mem[q]] == pc]
        if not prev or any(mem[q] not in WIDE or mem[q] in TERM for q in prev):
            starts.add(pc)
    out = []
    for pc in sorted(starts):
        seq = []
        p = pc
        while p in ispc and mem[p] in WIDE and mem[p] not in TERM:
            seq.append(p)
            p += SIZE[mem[p]]
        if len(seq) >= minlen:
            out.append(seq)
    return out


def zp_io(seq, mem):
    """(zp bytes read before written, zp bytes written) for a wide run."""
    rd, wr = set(), set()
    for pc in seq:
        op = mem[pc]
        if op in ZPLOAD or op in ZPALU:
            a = mem[pc + 1]
            if a not in wr:
                rd.add(a)
        elif op in ZPSTORE:
            wr.add(mem[pc + 1])
        elif op in ZPRMW:
            a = mem[pc + 1]
            if a not in wr:
                rd.add(a)
            wr.add(a)
    return rd, wr


def wdisasm(pc, mem):
    op = mem[pc]
    if op in IMPL:
        return IMPL[op]
    if op in IMMED:
        return f'{IMMED[op]} #${mem[pc + 1]:02X}'
    for tab in (ZPLOAD, ZPSTORE, ZPRMW, ZPALU):
        if op in tab:
            return f'{tab[op]} ${mem[pc + 1]:02X}'
    return f'?{op:02X}'


def runs(cnt, mem, minlen=3):
    """Maximal straight-line register-only runs among EXECUTED instructions.

    Only PCs the corpus actually ran are considered, which is also how the
    walk knows where instructions start -- a linear disassembly of this
    image would misparse the interleaved tables.
    """
    ispc = set(cnt)
    starts = set()
    for pc in ispc:
        op = mem[pc]
        if op not in REGONLY or op in TERM:
            continue
        # a run starts where the preceding executed instruction does not
        # fall straight into it as another register-only op
        prev = [q for q in range(pc - 3, pc) if q in ispc
                and q + SIZE[mem[q]] == pc]
        if not prev or any(mem[q] not in REGONLY or mem[q] in TERM
                           for q in prev):
            starts.add(pc)
    out = []
    for pc in sorted(starts):
        seq = []
        p = pc
        while p in ispc and mem[p] in REGONLY and mem[p] not in TERM:
            seq.append(p)
            p += SIZE[mem[p]]
        if len(seq) >= minlen:
            out.append(seq)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--minlen', type=int, default=3)
    ap.add_argument('--top', type=int, default=30)
    ap.add_argument('--wide', action='store_true',
                    help='allow zero-page operands, not just registers')
    a = ap.parse_args()
    cnt, cyc, frame, nfr, mem = trace()
    if a.wide:
        report_wide(cnt, cyc, frame, nfr, mem, a)
        return report_candidates(cnt, cyc, frame, nfr, mem, a.top)
    rs = runs(cnt, mem, a.minlen)
    rows = []
    for seq in rs:
        n = cnt[seq[0]]
        if any(cnt[p] != n for p in seq):
            continue                    # not single-entry: something branches in
        c = sum(cyc[p] for p in seq)
        li, wr = liveness(seq, mem)
        rows.append((c, seq, n, li, wr))
    rows.sort(reverse=True, key=lambda r: r[0])
    tot = sum(r[0] for r in rows)
    print(f'frame MEAN {frame / nfr:,.0f} cyc over {nfr} poses')
    print(f'{len(rows)} single-entry register-only runs of >= {a.minlen} '
          f'instructions, {tot:,} cyc total = {tot / nfr:.0f}/frame '
          f'({tot / frame:.2%} of the frame)\n')
    print(f'{"cyc/fr":>7} {"calls/fr":>9} {"cyc":>5} {"in":>4} {"out":>4}  site      body')
    for c, seq, n, li, wr in rows[:a.top]:
        body = ' '.join(disasm(p, mem) for p in seq)
        print(f'{c / nfr:7.1f} {n / nfr:9.1f} {c / n:5.1f} '
              f'{"".join(sorted(li)) or "-":>4} {"".join(sorted(wr)):>4}  '
              f'${seq[0]:04X}  {body[:88]}')


def report_wide(cnt, cyc, frame, nfr, mem, a):
    rows = []
    for seq in wide_runs(cnt, mem, a.minlen):
        n = cnt[seq[0]]
        if any(cnt[p] != n for p in seq):
            continue
        c = sum(cyc[p] for p in seq)
        li, wro = liveness_wide(seq, mem)
        rd, wr = zp_io(seq, mem)
        nin = len(li) + len(rd)
        rows.append((c, seq, n, li, rd, wr, nin))
    rows.sort(reverse=True, key=lambda r: r[0])
    tot = sum(r[0] for r in rows)
    one = [r for r in rows if r[6] == 1]
    print(f'frame MEAN {frame / nfr:,.0f} cyc over {nfr} poses')
    print(f'{len(rows)} straight-line register+zp runs >= {a.minlen} instrs, '
          f'{tot / nfr:,.0f} cyc/frame ({tot / frame:.2%} of the frame)')
    print(f'{len(one)} of them depend on exactly ONE input byte '
          f'({sum(r[0] for r in one) / nfr:,.0f} cyc/frame)\n')
    print(f'{"cyc/fr":>7} {"calls":>7} {"cyc":>5} {"in":>10} {"tbl":>4}  site      body')
    for c, seq, n, li, rd, wr, nin in rows[:a.top]:
        body = ' '.join(wdisasm(p, mem) for p in seq)
        inp = ('/'.join(sorted(li)) + ' ' if li else '') + \
              ' '.join(f'${x:02X}' for x in sorted(rd))
        print(f'{c / nfr:7.1f} {n / nfr:7.1f} {c / n:5.1f} {inp[:10]:>10} '
              f'{"YES" if nin == 1 else "":>4}  ${seq[0]:04X}  {body[:78]}')


def liveness_wide(seq, mem):
    live_in, written = set(), set()
    for pc in seq:
        op = mem[pc]
        if op in RW:
            rd, wrs = RW[op]
        elif op in ZPLOAD:
            rd, wrs = '', {0xA5: 'A', 0xA6: 'X', 0xA4: 'Y'}[op]
        elif op in ZPSTORE:
            rd, wrs = {0x85: 'A', 0x86: 'X', 0x84: 'Y'}[op], ''
        elif op in ZPRMW:
            rd, wrs = '', 'C'
        elif op in ZPALU:
            rd = {0x65: 'AC', 0x25: 'A', 0xC5: 'A', 0x45: 'A', 0x05: 'A',
                  0xE5: 'AC', 0x24: 'A', 0xE4: 'X', 0xC4: 'Y'}[op]
            wrs = 'C' if op in (0xC5, 0x24, 0xE4, 0xC4) else 'AC'
        else:
            rd, wrs = '', ''
        for ch in rd:
            if ch not in written:
                live_in.add(ch)
        for ch in wrs:
            written.add(ch)
    return live_in, written




# --- pricing a table replacement ------------------------------------------
# On a 6502 the table form is LDA tab,X (4 cycles, +1 if the table crosses a
# page under the index -- so a 256-entry table must be page-aligned).  What
# it costs at a SITE depends on where the byte already is and where the
# answer is wanted:
#     input already in X or Y, answer wanted in A        4
#     input in A                                     2 + 4      (TAX)
#     input in zero page                             3 + 4      (LDX zp)
#     answer wanted in zero page                        + 3     (STA zp)
#     answer wanted in X or Y                           + 2     (TAX/TAY)
# So the floor for a zp -> zp byte function is 10 cycles, and for an
# X -> A one it is 4.  A run only wins if it costs more than that today.
def table_cost(live_in, zp_rd, zp_wr, live_out):
    c = 4
    if zp_rd:
        c += 3                      # LDX zp
    elif 'A' in live_in:
        c += 2                      # TAX
    if zp_wr:
        c += 3 * len(zp_wr)         # STA zp per output byte
    elif live_out and live_out != {'A'}:
        c += 2
    return c


def report_candidates(cnt, cyc, frame, nfr, mem, top=40):
    rows = []
    for seq in wide_runs(cnt, mem, 2):
        n = cnt[seq[0]]
        if any(cnt[p] != n for p in seq):
            continue
        li, wro = liveness_wide(seq, mem)
        rd, wr = zp_io(seq, mem)
        if len(li - {'C'}) + len(rd) != 1:
            continue                # not a function of exactly one byte
        c = sum(cyc[p] for p in seq)
        per = c / n
        tc = table_cost(li - {'C'}, rd, wr, wro & {'A', 'X', 'Y'})
        save = (per - tc) * n
        rows.append((save, c, seq, n, per, tc, li, rd, wr))
    rows.sort(reverse=True)
    print(f'\nSINGLE-BYTE straight-line runs, priced against a table:\n')
    print(f'{"save/fr":>8} {"now/fr":>8} {"calls":>7} {"now":>5} {"tbl":>4}'
          f'  site      body')
    tot = 0
    for save, c, seq, n, per, tc, li, rd, wr in rows[:top]:
        body = ' '.join(wdisasm(p, mem) for p in seq)
        if save > 0:
            tot += save
        print(f'{save / nfr:8.1f} {c / nfr:8.1f} {n / nfr:7.1f} {per:5.1f} '
              f'{tc:4}  ${seq[0]:04X}  {body[:74]}')
    print(f'\n{len(rows)} single-byte runs; positive-saving total '
          f'{tot / nfr:,.1f} cyc/frame ({tot / frame:.3%} of the frame)')


if __name__ == '__main__':
    main()
