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
Everything else (recip/bbox/angle subsystem/vxcache) stays flat (above the
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
from symmap import sym as _rsym
abi_RASTER_ENTRY_BANKED = _rsym('RASTER_ENTRY', banked=1)  # clip/arith.s banked arm; was hardcoded $A800 pre-compaction
RASTER_OFF = abi_RASTER_ENTRY_BANKED           # bank C, pulled to $A300 by the
RASTER_BUDGET = 0x0C00                          # 2026-09-02 C compaction


def _w16(mem, addr, val):
    mem[addr] = val & 0xFF
    mem[addr + 1] = (val >> 8) & 0xFF


def build_banked(flatr):
    """flatr: a constructed BspRender6502 (flat). Returns a BankedMemory set up
    for the banked layout, sharing the same loaded tables."""
    # Build the banked engine BEFORE reading its bins: without this, the
    # region loop below loads whatever a PREVIOUS process linked — every
    # consumer ran one build behind its sources (caught 2026-07-10 when a
    # vrcache negative-test alternated PASS/FAIL run-to-run).
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
    # @ $8000, vertex planes @ ROM_VERTS_C, recip @ RECIP_M8/M8H, VYCACHE BSS
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
    _ut = _cm.blobs(flat=False)[abi.USETAB_BASE]        # USETAB (bank A —
    la[abi.USETAB_BASE-0x8000:abi.USETAB_BASE-0x8000 + len(_ut)] = _ut  # seed BEFORE
                                                        # define_bank COPIES)
    vlen = off_hdr - off_verts
    la[bdst('ROM_VERTS_C'):bdst('ROM_VERTS_C') + vlen] = bytes(rom_main[off_verts:off_hdr])
    # static-object (billboard) table -- bank SEG, beside the vertex planes
    # it is read alongside (layout.inc ROM_OBJ_C)
    _oo = layout['off_obj']; _od = bdst('ROM_OBJ_C')
    la[_od:_od + 0x200] = bytes(rom_main[_oo:_oo + 0x200])   # the hole only
                                                             # (K planes below)
    # EXACT recip lengths (256 + 128): a padded 1K copy here would drag
    # flat-image garbage over the VYCACHE key plane at $B300 -> stale serves
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
            if 0xBA00 <= addr < 0xBB00:           # TABL0 @ $BA00 (bank A, moved 2026-09-02)
                la[addr - 0x8000:addr - 0x8000 + len(blob)] = blob
            # (SSMASK no longer routed here: its blob is keyed at its
            #  bank-B home $B400 and seeded in the L2 section below)
    # LV1 K planes -> bank A $B900/$B980 + DBOUND $B880 (exact-backface
    # 2026-08-26). MUST precede define_bank: it copies the image.
    la[0x3900:0x3980] = bytes(rom_main[layout['off_bktlo']:layout['off_bktlo'] + 128])
    la[0x3980:0x3A00] = bytes(rom_main[layout['off_bkthi']:layout['off_bkthi'] + 128])
    la[0x3880:0x3900] = bytes(rom_main[layout['off_dbound']:layout['off_dbound'] + 128])
    # USE VECTORS -> bank A $96FC (EVICTED from bank C 2026-09-02): read under
    # SEG right before ENG_PMOVE_USE pages SEG for USETAB, so bank A is zero-
    # cost.  Fills the 260 B gap above the seg headers.  Seeded here, before
    # define_bank COPIES la.
    import colmap as _cm_uv
    _uvb = _cm_uv.use_vectors()
    _uvd = bdst('ROM_DRV_USEVEC_C')
    assert _uvd + len(_uvb) <= 0x1800, 'USEVEC runs into VCACHE @ $9800'
    la[_uvd:_uvd + len(_uvb)] = _uvb
    bm.define_bank(BANK_L0, la)                   # BANK_L0 == BANK_SEG (4)
    # post-define content gate (2026-08-28): the dead-write class above is
    # silent — verify the planes actually live in the defined bank.
    for _go, _gn in ((0x3900, 'off_bktlo'), (0x3980, 'off_bkthi'),
                     (0x3880, 'off_dbound')):
        assert bytes(bm._banks[BANK_L0][_go:_go + 128]) == \
               bytes(rom_main[layout[_gn]:layout[_gn] + 128]), \
               f'bank A plane at ${0x8000+_go:04X} ({_gn}) did not survive define_bank'

    # --- bank C = clipper ($8000) + rasteriser ($A900) ---
    c = bytearray(16384)
    clip = open('span_clip_bankc.bin', 'rb').read()
    c[:len(clip)] = clip
    rast = open('engine_raster_bankc.bin', 'rb').read()   # IN THE ENGINE LINK
                                                          # since 2026-09-05
    assert len(rast) <= RASTER_BUDGET, f'rasteriser {len(rast)} bytes overruns VPLOTC at $AE00'
    roff = RASTER_OFF - 0x8000
    c[roff:roff + len(rast)] = rast
    # VRCACHE fat-path planes are BSS at $9700-$A2D3, directly below the raster code @ $A300 (the
    # clipper must stay below $9700 — guarded here). Must be seeded BEFORE
    # define_bank: it COPIES the image into a fresh buffer.
    assert len(clip) <= 0x1800, f'clipper {len(clip)} bytes reaches VEXPL_CONT at $9800'
    # Driver tables, evicted from bank A 2026-08-17 so its bottom 19 pages come
    # free: sincos $9900 (512 B), use vectors $9B00. Both are read ONLY by
    # walk_drv, which pages this bank for them (one ROMSEL write each, and the
    # sincos read happens once per frame).
    import colmap as _cm0
    from build_anim_ssd import sincos_table as _sct
    from symmap import sym as _csym
    # sincos: bank C $9900 (walk_drv pages C once/frame for it)
    _scd = _csym('ROM_DRV_SINCOS_C', banked=1) - 0x8000
    _scb = _sct()
    assert _scd + len(_scb) <= 0x2400, 'sincos runs into the records arenas'
    c[_scd:_scd + len(_scb)] = _scb
    # USE VECTORS seeded into bank A (la) BEFORE define_bank(BANK_L0) -- see
    # the bank-A section above.
    # Billboard art templates -> BANK C (2026-08-29), abutting USEVEC.  They
    # lived with the level data in bank A, which made obj_stamp page BANK_SEG
    # for four art bytes and BANK_C to draw, EVERY template line: 22.4 ROMSEL
    # stores/frame (tools/pagecensus.py).  In bank C the loop needs no paging
    # at all -- the object prologue's PAGE BANK_C covers it, and nothing in
    # src/clip pages.  This home is Python-seeded, so ld65 cannot police it:
    # the asserts below and the matching pair in layout.inc are the guard.
    _art_off = layout['off_obj_art']
    _art_n = layout['art_len']              # all three windows (652 B)
    _art_d = _csym('OBJ_ART', banked=1) - 0x8000
    assert _art_d == 0x1B00, f'OBJ_ART banked home moved to ${_art_d + 0x8000:04X}'
    assert _art_d >= 0x1B00, 'object art overlaps the driver sincos ($9900-$9AFF)'
    assert _art_d + _art_n <= 0x1E00, 'object art runs into VDESC @ $9E00 (bank-C compaction)'
    # window alignment is LOAD-BEARING: the walker's four abs,X reads only
    # stay carry-free because every window head is 256-aligned
    assert _art_d % 256 == 0, 'OBJ_ART windows must be page-aligned'
    c[_art_d:_art_d + _art_n] = rom_main[_art_off:_art_off + _art_n]

    # (VRCACHE_CODE moved to main $2B00 2026-07-10 — loads via the generic region loop)
    if os.path.exists('bsp_render_hud_bk.bin'):
        hud = open('bsp_render_hud_bk.bin', 'rb').read()
        c[_csym('HUD_ENTRY', banked=1)-0x8000 : _csym('HUD_ENTRY', banked=1)-0x8000 + len(hud)] = hud
    # vertex-span descriptor tables (banked homes: bank C $B200/$B400 —
    # the verticals section runs under C, zero paging on the code path)
    for i, d in enumerate(dw.vspan_desc):
        c[(_csym('VDESC', banked=1)-0x8000) + i] = d   # VDESC (moved by C compaction)
    assert len(dw.vspan_expl) <= 0x80, \
        f'{len(dw.vspan_expl)} explicit vspan entries overrun the 128-slot split'
    for i, (lo, hi, cont) in enumerate(dw.vspan_expl):
        _lo, _hi, _ct = dw.vexpl_bytes(i, lo, hi, cont)   # H2 half-baking
        c[(_csym('VEXPL_LO', banked=1)-0x8000) + i] = _lo   # VEXPL (C compaction)
        c[(_csym('VEXPL_HI', banked=1)-0x8000) + i] = _hi
        c[0x1800 + i] = _ct                # VEXPL_CONT @ $9800 (moved off
        #  the page head 2026-08-22 to give the clipper its ceiling back;
        #  128 slots end $96FF, flush against BOT_RECORDS $9700)
    # unrolled vertical plot columns + tables ($B200-$BFFF, cfg VPLOTC)
    vp = open('engine_vplot_bankc.bin', 'rb').read()
    assert len(vp) <= 0x0C00, f'vplot {len(vp)} bytes overruns bank C'
    c[0x2E00:0x2E00 + len(vp)] = vp   # VPLOTC @ $AE00 (top-of-A free 2026-09-02; must match cfg VPLOTC-$8000)
    bm.define_bank(BANK_C, c)

    # (FHCH moved into bank L0 2026-07-10 — level data out of main, $2400-$33xx freed for code)

    # --- sqr tables: lo pages -> $1C00, HI pages -> $0200 (banked
    # SQRH_BASE, 2026-07-27 — $1E00 is the LCODE island now) ---
    for i in range(0x600):
        bm[abi.SQR_MIR_LO + i] = fmem[abi.SQR_MIR_LO + i]   # $0200-$07FF quad+mirrors, identical maps
    # (LV1 K planes + DBOUND moved ABOVE define_bank(BANK_L0) 2026-08-28:
    #  define_bank COPIES, so writes here were DEAD. DBOUND was shipping
    #  as ZEROS in every banked build/disc — the banded backface's bound
    #  read 0 and mis-culled near-band diagonals: the 009C.9A tick bleed,
    #  a front SOLID culled with the room behind drawn through its
    #  columns. See project_rhs_bleed_2.)
    # OBJ_ANYB main-RAM bitmap copy (2026-08-25 grind): hardware fills it
    # via anim_init/obj_anyb_fill; model runs may skip init, so seed it
    _bits = layout['off_obj'] + 7 * layout['n_obj']   # OBJ_BITS = ROM_OBJ_C+7*N_OBJ
    from symmap import sym as _bsym
    _anyb = _bsym('OBJ_ANYB', banked=1)
    for i in range(layout['obj_bits_len']):
        bm[_anyb + i] = rom_main[_bits + i]

    # --- bank B (BANK_WALK=7): node/ss SoA @ $8000 (SS_PHI rebased onto
    # the bank-A header base), L8/AE/VATOX behind the SoA, bbox @ ROM_BBOX_C,
    # COLIDX, ANIM CFG @ $B300 + SSMASK staging @ $B400 (the corner memo
    # planes and the extent cache BSS that used to sit at $A600-$AFFF went
    # with those two caches, 2026-09-04) ---
    lb = bytearray(16384)
    lb[:off_verts] = bytes(rom_main[:off_verts])         # node/ss SoA pages
    # SS_PG rebase (RESURRECTED 2026-08-29, one line per loader): the
    # plane ships the FINAL header hi byte (page + >ROM_SEG_HDR_C), so
    # the prologue's CLC/ADC died. rom_main keeps the RAW page (the
    # python mirror reads it there). Empty subsectors rebase harmlessly
    # (CNT $FF is the empty test).
    for _i in range(layout['n_ss']):
        lb[layout['off_ss'] + _i] = (rom_main[layout['off_ss'] + _i] + 0x80) & 0xFF
    # SS_FH/SS_CH: planes 3+4 of the five adjacent SS planes ($8900 PG,
    # $8A00 SI, $8B00 FH, $8C00 CH, $8D00 VZ — VZ arrives via the colmap
    # blob router below). SS_CNT (the 2026-08-29 PG/CNT split) rides the
    # same loop to its own bank-B page at $B500 (the free pair below the DIR
    # planes; $A900 REJECTED: reads catching the window mid bank-C raster
    # excursion saw raster state there — vrcache warm mismatches).
    _nss = layout['n_ss']
    for _nm, _off in (('ROM_SS_FH_C', layout['off_ss_fh']),
                      ('ROM_SS_CH_C', layout['off_ss_ch']),
                      ('ROM_SS_CNT_C', layout['off_ss_cnt'])):
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
    # DIR planes: BANK A ONLY since 2026-08-30.  The bank-B duplicate served
    # cross_products_banded and node_band when entered from WALK context;
    # that whole chain pages SEG for itself now -- which it had to anyway,
    # because ROM_DBOUND_C is bank A and reading it under WALK had silently
    # DISABLED the exact-descent band refine.  $B700-$B87F is free in bank B.
    # (Measured: the backface side reads DIR 25.8x/frame, this side 0.)
    # (PMB stitching DELETED 2026-08-19: bank B carries no code any more —
    #  the pm_frame slices ride the CODE region tail and load with the
    #  rest of main below.)
    # collision map (colmap.py): banked homes SPLIT across banks since
    # the slide arc — USETAB lives in BANK A ($BE00, read under SEG by
    # pmove_use); everything else is bank B. The first cut routed ALL
    # blobs to lb and banked SPACE read TABL0-neighborhood garbage (the
    # 2026-08-14 'again' investigation's real find).
    for _ca, _cb in _cm.blobs(flat=False).items():
        if not isinstance(_ca, int) or _ca == abi.USETAB_BASE:   # USETAB seeded in
            continue                                    # the LA section
        if _ca < 0x8000:                                # COLPORT etc: MAIN
            for _k, _v in enumerate(_cb):               # (model RAM; discs
                bm[_ca + _k] = _v                       # ship via COLDAT)
        else:
            lb[_ca - 0x8000:_ca - 0x8000 + len(_cb)] = _cb
    # corner-phi memo validity: KDXH plane ships $80-filled — the
    bm.define_bank(BANK_L2, lb)                   # BANK_L2 == BANK_WALK (7)


    # --- banked bsp_render code (_bk variants) into low RAM ---
    # Region list comes FROM THE LD65 CONFIG (engine_load._regions) so a new
    # MEMORY area can never be silently missing here (a hardcoded list once
    # dropped the RCCODE rotation-cache region -> bca_frame jumped into
    # garbage and the disc hung at boot). Skip the clipper bank (loaded into
    # BANK_C above, not main RAM).
    from engine_load import _regions
    # BUILD FIRST (2026-09-02): these files are read RAW, and the four
    # build variants share their names -- without this, the rig loaded
    # whatever variant a previous build left (the C02-driver-on-NMOS-rig
    # wedge).  asmbuild's on-disk marker makes this a no-op when the
    # right variant is already there.
    import asmbuild as _ab
    _ab.build('engine', banked=1, c02=_ab.env_c02())
    for addr, fn in _regions(banked=1):
        if fn.startswith('span_clip') or fn == 'bsp_render_hud_bk.bin':
            continue    # clipper + HUD -> BANK_C (rc/anim/vrcache/sel are main now)
        if os.path.exists(fn):
            d = open(fn, 'rb').read()
            for i, b in enumerate(d):
                bm[addr + i] = b

    # (ROM-pointer block retired 2026-07-10: bases are layout.inc constants)
    bm[0xFF00] = 0x00
    bm.select(BANK_L0)
    return bm


def limit_objects_legacy(r):
    """Restrict a BANKED renderer to the legacy subset (kind <= 1).

    THE TUBE GATES NEED THIS (2026-08-31): their reference is the banked
    framebuffer, but the tube copro runs the FLAT engine, which gathers
    only the legacy subset (no honest flat hole holds 62 objects' planes).
    Retire each pickup by pointing its OBJ_SS entry at $FF (no subsector),
    rebuild the bitmap from the survivors, and mirror it into OBJ_ANYB.

    PATCH THROUGH THE WINDOW, with bank A selected: banked_mem writes the
    window back into the current bank's buffer on every select, so a
    direct buffer patch is un-done by the next select whenever bank A is
    the current bank -- which it is, right after construction.  (Both
    wrong forms were tried; this is the write-back-trap survivor.)
    """
    import doom_wireframe as _dw
    from symmap import sym as _sy
    L = _dw.packed_layout
    n = L['n_obj']
    mem = r.sc.mpu.memory
    _cur = mem._cur
    mem.select(BANK_L0)                          # window = bank A
    base = _sy('ROM_OBJ_C', banked=1)
    bits = base + 7 * n
    run8 = bits + L['obj_bits_len']
    for i in range(L['obj_bits_len']):
        mem[bits + i] = 0
        mem[run8 + i] = 0xFF
    for i in range(n):
        if mem[base + 4 * n + i] > 1:            # the RC/ASP plane
            mem[base + 3 * n + i] = 0xFF         # the SS plane
        else:
            ss = mem[base + 3 * n + i]
            mem[bits + (ss >> 3)] |= 1 << (ss & 7)
            if mem[run8 + (ss >> 3)] == 0xFF:
                mem[run8 + (ss >> 3)] = i        # ascending: first wins
    anyb = _sy('OBJ_ANYB', banked=1)
    for i in range(L['obj_bits_len']):
        mem[anyb + i] = mem[bits + i]
    if _cur is not None and _cur != BANK_L0:
        mem.select(_cur)                         # write-back keeps the patch


class BankedBspRender(BspRender6502):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.bm = build_banked(self)
        self.sc.mpu.memory = self.bm     # swap in banked memory
        self.sc.SCREEN_START = 0x5800    # hw screens: the BANKED rig is the
        self.sc.SCREEN_SIZE = 5120       # only one with a framebuffer since
        from symmap import sym as _sym0  # by SYMBOL, never a literal: the zp
        self.bm[_sym0('RASTER_ZP_SCRSTRT', banked=1)] = 0x58   # layout moves
                                         # (the parasite re-cut: SIZE=0 on the
                                         # flat side made clear_screen a
                                         # no-op — a stale-residue class)
        # span_init (pool reset) lives in the clipper -> bank C, by symbol.
        sc = self.sc
        from symmap import sym as _sym
        _span_init = _sym('span_init', banked=1)
        def banked_init():
            self.bm.select(BANK_C)
            sc._run(_span_init)
            sc.total_cycles = 0
        sc.init = banked_init

        # --- make this rig usable as a general BANKED span rig ------------
        # (2026-08-29: the shared flat rig, dw._span_clip_6502, is being
        # retired in favour of this one.)
        #
        # The plot entries are the only symbols the rig traps that MOVE
        # between builds -- everything else it names is zp or pool, and
        # $0000-$57FF is identical in both maps by rule.  Banked they live
        # in bank C (plot_h/plot_v in VPLOTC, RASTER_ENTRY at $A300).
        for _n, _s in (('ENTRY_INIT', 'span_init'),
                       ('ENTRY_MARK_SOLID', 'span_mark_solid'),
                       ('ENTRY_HAS_GAP', 'span_has_gap'),
                       ('ENTRY_INTERP_ST', 'interp_store'),
                       ('ENTRY_DRAW_CLIP', 'draw_clipped_line'),
                       ('ENTRY_DRAW_CLIP_S16', 'draw_clipped_line_s16'),
                       ('ENTRY_FUSED_BEGIN', 'fused_begin'),
                       ('ENTRY_FUSED_ABOVE', 'fused_above_raw'),
                       ('ENTRY_FUSED_BELOW', 'fused_below_raw'),
                       ('ENTRY_FUSED_MERGE', 'fused_merge_range')):
            setattr(sc, _n, _sym(_s, banked=1))
        sc.PLOT_PCS = frozenset((_sym('plot_h', banked=1),
                                 _sym('plot_v', banked=1),
                                 abi_RASTER_ENTRY_BANKED))
        # Every byte of CODE in the paged window is bank C -- banks A/B/L0/L2
        # are data only, by rule.  So an entry inside $8000-$BFFF is always
        # bank-C code, and running it with another bank live executes that
        # bank's DATA.  Page it here rather than making 20 call sites
        # remember (see the pq_pump_op spray, same day).
        _raw_run = sc._run
        def banked_run(entry, *a, **k):
            if 0x8000 <= entry < 0xC000:
                self.bm.select(BANK_C)
            return _raw_run(entry, *a, **k)
        sc._run = banked_run

    def render_frame(self, px, py, ab, floor_z=0):
        # bca_ab relocated from $FA2F to $1B6F (BCA_WS+$2F) in the banked build.
        self.bm[_rsym('bca_ab', banked=1)] = ab & 0xFF   # zp.inc symbol,
                                                  # not a baked abi address
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
