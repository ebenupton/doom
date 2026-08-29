#!/usr/bin/env python3
"""Dynamic zero-page traffic census: how many times each ZP byte is
actually accessed, and by which source lines.

    python3 tools/zpheat.py [--pos X,Y,ANG]

Every ZP byte costs one page of the machine's scarcest resource, and the
only honest price of evicting one to absolute is how often it is
touched (1 extra cycle per access, 1 extra byte per instruction).  So
decode each executed instruction's addressing mode and charge the byte:

  zpg/zpx/zpy   -> the effective address
  inx/iny       -> the POINTER pair at zp, zp+1 (2 bytes, twice each)

Indexed modes charge the effective address, so a struct walked with X
shows its real footprint rather than just its base.
"""
import os, sys, collections
# Profile the build that SHIPS: the shared span rig went banked
# 2026-08-29 (DOOM_FLAT_RIG=1 for the old flat one).
BANKED = 1 if os.environ.get('DOOM_BANKED_RIG') == '1' else 0

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import py65.devices.mpu6502 as M
MODES = M.MPU().disassemble

ZPG = {'zpg', 'zpx', 'zpy'}
IND = {'inx', 'iny'}


def census(px, py, ab):
    import doom_wireframe as dw, trace_compare as tc
    from symmap import sym
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    from bsp_render_6502 import poke_init_frame_state
    poke_init_frame_state(sc.mpu.memory)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = sym('render_frame', banked=BANKED); mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF; mpu.processorCycles = 0
    hits = collections.Counter()
    while mpu.pc != 0xFF00:
        pc = mpu.pc
        mode = MODES[mem[pc]][1]
        if mode in ZPG or mode in IND:
            z = mem[(pc + 1) & 0xFFFF]
            if mode == 'zpg' or mode in IND:
                base = z
            elif mode == 'zpx':
                base = (z + mpu.x) & 0xFF
            else:
                base = (z + mpu.y) & 0xFF
            if mode in IND:
                p = (z + mpu.x) & 0xFF if mode == 'inx' else z
                hits[p] += 1
                hits[(p + 1) & 0xFF] += 1
            else:
                hits[base] += 1
        mpu.step()
    return hits, mpu.processorCycles


def main():
    pos = (1133, -3242, 0x90)
    for a in sys.argv[1:]:
        if a.startswith('--pos'):
            pos = tuple(int(x, 0) for x in a.split('=', 1)[1].split(','))
    hits, tot = census(*pos)
    names = {}
    import re
    for f in ('src/zp.inc', 'src/abi.inc'):
        for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s*=\s*\$([0-9A-Fa-f]{1,4})\b',
                             open(os.path.join(ROOT, f)).read(), re.M):
            a = int(m.group(2), 16)
            if a < 0x100:
                names.setdefault(a, []).append(m.group(1))
    cold = [a for a in range(0x100) if hits[a] == 0]
    print(f'frame {pos}: {sum(hits.values()):,} ZP accesses over {tot:,} cycles')
    print(f'\nNEVER TOUCHED this frame: {len(cold)} bytes')
    runs, cur = [], []
    for a in cold:
        if cur and a == cur[-1] + 1:
            cur.append(a)
        else:
            if cur:
                runs.append(cur)
            cur = [a]
    if cur:
        runs.append(cur)
    print('  ' + ', '.join(f'${r[0]:02X}' if len(r) == 1
                           else f'${r[0]:02X}-${r[-1]:02X}({len(r)})' for r in runs))
    print('\nCOLDEST touched bytes (cheapest to evict to absolute):')
    warm = sorted((c, a) for a, c in hits.items() if c)
    for c, a in warm[:28]:
        print(f'  ${a:02X}  {c:6,} accesses  {",".join(names.get(a, ["?"]))[:44]}')


main()
