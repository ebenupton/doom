#!/usr/bin/env python3
"""zptrawl -- are the 256 hottest scalars actually IN zero page?

    python3 tools/zptrawl.py              the swap list (default)
    python3 tools/zptrawl.py --full       every ranked address
    python3 tools/zptrawl.py --frames N   corpus size (default: whole suite)

WHY.  Zero page is 256 bytes and the machine's scarcest resource: a byte
there saves 1 cycle and 1 instruction byte on EVERY access.  So the right
occupants are simply the 256 most-accessed scalars -- and that set drifts
every time the engine changes shape.  This ranks every scalar by measured
access count and answers one question: which ZP byte should swap with
which absolute one, and what does the swap buy?

METHOD.  Decode each executed instruction's addressing mode (zpheat's
approach, widened to absolute) and charge the EFFECTIVE address:

  zpg/zpx/zpy      -> in ZP already; count it
  abs              -> promotable, saves 1 cycle/access  (4 -> 3)
  abx/aby          -> abx promotable to zpx (4 -> 4, saves the BYTE only);
                      aby has no zp,Y form except LDX/STX, so NOT promotable
  inx/iny          -> the POINTER pair, 2 bytes, already ZP

TABLES ARE NOT SCALARS.  An abs,X sweep touches hundreds of addresses a
few times each; a scalar is one address touched many times.  Addresses
are therefore ranked individually and a promotion candidate must also be
NARROW -- see --full for the spread of any base you are unsure about.

WHAT COUNTS AS A CANDIDATE.  Only symbols the linker can move.  ZP is
linker-allocated since 24abd23, so promoting means moving a .res into the
ZEROPAGE segment and letting ld65 place it; nothing needs hand-assigning.
Hardware and ABI-pinned bytes are excluded by name.
"""
import os, sys, collections

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import py65.devices.mpu6502 as M
MODES = M.MPU().disassemble

# ONLY instructions that touch DATA.  JSR/JMP are 'abs' mode too, so
# without this the ranking fills up with subroutine entry points --
# umul8, bbox_visible, seg_proc -- as if they were hot scalars.  They
# are hot CODE, which is a different tool's problem.
DATA_OPS = {'LDA','STA','LDX','STX','LDY','STY','ADC','SBC','AND','ORA',
            'EOR','CMP','CPX','CPY','BIT','INC','DEC','ASL','LSR','ROL',
            'ROR','STZ','TRB','TSB'}

ZPG = {'zpg', 'zpx', 'zpy'}
IND = {'inx', 'iny'}
ABS = {'abs'}
ABX = {'abx'}
ABY = {'aby'}

# Never propose these: hardware, the stack, and the tables that must sit
# at a fixed page for their own arithmetic.
PINNED_LO, PINNED_HI = 0x0100, 0x01FF          # stack + SQR_MIRROR
IO_LO, IO_HI = 0xFE00, 0xFEFF


def corpus_counts(limit=None):
    """Access counts per effective address across the render suite."""
    import doom_wireframe as dw
    from banked_bsp import BankedBspRender
    import compare_renders as C
    from symmap import sym
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    mpu = r.sc.mpu
    hits = collections.Counter()      # addr -> accesses
    modes = collections.defaultdict(collections.Counter)   # addr -> mode
    poses = C.POSITIONS[:limit] if limit else C.POSITIONS
    entry = sym('render_frame', banked=1)
    for (px, py, ab) in poses:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        r.sc.init(); r.sc.clear_screen()
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem = mpu.memory
        mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
        k = 0
        while mpu.pc != 0xFF00 and k < 3_000_000:
            pc = mpu.pc
            op = MODES[mem[pc]]
            mnem, mode = op[0].split()[0].upper(), op[1]
            if mnem == 'JMP' and mode in ('ind', 'iax'):
                # an indirect JMP READS a pointer pair.  zp_bv_entry is
                # reached ONLY this way; excluding JMP made the frame-class
                # vector look untouched, and promoting onto it produced a
                # wild indirect jump and a 45M-cycle frame (2026-08-30).
                z = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8)
                if z < 0x100:
                    hits[z] += 1; hits[(z + 1) & 0xFF] += 1
                    modes[z]['ind'] += 1
                mpu.step(); k += 1; continue
            if mnem not in DATA_OPS:
                mpu.step(); k += 1; continue
            if mode in ZPG:
                z = mem[(pc + 1) & 0xFFFF]
                a = z if mode == 'zpg' else \
                    (z + (mpu.x if mode == 'zpx' else mpu.y)) & 0xFF
                hits[a] += 1; modes[a][mode] += 1
            elif mode in IND:
                z = mem[(pc + 1) & 0xFFFF]
                p = (z + mpu.x) & 0xFF if mode == 'inx' else z
                hits[p] += 1; hits[(p + 1) & 0xFF] += 1
                modes[p]['ind'] += 1
            elif mode in ABS or mode in ABX or mode in ABY:
                lo = mem[(pc + 1) & 0xFFFF]; hi = mem[(pc + 2) & 0xFFFF]
                base = lo | (hi << 8)
                a = base if mode == 'abs' else \
                    (base + (mpu.x if mode == 'abx' else mpu.y)) & 0xFFFF
                hits[a] += 1; modes[a][mode] += 1
            mpu.step(); k += 1
    # MOVEMENT TOO.  A render never runs pm_frame, so a render-only corpus
    # calls the whole pmove/driver half of zero page "untouched" and offers
    # it as free real estate.  That is precisely the trap this codebase
    # keeps walking into: a byte free in one phase and live in another.
    try:
        sys.path.insert(0, os.path.join(ROOT, 'tools'))
        import pm_fuzz
        rig = pm_fuzz.Rig(banked=1)
        rig.cold()
        m2 = rig.r.sc.mpu
        # THE INPUT MASK MUST CARRY FIELDS IN b4-6 or pm_frame early-outs:
        # x=$10 runs 151 steps and moves nothing, x=$41 runs 2,068 and is a
        # real frame.  Same landmine the tube walk gate documents.  Drive a
        # spread of inputs so turn and step paths both get counted.
        MASKS = (0x41, 0x42, 0x44, 0x48, 0x51, 0x61)
        for i in range(len(MASKS) * 2):
            m2.pc = rig.frame_e; m2.sp = 0xDD; m2.p = 0x30
            mm = m2.memory
            mm[0x1DF] = 0xFE; mm[0x1DE] = 0xFF
            m2.a = 4; m2.x = MASKS[i % len(MASKS)]
            k = 0
            while m2.pc != 0xFF00 and k < 2_000_000:
                pc = m2.pc
                op = MODES[mm[pc]]
                mnem, mode = op[0].split()[0].upper(), op[1]
                if mnem in DATA_OPS:
                    if mode in ZPG:
                        z = mm[(pc + 1) & 0xFFFF]
                        a = z if mode == 'zpg' else \
                            (z + (m2.x if mode == 'zpx' else m2.y)) & 0xFF
                        hits[a] += 1; modes[a][mode] += 1
                    elif mode in IND:
                        z = mm[(pc + 1) & 0xFFFF]
                        pp = (z + m2.x) & 0xFF if mode == 'inx' else z
                        hits[pp] += 1; hits[(pp + 1) & 0xFF] += 1
                    elif mode in ABS or mode in ABX or mode in ABY:
                        base = mm[(pc + 1) & 0xFFFF] | (mm[(pc + 2) & 0xFFFF] << 8)
                        a = base if mode == 'abs' else \
                            (base + (m2.x if mode == 'abx' else m2.y)) & 0xFFFF
                        hits[a] += 1; modes[a][mode] += 1
                m2.step(); k += 1
        nmove = len(MASKS) * 2
    except Exception as e:
        print(f'  WARNING: movement pass failed ({e}); ZP "free" list is '
              f'RENDER-ONLY and must not be trusted')
        nmove = 0
    return hits, modes, len(poses), nmove


def symbols():
    from symmap import _load
    t, _ = _load(1, 0)
    by = {}
    for n, a in t.items():
        by.setdefault(a, []).append(n)
    return {a: sorted(ns, key=len)[0] for a, ns in by.items()}


def code_spans():
    """Region extents that hold CODE, from the banked cfg."""
    import re
    cfg = open(os.path.join(ROOT, 'src', 'engine_banked.cfg')).read()
    out = []
    for m in re.finditer(r'^\s*(\w+):\s*start = \$([0-9A-Fa-f]+), '
                         r'size = \$([0-9A-Fa-f]+)', cfg, re.M):
        if m.group(1) in ('CODE', 'DRV', 'BANKC', 'VPLOTC', 'HUD'):
            a = int(m.group(2), 16); out.append((a, a + int(m.group(3), 16)))
    return out


CODE = None


def promotable(addr, modes):
    """Is this a SCALAR that could live in zero page?

    Two filters, both learned from the first run of this tool:

    UNINDEXED ONLY.  An address reached via abs,X is a TABLE ELEMENT --
    the first run proposed span-pool bytes ($0801, $0901, $08E1) that are
    swept by POOL_*,X.  Moving one means moving the whole plane, which is
    not a scalar promotion.  A real scalar is addressed absolutely.

    NOT INSIDE CODE.  Addresses in a code region are SMC operand sites --
    px_go_op, rns_go_op -- being written by the engine patching its own
    instructions.  They are already exactly where they must be.
    """
    global CODE
    if CODE is None:
        CODE = code_spans()
    if addr < 0x100:
        return False                      # already there
    if PINNED_LO <= addr <= PINNED_HI or IO_LO <= addr <= IO_HI:
        return False
    if any(lo <= addr < hi for lo, hi in CODE):
        return False
    return bool(modes[addr]['abs'])


def main():
    limit = None
    for a in sys.argv[1:]:
        if a.startswith('--frames'):
            limit = int(a.split('=', 1)[1])
    hits, modes, nposes, nmove = corpus_counts(limit)
    names = symbols()
    zp = {a: c for a, c in hits.items() if a < 0x100}
    ab = {a: c for a, c in hits.items() if promotable(a, modes)}

    print(f'\n  ZP TRAWL -- {nposes} render poses + {nmove} movement frames, banked')
    print('  ' + '=' * 70)
    print(f'  zero page: {len(zp)} of 256 bytes touched, '
          f'{sum(zp.values()):,} accesses')
    print(f'  absolute : {len(ab)} promotable addresses, '
          f'{sum(ab.values()):,} accesses')

    # the swap list: coldest ZP occupants vs hottest absolute scalars
    cold = sorted(zp.items(), key=lambda kv: kv[1])
    hot = sorted(ab.items(), key=lambda kv: -kv[1])
    # NEVER OFFER A NAMED BYTE.  A symbol in $00-$FF means somebody owns
    # that address, whether or not this corpus happens to touch it --
    # bca_ab ($62) and zp_bv_entry ($63/$64) live in abi.inc, are written
    # by the DRIVER, and are read through an indirect JMP.  They looked
    # free here and they are not.  Constants that merely have small values
    # (LAY_MAX_DIRS = 128) get excluded too; that is the conservative
    # direction and costs only candidates, never correctness.
    owned = set(names)
    untouched = [a for a in range(0x100) if a not in zp and a not in owned]
    named_but_cold = [a for a in range(0x100) if a not in zp and a in owned]

    print(f'\n  ZP bytes untouched AND unnamed: {len(untouched)}'
          f'   (+{len(named_but_cold)} untouched but OWNED -- not offered)')
    if untouched:
        print('    ' + ' '.join(f'${a:02X}' for a in untouched[:32])
              + (' ...' if len(untouched) > 32 else ''))
        print('    CAUTION: untouched BY THIS CORPUS, which runs render and')
        print('    movement only.  Boot, respawn, the HUD and the tube glue')
        print('    are not exercised here, and a byte that is free in one')
        print('    phase and live in another is this map\'s oldest trap')
        print('    (see feedback-zp-free-traps).  Confirm with a write-watch')
        print('    over a full boot before claiming any of these.')

    print('\n  HOTTEST ABSOLUTE SCALARS (promotion candidates)')
    print(f'    {"addr":>7} {"accesses":>9} {"/frame":>8}  {"modes":<12} name')
    shown = 0
    for a, c in hot:
        if shown >= 20: break
        md = ','.join(f'{k}:{v}' for k, v in modes[a].most_common(2))
        print(f'    ${a:04X} {c:9,} {c/nposes:8.1f}  {md:<12} {names.get(a,"")}')
        shown += 1

    print('\n  COLDEST ZP OCCUPANTS (eviction candidates)')
    print(f'    {"addr":>7} {"accesses":>9} {"/frame":>8}  name')
    for a, c in cold[:12]:
        print(f'    ${a:02X}   {c:9,} {c/nposes:8.1f}  {names.get(a,"")}')

    # the actual arbitrage
    print('\n  SWAPS WORTH MAKING (hot absolute > coldest ZP, 1 cyc/access)')
    gain = 0; n = 0
    for (ha, hc), (ca, cc) in zip(hot, cold):
        if hc <= cc: break
        d = hc - cc
        if len(untouched) > n:            # no eviction needed
            print(f'    ${ha:04X} {names.get(ha,""):<20} -> free ZP byte      '
                  f'+{hc/nposes:8.1f} cyc/frame')
            gain += hc
        else:
            print(f'    ${ha:04X} {names.get(ha,""):<20} evict ${ca:02X} '
                  f'{names.get(ca,""):<14} +{d/nposes:7.1f} cyc/frame')
            gain += d
        n += 1
    if not n:
        print('    none -- zero page already holds the hottest scalars')
    else:
        print(f'\n    {n} swap(s), {gain/nposes:,.0f} cycles/frame available')
    print()


if __name__ == '__main__':
    main()
