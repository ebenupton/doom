"""Unit-test 6502 seg processor against Python's packed_render_seg.

Sets up identical state in both, runs ONE seg, compares emitted clipper
calls. Identifies whether seg-processor divergence is local (the 6502
emits different draws for the same span state) or just timing-based
(same draws, different order across subsectors).

Strategy:
  - Spin up TWO SpanClip6502 instances with the same WAD + view state.
  - For each (px, py, ab, seg_idx) test case:
      * Reset both clippers (init).
      * Run Python's packed_render_seg.
      * Capture its clipper call trace.
      * Reset both clippers again.
      * Run 6502's seg processing on the same seg by setting zp_seg_first_*
        and zp_seg_count = 1, then jumping into the seg loop entry.
      * Capture its clipper call trace.
      * Diff.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from wad_packed import (read_u8, read_u16, spans_init_full, SEG_DTL_SIZE,
                        SD_FH, SD_CH, SD_BFH, SD_BCH)
import trace_compare as tc


def trace_python_seg(sc, si, px, py, ab):
    """Run Python's packed_render_seg on seg si, capture clipper calls."""
    # Need: ram, ctx, vz, player coords. Use a fresh ram each call.
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    sc_t = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(px_88, py_88, sc_t)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    surf = pygame.Surface((256, 160))
    trace = []
    tc.install_tracing_run(sc, trace, with_context=False)
    dw.packed_render_seg(si, dw.Instrumented6502Spans(), ctx, vz, surf,
                         p_ram, deferred=None)
    return trace


def trace_6502_seg(sc, si, px, py, ab):
    """Run 6502's seg processing on seg si via the seg loop entry.
    Sets zp_seg_first_* = si, zp_seg_count = 1, then enters the seg loop.
    """
    mem = sc.mpu.memory
    # Set view state via br_view_setup.
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    # Clear cache valid bitmap (so vertex cache rebuilds cleanly).
    for i in range(59):
        mem[0x1B00 + i] = 0
    # Set seg loop state: first_seg = si, count = 1.
    mem[0x5A] = si & 0xFF        # zp_seg_first_lo
    mem[0x5B] = (si >> 8) & 0xFF  # zp_seg_first_hi
    mem[0x5C] = 1                 # zp_seg_count
    # The seg loop entry .seg_loop is somewhere inside br_render_subsector.
    # br_render_subsector starts by reading the subsector header from ROM
    # and setting zp_seg_count/first. We want to BYPASS that — we set them
    # manually. So we need a direct jump into .seg_loop.
    # The seg_loop label's PC is hard-coded; find it dynamically by reading
    # the bin layout: the JMP target after the subsector-id parse is
    # .seg_loop. For now, hard-code via a search: assume seg_loop is at
    # zp_seg_count: BNE seg_proc / RTS / .seg_proc — at PC ~$4D71 region.
    # Easier: just call br_render_subsector with the cached values, but
    # the entry resets zp_seg_count. So instead bypass via the seg_loop
    # PC found from the binary.
    # For now, use the simplest: just JSR br_render_subsector entry but
    # with the subsector id pointing to a single-seg subsector. We can
    # fabricate a fake subsector in RAM.
    # Use $0900 as a scratch fake-ssector area: write (count=1, _, first_seg)
    # The br_render_subsector reads from ROM_SS + id*4. We can write a
    # fake at, say, RAM $1C30 (after lo binary helpers, in the free zone),
    # but ROM_SS is in ROM. Easier: write the fake header at the actual
    # ss id's slot temporarily — but that mutates ROM data.
    # Alternative: write fake header at unused subsector id (use 0).
    # Subsector 0 might be real geometry though.
    # Cleanest: just write fake subsector header at a SAFE unused area
    # and jump into br_render_subsector with that id.
    #
    # Actually simpler: use a fake id and write the header to an unused
    # ROM area, point zp_rom_ss_lo at it temporarily.
    #
    # For now: write fake header at $0900 (zero-page area available), and
    # temporarily redirect zp_rom_ss to point there minus id*4.
    FAKE_SS_BASE = 0x0900
    mem[FAKE_SS_BASE + 0] = 1            # count = 1
    mem[FAKE_SS_BASE + 1] = 0
    mem[FAKE_SS_BASE + 2] = si & 0xFF
    mem[FAKE_SS_BASE + 3] = (si >> 8) & 0xFF
    saved_ss_lo = mem[0x44]
    saved_ss_hi = mem[0x45]
    # Re-point so render_subsector with id=0 reads from $0900.
    mem[0x44] = FAKE_SS_BASE & 0xFF
    mem[0x45] = (FAKE_SS_BASE >> 8) & 0xFF
    mem[0x58] = 0; mem[0x59] = 0   # ss id = 0
    trace = []
    tc.install_tracing_run(sc, trace, with_context=False)
    # Find br_render_subsector entry by reading the JMP target at $4806
    # ... actually it's not in the jump table. Hmm.
    # Workaround: just call the BSP loop after pushing ss id 0 with $80 flag.
    mem[0x4D] = 0  # zp_bsp_stack_sp = 0
    # Push (ssid_lo=0, ssid_hi=$80) as subsector entry
    mem[0x0A00] = 0
    mem[0x0A01] = 0x80
    mem[0x4D] = 2  # stack pointer = 2 (2 bytes pushed)
    # Call into the bsp_loop. Find its address... actually I'll just call
    # the whole br_render_frame and capture only seg-related calls.
    # But that loses isolation. For now just call br_render_frame and
    # accept that the trace includes BSP + seg work.
    # Restore ss pointer
    mem[0x44] = saved_ss_lo
    mem[0x45] = saved_ss_hi
    return trace


if __name__ == '__main__':
    # Test: at (1056, -3616, 32), seg 21 (in ss5) — Python returns has_gap False
    # (occluded), ASM returns True. Both should compute the SAME sx/ft/fb
    # values for the seg. Verify.
    sc_py  = tc.SpanClip6502()
    sc_asm = tc.SpanClip6502()
    tc.setup_wad(sc_py)
    tc.setup_wad(sc_asm)

    # Initialise the clipper span lists fresh (no prior mark_solid).
    sc_py.init()
    sc_asm.init()

    px, py, ab = 1056, -3616, 32
    si = 21

    py_trace = trace_python_seg(sc_py, si, px, py, ab)
    print(f'Python seg {si} trace ({len(py_trace)} events):')
    for e in py_trace:
        print(f'  {e}')
