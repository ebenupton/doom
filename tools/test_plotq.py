#!/usr/bin/env python3
"""PLOT RUN-AHEAD QUEUE gate.

The queue (plotq_mode = $80) is a DRIVER feature: lines are appended to
PLOTQ instead of drawn, and the driver's pump drains them once the flip's
vsync has fired.  Nothing in the harness ever armed it, so the whole
enqueue -> pump -> drain -> dispatch path shipped untested — every gate
we have runs in direct mode.

This renders each pose twice, direct and queued, and requires the two
framebuffers to be BIT-IDENTICAL.  The pump is a stub poked into the
harness memory (drain when the queue is full, exactly the shape of the
driver's "or the queue fills" arm); anything still queued at end of
frame is drained before the compare.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw, symmap
from bsp_render_6502 import BspRender6502
import compare_renders as C

FB_LO, FB_HI = 0xEA00, 0xF7F0
STUB = 0xFE80                      # Somewhere a render does NOT wipe. Two
                                   # earlier homes were wrong and both showed
                                   # up as "the queue diverges": $0F00 is the
                                   # flat VCACHE, and the harness clears
                                   # $F800-$FDFF every frame, so the stub
                                   # became BRKs and the render fell into
                                   # zero page. $FE80 survives and is clear
                                   # of every register the engine touches
                                   # ($FE00/01 CRTC, $FE30 ROMSEL, $FE4D VIA).


def fb(mem):
    return bytes(mem[FB_LO:FB_HI])


def main():
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    mem = r.sc.mpu.memory
    S = symmap.sym
    mode, n, pump, drain = S('plotq_mode'), S('plotq_n'), S('pq_pump_op'), S('plotq_drain')
    arm, off = S('plotq_arm'), S('plotq_off')

    def call(entry):
        mpu = r.sc.mpu
        mpu.pc, mpu.sp, mpu.p = entry, 0xDD, 0x30
        mem[0x01DF], mem[0x01DE] = 0xFE, 0xFF
        steps = 0
        while mpu.pc != 0xFF00 and steps < 2_000_000:
            mpu.step(); steps += 1
    # pump stub: if plotq_n == 0 the queue just wrapped (FULL) -> drain.
    # The mode MUST drop to direct around the drain: the drain dispatches
    # through the same axis rules the emit sites use, so with the queue
    # still armed every drained line re-enqueues itself instead of being
    # drawn. (That is exactly what the driver's pump does, and getting it
    # wrong here is what made this gate's first run diverge on 13 poses.)
    for i, b in enumerate([0xAD, n & 0xFF, n >> 8,      # LDA plotq_n
                           0xF0, 0x01,                  # BEQ do
                           0x60,                        # RTS
                           0x20, off & 0xFF, off >> 8,      # do: JSR plotq_off
                           0x20, drain & 0xFF, drain >> 8,  # JSR plotq_drain
                           0x20, arm & 0xFF, arm >> 8,      # JSR plotq_arm
                           0x60]):                          # RTS
        mem[STUB + i] = b
    mem[pump + 1], mem[pump + 2] = STUB & 0xFF, STUB >> 8

    bad = 0
    for (px, py, ab) in C.POSITIONS:
        call(off)
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        direct = fb(mem)
        call(arm)
        mem[n] = 0
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        call(off)                                    # direct BEFORE draining
        if mem[n]:                                   # drain the tail
            call(drain)
        queued = fb(mem)
        d = sum(1 for a, b in zip(direct, queued) if a != b)
        if d:
            bad += 1
            print(f'  ({px},{py},{ab}): {d} FB bytes differ  *** QUEUE DIVERGES ***')
    print(f'  {len(C.POSITIONS)} poses, {len(C.POSITIONS) - bad} bit-identical')
    print('PLOTQ: ' + ('PASS' if not bad else 'FAIL'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
