"""Compare 6502-clipper call streams from Python vs 6502 front-ends.

Both paths drive the same 6502 span_clip. The Python front-end is the
working reference; the 6502 front-end (bsp_render.bin) should produce
the same sequence of entry-point invocations. Any divergence is a bug
in the 6502 front-end. This harness records and diffs the streams.

Captured calls (per clipper entry, with args read from ZP at PC = entry):
  $2003 mark_solid   (ilo, ihi)            from $C2, $C3
  $2009 has_gap      (ilo, ihi)            from $C2, A (A-hi ABI)
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

# Resolve symbols for the build the shared rig actually is (2026-08-29).
# zp/pool names are identical in both maps by rule ($0000-$57FF), so only
# the CODE entries below actually move -- but resolving everything through
# one build keeps it honest if that rule ever bends.
import functools as _ft
from symmap import sym as _raw_sym
_sym = _ft.partial(_raw_sym, banked=0 if dw.FLAT_RIG else 1)
ENTRY_BR_VIEW_SETUP   = _sym('view_setup')
ENTRY_BR_RENDER_FRAME = _sym('render_frame')
_E_MARK_SOLID = _sym('span_mark_solid')
_E_HAS_GAP    = _sym('span_has_gap')
_E_DCL_S16    = _sym('draw_clipped_line_s16')
from bsp_render_6502 import ROM_DETAIL_BASE, ROM_BBOX_BASE  # one truth (2026-07-21 map)


import angle_bbox as _A


def load_angle_module(mem):
    """Canonical loader ONLY (2026-07-17): this used to be a PRIVATE
    seeder copy and it silently seeded tantoangle into the pages the F
    tables took over — every in-frame harness ran the corner pipeline
    on garbage while the standalone path was correct (check_angle_calls
    caught it, 20/732). Private copies of table seeds are as forbidden
    as private address copies."""
    from engine_load import load_angle_module as _canonical
    _canonical(mem)


def setup_wad(sc):
    if getattr(sc, 'SCREEN_START', 0xEA00) == 0x5800:
        # BANKED RIG: it arrives FULLY SEEDED -- BspRender6502._load_wad put
        # the tables in, build_banked redistributed them into the banks and
        # loaded every engine region.  The flat scatter below would spray
        # flat-laid data over a banked image, and that does not fail, it
        # HANGS: the engine walks garbage to the cycle cap on every call
        # (test_bsp_render went 0.9s -> 180s+, one gate ran 40 minutes).
        # The only thing this differential still owes is the objects-off
        # state, since it has always run without billboards.
        mem = sc.mpu.memory
        for i in range(28):
            mem[_sym('OBJ_ANYB') + i] = 0
        return
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
    # SS_PG rebase (2026-08-29): final header hi byte in the loaded plane
    for i in range(layout['n_ss']):
        _pg = layout['off_ss'] + i
        mem[NODE_SOA_BASE + _pg] = (rom_main[_pg] + (ROM_SEG_HDR_BASE >> 8)) & 0xFF
    for i in range(off_verts, off_hdr):
        mem[ROM_VERTS_BASE + (i - off_verts)] = rom_main[i]
    off_obj = layout['off_obj']
    # header blob ends at off_ss_cnt (PG/CNT split 2026-08-29): the SS_CNT
    # plane is the rom_main tail with its OWN flat home — mirror of
    # bsp_render_6502's installer
    off_ss_cnt = layout['off_ss_cnt']
    for i in range(off_hdr, off_ss_cnt):
        mem[ROM_SEG_HDR_BASE + (i - off_hdr)] = rom_main[i]
    from symmap import sym as _symc
    _cntb = _symc('ROM_SS_CNT_C')
    for i in range(256):
        mem[_cntb + i] = rom_main[off_ss_cnt + i]
    from symmap import sym as _sym2                 # object table: own home
    _ob = _sym2('ROM_OBJ_C')
    for i in range(off_obj, off_obj + 0x200):       # the 512-byte hole ONLY
        mem[_ob + (i - off_obj)] = rom_main[i]      # (the K planes follow in
                                                    # the blob; own homes)
    for _nm, _off in (('ROM_BKTLO_C', layout['off_bktlo']),
                      ('ROM_BKTHI_C', layout['off_bkthi']),
                      ('ROM_DBOUND_C', layout['off_dbound'])):
        _dst = _sym2(_nm)
        for i in range(128):
            mem[_dst + i] = rom_main[_off + i]
    for i, b in enumerate(dw.packed_bbox_table):
        mem[ROM_BBOX_BASE + i] = b
    # OBJ_ANYB (2026-08-29): ZEROED explicitly — this differential has
    # always run objects-off (the bitmap sat in never-filled workspace)
    _anyb = _sym2('OBJ_ANYB')
    for i in range(28):
        mem[_anyb + i] = 0
    # vertex-span descriptor planes (flat homes; mirror of _load_wad)
    for i, d in enumerate(dw.vspan_desc):
        mem[0xDC00 + i] = d
    for i, (lo, hi, cont) in enumerate(dw.vspan_expl):
        _lo, _hi, _ct = dw.vexpl_bytes(i, lo, hi, cont)
        mem[0xDE00 + i] = _lo
        mem[0xDE80 + i] = _hi
        mem[0xDF00 + i] = _ct
    def w16(addr_lo, val):
        mem[addr_lo]     = val & 0xFF
        mem[addr_lo + 1] = (val >> 8) & 0xFF


def setup_view_zp(sc, px, py, ab):
    # Dynamic always-descend (2026-09-04): every driver that stages a pose
    # by hand comes through here, and they all TELEPORT between unrelated
    # poses in one engine.  The engine has no wipe, so clear its
    # productivity bits (NODE_DSGN b3/b2) with the pose — otherwise a cold
    # frame speculates on the last pose's world and the traversal stops
    # matching the reference.
    from bsp_render_6502 import adesc_reset_mem
    adesc_reset_mem(sc)
    # EVERY SLOT BY NAME.  These were literal mem[0]..mem[$0A] and
    # mem[$90]..mem[$93] -- the view block's addresses circa whenever the
    # function was written.  Zero page is linker-allocated and
    # tools/zprotate ROTATES cold bytes out of it, so those literals are
    # a standing landmine: on 2026-08-31 zp_br_px moved to absolute and
    # mem[0] started spraying the player position over the s16 clipper's
    # LC_OY1_LO anchor.  compare_subsector went to 56 pixel-affecting
    # subsectors and 6,889 px while the full-frame renders stayed CLEAN,
    # because the engine was fine and only this seeder was wrong.
    mem = sc.mpu.memory
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    mem[_sym('zp_br_px')]   = px_88 & 0xFF
    mem[_sym('zp_br_px_h')] = (px_88 >> 8) & 0xFF
    mem[_sym('zp_br_py')]   = py_88 & 0xFF
    mem[_sym('zp_br_py_h')] = (py_88 >> 8) & 0xFF
    mem[_sym('zp_br_px_x')] = (px_88 >> 16) & 0xFF
    mem[_sym('zp_br_py_x')] = (py_88 >> 16) & 0xFF
    fz = dw.player_floor(px, py)
    vz = dw._prescale_height(fz + 41)
    mem[_sym('zp_br_vz')] = vz & 0xFF
    raw_px = px_88 >> 5                         # FLOOR, mirroring pmf_cand
    raw_py = py_88 >> 5                         # (round() was unfaithful at
    fxw = (px_88 << 3) & 0xFF                   # fractional poses)
    fyw = (py_88 << 3) & 0xFF
    mem[_sym('zp_br_pxraw_l')] = raw_px & 0xFF
    mem[_sym('zp_br_pxraw_h')] = (raw_px >> 8) & 0xFF
    mem[_sym('zp_br_pyraw_l')] = raw_py & 0xFF
    mem[_sym('zp_br_pyraw_h')] = (raw_py >> 8) & 0xFF
    mem[_sym('PM_FXW')], mem[_sym('PM_FXW') + 2] = fxw, fyw
    _px2 = (raw_px << 1) | (1 if fxw else 0)
    _py2 = (raw_py << 1) | (1 if fyw else 0)
    mem[_sym('zp_br_px2_l')] = _px2 & 0xFF
    mem[_sym('zp_br_px2_h')] = (_px2 >> 8) & 0xFF
    mem[_sym('zp_br_py2_l')] = _py2 & 0xFF
    mem[_sym('zp_br_py2_h')] = (_py2 >> 8) & 0xFF
    mem[_sym('bca_ab')] = ab & 0xFF  # bca_ab: angle-space bbox view angle (u8)
    sc_t = fp.fp_sincos(ab)            # zp staging is mag8 again (2026-08-31)
    mem[_sym('zp_br_smag')] = sc_t[0]     # (2026-08-10)
    mem[_sym('zp_br_sneg')] = 1 if sc_t[1] else 0
    mem[_sym('zp_br_sone')] = 1 if sc_t[2] else 0
    mem[_sym('zp_br_cmag')] = sc_t[3]
    mem[_sym('zp_br_cneg')] = 1 if sc_t[4] else 0
    mem[_sym('zp_br_cone')] = 1 if sc_t[5] else 0


def s16(v):
    return v - 0x10000 if v >= 0x8000 else v


def install_tracing_run(sc, trace):
    """Replace sc._run with a stepping version that records clipper calls.

    (The with_context option is GONE, 2026-08-31.  It appended (ssid,
    seg_idx) read from literal $58/$59 and $5A/$5B; zp_seg_first had been
    retired since 2026-07-10 so seg_idx was garbage, $59 now holds
    zp_pm_p rather than an id high byte, and ids are u8 end to end
    anyway.  No caller ever passed it.  For per-seg attribution derive
    the offset from the FHCH cursor: (zp_fhch_p - rom_fhch_base) / 6.)
    """
    def traced_run(entry, max_cycles=20_000_000):
        mpu = sc.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xDD
        mpu.p = 0x30
        mem[0x01DF] = 0xFE
        mem[0x01DE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            if mpu.pc == 0xFF00:
                break
            pc = mpu.pc
            evt = None
            if pc == _E_MARK_SOLID:
                evt = ('mark_solid', mem[_sym('zp_i_l')], mem[_sym('zp_i_h')])
            elif pc == _E_HAS_GAP:
                # A-hi ABI: at entry the hi byte is still in A ($C3 is
                # written by the routine itself)
                evt = ('has_gap', mem[_sym('zp_i_l')], mpu.a)
            elif pc == _E_DCL_S16:
                xl = s16(mem[_sym('zp_line_xl_l')] | (mem[_sym('zp_line_xl_h')] << 8))
                yl = s16(mem[_sym('zp_line_yl_l')] | (mem[_sym('zp_line_yl_h')] << 8))
                xr = s16(mem[_sym('zp_line_xr_l')] | (mem[_sym('zp_line_xr_h')] << 8))
                yr = s16(mem[_sym('zp_line_yr_l')] | (mem[_sym('zp_line_yr_h')] << 8))
                evt = ('draw', xl, yl, xr, yr)
            if evt is not None:
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
