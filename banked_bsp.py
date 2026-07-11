#!/usr/bin/env python3
"""Verify the BANKED renderer (ROM_MAIN in sideways bank L0, clipper+rasteriser
in bank C) produces a bit-identical framebuffer to the flat BspRender6502, using
the banked_mem.py $FE30 model.

Strategy: build a flat BspRender6502 (loads all tables + code at flat addrs),
copy its 64K into a BankedMemory, then patch the banked deltas:
  - ROM_MAIN (verts/nodes/ss/seg_hdr) -> bank L0 @ $8000; ZP ptrs -> $8000+off
  - clipper (span_clip_bankc.bin) + rasteriser -> bank C @ $8000/$A900
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
RASTER_OFF = 0xA900            # rasteriser window addr in bank C


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
    l0 = bytearray(16384)
    off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
    n_segs = layout['n_segs']
    hdr_len = len(rom_main) - off_hdr        # stride-16 headers + DIR tables
    l0[:0x1000] = bytes(rom_main[:0x1000])               # node/ss SoA pages
    l0[0x1000:0x1000 + hdr_len] = bytes(rom_main[off_hdr:off_hdr + hdr_len])
    assert 0x1000 + hdr_len <= 0x3E90, "seg headers + DIRs reach TABL0 at $BE90"
    if dw.ANIM_SECTORS:
        import anim_sectors as _an0
        for addr, blob in _an0.gen_6502_tables(flat=False).items():
            if 0xBE90 <= addr < 0x4000 + 0x8000:  # L0-side table (TABL0 @ $BE90)
                l0[addr - 0x8000:addr - 0x8000 + len(blob)] = blob
            elif 0x0A80 <= addr < 0x0C00:         # SSMASK -> MAIN
                for i, b in enumerate(blob):
                    bm[addr + i] = b
    bm.define_bank(BANK_L0, l0)

    # --- bank C = clipper ($8000) + rasteriser ($A900) ---
    c = bytearray(16384)
    clip = open('span_clip_bankc.bin', 'rb').read()
    c[:len(clip)] = clip
    rast = open('linedraw_or_reloc.bin', 'rb').read()      # ORG $A900
    roff = RASTER_OFF - 0x8000
    c[roff:roff + len(rast)] = rast
    # VXC fat paths -> bank C @ $A300 (planes are BSS at $9700-$A2D3; the
    # clipper must stay below $9700 — guarded here). Must be seeded BEFORE
    # define_bank: it COPIES the image into a fresh buffer.
    assert len(clip) <= 0x1700, f'clipper {len(clip)} bytes reaches VXC planes at $9700'
    # (VXCODE moved to main $2B00 2026-07-10 — loads via the generic region loop)
    if os.path.exists('bsp_render_hud_bk.bin'):
        hud = open('bsp_render_hud_bk.bin', 'rb').read()
        c[0x2400:0x2400 + len(hud)] = hud   # debug HUD @ $A400
    bm.define_bank(BANK_C, c)

    # (FHCH moved into bank L0 2026-07-10 — level data out of main, $2400-$33xx freed for code)

    # --- sqr tables -> low $1C00 (copy from flat $A500) ---
    for i in range(0x400):
        bm[SQR_LOW + i] = fmem[abi.SQR_BASE_FLAT + i]

    # --- bank L2 = relocated $C000+ data (window offsets must match the asm) ---
    # TA_LO $8000, TA_HI $8400, VATOX $8800, bbox $8D00, recip $9C00,
    # VWHC cache $A600 (zeroed). ($A200 VWH heights stripped 2026-07-10.)
    l2 = bytearray(16384)
    def cpy(dst_off, src, n):
        l2[dst_off:dst_off + n] = bytes(fmem[src:src + n])
    cpy(0x0000, 0xDC00, 1024)            # TA_LO  -> $8000
    cpy(0x0400, 0xF200, 1025)            # TA_HI  -> $8400
    cpy(0x0900, 0xF601, 1025)            # VATOX  -> $8900
    cpy(0x0E00, 0xC600, len(flatr.bbox_table))   # bbox -> $8E00
    cpy(0x1D00, 0xE000, 1024)            # recip  -> $9D00 (M8[1024] mantissas)
    # (VWH heights table stripped 2026-07-10: no 6502 reader)
    # rotation-cache CODE -> $B500 in the L2 window (its data region $AD00-
    # $B4E8 is bank-L2 BSS; all consumers run with L2 paged; VWHC arrays
    # end at $ACFF).
    # verts -> L2 $A200 (evicted from L0 to make room for FHCH; the only
    # reader is vc_miss, which now pages L2 for the fetch)
    n_verts_b = layout['off_nodes'] and 0  # (offsets: verts span off_verts..off_seg_hdr)
    vlen = layout['off_seg_hdr'] - layout['off_verts']
    l2[0x2200:0x2200 + vlen] = bytes(rom_main[layout['off_verts']:layout['off_seg_hdr']])
    # Animated sectors (DOOM_ANIM builds): VWH worker -> L2 @ $BA00; tick
    # tables TABL2/CFG @ $B900/$B980; L0 gets the FHCH+flags worker @ $BE00
    # plus SSMASK/TABL0 @ $BB00/$BC00 (seeded before define_bank below via
    # the l0 image; L2 seeded here).
    # HARD requirement (was a silent if-exists: a missing stk bin shipped a
    # $FF-filled $0100 and the disc BRK'd through the first RNS vector).
    stk = open('bsp_render_stk_bk.bin', 'rb').read()
    assert len(stk) <= 0x100, f'STK image {len(stk)} overflows the $A100 staging page'
    l2[0x2100:0x2100 + len(stk)] = stk  # staged for the drivers' boot copy -> $0100
    if dw.ANIM_SECTORS:
        import anim_sectors as _an
        for addr, blob in _an.gen_6502_tables(flat=False).items():
            if 0xBA00 <= addr < 0xBB00:          # L2-side table (CFG @ $BA00)
                l2[addr - 0x8000:addr - 0x8000 + len(blob)] = blob
    bm.define_bank(BANK_L2, l2)


    # --- banked bsp_render code (_bk variants) into low RAM ---
    # Region list comes FROM THE LD65 CONFIG (engine_load._regions) so a new
    # MEMORY area can never be silently missing here (a hardcoded list once
    # dropped the RCCODE rotation-cache region -> jt_bca_frame jumped into
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
        # span_init (pool reset) lives in the clipper -> bank C @ $8000, not $2000.
        sc = self.sc
        def banked_init():
            self.bm.select(BANK_C)
            sc._run(0x8000)              # ENTRY_INIT (jump table entry 0) in bank C
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
        saved = (_br.ENTRY_BR_VIEW_SETUP, _br.ENTRY_BR_INIT_FRAME,
                 _br.ENTRY_BR_RENDER_FRAME)
        _br.ENTRY_BR_VIEW_SETUP   = _sym('jt_br_view_setup', banked=1)
        _br.ENTRY_BR_INIT_FRAME   = _sym('jt_br_init_frame', banked=1)
        _br.ENTRY_BR_RENDER_FRAME = _sym('jt_br_render_frame', banked=1)
        try:
            return super().render_frame(px, py, ab, floor_z)
        finally:
            (_br.ENTRY_BR_VIEW_SETUP, _br.ENTRY_BR_INIT_FRAME,
             _br.ENTRY_BR_RENDER_FRAME) = saved


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
