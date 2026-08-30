#!/usr/bin/env python3
"""Find ZP locations the engine READS before ever writing them.

Those consume the "memory arrives zeroed" ground state.  That state is
real in py65 and on the harnesses, and NOT real on hardware: the
parasite's zero page arrives holding tube MOS workspace, and the host's
holds OS/BASIC leftovers.  tubedrv's boot already zeroes the runtime
arenas ($0400-$19FF) for exactly this reason -- it just never covered
zero page.

Method: run the full setup with WRITE tracking, so every ZP byte the
driver/view-setup legitimately establishes is known.  Poison everything
else, run a frame, and report each read of a byte that is still poison.
Those reads are the ground-state consumers.

A hit is not automatically a bug -- the value may be dead, or the read
may be a cache-valid test that fails safe.  It is the candidate list.
"""
import os, sys, collections
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import re, py65.devices.mpu6502 as M
# Symbols resolve for the build the shared rig IS (banked since 2026-08-29;
# DOOM_FLAT_RIG=1 restores flat).  zp/pool names are identical in both maps
# by rule, so only CODE entries actually move -- but a stale flat entry in a
# banked rig is a silent jump into the wrong build, so resolve it all here.
import functools as _ft, os as _os
import doom_wireframe as dw   # the single rig switch
_BANKED = 0 if dw.FLAT_RIG else 1     # dw is the single switch
from symmap import sym as _raw_sym
sym = _ft.partial(_raw_sym, banked=_BANKED)
import storescan as SS

MODES = M.MPU().disassemble
LOADS = {0xA5:'zpg',0xB5:'zpx',0xA6:'zpg',0xB6:'zpy',0xA4:'zpg',0xB4:'zpx',
         0x24:'zpg',0x25:'zpg',0x35:'zpx',0x05:'zpg',0x15:'zpx',
         0x45:'zpg',0x55:'zpx',0x65:'zpg',0x75:'zpx',0xE5:'zpg',0xF5:'zpx',
         0xC5:'zpg',0xD5:'zpx',0xE4:'zpg',0xC4:'zpg',0x06:'zpg',0x16:'zpx',
         0x46:'zpg',0x56:'zpx',0x26:'zpg',0x36:'zpx',0x66:'zpg',0x76:'zpx',
         0xE6:'zpg',0xF6:'zpx',0xC6:'zpg',0xD6:'zpx',
         0xA1:'inx',0xB1:'iny',0x81:'inx',0x91:'iny'}


def zp_ea(mpu, mem, pc, mode):
    o = mem[(pc + 1) & 0xFFFF]
    if mode == 'zpg': return [o]
    if mode == 'zpx': return [(o + mpu.x) & 0xFF]
    if mode == 'zpy': return [(o + mpu.y) & 0xFF]
    if mode == 'inx': return [(o + mpu.x) & 0xFF, (o + mpu.x + 1) & 0xFF]
    if mode == 'iny': return [o, (o + 1) & 0xFF]
    return []


def main():
    import doom_wireframe as dw, trace_compare as tc, compare_renders as C
    from bsp_render_6502 import poke_init_frame_state as poke
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    mpu = sc.mpu; mem = mpu.memory

    written = set()
    def track():
        pc = mpu.pc; op = mem[pc]
        r = SS.STORES.get(op)
        if r:
            a = SS.ea(mpu, mem, pc, MODES[op][1])
            if a is not None and a < 0x100: written.add(a)

    tc.setup_wad(sc); tc.setup_view_zp(sc, *C.POSITIONS[0])
    # run view setup under tracking
    mpu.pc = tc.ENTRY_BR_VIEW_SETUP; mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
    while mpu.pc != 0xFF00:
        track(); mpu.step()
    sc.init(); sc.clear_screen(); poke(mem)
    # anything Python poked directly counts as established too
    # (zp_dcl_rec_* retired 2026-08-25 with the records machinery)
    for a in range(0x100):
        if mem[a]: written.add(a)          # non-zero => something set it

    POISON = 0xA5
    virgin = set(range(0x00, 0x100)) - written
    for a in virgin: mem[a] = POISON
    hits = collections.Counter(); first = {}
    mpu.pc = sym('render_frame'); mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
    while mpu.pc != 0xFF00:
        pc = mpu.pc; op = mem[pc]
        m = LOADS.get(op)
        if m:
            for a in zp_ea(mpu, mem, pc, m):
                if a in virgin:
                    hits[(pc, a)] += 1
                    first.setdefault((pc, a), True)
        r = SS.STORES.get(op)
        if r:
            a = SS.ea(mpu, mem, pc, MODES[op][1])
            if a is not None and a < 0x100: virgin.discard(a)
        mpu.step()

    lm = SS.linemap(); srcs = {}
    print(f'{len(written)} ZP bytes established by setup; '
          f'{0x100-len(written)} poisoned\n')
    if not hits:
        print('no reads of never-written ZP -- the engine does not rely on '
              'the zero ground state'); return
    print('READS OF NEVER-WRITTEN ZP (ground-state consumers):\n')
    for (pc, a), n in sorted(hits.items(), key=lambda kv: -kv[1]):
        loc = lm.get(pc); txt = ''
        if loc:
            fn, line = loc
            if fn not in srcs:
                srcs[fn] = open(os.path.join(ROOT, fn), errors='ignore').readlines()
            txt = f"{fn}:{line}  {srcs[fn][line-1].split(';')[0].strip()}"
        print(f'  {n:5d}x  ${pc:04X}  reads ${a:02X}   {txt}')


if __name__ == '__main__':
    main()
