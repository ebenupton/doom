"""Packed WAD data in flat byte arrays for 8-bit processor simulation.

Four arrays:
  rom_main    - vertices, BSP nodes, subsectors, seg headers, VWH heights,
                linedef back-face data, sin/cos, reciprocals (ROM bank 1)
  rom_detail  - seg detail: VWH indices for front/back (ROM bank 2)
  ram         - vertex cache, VWH cache, packed valid bitmaps (RAM)

Seg data is split: the header (SEG_HDR_SIZE, accessed for every traversed
seg) is in rom_main; the detail (SEG_DTL_SIZE, accessed only for
front-facing segs) is in rom_detail.  This keeps each ROM region under 16KB.

All multi-byte values are little-endian (6502 native).
Most struct sizes are powers of two for fast index->offset shifts. The seg
header is NOT: it is 14 bytes, walked by a cursor (never indexed), so its
slot->offset mapping goes through seg_hdr_off().
"""

import struct
import math

# ── Struct sizes (all powers of 2) ──────────────────────────────────────

VERTEX_SIZE  = 4     # s16 x, s16 y (SoA planes in rom_main; python-side stride)
NODE_SIZE    = 16    # (legacy AoS reader stride — packed data is now SoA)
SSECTOR_SIZE = 4     # (legacy)
# SoA pages at the head of rom_main (see build_packed): 11 node pages
# (8 field bytes + 2 child-id bytes + type) then 3 subsector pages.
# Ids are u8 EVERYWHERE (n_nodes, n_ss <= 256 asserted): no child hi
# bytes; "child is a subsector" lives in the parent's TYPE byte
# (NF_RLEAF/NF_LLEAF), not in the link.
NODE_SOA_PAGES = 9    # DY pages dropped 2026-07-15 (no 6502 reader)
SS_SOA_PAGES   = 2    # PC + SI since 2026-08-19 (was count/lo/hi: 3 pages)
NODE_SOA_SIZE  = (NODE_SOA_PAGES + SS_SOA_PAGES) * 256
# Node partition TYPE (bits 0-2): axis-aligned partitions bake the
# direction SIGN into a bf_ax-style strict-compare form (side0 iff the
# compare holds strictly; ties -> side1, matching D=0 -> side 1):
#   0: px > nx   1: px < nx   2: py > ny   3: py < ny   4: general
NT_GEN = 3   # MUST be 3: the engine's node_setup seeds the general form's
             # first SBC from the dispatch LSR's carry (LSR 3 -> C=1). The
             # 2026-08-14 lockstep fuzz caught this baked as 2 — every
             # general-node classify ran dx = px-nx-1 (engine-wide
             # off-by-one at diagonal partitions)
NF_RLEAF, NF_LLEAF = 0x80, 0x40   # child-is-subsector flags, baked into the TYPE byte
SEG_HDR_SIZE = 9     # SQUEEZED 16 -> 14 -> 12 -> 10 -> 9 (2026-08-17).
                     # 16->14: +14/+15 were the APV2 height pair, shipped
                     #   ZERO since the vertex-span descriptors retired the
                     #   APV overlay (2026-07-24), read by nobody.
                     # 14->12: fh/ch are SUBSECTOR-constant and left for the
                     #   per-subsector pages (off_ss_fh/off_ss_ch).
                     # 12->10: a diagonal's lv1 (4 bytes) deduped to 99
                     #   distinct pairs, so the header carries a u8 id into
                     #   the LV1 planes instead. Axis segs keep their C16
                     #   inline — that compare is the hottest gate.
                     # LAYOUT:
                     # +0/1 v1 key, +2/3 v2 key
                     # +4 form/dir_id: 0 front iff px>C16, 1 px<C16,
                     #    2 py>C16, 3 py<C16; >=4 diagonal (id-4 indexes
                     #    the DIR tables appended after the headers)
                     # +5/6 axis: C16.  diagonal: +5 = LV1 record id
                     # +7 flags
                     # +8 BACK-PAIR palette id -> BPAL planes. The pair
                     #    deduped 649 segs into 96 entries (56 shared +
                     #    one PRIVATE entry per mover-touching seg, so a
                     #    patch can never bleed into a neighbour). A
                     #    one-sided seg's entry carries the fh/ch alias,
                     #    so the descriptor role codes still need no
                     #    runtime branch.
                     # DIR tables (at off_seg_hdr + seg_hdr_bytes(n_segs)):
                     # DIRXM |dx'| , DIRYM |dy'|, DIRS sign byte (b7=dy'
                     # neg, b6=dx' neg) — one entry per distinct primitive
                     # diagonal direction (SAMEDIR folded at pack).

# Slot -> byte offset. The stride is no longer a power of two, so slots no
# longer tile a page exactly: 18 headers fill 252 of a page's 256 bytes and
# the 4-byte tail is dead. Keeping each page's slots page-based preserves the
# invariant the engine's advance depends on — a subsector's run never crosses
# its page, so the header pointer's HI BYTE is subsector-constant and the
# +stride advance carries nothing. THE one source for this mapping: every
# producer (packer, anim tables, the Python reference) goes through it.
SEG_HDR_PER_PAGE = 256 // SEG_HDR_SIZE   # derived: never hand-set this


def seg_hdr_off(slot):
    """Byte offset of a header slot, relative to off_seg_hdr."""
    page, k = divmod(slot, SEG_HDR_PER_PAGE)
    return page * 256 + k * SEG_HDR_SIZE


def srecip_table():
    """RECIP_S: the junior-page shift table for the floating-mantissa
    reciprocal, S(idx) = bit_length(idx-1) with the low clamp baked
    (S[0..2] = 1, matching the M8 table). Stored NIBBLE-SWAPPED so the
    fast-path index is (vy_l & $F0) | vy_h — see seg_xform nc_ok.

    Map-independent and static forever; it was assembled data in the LDATA
    region at $1E00 until 2026-08-17, when it moved next to RECIP_M8/M8H in
    bank A (the audit found all 1,663 reads already ran under bank 4, five
    bytes after the M8 read in the same routine).
    """
    t = bytearray(256)
    for idx in range(256):
        t[((idx & 0x0F) << 4) | (idx >> 4)] = 1 if idx <= 2 else (idx - 1).bit_length()
    return bytes(t)


def seg_hdr_slot(off):
    """Inverse of seg_hdr_off: slot index for a byte offset (page-slotted)."""
    page, k = divmod(off, 256)
    assert k % SEG_HDR_SIZE == 0, f'offset ${off:04X} is not a header slot'
    return page * SEG_HDR_PER_PAGE + k // SEG_HDR_SIZE


def seg_hdr_bytes(n_slots):
    """Footprint of an n_slots header array (the DIR tables follow it)."""
    if n_slots == 0:
        return 0
    return seg_hdr_off(n_slots - 1) + SEG_HDR_SIZE
SEG_DTL_SIZE = 20    # ×20 = (idx<<4)+(idx<<2): fh,ch + 8 VWH u16 + back heights
VWH_SIZE     = 1     # identity: s8 height
# No separate linedef table — data inlined into seg headers

# ── Offsets within seg header ───────────────────────────────────────────

SH_V1 = 0; SH_V2 = 2             # vertex keys: lo=idx&255, hi=idx>>3 (see pack site)
SH_FORM = 4; SH_C = 5           # back-face C-form (see SEG_HDR_SIZE note)
# (lv1x/lv1y/ldx/ldy retired 2026-07-11: the C-form + DIR tables replace them)
SH_DIAG = 5                      # u8 LV1 record id (diagonal forms only)
SH_FLAGS = 7                     # u8 flags
SH_BPAL = 8                      # u8 back-pair palette id -> BPAL planes
BPAL_PER_PLANE = 128             # 2 planes in ONE page at +$00/+$80 (as the
                                 # LV1 records): <=128 entries means no
                                 # indexed read crosses a page
# (SH_L died with the 12->10 squeeze: the fossil seg-length byte had no
#  reader in either language — see the 2026-08-17 census.)
LV1_PER_PLANE = 128              # 4 planes packed 2-per-page at $00/$80:
                                 # with <=128 records no indexed read can
                                 # cross a page (the +1-cycle penalty)
# (SH_PAD retired: the 16->10 squeeze left no spare byte in the header —
#  a diagonal's +6 is the only unused slot, and only for that class)

# ── Offsets within seg detail (20 bytes) ─────────────────────────────────

SD_FH = 0; SD_CH = 1             # s8 prescaled front floor/ceil
SD_BFH = 2; SD_BCH = 3           # s8 prescaled back floor/ceil (0 if solid)
SD_VWH_FT1 = 4; SD_VWH_FB1 = 6   # u16 front VWH
SD_VWH_FT2 = 8; SD_VWH_FB2 = 10
SD_VWH_BT1 = 12; SD_VWH_BB1 = 14 # u16 back VWH ($FFFF if solid)
SD_VWH_BT2 = 16; SD_VWH_BB2 = 18

# Solid-seg overlay: for segs with SF_SOLID set, these byte slots are
# reinterpreted as aperture-edge heights (emitted when SF_APEDGE1/2 is
# set at a NOVT endpoint — see _seg_novt_aperture in doom_wireframe).
# Portals use these bytes as normal BFH/BCH and VWH_BT1.
SD_APV1_CH = 2                   # s8  (overlay SD_BFH)
SD_APV1_FH = 3                   # s8  (overlay SD_BCH)
SD_APV2_CH = 12                  # s8  (overlay SD_VWH_BT1 lo)
SD_APV2_FH = 13                  # s8  (overlay SD_VWH_BT1 hi)


# ── Seg flags ───────────────────────────────────────────────────────────

SF_SAMEDIR = 0x80  # set when the seg runs WITH its linedef (bit INVERTED
                   # from the old SF_DIR, 2026-07-09): sign ^ flags then
                   # yields bit7 = FRONT directly, so the back-face sign
                   # tail is branchless (EOR flags / AND #$80 / RTS with
                   # the Z-contract). TOP bit so one EOR/BIT applies it.
SF_SOLID  = 0x40   # one-sided wall — bit 6 so the HOT test (1,670/
                   # frame-corpus census 2026-08-11) is BIT->V, 5.5 cyc
SF_NEEDBT = 0x04   # back ceiling < front ceiling
SF_NEEDBB = 0x08   # back floor > front floor
SF_NOVT1  = 0x10   # RETIRED in the packed byte (ships 0 since the
SF_NOVT2  = 0x20   # descriptors) — bits REUSED as SF_STEPUP_T/B below
SF_STEPUP_T = 0x10  # back ceiling > front ceiling (recorded ft emits) — baked
SF_STEPUP_B = 0x20  # back floor < front floor (recorded fb emits) — baked
SF_APEDGE1 = 0x02  # emit aperture edge at v1 when NOVT1 suppresses the
                   # vertical (swapped with SOLID 2026-08-11: cold path)
SF_APEDGE2 = 0x01  # emit aperture edge at v2 when NOVT2 suppresses the vertical

# ── Vertex cache (RAM) ─────────────────────────────────────────────────

VCACHE_ENTRY = 8    # shift 3
VC_VX = 0; VC_VY = 2; VC_VYIDX = 4; VC_SX = 6  # all s16/u16

# ── VWH cache (RAM) ────────────────────────────────────────────────────

VWHCACHE_ENTRY = 2  # s16 screen_y (needs 16-bit for off-screen)

# ── Clip spans (RAM) ───────────────────────────────────────────────────
#
# Flat byte array representation of the trapezoid clip span list.
# Max 32 spans. Each span is 16 bytes (shift 4).
#
# Span entry (16 bytes):
#   +0  u8   xlo
#   +1  u8   xhi
#   +2  s8   top_slope    (0.8 format)
#   +3  s8   bot_slope    (0.8 format)
#   +4  s16  top_intercept
#   +6  s16  bot_intercept
#   +8  s16  inner_top
#   +10 s16  inner_bot
#   +12 s16  outer_top
#   +14 s16  outer_bot
#
# Header (2 bytes before span array):
#   +0  u8   span_count
#   +1  u8   reserved

MAX_SPANS = 32
SPAN_SIZE = 16      # shift 4
SPAN_HDR = 2        # count + pad
SPAN_TOTAL = SPAN_HDR + MAX_SPANS * SPAN_SIZE  # 514 bytes

# Span field offsets.
#
# Slopes are stored as s16 (not s8) because fp_linfn can legitimately
# produce slopes outside s8 range (seen up to ±358 in E1M1 traversal).
# Truncating to s8 would cause bit-exactness drift.
#
# The outer_top/outer_bot bbox fields are NOT stored in RAM anymore —
# they're only used by Python's draw_clipped path and can be derived
# cheaply from tfn/bfn/xlo/xhi via 4 fp_evals.  Dropping them frees
# 4 bytes per span, which pays for the wider slope fields.
SP_XLO        = 0    # u8
SP_XHI        = 1    # u8 (0 = 256)
SP_TSLOPE     = 2    # s16
SP_BSLOPE     = 4    # s16
SP_TINTERCEPT = 6    # s16
SP_BINTERCEPT = 8    # s16
SP_INNER_TOP  = 10   # s16
SP_INNER_BOT  = 12   # s16
# +14..15 reserved for future use


def build_packed(vertexes, fp_vertexes, nodes, fp_ssectors, fp_segs,
                 fp_segs_vwh, vwh_table, fp_sectors, linedefs, sidedefs,
                 prescale, map_center_x, map_center_y,
                 fp_objects=None,
                 seg_novt_flags=None,
                 seg_novt_aperture=None,
                 novt_rule4=None,
                 vert_covered_by_solid_ap=None,
                 anim_vert_set=None,
                 anim_sector_set=None):
    """Build the byte arrays from parsed WAD data.

    Returns (rom_main, rom_detail, rom_recip, layout).

    seg_novt_flags: optional list of pre-computed SF_NOVT1/SF_NOVT2 bits
    per seg.  When supplied, these are OR'd into the seg header flags;
    when None, only the BSP-internal-vertex rule is applied here.

    seg_novt_aperture, novt_rule4, vert_covered_by_solid_ap: optional —
    used to compute SF_APEDGE1/2 flags + APV heights so the 6502 can
    emit aperture edges at NOVT endpoints.
    """

    n_verts = len(vertexes)
    n_nodes = len(nodes)
    n_ss = len(fp_ssectors)
    n_segs = len(fp_segs)
    n_vwh = len(vwh_table)
    n_ld = len(linedefs)

    # ── ROM Detail: seg VWH indices ─────────────────────────────────────

    rom_detail = bytearray(n_segs * SEG_DTL_SIZE)
    for i, svwh in enumerate(fp_segs_vwh):
        fh, ch = svwh[3], svwh[4]
        vft1, vfb1 = svwh[5], svwh[6]
        vft2, vfb2 = svwh[7], svwh[8]
        vbt1, vbb1 = svwh[9], svwh[10]
        vbt2, vbb2 = svwh[11], svwh[12]
        back_idx = svwh[2]
        if back_idx is not None:
            bs = fp_sectors[back_idx]
            bfh, bch = bs[0], bs[1]
        else:
            bfh, bch = 0, 0
        if vbt1 == -1: vbt1 = vbb1 = vbt2 = vbb2 = 0xFFFF
        o = i * SEG_DTL_SIZE
        struct.pack_into('<bbbbHHHHHHHH', rom_detail, o,
                         fh, ch, bfh, bch,
                         vft1, vfb1, vft2, vfb2,
                         vbt1, vbb1, vbt2, vbb2)

    # ── ROM Main: node + subsector data first, as page-aligned parallel
    # arrays (structure-of-arrays). Both counts are <=256, so the 6502
    # indexes every field with a constant-base LDA abs,X — no pointer
    # arithmetic, and br_node_setup reads only the fields its (baked)
    # partition type needs. Layout (offset = page*256):
    #   pg 0-7  node nx_lo,nx_hi,ny_lo,ny_hi,dx_lo,dx_hi,dy_lo,dy_hi
    #   pg 8/9  node children right_id, left_id (u8 — no hi bytes)
    #   pg 10   node type: bits 0-1 = 0 general, 1 dx==0 (vertical),
    #           2 dy==0; bit 7 (NF_RLEAF) / bit 6 (NF_LLEAF) = that
    #           child is a subsector (leaf-ness is the parent's property)
    #   pg 10-11 subsector PC / SI (packed — see the ss loop below)
    # Everything else follows at NODE_SOA_SIZE.
    assert n_nodes <= 256 and n_ss <= 256
    assert n_verts <= 512, \
        "VCACHE planes are page-split on the senior bit (B & 0x20)"

    off_nodes = 0
    off_ss = NODE_SOA_PAGES * 256
    off_verts = NODE_SOA_SIZE
    off_seg_hdr = off_verts + 0x600   # 3 page-split vertex planes (OX/OY/PG
                                      # — the 4th slot RECLAIMED 2026-08-11)
    # DIR tables tail the headers: 3 parallel u8 arrays, one entry per
    # distinct primitive diagonal direction (filled during the seg loop).
    _dirs = {}          # (dx', dy') -> id  (0-based; header stores id+4)
    _lv1_ids = {}       # (lv1x, lv1y) -> LV1 record id (diagonals only)
    _bpal_ids = {}      # (bfh, bch) -> palette id; mover-touching segs get a
                        # PRIVATE entry keyed by seg index instead, so an anim
                        # patch of one seg's back pair cannot move a neighbour
    _movers = set(anim_sector_set or ())
    off_dirs = off_seg_hdr + seg_hdr_bytes(n_segs)
    MAX_DIRS = 128                    # 160 -> 128 2026-08-20: E1M1 uses 118
                                      # slots; the stride ships x2 banks, so
                                      # -64 B in EACH of A and B (form byte
                                      # did+4 <= 255 still clears easily)
    # Per-SUBSECTOR front heights (2026-08-17). fh/ch are subsector-constant
    # — every seg fronts its subsector's sector — so carrying them per seg
    # duplicated 2 bytes across all 649 headers to say 221 things. Two pages
    # here, indexed by the subsector id the prologue already holds in X.
    # PAGE-ALIGNED RELATIVE TO off_seg_hdr: both builds copy this blob to a
    # page-aligned base, so aligning here aligns the runtime address in both
    # (LDA SS_FH,X needs it).
    _after_dirs = off_dirs + 3 * MAX_DIRS
    off_ss_fh = off_seg_hdr + ((_after_dirs - off_seg_hdr + 255) & ~0xFF)
    off_ss_ch = off_ss_fh + 256
    # Diagonal LV1 records (2026-08-17): a diagonal's back-face reference
    # point is 4 bytes that dedupe hard (99 distinct pairs over 159 diagonal
    # segs on E1M1), so the header carries a u8 id and the coordinates live
    # here. Two pages, planes at +$00/+$80 so no indexed read crosses a page.
    off_lv1 = off_ss_ch + 256
    # Back-pair palette (2026-08-17): one page, two planes at +$00/+$80.
    off_bpal = off_lv1 + 512
    off_vwh = off_bpal + 256
    # VWH heights no longer ship in rom_main (2026-07-10): the 6502 render
    # projects from the FHCH stream; VWH indices are Python-side cache keys
    # only. off_vwh == rom_main_size is kept as a layout landmark.
    rom_main_size = off_vwh

    # ---- static object (billboard) table --------------------------------
    # Map THINGS that never move, drawn as flat outline rectangles when
    # their home subsector is drawn.  SoA planes so one X indexes every
    # field, plus a per-subsector "has objects" bitmap so an ordinary
    # subsector costs a single bit test.  Position uses the SAME
    # page-decomposed encoding as the vertex planes, so the 6502 stages
    # an object exactly as it stages a vertex and reuses rot_w_pages.
    fp_objects = fp_objects or []
    n_obj = len(fp_objects)
    off_obj = rom_main_size
    OBJ_N_PLANES = 7                       # OX OY PG SS RC ZT ZB
    off_obj_bits = off_obj + OBJ_N_PLANES * n_obj
    obj_bits_len = (n_ss + 7) // 8
    # ---- billboard ART template ------------------------------------------
    # A billboard is a 2D SCALED stamp: the engine derives a base point and
    # ONE scale factor, then plays this table.  Nothing here is projected.
    # Each line is (x1,y1,x2,y2) as PRE-DOUBLED indices into the engine's
    # scaled obj_X[5] / obj_Y[10] (doubled because those hold s16):
    #   x: 0=cx-a, 2=cx-a7, 4=cx, 6=cx+a7, 8=cx+a      (a = half width)
    #   y: 0..8 = lid (cy-b .. cy+b), 10..18 = the same dropped to the base
    # An octagon's vertices are only ever +-a and +-0.7071a, which is why
    # five x values and five y values cover all eight.  Eight lid edges,
    # the base's four VISIBLE edges, and the two silhouette verticals: the
    # six interior verticals are left out so the shape reads as the
    # smooth-sided barrel it stands in for.  The first FOUR lines are the
    # lid's top arc -- the ones the engine arms to record its tighten.
    #
    # LEFT-TO-RIGHT IS A HARD CONTRACT, not a nicety.  draw_clipped_line_s16
    # requires x1 <= x2: the in-clipper swap was DELETED when the seg layer
    # took over canonicalising (the 8F.1F "solid bars" fix), so a reversed
    # line now walks the span list without emitting or recording.  The lid's
    # top arc runs V[0]..V[4], whose x indices descend 4,3,2,1,0 -- i.e.
    # every one of the four ARMED lines was reversed, which is why
    # BOT_RECORDS stayed 0, the tighten never fired, and the reversed walks
    # smeared horizontal runs up to 121 px wide.  obj_X is monotone in its
    # index, so ordering by INDEX is ordering by x, and doing it here costs
    # the 6502 nothing.
    # TWO templates, laid end to end and SELF-TERMINATING, so the draw loop
    # needs no per-template length: a 4-byte entry whose first byte is
    # OBJ_ART_STOPREC stops recording, OBJ_ART_END ends the template.  The
    # RECORDED lines are therefore always the block's leading run -- the
    # lid's top arc for the prism, the top edge for the rectangle -- and
    # the engine plays a template by starting at its offset and reading
    # until END.  The per-object aspect byte's bit 7 picks which.
    OBJ_ART_STOPREC, OBJ_ART_END = 0xFE, 0xFF
    _CTL = lambda b: [b, 0, 0, 0]
    _V = [(4,2),(3,1),(2,0),(1,1),(0,2),(1,3),(2,4),(3,3)]

    def _ln(p, q):
        # LEFT-TO-RIGHT IS A HARD CONTRACT.  draw_clipped_line_s16 requires
        # x1 <= x2: the in-clipper swap was deleted when the seg layer took
        # over canonicalising (the 8F.1F "solid bars" fix), so a reversed
        # line walks the span list WITHOUT emitting or recording.  The lid
        # arc descends 4,3,2,1,0 in x, so all four ARMED lines were
        # reversed -- BOT_RECORDS stayed 0, the tighten never fired, and
        # the reversed walks smeared 121 px horizontal runs.  obj_X is
        # monotone in its index, so ordering by INDEX is ordering by x.
        if p[0] > q[0]:
            p, q = q, p
        return [p[0]*2, p[1]*2, q[0]*2, q[1]*2]

    # -- octagonal prism (BARRELS ONLY): lid top arc, then the rest -------
    obj_art = []
    for a_, b_ in [(0,1),(1,2),(2,3),(3,4)]:            # top arc: RECORDED
        obj_art += _ln(_V[a_], _V[b_])
    obj_art += _CTL(OBJ_ART_STOPREC)
    for a_, b_ in [(4,5),(5,6),(6,7),(7,0)]:            # lid, lower arc
        obj_art += _ln(_V[a_], _V[b_])
    for a_, b_ in [(4,5),(5,6),(6,7),(7,0)]:            # base, visible edges
        obj_art += _ln((_V[a_][0], _V[a_][1]+5), (_V[b_][0], _V[b_][1]+5))
    for v in (0, 4):                                    # silhouette verticals
        obj_art += _ln(_V[v], (_V[v][0], _V[v][1]+5))
    obj_art += _CTL(OBJ_ART_END)
    off_art_oct = 0

    # -- plain outline rectangle (everything that is not a barrel) --------
    # Y index 9 is Y[4] + dy = (yt + 2b) + dy = yt + H/8 + 7H/8 = syb, so
    # the rectangle spans exactly the projected top and bottom.
    off_art_rect = len(obj_art)
    obj_art += _ln((0, 0), (4, 0))                      # top edge: RECORDED
    obj_art += _CTL(OBJ_ART_STOPREC)
    obj_art += _ln((0, 9), (4, 9))
    obj_art += _ln((0, 0), (0, 9))
    obj_art += _ln((4, 0), (4, 9))
    obj_art += _CTL(OBJ_ART_END)

    # The engine turns the aspect byte's bit 7 straight into a start
    # offset, so these two must be exactly what layout.inc's OBJ_ART_OCT /
    # OBJ_ART_RECT say. Assert rather than plumb a constant through.
    assert off_art_oct == 0 and off_art_rect == 64, \
        f"art block offsets moved ({off_art_oct}, {off_art_rect}) -- " \
        f"update OBJ_ART_OCT/OBJ_ART_RECT in layout.inc to match"
    for _e in range(0, len(obj_art), 4):
        if obj_art[_e] >= OBJ_ART_STOPREC:
            continue
        assert obj_art[_e] <= obj_art[_e+2], \
            f"billboard art line {_e//4} is reversed -- draw_clipped_line_s16 " \
            f"requires x1 <= x2 and will silently drop its tighten record"
    off_obj_art = off_obj_bits + obj_bits_len
    n_obj_art = len(obj_art) // 4
    rom_main_size = off_obj_art + len(obj_art)

    rom_main = bytearray(rom_main_size)

    for _i, _o in enumerate(fp_objects):
        _px, _py = _o['x'], _o['y']
        assert -512 <= _px < 512 and -512 <= _py < 512, \
            f"object {_i} {(_px, _py)} outside the page-decomposed range"
        assert 0 <= _o['ss'] < 256, "subsector id must fit u8"
        # k <= 63 keeps H*k/64 inside a u8 for any H (max 251), so the
        # engine's half-width needs no clamp.
        assert 0 < (_o['asp'] & 0x7F) < 64, "object width ratio must be 1..63"
        for _pl, _v in enumerate((_px & 0xFF, _py & 0xFF,
                                  (((_px >> 8) + 2) & 3) | ((((_py >> 8) + 2) & 3) << 2),
                                  _o['ss'], _o['asp'],
                                  _o['zt'] & 0xFF, _o['zb'] & 0xFF)):
            rom_main[off_obj + _pl * n_obj + _i] = _v
        rom_main[off_obj_bits + (_o['ss'] >> 3)] |= 1 << (_o['ss'] & 7)
    rom_main[off_obj_art:off_obj_art + len(obj_art)] = bytes(obj_art)

    # Vertices — page-split SoA planes (OX/OY/PG, 512 bytes each;
    # n_verts <= 512 asserted above): junior page idx 0-255, senior 256+.
    # PAGE-DECOMPOSED (Eben's concept, 2026-08-11): w = page_base +
    # (ox, oy) with ox/oy UNSIGNED u8 (w & 255) and the 2+2 senior bits
    # packed as a nibble: pg = ((wx>>8)+2) | (((wy>>8)+2) << 2), page
    # bases in {-512,-256,0,+256}. rot() is linear, so the engine adds
    # rot(page_base) — 16 s16 pairs rebuilt per angle epoch — to the
    # four UNSIGNED u8 x mag5 products, whose combine signs are frame-
    # constant (trig signs only): the per-vertex sign ladders died.
    # V16 RANGE ASSERT: base = rot(w) must fit s16 in 1/64 units for
    # EVERY angle; |rot(w)| <= hypot(w) (trig magnitudes <= 1), so
    # hypot(w) <= 32767/64 = 511.98 is sound over all angles.
    # TRUE16 RANGE ASSERT (2026-08-10): the pipeline's s16 COUNT totals
    # (1/32 unit) must never overflow: |total| ~= |rot(w - p)| <=
    # hypot(w) + hypot(p). Vertices are bounded by the V16 assert below
    # (511.98); the player is clamped by walk_drv's RAWX/RAWY box, whose
    # center-relative corner hypot is < 2500 world = 312.5 units — 320
    # here is that bound plus slack. 511.98 + 320 + 2 (frac terms +
    # count rounding) = 833.98 units < 32767/32 = 1023.97. Update the
    # 320 if the walk clamp box ever grows.
    _PLAYER_MAX_HYPOT_UNITS = 320
    # (the SQR_MIRROR-in-the-VXC-tail constraint died 2026-08-18: the
    #  mirror protrudes into the stack page at $01E0 now, so the senior
    #  vertex ceiling is the plain plane size again)
    assert len(fp_vertexes) <= 512, "vertex planes are page-split on 512"
    for i, v in enumerate(fp_vertexes):
        assert v[0] * v[0] + v[1] * v[1] <= 511 * 511, \
            f"V16 base range: vertex {i} {v} exceeds s16 1/64-unit storage"
        assert ((v[0] * v[0] + v[1] * v[1]) ** 0.5
                + _PLAYER_MAX_HYPOT_UNITS + 2) * 32 <= 32767, \
            f"TRUE16 total range: vertex {i} {v} can overflow s16 counts"
        pg, off = (i >> 8) * 256, i & 0xFF
        pxi = ((v[0] >> 8) + 2) & 3
        pyi = ((v[1] >> 8) + 2) & 3
        assert 0 <= pxi < 4 and 0 <= pyi < 4
        rom_main[off_verts + 0x000 + pg + off] = v[0] & 0xFF
        rom_main[off_verts + 0x200 + pg + off] = v[1] & 0xFF
        rom_main[off_verts + 0x400 + pg + off] = pxi | (pyi << 2)

    # BSP nodes — point_on_side uses raw s16 values so the prescale rounding
    # doesn't lose a weak axis (nodes where, e.g., raw dx=0 dy=8 would
    # otherwise both truncate to 0).  nx/ny are stored relative to
    # map_center so they stay in s16 range. SoA pages (see layout above),
    # with the partition type baked so the 6502 skips the axis test AND
    # the unused field loads (73% of E1M1 nodes are axis-aligned).
    def _npg(pg, i, v):
        rom_main[off_nodes + pg * 256 + i] = v & 0xFF
    # Axis-extent guarantee (2026-07-16): every s16 point-vs-point
    # subtract in the side tests (node axis arms, backface axis arms,
    # and BOTH general paths' delta stagings) decodes the sign WITHOUT
    # V-overflow handling — sound iff any two engine-visible points are
    # < 32768 apart per axis. The player is wall-confined inside the
    # vertex hull, so the map bounding box bounds everything.
    _xs = [v[0] for v in vertexes] + [n[0] for n in nodes]
    _ys = [v[1] for v in vertexes] + [n[1] for n in nodes]
    assert max(_xs) - min(_xs) < 32768 and max(_ys) - min(_ys) < 32768, \
        "map axis extent >= 32768: side tests need V-overflow decode back"
    for i, n in enumerate(nodes):
        raw_nx = n[0] - map_center_x
        raw_ny = n[1] - map_center_y
        raw_dx = n[2]
        raw_dy = n[3]
        assert -32768 <= raw_nx <= 32767 and -32768 <= raw_ny <= 32767, \
            f"node {i} nx/ny out of s16 range"
        assert -32768 <= raw_dx <= 32767 and -32768 <= raw_dy <= 32767, \
            f"node {i} dx/dy out of s16 range"
        assert raw_dx or raw_dy, \
            f"node {i} degenerate (dx==dy==0) — type bake can't represent it"
        _npg(0, i, raw_nx); _npg(1, i, raw_nx >> 8)
        _npg(2, i, raw_ny); _npg(3, i, raw_ny >> 8)
        _npg(4, i, raw_dx)                   # general nodes: over-written by
        _npg(5, i, 0)                        # the DIR bake below (dir id /
        # sign byte); raw dy has no reader on either side -> its pages
        # are GONE (14 -> 12 SoA). DSGN (pg 5) starts CLEAN for every
        # node (was raw_dx>>8 for axis nodes — garbage bits 0/1 would
        # trip the 2026-07-17 SAME-AS-PARENT box flags OR'd in below).
        cr, cl = n[12], n[13]
        assert (cr & 0x7FFF) < 256 and (cl & 0x7FFF) < 256, \
            f"node {i} child id exceeds u8 — format is specialised to 256"
        _npg(6, i, cr)
        _npg(7, i, cl)
        # Sense-normalized axis nodes (doom_wireframe swaps children on
        # load): only the '>' forms exist. 0 = px>nx, 1 = py>ny,
        # 3 = general — the walk dispatch is LSR / BNE gen / BCS py,
        # and 3 (not 2) leaves C=1 in the LSR: the general arm's first
        # delta SBC needs no SEC.
        if raw_dx == 0:                      # vertical: D = ndy*(px-nx)
            assert raw_dy > 0, f"node {i}: '<' sense survived normalization"
            typ = 0                          # side0 iff px > nx
        elif raw_dy == 0:                    # horizontal: D = -ndx*(py-ny)
            assert raw_dx < 0, f"node {i}: '<' sense survived normalization"
            typ = 1                          # side0 iff py > ny
        else:
            typ = NT_GEN                     # 3 (C=1 seed; see above)
        if cr & 0x8000: typ |= NF_RLEAF
        if cl & 0x8000: typ |= NF_LLEAF
        _npg(8, i, typ)

    # Subsectors (SoA pages 10-11: TWO packed bytes since 2026-08-19 —
    # was count / hdr-offset lo / hdr-offset hi in three pages; the value
    # ranges never needed them: cnt <= 8, header pages <= 24, slots are
    # k*9 with k <= 27):
    #   PC  = ((page+1) << 3) | (cnt - 1)   $00 = empty subsector
    #         (page biased +1, Eben's sentinel trick 2026-08-19: the
    #         prologue's LDY sets Z on empty for free — no CMP — and the
    #         -1 folds into the ADC base constant; the low bits stay
    #         cnt-1 untouched, unlike a +1 which carries into the page
    #         field at cnt=8)
    #   PLO = the in-page byte offset (slot * stride), stored PLAIN — an
    #         (info<<5)|slot packing was tried and clawed back the same
    #         day: the decode cost 8 cycles per visited subsector on the
    #         render's hot prologue to save bits that pm reads twice per
    #         MOVE. The 7 mover subsectors live in colmap's MV_SS probe
    #         list instead, and the prologue loads PLO in 7 cycles.
    # The engine derives the header hi at run time: page + >ROM_SEG_HDR_C
    # (which KILLED both loaders' rebase passes).
    for i, ss in enumerate(fp_ssectors):
        off16 = seg_hdr_off(ss[1])
        # page-slotting invariant (doom_wireframe): a run never crosses
        # its 256-byte page — the engine's +SEG_HDR_SIZE advance carries no
        # page handling and the header page is subsector-constant
        assert (off16 & 0xFF) + ss[0] * SEG_HDR_SIZE <= 256, \
            f"subsector {i} seg run crosses a page (slotting broken)"
        page, rem = off16 >> 8, off16 & 0xFF
        slot, r9 = divmod(rem, SEG_HDR_SIZE)
        assert r9 == 0 and slot < 29 and page < 24 and ss[0] <= 8, \
            f"subsector {i}: PC/SI encoding out of range ({page},{slot},{ss[0]})"
        rom_main[off_ss + i] = 0 if ss[0] == 0 \
            else (((page + 1) << 3) | (ss[0] - 1))
        rom_main[off_ss + 256 + i] = rem            # PLO: slot * stride
        # Front heights, per SUBSECTOR (2026-08-17). ASSERTED constant over
        # the run: if a future map ever breaks that, this fails at pack time
        # instead of rendering one seg's heights for its neighbours.
        if ss[0]:
            fh_ch = {(fp_segs_vwh[j][3] & 0xFF, fp_segs_vwh[j][4] & 0xFF)
                     for j in range(ss[1], ss[1] + ss[0])}
            assert len(fh_ch) == 1, \
                f"subsector {i}: fh/ch not constant over its segs ({fh_ch})"
            fh_i, ch_i = fh_ch.pop()
            rom_main[off_ss_fh + i] = fh_i
            rom_main[off_ss_ch + i] = ch_i

    # Build the set of "linedef-endpoint" vertices. Any vertex not in this
    # set is a BSP-inserted split point; segs whose v1 or v2 is such a
    # vertex lie in the middle of a longer continuous wall, and the
    # verticals at those endpoints are geometrically fake (no real wall
    # edge, just a seam from BSP splitting).  This handles RULE 1 of the
    # NOVT scheme; RULE 2 (colinear solid neighbour) is computed by the
    # caller and passed in via `seg_novt_flags`.
    ld_endpoint_verts = set()
    for ld in linedefs:
        ld_endpoint_verts.add(ld[0])
        ld_endpoint_verts.add(ld[1])

    # Seg headers (with inlined linedef data)
    for i, svwh in enumerate(fp_segs_vwh):
        s = svwh[0]
        front_idx, back_idx = svwh[1], svwh[2]
        fh, ch = svwh[3], svwh[4]

        # Linedef data for back-face test.  ldx/ldy are pre-computed and
        # asserted s8 by doom_wireframe at load time — read them from the
        # svwh tuple directly rather than silently clamping here.
        ld = linedefs[s[3]]
        lv1 = fp_vertexes[ld[0]]
        ldx = svwh[13]
        ldy = svwh[14]
        assert -128 <= ldx <= 127 and -128 <= ldy <= 127, \
            f"seg {i}: ldx/ldy not s8 — caller should have asserted earlier"

        flags = 0
        if s[4] != 1: flags |= SF_SAMEDIR   # inverted: set = same direction
        if back_idx is None:
            flags |= SF_SOLID
        else:
            bs = fp_sectors[back_idx]
            if bs[1] <= fh or bs[0] >= ch:
                flags |= SF_SOLID
            else:
                if bs[1] < ch: flags |= SF_NEEDBT
                if bs[0] > fh: flags |= SF_NEEDBB
                if bs[1] > ch: flags |= SF_STEPUP_T   # baked step-up verdicts:
                if bs[0] < fh: flags |= SF_STEPUP_B   # the cascade's bch/bfh
                                                      # header reads die
        # (NOVT/APEDGE flag baking RETIRED 2026-07-24: verticals come
        # from the per-vertex span descriptors — SF_NOVT1/2 and
        # SF_APEDGE1/2 ship as ZERO; the constants remain for old
        # tooling that masks them out.)


        # (the fossil seg-length byte died with the 12->10 squeeze — it was
        #  written for an option-2b angle-space projection that never shipped
        #  and had no reader in either language)
        o = off_seg_hdr + seg_hdr_off(i)
        # --- back-face C-form, UNIFORM (2026-07-11, stride 16) ---
        # dot = dy'*px - dx'*py - C with (dx',dy') the primitive linedef
        # direction (SF_SAMEDIR folded into its sign) and C pack-time.
        # Axis: one s16 compare via form 0-3. Diagonal: form = dir_id+4,
        # magnitudes+signs from the DIR tables, C24 in the header.
        sgn = 1 if (flags & SF_SAMEDIR) else -1
        pdx, pdy = sgn * ldx, sgn * ldy
        g = math.gcd(abs(pdx), abs(pdy))
        if g:
            pdx //= g; pdy //= g
        if ldx == 0 and ldy == 0:
            form, c24 = 1, (-32768) & 0xFFFFFF   # px < -32768: always BACK
        elif pdx == 0:
            form = 0 if pdy > 0 else 1
            c24 = lv1[0] & 0xFFFFFF              # compare constant = lv1x
        elif pdy == 0:
            form = 3 if pdx > 0 else 2
            c24 = lv1[1] & 0xFFFFFF              # compare constant = lv1y
        else:
            # diagonal: DELTA form (operands stay small — the C-form's
            # raw-coordinate products measured SLOWER: 4 muls vs the
            # delta form's senior-byte-clear 1-mul fast paths). Header:
            # +5/6 lv1x s16, +7 lv1y lo, +9 lv1y hi (evicting the fossil
            # L byte); primitives via the DIR tables.
            did = _dirs.setdefault((pdx, pdy), len(_dirs))
            assert did + 4 <= 255 and len(_dirs) <= MAX_DIRS
            form = did + 4
            rom_main[off_dirs + did] = abs(pdx)
            rom_main[off_dirs + MAX_DIRS + did] = abs(pdy)
            rom_main[off_dirs + 2 * MAX_DIRS + did] = \
                ((0x80 if pdy < 0 else 0) | (0x40 if pdx < 0 else 0))
        # v1/v2 stored as (A = idx & 255, B = idx >> 3) — 2026-07-12: B is
        # the valid-bitmap byte index AND the VXC_VALID index, consumed raw
        # by the 6502; idx*8 (vcache) and idx*4 (verts) rebuild from A/B in
        # pure A-register shifts. Bijective: idx = B*8 + (A & 7).
        _vk = lambda v: (v & 0xFF) | ((v >> 3) << 8)
        struct.pack_into('<HH', rom_main, o, _vk(s[0]), _vk(s[1]))
        rom_main[o + 4] = form
        if form >= 4:
            # diagonal: the reference point goes in the deduped LV1 records
            key = (lv1[0] & 0xFFFF, lv1[1] & 0xFFFF)
            rid = _lv1_ids.setdefault(key, len(_lv1_ids))
            assert rid < LV1_PER_PLANE, \
                f'LV1 records ({rid + 1}) exceed the {LV1_PER_PLANE}-slot planes'
            rom_main[o + SH_DIAG] = rid
        else:
            rom_main[o + 5] = c24 & 0xFF
            rom_main[o + 6] = (c24 >> 8) & 0xFF
        rom_main[o + SH_FLAGS] = flags

        # Heights INLINED into the header. SOLID ALIAS (2026-07-24,
        # descriptor scheme): a solid's +12/+13 carry fh/ch so the
        # descriptor role codes bfh/bch evaluate with NO runtime branch
        # (the APV overlay died with APEDGE); +14/+15 ship zero.
        od = i * SEG_DTL_SIZE
        back_idx = svwh[2]
        def _bpal(bfh_v, bch_v, seg=i, front=svwh[1], back=svwh[2]):
            key = (('seg', seg) if (front in _movers or back in _movers)
                   else (bfh_v & 0xFF, bch_v & 0xFF))
            rid = _bpal_ids.setdefault(key, (len(_bpal_ids), bfh_v & 0xFF, bch_v & 0xFF))
            assert rid[0] < BPAL_PER_PLANE, \
                f'back-pair palette ({rid[0] + 1}) exceeds the {BPAL_PER_PLANE}-slot planes'
            return rid[0]
        if back_idx is None:
            # ONE-SIDED solid: fh/ch alias — the descriptor role codes
            # bfh/bch evaluate with no runtime branch (never consumed
            # live: c2/c3 are NEEDBB/NEEDBT-gated, forever clear here)
            rom_main[o + SH_BPAL] = _bpal(rom_detail[od + SD_FH],
                                          rom_detail[od + SD_CH])
        else:
            # TWO-SIDED — portal now or potentially at runtime (a closed
            # door is pack-time SOLID): TRUE back heights, NOT the alias.
            # The anim flag worker re-derives SOLID/NEEDBT/NEEDBB from
            # this quad; an alias here poisons it into SOLID forever
            # (the anim6502 phase-lockstep catch, 2026-07-25). While the
            # SOLID flag holds, c2/c3 gate off, so the alias is not
            # missed; detail SD_BFH/BCH stay 0 for pack-time solids.
            bs = fp_sectors[back_idx]
            rom_main[o + SH_BPAL] = _bpal(bs[0], bs[1])

    # Diagonal LV1 records: 4 planes packed two per page at +$00/+$80 so an
    # indexed read never crosses a page boundary.
    for _key, (rid, bfh_v, bch_v) in _bpal_ids.items():
        rom_main[off_bpal + 0x00 + rid] = bfh_v
        rom_main[off_bpal + 0x80 + rid] = bch_v
    for (lx, ly), rid in _lv1_ids.items():
        rom_main[off_lv1 + 0x000 + rid] = lx & 0xFF
        rom_main[off_lv1 + 0x080 + rid] = (lx >> 8) & 0xFF
        rom_main[off_lv1 + 0x100 + rid] = ly & 0xFF
        rom_main[off_lv1 + 0x180 + rid] = (ly >> 8) & 0xFF

    # ── ROM Recip: sin/cos + reciprocal tables ────────────────────────────

    from fp import _SIN_QUADRANT, _SIN_UNITY, _RECIP_M8

    # Layout: sin_mag[64] + sin_unity[64] + recip_m8[1024]. The recip is a
    # normalized floating mantissa per 10-bit 9.1 index (see fp.py); the
    # shift S = bit_length(idx-1) is computed by br_recip, not stored.
    SINCOS_SIZE = 64 + 64   # magnitude + unity flags, one quadrant
    RECIP_ENTRIES = 256     # page 0 only (far synthesis, 2026-08-13)
    RECIP_FAR = 128         # unswapped [128,255] half for recip_hi
    rom_recip_size = SINCOS_SIZE + RECIP_ENTRIES + RECIP_FAR

    rom_recip = bytearray(rom_recip_size)
    off_sin_mag = 0
    off_sin_unity = 64
    off_recip_m8 = SINCOS_SIZE

    for j in range(64):
        rom_recip[off_sin_mag + j] = _SIN_QUADRANT[j] & 0xFF
        rom_recip[off_sin_unity + j] = 1 if _SIN_UNITY[j] else 0

    # Page 0 (the fast-path domain, idx < 256) is stored NIBBLE-SWAPPED
    # (Eben 2026-08-10): entry ((idx&15)<<4)|(idx>>4) holds M8[idx], so
    # the 6502 forms the index as (vy_l & $F0) | vy_h — a mask+OR
    # instead of the 4xASL + 4xLSR nibble splice. Pages 1-3 (the
    # recip_hi ladder) stay linear. The python mirror indexes
    # LOGICALLY (fp_recip) and never sees the layout.
    for j in range(256):
        rom_recip[off_recip_m8 + (((j & 0x0F) << 4) | (j >> 4))] = _RECIP_M8[j] & 0xFF
    # far half-table, UNSWAPPED, idx2-128 indexed: recip_hi reduces
    # far indices into [128,255] and reads this directly (the linear
    # pages 1-3 died — 1024 -> 384 recip bytes)
    for j in range(128, 256):
        rom_recip[off_recip_m8 + 256 + (j - 128)] = _RECIP_M8[j] & 0xFF

    # ── RAM sizing ──────────────────────────────────────────────────────

    vcache_size = n_verts * VCACHE_ENTRY
    vcache_valid = (n_verts + 7) // 8
    vwh_cache_size = n_vwh * VWHCACHE_ENTRY
    vwh_valid = (n_vwh + 7) // 8
    # Node general partitions -> DIR delta form (2026-07-15): repurpose
    # NODE_DXLO/DXHI as (dir id, sign byte) — the 6502 general arm shares
    # the backface CROSS_MAG_DECIDE core and the same DIR tables (56/60
    # of E1M1's general partitions are seg-primitive directions already).
    # DYLO/DYHI keep the raw values (no 6502 reader; the Python mirror
    # uses the fp node data). Runs AFTER the seg loop so _dirs is final.
    for i, n in enumerate(nodes):
        raw_dx, raw_dy = n[2], n[3]
        if raw_dx == 0 or raw_dy == 0:
            continue
        g = math.gcd(abs(raw_dx), abs(raw_dy))
        pdx, pdy = raw_dx // g, raw_dy // g
        assert abs(pdx) <= 255 and abs(pdy) <= 255,             f"node {i} reduced dir {pdx},{pdy} exceeds u8"
        assert pdy > 0, f"node {i}: diagonal '<' sense survived normalization"
        # MAGNITUDE-KEYED lookup (2026-08-20): the node arm reads its signs
        # from NODE_DSGN, never from the DIR sign array — any entry with
        # matching |pdx|,|pdy| serves, so normalization grows NOTHING.
        did = _dirs.get((pdx, pdy))
        if did is None:
            did = _dirs.get((-pdx, -pdy))
        if did is None:
            did = _dirs.setdefault((pdx, pdy), len(_dirs))
            rom_main[off_dirs + did] = abs(pdx)
            rom_main[off_dirs + MAX_DIRS + did] = abs(pdy)
            rom_main[off_dirs + 2 * MAX_DIRS + did] = \
                ((0x80 if pdy < 0 else 0) | (0x40 if pdx < 0 else 0))
        assert len(_dirs) <= MAX_DIRS, "DIR table overflow (nodes+segs)"
        _npg(4, i, did)                      # NODE_DXLO := dir id
        _npg(5, i, (0x40 if pdx < 0 else 0)) # NODE_DXHI := sign byte —
                                             # b7 (ndy) pinned 0 by the
                                             # normalization, only b6 lives

    # Always-descend flags (2026-08-20, tools/adesc_sweep.py verdicts):
    # DSGN b2 = RIGHT box (side 0) / b3 = LEFT box (side 1) — the walk
    # skips bbox_visible outright for these check sites (near sites fold
    # the bit into the same-as-parent serve mask for free; far sites pay
    # a ~10-cycle gate). Node ids are post-transform, same as this bake.
    import json as _json, os as _os
    try:
        if _os.environ.get('DOOM_ADESC_OFF'):
            _adesc = set()                   # measurement runs: policy off
        else:
            _adesc = {tuple(p) for p in _json.load(
                open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                                   'adesc_policy.json')))['wins']}
    except Exception:
        _adesc = set()
    for (_ni, _sd) in _adesc:
        rom_main[off_nodes + 5 * 256 + _ni] |= (0x04 << _sd)

    # SAME-AS-PARENT box flags (2026-07-17): DSGN bit 0 (right box) /
    # bit 1 (left box) set on child node c when box(c,side) is byte-
    # identical to the parent box the walk descended through — the
    # walk's NEAR-side check then inherits the parent's WHOLE verdict
    # (angle AND has_gap: the descent proves has_gap returned 1 for the
    # same interval, and no leaf renders between, so the spans are
    # unchanged) and descends with no call at all; EXACT (same box, same
    # viewer, same spans). The root has no parent and keeps clear bits;
    # far-side flags are baked but only the near-side site tests them
    # (the near subtree's draws invalidate a far inheritance).
    for i, n in enumerate(nodes):
        for s_, sb in ((0, 4), (1, 8)):
            c = n[12 + s_]
            if c & 0x8000:
                continue                     # leaf child: no DSGN byte
            cn = nodes[c]
            fl = 0
            if tuple(cn[4:8]) == tuple(n[sb:sb+4]):
                fl |= 0x01                   # child's RIGHT box == parent box
            if tuple(cn[8:12]) == tuple(n[sb:sb+4]):
                fl |= 0x02                   # child's LEFT box == parent box
            if fl:
                pg5 = off_nodes + 5 * 256 + c
                rom_main[pg5] |= fl

    spans_offset = vcache_size + vcache_valid + vwh_cache_size + vwh_valid
    ram_size = spans_offset + SPAN_TOTAL

    layout = {
        'n_verts': n_verts, 'n_nodes': n_nodes, 'n_ss': n_ss,
        'n_segs': n_segs, 'n_vwh': n_vwh,
        'off_verts': off_verts, 'off_nodes': off_nodes,
        'off_ss': off_ss, 'off_seg_hdr': off_seg_hdr,
        'off_vwh': off_vwh,
        'off_dirs': off_dirs, 'n_dirs': len(_dirs), 'max_dirs': MAX_DIRS,
        'off_ss_fh': off_ss_fh, 'off_ss_ch': off_ss_ch,
        'off_lv1': off_lv1, 'n_lv1': len(_lv1_ids),
        'off_obj': off_obj, 'n_obj': n_obj,
        'off_obj_bits': off_obj_bits, 'obj_bits_len': obj_bits_len,
        'off_obj_art': off_obj_art, 'n_obj_art': n_obj_art,
        'off_bpal': off_bpal, 'n_bpal': len(_bpal_ids),
        'rom_main_size': rom_main_size,
        'rom_detail_size': len(rom_detail),
        'rom_recip_size': rom_recip_size,
        'off_sin_mag': off_sin_mag, 'off_sin_unity': off_sin_unity,
        'off_recip_m8': off_recip_m8,
        'ram_vcache': 0,
        'ram_vcache_valid': vcache_size,
        'ram_vwh_cache': vcache_size + vcache_valid,
        'ram_vwh_valid': vcache_size + vcache_valid + vwh_cache_size,
        'ram_spans': spans_offset,
        'ram_size': ram_size,
    }

    print(f"Packed WAD: {rom_main_size} ROM main, "
          f"{len(rom_detail)} ROM detail, {rom_recip_size} ROM recip, "
          f"{ram_size} RAM")
    print(f"  Vertices:    {n_verts} in 4 page-split planes = 2048")
    print(f"  Nodes:       {n_nodes} × {NODE_SIZE} = {n_nodes * NODE_SIZE}")
    print(f"  Subsectors:  {n_ss} × {SSECTOR_SIZE} = {n_ss * SSECTOR_SIZE}")
    print(f"  LV1 records: {layout['n_lv1']} diagonal reference points")
    print(f"  Objects:     {n_obj} static billboards "
          f"({OBJ_N_PLANES * n_obj} B) + {obj_bits_len} B subsector bitmap"
)
    print(f"  Back pairs:  {layout['n_bpal']} palette entries "
          f"({sum(1 for k in _bpal_ids if k[0] == 'seg')} private to movers)")
    print(f"  Seg headers: {n_segs} × {SEG_HDR_SIZE} = "
          f"{seg_hdr_bytes(n_segs)} B ({SEG_HDR_PER_PAGE}/page, page tails dead)")
    print(f"  VWH heights: {n_vwh} × {VWH_SIZE} = {n_vwh}")
    print(f"  Seg detail:  {n_segs} × {SEG_DTL_SIZE} = {len(rom_detail)}")
    print(f"  Recip/trig:  {rom_recip_size} (sin/cos {SINCOS_SIZE} + recip {RECIP_ENTRIES}+{RECIP_FAR})")
    print(f"  RAM:         {ram_size}")

    # Build prescaled bbox table as 16 page-split SoA planes (4KB):
    # field f (T_LO,T_HI,B_LO,B_HI,L_LO,L_HI,R_LO,R_HI) at f*$200, side
    # (0 = right child box, 1 = left) at +$100 — node ids are u8, so the
    # engine reads corners with plain abs,Y and NO pointer build; the
    # side is an arm dimension (BBP_* equates, layout.inc).
    bbox_table = bytearray(16 * 256)
    for i, n in enumerate(nodes):
        o = i * 16
        for side_base in (4, 8):  # right bbox, left bbox
            raw_top   = n[side_base]
            raw_bot   = n[side_base + 1]
            raw_left  = n[side_base + 2]
            raw_right = n[side_base + 3]
            # Corners round OUTWARD (+1 unit inflation) so the prescaled
            # box is a strict superset of the raw box even against the
            # integer player position (2026-07-08): plain floor pulled the
            # north/east edges INWARD by up to 7 world units, costing the
            # angle-space gate several columns of span at near boxes (the
            # gate-excess study; see fp_project_x's matching note).
            p_top   = -((-(raw_top   - map_center_y)) // prescale) + 1
            p_bot   = (raw_bot   - map_center_y) // prescale - 1
            p_left  = (raw_left  - map_center_x) // prescale - 1
            p_right = -((-(raw_right - map_center_x)) // prescale) + 1
            sb = ((side_base - 4) // 4) * 256   # +0 right, +$100 left
            for f, v in enumerate((p_top, p_bot, p_left, p_right)):
                bbox_table[f * 0x400 + sb + i] = v & 0xFF
                # HI bytes ship OFFSET-BINNED (^0x80, 2026-07-19): the
                # classify ladders compare them UNSIGNED hi-first against
                # the equally-biased bca_pxs/pys (view.s). Every consumer
                # that SUBTRACTS (the ZCF corner deltas) cancels the bias
                # exactly — values downstream are bit-identical.
                bbox_table[f * 0x400 + 0x200 + sb + i] = ((v >> 8) ^ 0x80) & 0xFF
    layout['bbox_table_size'] = len(bbox_table)

    return rom_main, rom_detail, rom_recip, bbox_table, layout


# ── Accessor helpers (simulate 6502 memory reads) ───────────────────────

def read_u8(arr, off):
    return arr[off]

def read_s8(arr, off):
    v = arr[off]
    return v - 256 if v >= 128 else v

def read_u16(arr, off):
    return arr[off] | (arr[off + 1] << 8)

def read_s16(arr, off):
    v = arr[off] | (arr[off + 1] << 8)
    return v - 65536 if v >= 32768 else v

def write_u16(arr, off, val):
    arr[off] = val & 0xFF
    arr[off + 1] = (val >> 8) & 0xFF

def write_s16(arr, off, val):
    if val < 0: val += 65536
    arr[off] = val & 0xFF
    arr[off + 1] = (val >> 8) & 0xFF


# ── Packed bitmap valid bits ────────────────────────────────────────────

# ── Span array helpers ──────────────────────────────────────────────────

def spans_init(ram, base):
    """Initialise span array with one full-screen span."""
    ram[base] = 1   # count = 1
    o = base + SPAN_HDR
    ram[o + SP_XLO] = 0
    ram[o + SP_XHI] = 255  # FP_RENDER_W - 1... will be overwritten by caller
    write_s16(ram, o + SP_TSLOPE, 0)
    write_s16(ram, o + SP_BSLOPE, 0)
    write_s16(ram, o + SP_TINTERCEPT, 0)
    write_s16(ram, o + SP_BINTERCEPT, 159)
    write_s16(ram, o + SP_INNER_TOP, 0)
    write_s16(ram, o + SP_INNER_BOT, 159)

def spans_init_full(ram, base, xhi, bot):
    """Initialise span array: one span [0, xhi) top=0, bot=bot."""
    ram[base] = 1
    o = base + SPAN_HDR
    ram[o + SP_XLO] = 0
    ram[o + SP_XHI] = xhi & 0xFF
    write_s16(ram, o + SP_TSLOPE, 0)
    write_s16(ram, o + SP_BSLOPE, 0)
    write_s16(ram, o + SP_TINTERCEPT, 0)
    write_s16(ram, o + SP_BINTERCEPT, bot)
    write_s16(ram, o + SP_INNER_TOP, 0)
    write_s16(ram, o + SP_INNER_BOT, bot)

def spans_count(ram, base):
    return ram[base]

def span_offset(base, i):
    """Byte offset of span i in the array."""
    return base + SPAN_HDR + i * SPAN_SIZE

def read_span_tuple(ram, base, i):
    """Read span i as a Python tuple (for compatibility with FPClipSpans code).
    xhi=0 in u8 means 256 (wrap convention for half-open [xlo, 256)).

    outer_top/outer_bot are NOT stored in RAM — they're recomputed from
    tfn/bfn/xlo/xhi via fp_eval (4 multiplies per read).  Only Python's
    draw_clipped path needs them; the 6502 visibility path doesn't.
    """
    from fp import fp_eval
    o = span_offset(base, i)
    xlo = ram[o + SP_XLO]
    xhi = ram[o + SP_XHI]
    if xhi == 0:
        xhi = 256
    tfn = (read_s16(ram, o + SP_TSLOPE), read_s16(ram, o + SP_TINTERCEPT))
    bfn = (read_s16(ram, o + SP_BSLOPE), read_s16(ram, o + SP_BINTERCEPT))
    inner_top = read_s16(ram, o + SP_INNER_TOP)
    inner_bot = read_s16(ram, o + SP_INNER_BOT)
    # Recompute outer_top / outer_bot on the fly
    top_l = fp_eval(tfn, xlo)
    top_r = fp_eval(tfn, xhi - 1)
    bot_l = fp_eval(bfn, xlo)
    bot_r = fp_eval(bfn, xhi - 1)
    outer_top = min(top_l, top_r)
    outer_bot = max(bot_l, bot_r)
    return (xlo, xhi, tfn, bfn, inner_top, inner_bot, outer_top, outer_bot)

def write_span(ram, base, i, xlo, xhi, tfn, bfn, inner_top, inner_bot, outer_top, outer_bot):
    """Write span i from components.  Bytes 14/15 store outer_top/outer_bot
    as u8 clamped to [0, 159] for the 6502 clipper's fast reject/accept."""
    o = span_offset(base, i)
    ram[o + SP_XLO] = xlo & 0xFF
    ram[o + SP_XHI] = xhi & 0xFF
    write_s16(ram, o + SP_TSLOPE, tfn[0])
    write_s16(ram, o + SP_BSLOPE, bfn[0])
    write_s16(ram, o + SP_TINTERCEPT, tfn[1])
    write_s16(ram, o + SP_BINTERCEPT, bfn[1])
    write_s16(ram, o + SP_INNER_TOP, inner_top)
    write_s16(ram, o + SP_INNER_BOT, inner_bot)
    ram[o + 14] = max(0, min(159, outer_top))
    ram[o + 15] = max(0, min(159, outer_bot))

def write_span_from_tuple(ram, base, i, s):
    """Write span i from an 8-tuple (as returned by read_span_tuple)."""
    write_span(ram, base, i, s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7])

def set_spans_count(ram, base, n):
    ram[base] = n & 0xFF

def read_all_spans(ram, base):
    """Read all spans as a list of tuples (for FPClipSpans compatibility)."""
    n = ram[base]
    return [read_span_tuple(ram, base, i) for i in range(n)]

def write_all_spans(ram, base, spans):
    """Write a list of span tuples back to the byte array."""
    n = min(len(spans), MAX_SPANS)
    ram[base] = n
    for i in range(n):
        write_span_from_tuple(ram, base, i, spans[i])


def clear_valid(ram, offset, n_bytes):
    for i in range(n_bytes):
        ram[offset + i] = 0

def is_valid(ram, offset, idx):
    return (ram[offset + (idx >> 3)] >> (idx & 7)) & 1

def set_valid(ram, offset, idx):
    ram[offset + (idx >> 3)] |= (1 << (idx & 7))
