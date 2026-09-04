"""BspRender6502 — wrap span_clip + bsp_render.bin for use by doom_wireframe.

Loads the BSP-traversal/transform 6502 binary alongside span_clip + the
quarter-square tables + the recip table, and exposes a render_frame()
method that runs one frame and returns the framebuffer at $5800.

This is the binary built by bsp_render.asm (BSP walk, vertex transform,
seg processing, span_clip integration) — distinct from the older
Frontend6502 in fe6502.py which uses doom_fe.bin.
"""
import os
from span_clip_6502 import SpanClip6502
from symmap import sym as _sym


# ZP slots used by the engine — resolved from the linked symbol map.
ZP_PX           = _sym('zp_br_px')
ZP_PXH          = _sym('zp_br_px_h')
ZP_PY           = _sym('zp_br_py')
ZP_PYH          = _sym('zp_br_py_h')
ZP_VZ           = _sym('zp_br_vz')
ZP_SMAG         = _sym('zp_br_smag')
ZP_SNEG         = _sym('zp_br_sneg')
ZP_SONE         = _sym('zp_br_sone')
ZP_CMAG         = _sym('zp_br_cmag')
ZP_CNEG         = _sym('zp_br_cneg')
ZP_CONE         = _sym('zp_br_cone')
# Table base pointer slots (absolute RAM — the ZP scavenge moved most of
# them out of ZP; the angle module owns the freed slots).
ZP_PXRAW_LO     = _sym('zp_br_pxraw_l')
ZP_PXRAW_HI     = _sym('zp_br_pxraw_h')
ZP_PYRAW_LO     = _sym('zp_br_pyraw_l')
ZP_PYRAW_HI     = _sym('zp_br_pyraw_h')

ENTRY_BR_VIEW_SETUP   = _sym('view_setup')
ENTRY_BR_RENDER_FRAME = _sym('render_frame')

# Table load addresses: harness-owned placement decisions (the engine reads
# these tables only through the pointer slots above), NOT engine symbols.
ROM_MAIN_BASE   = 0x8600
                           # mover slots (1248 total) overflowed the old slot below
                           # ANG at $E940; $FB00-$FFF9 is unused in the flat harness.
                           # $E484-$E93F now hosts the flat ANIM tables + workers.
ROM_DETAIL_BASE = 0xB900
# flat bases (KEEP IN SYNC with src/layout.inc flat branch; 2026-07-21 map):
# THE PARASITE MAP (2026-09-02): flat homes = the banked bank images laid
# flat (bank A at $5800, bank B at $9800) — every base comes from the flat
# symbol map, which itself derives from the BANKx_ORG formulas in gen_abi
# and layout.inc.  No hand-kept flat addresses survive here.
ROM_SEG_HDR_BASE = _sym('ROM_SEG_HDR_C', banked=0)
ROM_VERTS_BASE   = _sym('ROM_VERTS_C', banked=0)
NODE_SOA_BASE    = _sym('NODE_SOA_C', banked=0)
ROM_BBOX_BASE    = _sym('ROM_BBOX_C', banked=0)
                           # build/split the bbox pointer byte-at-a-time


def _mem_banked(mem):
    """Is this a banked rig's memory?  BankedMemory models the $8000-$BFFF
    window; a plain list is the flat image.  Symbol lookups below MUST
    follow it -- resolving flat addresses against a banked rig poked the
    vrcache-valid clear into the wrong place (the walk then saw stale
    'done' state and visited ZERO subsectors) and left OBJ_ANYB non-zero
    so objects drew into an objects-off differential.  2026-08-30."""
    return type(mem).__name__ == 'BankedMemory'


ADESC_NODES = 194                          # MAX_NODES (walk.s gate bound)


def adesc_reset_mem(sc):
    """Clear the walk's DYNAMIC always-descend bits (NODE_DSGN b3/b2).

    The engine keeps those bits across frames and has no wipe of its own:
    after a teleport the stale bits cost one frame of over-descent and the
    judge clears them.  A bench that steps between unrelated poses in one
    engine is not a motion the predictor is meant to survive, so the bench
    clears them and a cold frame descends exactly as the reference does.
    """
    from symmap import sym as _sym
    mem = sc.mpu.memory
    banked = hasattr(mem, 'select')        # banked_bsp swaps in BankedMemory
    base = _sym('NODE_DSGN', banked=1) if banked else _sym('NODE_DSGN')
    if banked:
        saved = mem[0xFE30]
        mem.select(7)                      # abi.BANK_WALK: the node SoA
    for i in range(ADESC_NODES):
        mem[base + i] &= 0xF3
    if banked:
        mem.select(saved)


def poke_init_frame_state(mem):
    """Mirror render_frame's inline per-frame init for partial-flow
    harnesses (the standalone jt_br_init_frame entry retired 2026-07-15):
    records-pointer ground state + the 60-byte vrcache valid clear."""
    # VRCACHE_VALID + VDONE ride separate VXCACHE plane tails since
    # 2026-08-13 (57 B each) — wipe both by symbol
    _bk = 1 if _mem_banked(mem) else 0
    for name in ('VRCACHE_VALID_BASE', 'VDONE'):
        base = _sym(name, banked=_bk)
        for i in range(57):
            mem[base + i] = 0


def disable_objects(mem):
    """Zero the OBJ_ANYB per-subsector bitmap: no subsector tests positive,
    so the engine neither stamps billboards nor tightens behind them.
    For FB-compare harnesses whose python reference does not model objects
    (the documented OBJ_DRAW reference gap). Call AFTER any init that runs
    obj_anyb_fill (anim_init refills the bitmap from OBJ_BITS)."""
    from symmap import sym as _sym2
    _anyb = _sym2('OBJ_ANYB', banked=1 if _mem_banked(mem) else 0)
    for i in range(28):
        mem[_anyb + i] = 0


class BspRender6502:
    """Persistent BSP-render 6502 instance for interactive use."""

    def __init__(self, packed_layout, packed_rom_main, packed_rom_detail,
                 packed_bbox_table, map_center_x=1200, map_center_y=-3250,
                 prescale=8):
        self.layout = packed_layout
        self.rom_main = packed_rom_main
        self.rom_detail = packed_rom_detail
        self.bbox_table = packed_bbox_table
        self.map_center_x = map_center_x
        self.map_center_y = map_center_y
        self.prescale = prescale
        self.last_cycles = 0

        self.sc = SpanClip6502()
        self._load_wad()

    def _load_wad(self):
        from wad_packed import SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH

        layout = self.layout
        rom_main = self.rom_main
        rom_detail = self.rom_detail
        bbox = self.bbox_table
        mem = self.sc.mpu.memory

        # THE PARASITE MAP LOADER (2026-09-02): the flat build IS the banked
        # bank images laid flat — this mirrors banked_bsp's la/lb/c-data
        # construction copy-for-copy, at the flat symbol homes (which are
        # BANKx_ORG formulas of the SAME in-window offsets).  The legacy
        # scatter map and the 14-object gather are gone.
        from symmap import sym as _sy
        F = lambda n: _sy(n, banked=0)
        off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
        off_dirs = layout['off_dirs']

        # ---- bank A image content ----
        hdr_bytes = off_dirs - off_hdr
        _d = F('ROM_SEG_HDR_C')
        for i in range(hdr_bytes):                       # seg headers
            mem[_d + i] = rom_main[off_hdr + i]
        for _nm, _off, _n in (('ROM_LV1X_LO_C', layout['off_lv1'], 512),
                              ('ROM_BPAL_BFH_C', layout['off_bpal'], 256)):
            _d = F(_nm)
            for i in range(_n):
                mem[_d + i] = rom_main[_off + i]
        _d = F('ROM_DIRS_C')                             # DIR planes
        for i in range(3 * layout['max_dirs']):
            mem[_d + i] = rom_main[off_dirs + i]
        _d = F('ROM_VERTS_C')                            # vertex planes
        for i in range(off_verts, off_hdr):
            mem[_d + (i - off_verts)] = rom_main[i]
        off_obj = layout['off_obj']                      # FULL object planes
        _d = F('ROM_OBJ_C')                              # (+BITS+RUN8: the
        for i in range(0x200):                           # $200 hole, banked-
            mem[_d + i] = rom_main[off_obj + i]          # identical copy)
        import wad_packed as _wp                         # RECIP_S (M8/M8H are
        _d = F('RECIP_S')                                # seeded by SpanClip)
        for i, v in enumerate(_wp.srecip_table()):
            mem[_d + i] = v
        for _nm, _off in (('ROM_BKTLO_C', layout['off_bktlo']),   # K planes
                          ('ROM_BKTHI_C', layout['off_bkthi']),
                          ('ROM_DBOUND_C', layout['off_dbound'])):
            _d = F(_nm)
            for i in range(128):
                mem[_d + i] = rom_main[_off + i]

        # ---- bank B image content ----
        _d = F('NODE_SOA_C')
        for i in range(off_verts):                       # node/ss SoA pages
            mem[_d + i] = rom_main[i]
        _rb = F('ROM_SEG_HDR_C') >> 8                    # SS_PG rebase: the
        for i in range(layout['n_ss']):                  # plane ships the
            _pgoff = layout['off_ss'] + i                # FINAL header hi byte
            mem[_d + _pgoff] = (rom_main[_pgoff] + _rb) & 0xFF
        _nss = layout['n_ss']
        for _nm, _off in (('ROM_SS_FH_C', layout['off_ss_fh']),
                          ('ROM_SS_CH_C', layout['off_ss_ch']),
                          ('ROM_SS_CNT_C', layout['off_ss_cnt'])):
            _d = F(_nm)
            for i in range(_nss):
                mem[_d + i] = rom_main[_off + i]
        for i, v in enumerate(bbox):                     # bbox corner planes
            mem[ROM_BBOX_BASE + i] = v
        import abi as _abi                               # CPM_KDXH validity:
        _d = _abi.CPM_KDXH_FLAT if hasattr(_abi, 'CPM_KDXH_FLAT') else \
            (_abi.CPM_BASE_FLAT + 0x80)                  # plane ships $80-filled
        for i in range(128):
            mem[_d + i] = 0x80

        # ---- bank C data (CBITS run + the bank A window hole) ----
        import doom_wireframe as dw
        _d = F('VDESC')
        for i, v in enumerate(dw.vspan_desc):
            mem[_d + i] = v
        _lo, _hi, _ct = F('VEXPL_LO'), F('VEXPL_HI'), F('VEXPL_CONT')
        for i, (lo, hi, cont) in enumerate(dw.vspan_expl):
            _l, _h, _c = dw.vexpl_bytes(i, lo, hi, cont)
            mem[_lo + i] = _l
            mem[_hi + i] = _h
            mem[_ct + i] = _c
        _art_off = layout['off_obj_art']                 # ALL THREE art
        _art_n = layout['art_len']                       # windows, verbatim
        _d = F('OBJ_ART')
        assert _d % 256 == 0, 'flat OBJ_ART windows must be page-aligned'
        for i in range(_art_n):
            mem[_d + i] = rom_main[_art_off + i]
        _anyb = F('OBJ_ANYB')                            # model runs may skip
        _bits = off_obj + 7 * layout['n_obj']            # anim_init: seed the
        for i in range(layout['obj_bits_len']):          # bitmap directly
            mem[_anyb + i] = rom_main[_bits + i]

        # Angle-space bbox module + tables (rebuilds first — a standalone run
        # after a source edit must not test a stale bin).
        from engine_load import load_angle_module
        load_angle_module(mem)
        # CANARY: load_angle_module RELOADS every flat region file — any
        # poked table a region overlaps gets silently replaced by code
        # bytes (the dbound stomp read as +0.35% MEAN before this tripped).
        for _nm, _off in (('ROM_BKTLO_C', layout['off_bktlo']),
                          ('ROM_BKTHI_C', layout['off_bkthi']),
                          ('ROM_DBOUND_C', layout['off_dbound'])):
            _d = F(_nm)
            for i in (0, 64, 127):
                assert mem[_d + i] == rom_main[_off + i], \
                    f'{_nm} stomped by a region reload (engine code grew over it?)'
        # re-plant the plot RTS stubs: the region reload above rewrote the
        # patch slots (see SpanClip6502's plant for the contract)
        for _n in ('plot_h', 'plot_v', 'RASTER_ENTRY'):
            mem[F(_n)] = 0x60

    def render_frame(self, player_x, player_y, angle_byte, floor_z=0):
        import fp
        sc = self.sc
        mem = sc.mpu.memory

        px_88 = int((player_x - self.map_center_x) * 256 / self.prescale)
        py_88 = int((player_y - self.map_center_y) * 256 / self.prescale)
        mem[ZP_PX]     = px_88 & 0xFF
        mem[ZP_PXH] = (px_88 >> 8) & 0xFF
        mem[ZP_PY]     = py_88 & 0xFF
        mem[ZP_PYH] = (py_88 >> 8) & 0xFF
        # s16 integer position: high bytes (whole-map support, not just
        # +/-127 prescaled units around MAP_CENTER)
        mem[_sym('zp_br_px_x')] = (px_88 >> 16) & 0xFF
        mem[_sym('zp_br_py_x')] = (py_88 >> 16) & 0xFF

        # Eye height (pre-scaled, s8). doom_wireframe normally does
        # vz = prescale_height(player_floor + 41); we get player_floor in.
        # Inline a minimal prescale_height.
        ASPECT_NUM = 6; ASPECT_DEN = 5
        vz = ((floor_z + 41) * ASPECT_NUM + (self.prescale * ASPECT_DEN) // 2) \
             // (self.prescale * ASPECT_DEN)
        mem[ZP_VZ] = vz & 0xFF

        # raws mirror pmf_cand EXACTLY (2026-08-26): position quantized
        # to 8.8 prescaled, raw = FLOOR (the old int() truncation and
        # trace_compare's round() were unfaithful at fractional poses),
        # plus the world-frac bytes and the tie-broken doubled pairs the
        # exact node point-on-side consumes.
        _px88 = int((player_x - self.map_center_x) * 256 / self.prescale)
        _py88 = int((player_y - self.map_center_y) * 256 / self.prescale)
        raw_px, raw_py = _px88 >> 5, _py88 >> 5
        _fx, _fy = (_px88 << 3) & 0xFF, (_py88 << 3) & 0xFF
        mem[ZP_PXRAW_LO]     = raw_px & 0xFF
        mem[ZP_PXRAW_HI] = (raw_px >> 8) & 0xFF
        mem[ZP_PYRAW_LO]     = raw_py & 0xFF
        mem[ZP_PYRAW_HI] = (raw_py >> 8) & 0xFF
        from symmap import sym as _sy
        mem[_sy('PM_FXW')], mem[_sy('PM_FXW') + 2] = _fx, _fy
        _px2 = (raw_px << 1) | (1 if _fx else 0)
        _py2 = (raw_py << 1) | (1 if _fy else 0)
        mem[_sy('zp_br_px2_l')] = _px2 & 0xFF
        mem[_sy('zp_br_px2_h')] = (_px2 >> 8) & 0xFF
        mem[_sy('zp_br_py2_l')] = _py2 & 0xFF
        mem[_sy('zp_br_py2_h')] = (_py2 >> 8) & 0xFF

        s_mag, s_neg, s_one, c_mag, c_neg, c_one = fp.fp_sincos(angle_byte)
        mem[ZP_SMAG] = s_mag
        mem[ZP_SNEG] = 1 if s_neg else 0
        mem[ZP_SONE] = 1 if s_one else 0
        mem[ZP_CMAG] = c_mag
        mem[ZP_CNEG] = 1 if c_neg else 0
        mem[ZP_CONE] = 1 if c_one else 0
        mem[_sym('bca_ab')] = angle_byte & 0xFF  # angle-space bbox view angle

        # --- Dynamic always-descend: the harness owns the discontinuity.
        # The engine keeps its productivity bits (NODE_DSGN b3/b2) across
        # frames and has NO wipe — after a teleport the stale bits cost one
        # frame of over-descent and the judge clears them.  A bench that
        # steps between unrelated poses in one engine is not a motion the
        # predictor is meant to survive, so clear the bits on a jump here,
        # with the same windows the walk's kinematics can never reach:
        # 128 world units, or 24 angle bytes (a max-rate turn frame is 14).
        _prev = getattr(self, '_adesc_pose', None)
        if _prev is None or abs(player_x - _prev[0]) > 128 \
                or abs(player_y - _prev[1]) > 128 \
                or min((angle_byte - _prev[2]) % 256,
                       (_prev[2] - angle_byte) % 256) > 24:
            self.adesc_reset()
        self._adesc_pose = (player_x, player_y, angle_byte)

        sc._run(ENTRY_BR_VIEW_SETUP)
        sc.init()
        sc.clear_screen()
        cyc = sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)
        self.last_cycles = cyc
        return cyc

    def adesc_reset(self):
        adesc_reset_mem(self.sc)

    def blit_framebuffer_to(self, surface):
        """Render the 256x160 BBC mode-4 framebuffer into `surface`.

        The base is the harness's own SCREEN_START -- flat parks the FB at
        $EA00 (out of the shared <32K map), banked uses the real hardware
        screen at $5800.  Hardcoding $EA00 here made every banked frame
        read as blank (2026-08-29).
        """
        import pygame
        mem = self.sc.mpu.memory
        start = getattr(self.sc, 'SCREEN_START', 0xEA00)
        surface.fill((0, 0, 0))
        pix = pygame.PixelArray(surface)
        for cy in range(20):
            for col in range(32):
                for pr in range(8):
                    y = cy * 8 + pr
                    if y >= surface.get_height():
                        break
                    byte = mem[start + cy * 256 + col * 8 + pr]
                    for bit in range(8):
                        if byte & (0x80 >> bit):
                            pix[col * 8 + bit, y] = (255, 255, 255)
        del pix
