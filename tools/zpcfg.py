#!/usr/bin/env python3
"""zpcfg -- intraprocedural CFG dataflow for zero page, from machine code.

    python3 tools/zpcfg.py             live-in summary
    python3 tools/zpcfg.py --fn NAME   one routine's blocks and sets

WHY MACHINE CODE.  zpliveness answered the write-before-read question
TEXTUALLY -- first mention in source order -- which calls a loop whose
read appears above its initialising write "state", and over-reports
wildly.  The question is really a dataflow one: is there a path from the
routine's entry to a READ of b with no WRITE of b before it?  That needs
a control-flow graph, and the honest place to get one is the linked
image: macros are expanded, branch targets are real, and there is no
source-vs-emitted ambiguity.

  live(exit)  = {}                     (uses after RTS are the caller's)
  live(n)     = use(n) U (live(succ) - def(n))
  b is SCRATCH in r  iff  b not in live-in(r)

POISON, not optimism.  A routine that jumps somewhere this walk cannot
resolve -- an indirect JMP, an armed-RTS dispatch, a jump out of its own
extent -- has ALL of zero page marked live-in.  Unanalysable means
unavailable, never "probably fine".
"""
import os, sys, collections

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(ROOT); sys.path.insert(0, ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

import py65.devices.mpu6502 as M
_T = M.MPU().disassemble          # opcode -> (mnemonic, mode)

LEN = {'imp': 1, 'acc': 1, 'imm': 2, 'zpg': 2, 'zpx': 2, 'zpy': 2,
       'inx': 2, 'iny': 2, 'rel': 2, 'abs': 3, 'abx': 3, 'aby': 3,
       'ind': 3, 'iax': 3, 'iay': 3, 'zpi': 2, 'zpr': 3}
READS  = {'JMP',      # an indirect JMP reads its pointer pair
          'LDA','LDX','LDY','ADC','SBC','AND','ORA','EOR','CMP','CPX','CPY',
          'BIT','INC','DEC','ASL','LSR','ROL','ROR','TRB','TSB'}
WRITES = {'STA','STX','STY','STZ','INC','DEC','ASL','LSR','ROL','ROR',
          'TRB','TSB'}
BRANCH = {'BCC','BCS','BEQ','BNE','BMI','BPL','BVC','BVS','BRA'}
ENDS   = {'RTS','RTI','JMP','BRA'}

# ZP dispatch vectors whose target set is known (kept in step with
# zpliveness.VECTOR_TARGETS).  A JMP through one is a TAIL CALL --
# treating it as unresolvable poisoned all 256 bytes and left the
# overlay pool empty.
VECTORS = {}          # filled in main() from the symbol table
VECTOR_OUT = set()    # union of the targets' live-in sets


def load_image():
    """The linked banked image, plus symbol table."""
    import doom_wireframe as dw
    from banked_bsp import BankedBspRender
    import pygame; pygame.init()
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    from symmap import _load
    import abi
    # PAGE BANK C.  Every byte of code in $8000-$BFFF is bank C (banks
    # A/B/L0/L2 are data only, by rule), and BankedMemory shows whatever
    # was last selected -- so without this the clipper disassembles as
    # whichever bank happened to be live.  no_u16_quot read as
    # "JMP ($020D)" and poisoned the entire pool; it is a ZERO macro.
    r.bm.select(abi.BANK_C)
    t, _ = _load(1, 0)
    return r.bm, t


def zp_operand(mem, pc, mode):
    """Effective ZP byte(s) an instruction touches, or None."""
    if mode == 'zpg':
        return [mem[(pc + 1) & 0xFFFF]]
    if mode in ('zpx', 'zpy'):
        # INDEXED ZP: the effective byte is base+X, unknown statically.
        # Returning just the base UNDER-approximates uses, which is
        # unsound for liveness -- it misses every byte an indexed read
        # keeps alive.  Sound bound: everything from the base upward.
        # Only 27 sites at 13 bases exist, all at $90 (the raws) and
        # $E2-$EE (the VX1/VX2 block that feedback-bottom22k-identity
        # warns "a naive zp scan cannot see"), so the cost is contained.
        b = mem[(pc + 1) & 0xFFFF]
        return list(range(b, 0x100))
    if mode in ('inx', 'iny', 'zpi'):
        z = mem[(pc + 1) & 0xFFFF]
        return [z, (z + 1) & 0xFF]
    if mode in ('abs', 'abx', 'aby'):
        a = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8)
        return [a] if a < 0x100 else None
    if mode in ('ind', 'iax', 'iay'):
        # AN INDIRECT JMP READS ITS POINTER PAIR.  Without this the
        # frame-class vector zp_bv_entry ($63/$64) has no reader in the
        # whole program -- the driver writes it, and the only read is
        # this JMP -- so it lands in the shareable pool and gets
        # clobbered.  That is exactly the bug that took MEAN to 45M
        # earlier today; the analysis must not repeat it.
        a = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8)
        return [a, (a + 1) & 0xFFFF] if a < 0x100 else None
    return None


def decode(mem, entry, limit):
    """Linear-sweep a routine into blocks. -> (blocks, ok)

    ok=False means something unanalysable was hit and the caller must
    treat the whole routine as poisoning zero page.
    """
    blocks, work, seen, ok = {}, [entry], set(), True
    while work:
        start = work.pop()
        if start in seen or not (entry <= start < limit):
            continue
        seen.add(start)
        pc, insns, succ = start, [], []
        while entry <= pc < limit:
            op = mem[pc]
            mnem, mode = _T[op][0].split()[0].upper(), _T[op][1]
            n = LEN.get(mode)
            if n is None:
                ok = False; break
            insns.append((pc, mnem, mode))
            if mnem in BRANCH:
                d = mem[(pc + 1) & 0xFFFF]
                tgt = (pc + 2 + (d - 256 if d > 127 else d)) & 0xFFFF
                succ = [tgt, pc + 2]
                work += [tgt, pc + 2]
                break
            if mnem == 'JMP':
                if mode == 'abs':
                    tgt = mem[pc+1] | (mem[pc+2] << 8)
                    if entry <= tgt < limit:
                        succ = [tgt]; work.append(tgt)
                    else:
                        succ = []          # tail call: leaves the routine
                elif mode == 'ind' and (mem[pc+1] | (mem[pc+2] << 8)) in VECTORS:
                    succ = []              # tail call through a curated
                    break                  # vector: targets handled by the
                                           # caller via VECTOR_OUT
                else:
                    ok = False             # indirect: genuinely unresolvable
                break
            if mnem in ('RTS', 'RTI', 'BRK'):
                succ = []; break
            pc += n
        blocks[start] = (insns, succ)
    return blocks, ok


def live_in(mem, entry, limit):
    """Backward liveness -> set of ZP bytes live on entry, or None if poisoned."""
    blocks, ok = decode(mem, entry, limit)
    if not ok or not blocks:
        return None
    live = {b: set() for b in blocks}
    for _ in range(len(blocks) + 2):        # iterate to fixpoint
        changed = False
        for b, (insns, succ) in blocks.items():
            out = set()
            for s in succ:
                out |= live.get(s, set())
            cur = set(out)
            for pc, mnem, mode in reversed(insns):
                zs = zp_operand(mem, pc, mode)
                if zs is None:
                    continue
                if mnem in WRITES and mnem not in READS and mode == 'zpg':
                    cur -= set(zs)          # only a DIRECT write provably kills
                if mnem in READS:
                    cur |= set(zs)          # read makes live
            if cur != live[b]:
                live[b] = cur; changed = True
        if not changed:
            break
    return live[entry]


def live_across_calls(mem, entry, limit):
    """ZP bytes live ACROSS a JSR in this routine -- what a callee must not touch.

    Entry-liveness alone is not the overlay condition.  A routine can
    write b, call something, and read b afterwards: b is not live on
    ENTRY, but it IS live across that call, and a callee using b as
    scratch would destroy it.  This is the set the stack discipline has
    to respect.
    """
    blocks, ok = decode(mem, entry, limit)
    if not ok or not blocks:
        return None
    live = {b: set() for b in blocks}
    across = set()
    for _ in range(len(blocks) + 2):
        changed = False
        for b, (insns, succ) in blocks.items():
            out = set()
            for sc in succ:
                out |= live.get(sc, set())
            cur = set(out)
            for pc, mnem, mode in reversed(insns):
                if mnem == 'JSR':
                    across |= cur          # everything live at the call site
                    continue
                zs = zp_operand(mem, pc, mode)
                if zs is None:
                    continue
                if mnem in WRITES and mnem not in READS:
                    cur -= set(zs)
                if mnem in READS:
                    cur |= set(zs)
            if cur != live[b]:
                live[b] = cur; changed = True
        if not changed:
            break
    return across


def main():
    mem, syms = load_image()
    global VECTORS
    import zpliveness as ZL0
    VECTORS = {syms[v]: v for v in ZL0.VECTOR_TARGETS if v in syms}
    # routine entries = call targets, bounded by the next symbol
    import zpliveness as ZL
    targets = ZL.call_targets()
    addr = {n: a for n, a in syms.items() if n in targets and 0x0F00 <= a < 0xC000}
    ordered = sorted(set(syms.values()))
    poisoned, clean, allzp = [], {}, set()
    for n, a in addr.items():
        nxt = next((x for x in ordered if x > a), a + 256)
        li = live_in(mem, a, min(nxt, a + 512))
        if li is None:
            poisoned.append(n)
        else:
            clean[n] = li; allzp |= li
    print(f'\n  ZP CFG DATAFLOW -- {len(addr)} routines from the linked image')
    print('  ' + '=' * 66)
    print(f'    analysed cleanly : {len(clean)}')
    print(f'    POISONED (indirect jump / unresolvable): {len(poisoned)}')
    print(f'    bytes live-in somewhere (= carry state): {len(allzp)}')
    print(f'    bytes NEVER live-in anywhere           : {256 - len(allzp)}')
    # ---- resolve the vector dispatchers with the targets' live-ins ------
    global VECTOR_OUT
    import zpliveness as ZL2
    tg = set()
    for v in ZL2.VECTOR_TARGETS.values():
        tg.update(v)
    VECTOR_OUT = set().union(*[clean[t] for t in tg if t in clean]) \
        if any(t in clean for t in tg) else set()
    for n in list(poisoned):
        a = addr[n]
        nxt = next((x for x in ordered if x > a), a + 256)
        li = live_in(mem, a, min(nxt, a + 512))
        if li is not None:
            clean[n] = li | VECTOR_OUT
            allzp |= clean[n]
            poisoned.remove(n)
    print(f'    after resolving vectors, poisoned: {len(poisoned)}')

    # ---- what a callee may NOT touch: live across a call, anywhere ------
    across_all, across_by = set(), {}
    for n, a in addr.items():
        nxt = next((x for x in ordered if x > a), a + 256)
        ac = live_across_calls(mem, a, min(nxt, a + 512))
        if ac is None:
            across_all |= set(range(0x100))     # poisoned: assume the worst
        else:
            across_by[n] = ac; across_all |= ac
    pool = sorted(set(range(0x100)) - across_all - allzp)
    print(f'\n  OVERLAY POOL')
    print(f'    live ACROSS a call somewhere : {len(across_all)} bytes')
    print(f'    never live-in, never live-across:')
    print(f'      >>> {len(pool)} BYTES SHAREABLE BY ANY ROUTINE <<<')
    print('      ' + ' '.join(f'${a:02X}' for a in pool[:40]))
    if len(pool) > 40: print('      ...')

    # ---- how many SLOTS does the pool actually need? --------------------
    # The pool bytes are all scratch, but several can be live at once
    # INSIDE a routine.  The slots needed is the maximum simultaneous
    # liveness over every program point; everything above that is freed.
    poolset = set(pool)
    worst, worst_fn = 0, ''
    for n, a in addr.items():
        nxt = next((x for x in ordered if x > a), a + 256)
        blocks, okk = decode(mem, a, min(nxt, a + 512))
        if not okk or not blocks:
            continue
        live = {b: set() for b in blocks}
        for _ in range(len(blocks) + 2):
            ch = False
            for b, (insns, succ) in blocks.items():
                out = set()
                for sc in succ: out |= live.get(sc, set())
                cur = set(out)
                for pc, mnem, mode in reversed(insns):
                    zs = zp_operand(mem, pc, mode)
                    if zs:
                        if mnem in WRITES and mnem not in READS: cur -= set(zs)
                        if mnem in READS: cur |= set(zs)
                    k = len(cur & poolset)
                    if k > worst: worst, worst_fn = k, n
                if cur != live[b]: live[b] = cur; ch = True
            if not ch: break
    print(f'\n  SLOTS NEEDED')
    print(f'    max pool bytes live at once : {worst}  (in {worst_fn})')
    print(f'    pool size                   : {len(pool)}')
    print(f'    >>> ZERO PAGE BYTES FREED   : {len(pool) - worst} <<<')

    ex = sorted(clean.items(), key=lambda kv: -len(kv[1]))[:6]
    print('\n    routines with the largest live-in sets:')
    for n, s in ex:
        print(f'      {n:<26} {len(s):3d} bytes live on entry')
    print(f'\n    poisoned examples: {", ".join(poisoned[:8])}')
    print()


if __name__ == '__main__':
    main()
