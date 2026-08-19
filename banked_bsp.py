#!/usr/bin/env python3
"""Verify the BANKED renderer (ROM_MAIN in sideways bank L0, clipper+rasteriser
in bank C) produces a bit-identical framebuffer to the flat BspRender6502, using
the banked_mem.py $FE30 model.

Strategy: build a flat BspRender6502 (loads all tables + code at flat addrs),
copy its 64K into a BankedMemory, then patch the banked deltas:
  - ROM_MAIN (verts/nodes/ss/seg_hdr) -> bank L0 @ $8000; ZP ptrs -> $8000+off
  - clipper (span_clip_bankc.bin) + rasteriser -> bank C @ $8000/$A800
  - sqr tables -> low RAM $1C00 (banked clipper/bsp umul8 read them there)
  - bsp_render code -> the *_bk.bin variants (PAGE inserts + $80xx clip entries)
Everything else (recip/bbox/angle subsystem/vcache) stays flat (above the
$8000-$BFFF window) — reachable in the model; real-HW relocation is a later step.
"""
import os, math
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_mem import BankedMemory
from bsp_render_6502 import BspRender6502

import abi
BANK_L0, BANK_C, BANK_L2 = abi.BANK_L0, abi.BANK_C, abi.BANK_L2
FHCH_LOW = 0x2400
SQR_LOW = abi.SQR_BASE
RASTER_OFF = 0xA800            # rasteriser window addr in bank C
RASTER_BUDGET = 0x0C00         # $A800-$B3FF (VPLOTC at $B400)


def _w16(mem, addr, val):
    mem[addr] = val & 0xFF
    mem[addr + 1] = (val >> 8) & 0xFF


def build_banked(flatr):
    """flatr: a constructed BspRender6502 (flat). Returns a BankedMemory set up
    for the banked layout, sharing the same loaded tables."""
    # Build the banked engine BEFORE reading its bins: without this, the
    # region loop below loads whatever a PREVIOUS process linked — every
    # consumer ran one build behind its sources (caught 2026-07-10 when a
    # vxcache negative-test alternated PASS/FAIL run-to-run).
    import asmbuild
    asmbuild.build('engine', banked=1)
    fmem = flatr.sc.mpu.memory
    bm = BankedMemory(list(fmem))
    layout = dw.packed_layout
    off_vwh = layout['off_vwh']
    rom_main = flatr.rom_main

    # --- bank L0: pure level data, verts evicted to L2.
    # [SoA $8000 | seg_hdr $9000 (stride 18, heights INLINED at +12..17;
    # the separate FHCH stream retired 2026-07-11) | TABL0 $BE90].
    # SSMASK -> MAIN $0A80 (rule exception, measured: hub reads it per
    # subsector under whatever bank; main = 0 paging. 237 B.)
    # --- bank A (BANK_SEG=4, two-bank re-cut 2026-08-13): seg headers+DIRs
    # @ $8000, vertex planes @ ROM_VERTS_C, recip @ RECIP_M8/M8H, VWHC BSS
    # (must ship ZERO — the key plane doubles as validity), TABL0 @ $BE90 ---
    la = bytearray(16384)
    off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
    n_segs = layout['n_segs']
    from symmap import sym as _vsym
    def bdst(name):
        return _vsym(name, banked=1) - 0x8000    # dst offsets BY SYMBOL —
                                                 # the .s equates are the
                                                 # single source (2026-07-21)
    # HEADERS ONLY at the bottom (2026-08-17). The side tables and the DIR
    # source used to ride along as one contiguous blob copy; they are placed by
    # symbol now, at the top of the bank, so everything between the header
    # block and the vertex planes is one free run for the main-RAM caches.
    hdr_bytes = layout['off_dirs'] - off_hdr
    la[:hdr_bytes] = bytes(rom_main[off_hdr:off_hdr + hdr_bytes])
    for _nm, _off, _n in (('ROM_LV1X_LO_C', layout['off_lv1'],   512),
                          ('ROM_BPAL_BFH_C', layout['off_bpal'], 256)):
        _d = bdst(_nm)
        la[_d:_d + _n] = bytes(rom_main[_off:_off + _n])
    # (SS_FH/SS_CH left bank A for bank B 2026-08-19 — seeded into lb
    #  below with the rest of the five adjacent SS planes)
    assert hdr_bytes <= bdst('ROM_VERTS_C'), "seg headers reach the vertex planes"
    # DIR planes (3 x LAY_MAX_DIRS) also land at ROM_DIRS_C in BOTH banks:
    # the shared CROSS_MAG_DECIDE reads them from node classify (bank WALK)
    # AND seg backface (bank SEG) — $B700 is free in both windows
    dirs_off = layout['off_dirs']       # (page-slotted headers: NOT n_segs*stride)
    dir_blob = bytes(rom_main[dirs_off:dirs_off + 3 * layout['max_dirs']])
    la[0x3700:0x3700 + len(dir_blob)] = dir_blob
    # driver tables: sincos and the use vectors moved to BANK C 2026-08-17 (see
    # the C image below) so the top of bank A could take the seg side tables;
    # STEPTAB went with them — DELETED, it had no reader in either language
    # after the single-step momentum rework replaced stepping with arithmetic.
    import colmap as _cm
    _ut = _cm.blobs(flat=False)[0xBE00]                 # USETAB (bank A —
    la[0x3E00:0x3E00 + len(_ut)] = _ut                  # seed BEFORE
                                                        # define_bank COPIES)
    vlen = off_hdr - off_verts
    la[bdst('ROM_VERTS_C'):bdst('ROM_VERTS_C') + vlen] = bytes(rom_main[off_verts:off_hdr])
    # EXACT recip lengths (256 + 128): a padded 1K copy here would drag
    # flat-image garbage over the VWHC key plane at $B300 -> stale serves
    la[bdst('RECIP_M8'):bdst('RECIP_M8') + 256] = bytes(fmem[_vsym('RECIP_M8'):_vsym('RECIP_M8') + 256])
    la[bdst('RECIP_M8H'):bdst('RECIP_M8H') + 128] = bytes(fmem[_vsym('RECIP_M8H'):_vsym('RECIP_M8H') + 128])
    # RECIP_S: the junior-page shift table, beside the mantissa tables it is
    # read with (2026-08-17 — it was assembled data in main until the census
    # showed every read already ran under bank 4)
    import wad_packed as _wp
    la[bdst('RECIP_S'):bdst('RECIP_S') + 256] = _wp.srecip_table()
    if dw.ANIM_SECTORS:
        import anim_sectors as _an0
        for addr, blob in _an0.gen_6502_tables(flat=False).items():
            if 0xBE90 <= addr < 0xC000:           # TABL0 @ $BE90 (bank A)
                la[addr - 0x8000:addr - 0x8000 + len(blob)] = blob
            # (SSMASK no longer routed here: its blob is keyed at its
            #  bank-B home $B400 and seeded in the L2 section below)
    bm.define_bank(BANK_L0, la)                   # BANK_L0 == BANK_SEG (4)

    # --- bank C = clipper ($8000) + rasteriser ($A900) ---
    c = bytearray(16384)
    clip = open('span_clip_bankc.bin', 'rb').read()
    c[:len(clip)] = clip
    rast = open('linedraw_or_reloc.bin', 'rb').read()      # ORG $A800
    assert len(rast) <= RASTER_BUDGET, f'rasteriser {len(rast)} bytes overruns VPLOTC at $B400'
    roff = RASTER_OFF - 0x8000
    c[roff:roff + len(rast)] = rast
    # VXC fat paths -> bank C @ $A300 (planes are BSS at $9700-$A2D3; the
    # clipper must stay below $9700 — guarded here). Must be seeded BEFORE
    # define_bank: it COPIES the image into a fresh buffer.
    assert len(clip) <= 0x1600, f'clipper {len(clip)} bytes reaches VEXPL_CONT at $9600'
    # Driver tables, evicted from bank A 2026-08-17 so its bottom 19 pages come
    # free: sincos $9900 (512 B), use vectors $9B00. Both are read ONLY by
    # walk_drv, which pages this bank for them (one ROMSEL write each, and the
    # sincos read happens once per frame).
    import colmap as _cm0
    from build_anim_ssd import sincos_table as _sct
    from symmap import sym as _csym
    for _nm, _blob in (('ROM_DRV_SINCOS_C', _sct()),
                       ('ROM_DRV_USEVEC_C', _cm0.use_vectors())):
        _d = _csym(_nm, banked=1) - 0x8000
        assert _d + len(_blob) <= 0x2400, f'{_nm} runs into the records arenas'
        c[_d:_d + len(_blob)] = _blob
    # (VXCODE moved to main $2B00 2026-07-10 — loads via the generic region loop)
    if os.path.exists('bsp_render_hud_bk.bin'):
        hud = open('bsp_render_hud_bk.bin', 'rb').read()
        c[0x2400:0x2400 + len(hud)] = hud   # debug HUD @ $A400
    # vertex-span descriptor tables (banked homes: bank C $B200/$B400 —
    # the verticals section runs under C, zero paging on the code path)
    for i, d in enumerate(dw.vspan_desc):
        c[0x2500 + i] = d                # VDESC @ $A500 (moved 2026-07-27)
    assert len(dw.vspan_expl) <= 0x80, \
        f'{len(dw.vspan_expl)} explicit vspan entries overrun the 128-slot split'
    for i, (lo, hi, cont) in enumerate(dw.vspan_expl):
        c[0x2700 + i] = lo & 0xFF        # VEXPL @ $A700/$A780 (+cont $9600;
        c[0x2780 + i] = hi & 0xFF        #  HI split widened 2026-08-14)
        c[0x1600 + i] = 1 if cont else 0   # VEXPL_CONT @ $9600 (2026-08-11)
    # unrolled vertical plot columns + tables ($B200-$BFFF, cfg VPLOTC)
    vp = open('engine_vplot_bankc.bin', 'rb').read()
    assert len(vp) <= 0x0C00, f'vplot {len(vp)} bytes overruns bank C'
    c[0x3400:0x3400 + len(vp)] = vp   # VPLOTC @ $B400 (2026-08-11)
    bm.define_bank(BANK_C, c)

    # (FHCH moved into bank L0 2026-07-10 — level data out of main, $2400-$33xx freed for code)

    # --- sqr tables: lo pages -> $1C00, HI pages -> $0200 (banked
    # SQRH_BASE, 2026-07-27 — $1E00 is the LCODE island now) ---
    for i in range(0x200):
        bm[SQR_LOW + i] = fmem[abi.SQR_BASE + i]
        bm[abi.SQRH_BASE + i] = fmem[abi.SQR_BASE + 0x200 + i]

    # --- bank B (BANK_WALK=7): node/ss SoA @ $8000 (SS_PHI rebased onto
    # the bank-A header base), L8/AE/VATOX behind the SoA, bbox @ ROM_BBOX_C,
    # CPM, rcache BSS, ANIM CFG @ $B300 + SSMASK staging @ $B400 ---
    lb = bytearray(16384)
    lb[:off_verts] = bytes(rom_main[:off_verts])         # node/ss SoA pages
    # (the SS_PHI rebase loop died 2026-08-19: SS_PC carries a raw page
    #  index and the engine adds >ROM_SEG_HDR_C itself)
    # SS_FH/SS_CH: planes 3+4 of the five adjacent SS planes ($8900 PC,
    # $8A00 SI, $8B00 FH, $8C00 CH, $8D00 VZ — VZ arrives via the colmap
    # blob router below)
    _nss = layout['n_ss']
    for _nm, _off in (('ROM_SS_FH_C', layout['off_ss_fh']),
                      ('ROM_SS_CH_C', layout['off_ss_ch'])):
        _d = bdst(_nm)
        lb[_d:_d + _nss] = bytes(rom_main[_off:_off + _nss])
    def cpy(dst_off, src, n):
        lb[dst_off:dst_off + n] = bytes(fmem[src:src + n])
    cpy(bdst('L8_TAB'), _vsym('L8_TAB'), 256)     # dst offsets BY SYMBOL
    cpy(bdst('AE_LO'), _vsym('AE_LO'), 256)
    cpy(bdst('AE_HI'), _vsym('AE_HI'), 256)
    cpy(bdst('VATOX'), _vsym('VATOX'), 1025)
    cpy(bdst('L2_BBOX'), _vsym('ROM_BBOX_C'), len(flatr.bbox_table))
    if dw.ANIM_SECTORS:
        import anim_sectors as _an
        for addr, blob in _an.gen_6502_tables(flat=False).items():
            if 0xB300 <= addr < 0xB400:          # CFG @ $B300 (bank B)
                lb[addr - 0x8000:addr - 0x8000 + len(blob)] = blob
            elif addr == 0xB400:                 # SSMASK: bank-B HOME (the
                # hub reads it in place under WALK since 2026-08-19; the
                # $1100 main copy and the copy-down are gone)
                assert len(blob) <= 256, f'SSMASK {len(blob)} B overflows its $B400 page'
                lb[0x3400:0x3400 + len(blob)] = blob
    lb[0x3700:0x3700 + len(dir_blob)] = dir_blob   # DIR planes, bank-B copy
    # (PMB stitching DELETED 2026-08-19: bank B carries no code any more —
    #  the pm_frame slices ride the CODE region tail and load with the
    #  rest of main below.)
    # collision map (colmap.py): banked homes SPLIT across banks since
    # the slide arc — USETAB lives in BANK A ($BE00, read under SEG by
    # pmove_use); everything else is bank B. The first cut routed ALL
    # blobs to lb and banked SPACE read TABL0-neighborhood garbage (the
    # 2026-08-14 'again' investigation's real find).
    for _ca, _cb in _cm.blobs(flat=False).items():
        if not isinstance(_ca, int) or _ca == 0xBE00:   # USETAB seeded in
            continue                                    # the LA section
        if _ca < 0x8000:                                # COLPORT etc: MAIN
            for _k, _v in enumerate(_cb):               # (model RAM; discs
                bm[_ca + _k] = _v                       # ship via COLDAT)
        else:
            lb[_ca - 0x8000:_ca - 0x8000 + len(_cb)] = _cb
    # corner-phi memo validity: KDXH plane ships $80-filled — the
    # probe's KDXH compare doubles as the never-written test (no EP plane).
    lb[abi.CPM_KDXH - 0x8000:abi.CPM_KDXH - 0x8000 + 128] = b'\x80' * 128
    bm.define_bank(BANK_L2, lb)                   # BANK_L2 == BANK_WALK (7)


    # --- banked bsp_render code (_bk variants) into low RAM ---
    # Region list comes FROM THE LD65 CONFIG (engine_load._regions) so a new
    # MEMORY area can never be silently missing here (a hardcoded list once
    # dropped the RCCODE rotation-cache region -> bca_frame jumped into
    # garbage and the disc hung at boot). Skip the clipper bank (loaded into
    # BANK_C above, not main RAM).
    from engine_load import _regions
    for addr, fn in _regions(banked=1):
        if fn.startswith('span_clip') or fn == 'bsp_render_hud_bk.bin':
            continue    # clipper + HUD -> BANK_C (rc/anim/vxc/sel are main now)
        if os.path.exists(fn):
            d = open(fn, 'rb').read()
            for i, b in enumerate(d):
                bm[addr + i] = b

    # (ROM-pointer block retired 2026-07-10: bases are layout.inc constants)
    bm[0xFF00] = 0x00
    bm.select(BANK_L0)
    return bm


class BankedBspRender(BspRender6502):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.bm = build_banked(self)
        self.sc.mpu.memory = self.bm     # swap in banked memory
        self.sc.SCREEN_START = 0x5800    # hw screens (the flat harness FB
        self.bm[0x70] = 0x58             # moved to $EA00, 2026-07-21 map)
        # span_init (pool reset) lives in the clipper -> bank C, by symbol.
        sc = self.sc
        from symmap import sym as _sym
        _span_init = _sym('span_init', banked=1)
        def banked_init():
            self.bm.select(BANK_C)
            sc._run(_span_init)
            sc.total_cycles = 0
        sc.init = banked_init

    def render_frame(self, px, py, ab, floor_z=0):
        # bca_ab relocated from $FA2F to $1B6F (BCA_WS+$2F) in the banked build.
        self.bm[abi.BCA_AB] = ab & 0xFF
        # 2026-07-10 one-region merge: banked jt is at $2C00 (flat stays at
        # $4800), so the inherited render_frame's flat entry constants no
        # longer apply. Swap in the banked-map addresses around the call.
        import bsp_render_6502 as _br
        from symmap import sym as _sym
        saved = (_br.ENTRY_BR_VIEW_SETUP, _br.ENTRY_BR_RENDER_FRAME)
        _br.ENTRY_BR_VIEW_SETUP   = _sym('view_setup', banked=1)
        _br.ENTRY_BR_RENDER_FRAME = _sym('render_frame', banked=1)
        try:
            return super().render_frame(px, py, ab, floor_z)
        finally:
            (_br.ENTRY_BR_VIEW_SETUP, _br.ENTRY_BR_RENDER_FRAME) = saved


def fb_mask(r):
    s = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    r.blit_framebuffer_to(s)
    import pygame.surfarray as sa
    return sa.array3d(s).sum(2) > 0


def main():
    import sys
    positions = [(1056, -3616, 128), (1056, -3328, 14), (1308, -3289, 252),
                 (994, -3291, 237), (845, -3084, 215), (1056, -3291, 34)]
    if len(sys.argv) == 4:
        positions = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
    flat = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                         dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bank = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                           dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    import numpy as np
    allok = True
    for (px, py, ab) in positions:
        fz = dw.player_floor(px, py)
        fc = flat.render_frame(px, py, ab, fz); fdone = flat.sc.mpu.pc == 0xFF00
        bc = bank.render_frame(px, py, ab, fz); bdone = bank.sc.mpu.pc == 0xFF00
        fm, bm_ = fb_mask(flat), fb_mask(bank)
        same = bool((fm == bm_).all())
        diff = int((fm != bm_).sum())
        print(f"({px},{py},{ab}): flat={'ok' if fdone else 'CRASH'}({fc:,}) "
              f"bank={'ok' if bdone else 'CRASH'}({bc:,}) "
              f"{'IDENTICAL' if same else f'DIFFER {diff}px'}")
        allok = allok and same and bdone
    print("\nBANKED RENDERER:", "PASS — bit-identical to flat" if allok else "FAIL")


if __name__ == '__main__':
    main()
