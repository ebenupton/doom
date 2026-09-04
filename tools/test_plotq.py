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
import doom_wireframe as dw, symmap, abi
from banked_bsp import BankedBspRender as BspRender6502, BANK_C
import compare_renders as C

FB_LO, FB_HI = 0x5800, 0x6C00      # banked hw screen (was the flat harness
                                   # FB $EA00; the reference moved 2026-08-29)
STUB = 0x7F00                      # Somewhere a render does NOT wipe. THREE
                                   # earlier homes were wrong and each showed
                                   # up as "the queue diverges": $0F00 is the
                                   # flat VXCACHE; the flat harness cleared
                                   # $F800-$FDFF every frame; and $FE80 is
                                   # real I/O once the memory model banks
                                   # (the stub became register writes).  In
                                   # the banked map $6C00-$7FFF is SCREEN1,
                                   # which this harness never renders into --
                                   # it always draws to SCREEN0 at $5800.


def fb(mem):
    return bytes(mem[FB_LO:FB_HI])


def main():
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    mem = r.sc.mpu.memory
    S = lambda nm: symmap.sym(nm, banked=1)
    mode, n, pump, drain = S('plotq_mode'), S('plotq_n'), S('pq_pump_op'), S('plotq_drain')
    arm, off = S('plotq_arm'), S('plotq_off')

    def call(entry):
        mpu = r.sc.mpu
        # plotq_arm/off/drain live in BANK C and the ABI says the bank must
        # be paged before entry -- dv_emit_op, the SMC site they retarget,
        # is in there too.  Without this the pokes land in whatever bank
        # happened to be selected and the queue "diverges" (2026-08-29).
        mem.select(BANK_C)
        mpu.pc, mpu.sp, mpu.p = entry, 0xDD, 0x30
        mem[0x01DF], mem[0x01DE] = 0xFE, 0xFF
        steps = 0
        while mpu.pc != 0xFF00 and steps < 2_000_000:
            mpu.step(); steps += 1
    # pump stub: if plotq_n is $FF the queue just wrapped (FULL) -> drain
    # (count-down design 2026-09-01: 63 = empty, DEX past 0 = full).
    # The mode MUST drop to direct around the drain: the drain dispatches
    # through the same axis rules the emit sites use, so with the queue
    # still armed every drained line re-enqueues itself instead of being
    # drawn. (That is exactly what the driver's pump does, and getting it
    # wrong here is what made this gate's first run diverge on 13 poses.)
    # The stub must page BANK C itself, exactly as the driver's pq_pump does
    # ("explicit: the emit cascade leaves C live, but do not lean on it") --
    # plotq_off/drain/arm AND the plot_h/plot_v the drain dispatches to all
    # live in bank C.  Without it only the light poses agreed: the heavy ones
    # are the frames that actually fill the queue and fire the pump.
    for i, b in enumerate([0xA9, abi.BANK_C, 0x8D, 0x30, 0xFE,   # LDA #C:STA ROMSEL
                           0xAD, n & 0xFF, n >> 8,      # LDA plotq_n
                           0x30, 0x01,                  # BMI do (FULL = $FF)
                           0x60,                        # RTS
                           0x20, off & 0xFF, off >> 8,      # do: JSR plotq_off
                           0x20, drain & 0xFF, drain >> 8,  # JSR plotq_drain
                           0x20, arm & 0xFF, arm >> 8,      # JSR plotq_arm
                           0x60]):                          # RTS
        mem[STUB + i] = b
    # pq_pump_op is IN THE BANK C WINDOW.  Poking it with another bank
    # selected writes into that bank's data instead (walk_drv's init pages
    # C explicitly for this very reason -- "the RCACHE write would shred
    # node data").  Un-paged, the patch vanished, the pump never fired, the
    # queue silently wrapped and the armed heavy frames drew NOTHING while
    # the light ones -- which never fill the queue -- still matched.
    mem.select(BANK_C)
    mem[pump + 1], mem[pump + 2] = STUB & 0xFF, STUB >> 8

    bad = 0
    for (px, py, ab) in C.POSITIONS:
        call(off)
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        direct = fb(mem)
        call(arm)                                    # arm inits n = 63 (count-down)
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        call(off)                                    # direct BEFORE draining
        if mem[n] != 63:                             # drain the tail (63 = empty)
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
