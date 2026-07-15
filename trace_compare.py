"""Compare 6502-clipper call streams from Python vs 6502 front-ends.

Both paths drive the same 6502 span_clip. The Python front-end is the
working reference; the 6502 front-end (bsp_render.bin) should produce
the same sequence of entry-point invocations. Any divergence is a bug
in the 6502 front-end. This harness records and diffs the streams.

Captured calls (per clipper entry, with args read from ZP at PC = entry):
  $2003 mark_solid   (ilo, ihi)            from $C2, $C3
  $2009 has_gap      (ilo, ihi)            from $C2, $C3
  $200C is_full      ()
  $201E draw_s16     (xl, yl, xr, yr)      from $A8|$B2, $A9|$B3, $AA|$B4, $AB|$B5
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502
import doom_wireframe as dw
import fp
from wad_packed import (SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH,
                        spans_init_full)

from symmap import sym as _sym
ENTRY_BR_VIEW_SETUP   = _sym('jt_br_view_setup')
ENTRY_BR_RENDER_FRAME = _sym('jt_br_render_frame')
_E_MARK_SOLID = _sym('jt_mark_solid')
_E_HAS_GAP    = _sym('jt_has_gap')
_E_IS_FULL    = _sym('jt_is_full')
_E_DCL_S16    = _sym('jt_draw_clip_s16')
ROM_DETAIL_BASE = 0xB600
ROM_BBOX_BASE   = 0xC400


import angle_bbox as _A


def load_angle_module(mem):
    """Load the angle-space bbox module + tables into 6502 memory.
    Code @ $E940; TA_LO $DC00, TA_HI $EF00 (tantoangle); VATOX $F300 (1025)."""
    code = open('bsp_render_ang.bin', 'rb').read()
    for i, b in enumerate(code):
        mem[0xE940 + i] = b
    for i in range(1024):
        v = _A._tantoangle[i]
        mem[0xDC00 + i] = v & 0xFF
        mem[0xF200 + i] = (v >> 8) & 0xFF
    for k in range(1025):            # VATOX shrunk: phi+512 index, $F300
        _vt = (_A._vatox_lo[k + 512] + _A._vatox_hi[k + 512]) // 2
        mem[0xF601 + k] = max(0, min(255, _vt))


def setup_wad(sc):
    load_angle_module(sc.mpu.memory)
    layout = dw.packed_layout
    rom_main = dw.packed_rom_main
    rom_detail = dw.packed_rom_detail
    mem = sc.mpu.memory
    # flat scatter (2026-07-11): headers (stride 18, heights inlined by
    # the packer) at $6C00, verts $9C00, SoA $B600 — one loader truth in
    # bsp_render_6502; reuse its bases.
    from bsp_render_6502 import (ROM_SEG_HDR_BASE, ROM_VERTS_BASE,
                                 NODE_SOA_BASE)
    off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
    for i in range(off_verts):
        mem[NODE_SOA_BASE + i] = rom_main[i]
    for i in range(0xD00, 0xE00):        # SS_PHI: offsets -> flat pointers
        mem[NODE_SOA_BASE + i] = (rom_main[i] + (ROM_SEG_HDR_BASE >> 8)) & 0xFF
    for i in range(off_verts, off_hdr):
        mem[ROM_VERTS_BASE + (i - off_verts)] = rom_main[i]
    for i in range(off_hdr, len(rom_main)):
        mem[ROM_SEG_HDR_BASE + (i - off_hdr)] = rom_main[i]
    for i, b in enumerate(dw.packed_bbox_table):
        mem[ROM_BBOX_BASE + i] = b
    def w16(addr_lo, val):
        mem[addr_lo]     = val & 0xFF
        mem[addr_lo + 1] = (val >> 8) & 0xFF


def setup_view_zp(sc, px, py, ab):
    mem = sc.mpu.memory
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    mem[0]     = px_88 & 0xFF
    mem[1]     = (px_88 >> 8) & 0xFF
    mem[2]     = py_88 & 0xFF
    mem[3]     = (py_88 >> 8) & 0xFF
    from symmap import sym as _sym
    mem[_sym('zp_br_px_x')] = (px_88 >> 16) & 0xFF
    mem[_sym('zp_br_py_x')] = (py_88 >> 16) & 0xFF
    fz = dw.player_floor(px, py)
    vz = dw._prescale_height(fz + 41)
    mem[4] = vz & 0xFF
    raw_px = px - dw.MAP_CENTER_X
    raw_py = py - dw.MAP_CENTER_Y
    mem[0x90] = raw_px & 0xFF
    mem[0x91] = (raw_px >> 8) & 0xFF
    mem[0x92] = raw_py & 0xFF
    mem[0x93] = (raw_py >> 8) & 0xFF
    mem[0xFA2F] = ab & 0xFF        # bca_ab: angle-space bbox view angle (u8)
    sc_t = fp.fp_sincos(ab)
    mem[5] = sc_t[0]
    mem[6] = 1 if sc_t[1] else 0
    mem[7] = 1 if sc_t[2] else 0
    mem[8] = sc_t[3]
    mem[9] = 1 if sc_t[4] else 0
    mem[0x0A] = 1 if sc_t[5] else 0


def s16(v):
    return v - 0x10000 if v >= 0x8000 else v


def install_tracing_run(sc, trace, with_context=False):
    """Replace sc._run with a stepping version that records clipper calls.

    If with_context, each call tuple is (op, *args, ssid, seg_idx) where
    ssid is zp_node_ch_l:hi (subsector id, with $80 flag). seg_idx —
    NOTE (2026-07-10): zp_seg_first is RETIRED ($5A/$5B freed; the
    prologue derives both cursors from the SS SoA directly), so $5A/$5B
    read garbage. For per-seg attribution derive the offset from the
    FHCH cursor: (zp_fhch_p - rom_fhch_base) / 6.
    """
    def traced_run(entry, max_cycles=20_000_000):
        mpu = sc.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xFD
        mpu.p = 0x30
        mem[0x01FF] = 0xFE
        mem[0x01FE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            if mpu.pc == 0xFF00:
                break
            pc = mpu.pc
            evt = None
            if pc == _E_MARK_SOLID:
                evt = ('mark_solid', mem[0xC2], mem[0xC3])
            elif pc == _E_HAS_GAP:
                evt = ('has_gap', mem[0xC2], mem[0xC3])
            elif pc == _E_IS_FULL:
                evt = ('is_full', mem[0x58], mem[0x59])
            elif pc == _E_DCL_S16:
                xl = s16(mem[0xA8] | (mem[0xB2] << 8))
                yl = s16(mem[0xA9] | (mem[0xB3] << 8))
                xr = s16(mem[0xAA] | (mem[0xB4] << 8))
                yr = s16(mem[0xAB] | (mem[0xB5] << 8))
                evt = ('draw', xl, yl, xr, yr)
            if evt is not None:
                if with_context:
                    ssid = mem[0x58] | (mem[0x59] << 8)
                    seg_idx = mem[0x5A] | (mem[0x5B] << 8)
                    evt = evt + (ssid, seg_idx)
                trace.append(evt)
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += sc.last_cycles
        return sc.last_cycles
    sc._run = traced_run


def trace_python(px, py, ab):
    # The Python front-end uses dw._span_clip_6502 (a module global),
    # not a fresh sc instance — so trace THAT instance.
    spans = dw.Instrumented6502Spans()    # this initialises the global
    sc = dw._span_clip_6502
    setup_wad(sc)
    setup_view_zp(sc, px, py, ab)
    sc._run(ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    trace = []
    install_tracing_run(sc, trace)

    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    sc_t = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(px_88, py_88, sc_t)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    surf = pygame.Surface((256, 160))
    dw.packed_render_bsp(
        len(dw.nodes) - 1, spans,
        ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    return trace


def trace_6502(px, py, ab):
    sc = SpanClip6502()
    setup_wad(sc)
    setup_view_zp(sc, px, py, ab)
    sc._run(ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    trace = []
    install_tracing_run(sc, trace)
    sc._run(ENTRY_BR_RENDER_FRAME)
    return trace


def fmt(call):
    if call[0] == 'is_full':
        return 'is_full()'
    if call[0] == 'draw':
        return f'draw({call[1]},{call[2]},{call[3]},{call[4]})'
    return f'{call[0]}({call[1]},{call[2]})'


def normalize(trace):
    """Strip nid info from is_full so traces compare on op-only."""
    return [(c[0],) if c[0] == 'is_full' else c for c in trace]


def filter_state_changing(trace):
    """Drop has_gap/is_full queries (read-only; their position in the
    sequence doesn't affect framebuffer output). Keep mark_solid and draw."""
    return [c for c in trace if c[0] in ('mark_solid', 'draw')]


def diff_traces(py_trace, asm_trace, label='full'):
    n = min(len(py_trace), len(asm_trace))
    print(f'  [{label}] py len = {len(py_trace)}, asm len = {len(asm_trace)}')
    diffs = 0
    first_diff = None
    for i in range(n):
        if py_trace[i] != asm_trace[i]:
            diffs += 1
            if first_diff is None:
                first_diff = i
    if first_diff is None and len(py_trace) == len(asm_trace):
        print(f'  [{label}] IDENTICAL')
        return
    if first_diff is not None:
        print(f'  [{label}] first divergence at index {first_diff}')
        lo = max(0, first_diff - 3)
        hi = min(n, first_diff + 8)
        for i in range(lo, hi):
            mark = '<--' if i == first_diff else '   '
            py_s  = fmt(py_trace[i])  if i < len(py_trace)  else '(end)'
            asm_s = fmt(asm_trace[i]) if i < len(asm_trace) else '(end)'
            print(f'    [{i:5d}] py={py_s:38s} asm={asm_s:38s} {mark}')
    print(f'  [{label}] mismatches in common prefix: {diffs}/{n}')


if __name__ == '__main__':
    if len(sys.argv) >= 4:
        px, py, ab = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    else:
        px, py, ab = 1056, -3616, 192   # 100% match position — should diff cleanly
    print(f'Tracing at ({px}, {py}, ab={ab})...')
    py_trace = normalize(trace_python(px, py, ab))
    asm_trace = normalize(trace_6502(px, py, ab))
    print()
    diff_traces(py_trace, asm_trace, 'full')
    print()
    py_state  = filter_state_changing(py_trace)
    asm_state = filter_state_changing(asm_trace)
    diff_traces(py_state, asm_state, 'state-changing')
