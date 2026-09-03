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

VRCACHE_ENTRY = 8    # shift 3
VC_VX = 0; VC_VY = 2; VC_VYIDX = 4; VC_SX = 6  # all s16/u16

# ── VWH cache (RAM) ────────────────────────────────────────────────────

VYCACHE_ENTRY = 2  # s16 screen_y (needs 16-bit for off-screen)

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
    _movers = set(anim_sector_set or ())
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
            if back_idx in _movers:
                # HALF-UNIT mover tier (2026-08-25): a mover's back pair
                # ships in half-prescaled units so the anim patcher can
                # move the lip in half steps (projection uses S+1; at
                # rest 2h with S+1 is BIT-IDENTICAL to h with S).
                bfh, bch = bfh * 2, bch * 2
                assert -128 <= bfh <= 127 and -128 <= bch <= 127
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
        "VRCACHE planes are page-split on the senior bit (B & 0x20)"

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
    # HALF-UNIT mover tier (2026-08-25): entries whose VALUES are mover
    # heights (back sector is a mover, or a mover's own solid alias)
    # allocate ids 64..127 and carry HALF-prescaled bytes — the ys stage
    # gates on id bit 6 (TYA/AND #$40, carry-preserving) and projects
    # them at S+1 against vz*2. Static-valued entries stay 0..63.
    _BPAL_MOVER_MIN = 64
    _bpal_next = [0, _BPAL_MOVER_MIN]   # [shared/static pool, mover pool]
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
    # Per-subsector seg count (2026-08-29, the PG/CNT split): cnt-1 in its
    # own plane so the prologue loads it flat instead of masking it out of
    # the packed byte, and the page field gets the whole byte (no shifts).
    # LAST in rom_main and NOT part of the header blob: the flat blob copy
    # ends at off_ss_cnt and this page goes to its OWN home (flat $C400,
    # banked $A900) — growing the blob itself slid BPAL onto the flat
    # rcache plane RC_PH_0 at $A400 (the first cut of this split).
    off_ss_cnt = off_bpal + 256
    off_vwh = off_ss_cnt + 256
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
    # THE HOLE HOLDS PLANES + BITMAP ONLY (2026-08-31, the pickup landing):
    # 62 objects x 7 planes + the bitmap = 459 of 512.  The art templates
    # moved to their own region at the rom_main TAIL -- they outgrew the
    # hole (three 256-byte windows, see below), and they never belonged in
    # it: both loaders copy them to a bank C home anyway.
    # ... plus OBJ_RUN8: the per-ss-OCTET first-object index that replaced
    # the engine's exhaustive scan (2026-08-31).
    assert OBJ_N_PLANES * n_obj + 2 * obj_bits_len <= 0x200, \
        f'obj planes+bitmap+run8 {OBJ_N_PLANES*n_obj + 2*obj_bits_len} > the 512 hole'
    import collections as _cl
    _sscount = _cl.Counter(_o['ss'] for _o in fp_objects)
    assert not _sscount or max(_sscount.values()) <= 6, \
        f'a subsector holds {max(_sscount.values())} objects; OBJ_MAXSLOT is 6'
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
    # OBJ_ART_ARM starts the FUSED authority run, OBJ_ART_END ends it.  The
    # RECORDED lines are therefore always the block's leading run -- the
    # lid's top arc for the prism, the top edge for the rectangle -- and
    # the engine plays a template by starting at its offset and reading
    # until END.  The per-object aspect byte's bit 7 picks which.
    OBJ_ART_ARM, OBJ_ART_END = 0xFE, 0xFF
    _CTL = lambda b: [b, 0, 0, 0]
    # -- THE 12-GON LID (OBJ_ART_OCT) IS RETIRED (2026-08-31) -------------
    # It was the barrel's close-range tier, 17 lines / 76 B.  The floor
    # lamp's exact L1 needs 88 B and obj_e is a byte, so the whole table
    # must fit 256: HEX 52 + LAMP 88 + PILLAR 96 = 236 is the only cut that
    # clears both that wall and the FLAT art home's 152 B.  The corpus never
    # selected OCT (it needs a >= 12, i.e. within ~64 units of a barrel), and
    # the lamp is drawn 12 times in the same corpus as a bare rectangle, so
    # the trade buys far more than it costs.  To bring OCT back, obj_e has to
    # widen -- see the note on the assert at the end of the block.
    def _ln(p, q):
        # LEFT-TO-RIGHT IS A HARD CONTRACT.  draw_clipped_line_s16 requires
        # x1 <= x2 -- the in-clipper swap died when the seg layer took over
        # canonicalising (the 8F.1F "solid bars" fix), so a reversed line
        # walks the span list WITHOUT emitting or recording.
        if p[0] > q[0]:
            p, q = q, p
        return [p[0]*2, p[1]*2, q[0]*2, q[1]*2]

    obj_art = []

    # -- THE OUTLINE RECTANGLE (OBJ_ART_RECT) IS RETIRED (2026-08-31) -----
    # Nothing selects it any more: the lamps and candelabras that were its
    # only users now have the lamp template, and on FLAT the pillar falls
    # into the lamp too (a tall thin lamp reads far closer to a column than
    # the barrel drum does).
    # -- LOD barrel: flat-top hexagonal lid (2026-08-27) ------------------
    # THE BARREL'S ONLY TEMPLATE since OCT retired (2026-08-31).
    # Vertices (+-a, lidc+-~0) , (+-w, lidc+-b): the silhouette still
    # touches +-a (the body sides join there) and the lid top stays at
    # the 12-gon's bbox (the FUSED authority height is preserved).
    # BEST FIT, computed here: normalize the lid to a unit ellipse and
    # least-squares the hex outline against the ACTUAL 12-gon template
    # polygon (engine ratios 1, 47/64, 17/64) over a dense angular
    # sweep, for w/a among the engine's shift-cheap candidates. The mid
    # vertices ride the EXISTING +-b3 table heights (lidc -+ b3, the top
    # arc off Y[2] and the bottom off Y[3]) so the lid is SYMMETRIC in y
    # — rise and drop are both b - b3 = b2 exactly — and the engine
    # builds NO new y values: only cx -+ w into the two dead Y slots
    # (which the walker reaches as x indices 12/13, the arrays being
    # adjacent).  Until 2026-09-01 the top arc ALSO anchored at Y[3],
    # making it b + b3 deep — Eben: "the weirdly bulging top".
    import math as _mm
    _th = [_mm.tau * _i / 720 for _i in range(720)]
    _v12 = [(_mm.cos(_mm.radians(15+30*k)), _mm.sin(_mm.radians(15+30*k))) for k in range(12)]
    # replace true cos/sin with the ENGINE's baked ratios (x: 1,.734,.266; y likewise)
    def _snap(v):
        s_ = 1 if v >= 0 else -1
        av = abs(v)
        return s_ * min((1.0, 47/64, 17/64), key=lambda r: abs(r-av))
    _v12 = [(_snap(x), _snap(y)) for (x, y) in _v12]
    def _poly_r(poly, th):
        # boundary radius of a star-shaped polygon along direction th
        import math as _m
        dx, dy = _m.cos(th), _m.sin(th)
        best = 0.0
        n = len(poly)
        for i in range(n):
            x1, y1 = poly[i]; x2, y2 = poly[(i+1) % n]
            den = dx*(y2-y1) - dy*(x2-x1)
            if abs(den) < 1e-12:
                continue
            r = (x1*(y2-y1) - y1*(x2-x1)) / den
            if r <= 0:
                continue
            px, py = r*dx, r*dy
            if abs(x2-x1) >= abs(y2-y1):
                u = (px-x1) / (x2-x1)
            else:
                u = (py-y1) / (y2-y1)
            if -1e-9 <= u <= 1 + 1e-9:
                best = max(best, r)
        return best
    _r12 = [_poly_r(_v12, t) for t in _th]
    _best_w, _best_e = None, None
    for _w, _nm in ((0.5, 'a>>1'), (7/16, 'a>>1-a>>4'), (9/16, 'a>>1+a>>4'), (17/64, 'a3')):
        _hex = [(1,0),(_w,1),(-_w,1),(-1,0),(-_w,-1),(_w,-1)]
        _rh = [_poly_r(_hex, t) for t in _th]
        _e = sum((a-b)**2 for a, b in zip(_r12, _rh))
        if _best_e is None or _e < _best_e:
            _best_e, _best_w, _best_nm = _e, _w, _nm
    assert _best_w == 9/16, \
        f'hex LOD best-fit drifted from 9a/16 (got {_best_w}, {_best_nm}) — retune objects.s'
    _dev = max(abs(a-b) for a, b in zip(_r12, [_poly_r([(1,0),(9/16,1),(-9/16,1),(-1,0),(-9/16,-1),(9/16,-1)], t) for t in _th]))
    assert _dev * 12 <= 1.75, \
        f'hex LOD deviation {_dev:.3f}*a exceeds ~1.5px at a=12 (corpus max is 8; hex is ALL-RANGE now OCT is retired)'
    # template: x idx 0=-a, 5=+a, 12=-w, 13=+w; y idx 0=syt, 3=lidc+b3,
    # 5=lidc+b, 9/11 = the base twins. 11 lines, outline then ARM+authority.
    off_art_hex = len(obj_art)
    _H = lambda x1,y1,x2,y2: [x1*2, y1*2, x2*2, y2*2]
    obj_art += _H(0,3, 12,5)                    # near lid, left slant
    obj_art += _H(12,5, 13,5)                   # near lid, bottom edge
    obj_art += _H(13,5, 5,3)                    # near lid, right slant
    obj_art += _H(0,9, 12,11)                   # near base, left slant
    obj_art += _H(12,11, 13,11)                 # near base, bottom edge
    obj_art += _H(13,11, 5,9)                   # near base, right slant
    obj_art += _H(0,2, 0,9)                     # left side (silhouette)
    obj_art += _H(5,2, 5,9)                     # right side
    obj_art += _CTL(OBJ_ART_ARM)
    obj_art += _H(0,2, 12,0)                    # far lid, left slant: FUSED
    obj_art += _H(12,0, 13,0)                   # far lid, top edge: FUSED
    obj_art += _H(13,0, 5,2)                    # far lid, right slant: FUSED
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_hex == 0, f'OBJ_ART_HEX drifted: {off_art_hex} (layout.inc says 0)'

    # -- THE FLOOR LAMP (thing 2028, and thing 35 the candelabra) ---------
    # doc/billboard's lamp L1, VERBATIM: 3 coaxial bands (r 11.5 z 0-5, r 7.5
    # z 5-14, r 5.5 z 14-48), 20 lines, 5 |x| and 13 y.  Unlike the barrel and
    # the pillar the lamp shows ALL THREE bands' rims, and its radii are off
    # the dodecagon vertex ladder, so its occlusion cuts land on values the
    # {a, a2, a3} triple does not contain -- that is why it needs 5 magnitudes
    # where they need 3, and why obj_lamp_xy has to build the x table too.
    #
    # THE LADDER SLOTS.  10 signed x and 13 y is 23 s16, and obj_X + obj_Y is
    # 24, so it just fits -- with the last 4 x values living in obj_Y[13..16],
    # which the walker reaches as x byte offsets 38..44 exactly as the hex LOD
    # reaches obj_Y[6..7] at 24/26.  _LP maps ladder index -> byte offset.
    #   x idx 0..9 = cx -+ a*{256,167,166,122,109}/256, ascending.  +-a KEEP
    #   the obj_X+0 / obj_X+10 slots -- obj_probe hardwires those as the
    #   silhouette's leftmost/rightmost columns -- so the -side magnitudes
    #   fill obj_X[1..4] and the +side ones spill to obj_Y[13..16]
    #   y idx 0..12 = syt + H*{0,174,176,177,178,180,218,221,224,226,229,252,
    #                          256}/256
    # GENERATED by doc/billboard/tables.py, which asserts extent, joins and
    # the armed rule on the same numbers.
    _LXOFF = (0, 2, 4, 6, 8, 38, 40, 42, 44, 10)
    def _LP(x1, y1, x2, y2):
        if x1 > x2:                             # left-to-right, as for _ln
            x1, y1, x2, y2 = x2, y2, x1, y1
        return [_LXOFF[x1], y1*2, _LXOFF[x2], y2*2]
    off_art_lamp = len(obj_art)
    obj_art += _LP( 0, 9,  2,10)                # base disc, near arc
    obj_art += _LP( 2,10,  7,10)
    obj_art += _LP( 7,10,  9, 9)
    obj_art += _LP( 0,11,  2,12)                # base disc, bottom arc
    obj_art += _LP( 2,12,  7,12)
    obj_art += _LP( 7,12,  9,11)
    obj_art += _LP( 0, 7,  0,11)                # base disc sides
    obj_art += _LP( 9, 7,  9,11)
    obj_art += _LP( 1, 4,  4, 5)                # collar, near arc
    obj_art += _LP( 4, 5,  5, 5)
    obj_art += _LP( 5, 5,  8, 4)
    obj_art += _LP( 1, 2,  1, 8)                # collar sides
    obj_art += _LP( 8, 2,  8, 8)
    obj_art += _LP( 3, 0,  3, 3)                # stem sides
    obj_art += _LP( 6, 0,  6, 3)
    obj_art += _CTL(OBJ_ART_ARM)
    # The armed run is the topmost line at every x, and for the lamp that is
    # THREE bands' worth, not one: the stem's top rim over the middle, the
    # collar's top rim on either side of it, and the base disc's top rim
    # outboard of those.  Their union is exactly -a..+a.
    obj_art += _LP( 0, 7,  1, 6)                # base disc top rim, left
    obj_art += _LP( 8, 6,  9, 7)                #                    right
    obj_art += _LP( 1, 2,  3, 1)                # collar top rim, left
    obj_art += _LP( 6, 1,  8, 2)                #                 right
    obj_art += _LP( 3, 0,  6, 0)                # stem top
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_lamp == 52, \
        f'OBJ_ART_LAMP drifted: {off_art_lamp} (layout.inc says 52)'
    # HELMET L0 -- THE HOPLITE (Eben 2026-09-02): diagonal bottom
    # corners off BON2A0's tapering feet, and the base gaps traced UP
    # into eyeholes -- N up the outer wall, NW temple flare, E roof,
    # S down the nasal wall (open at the bottom edge, like the sprite's
    # slits).  Window A had the 116 free bytes this 88 needs.
    #   x offs: 0=-a 2=-x6 4=-x4 6=-x3 8=-x2 10=+a; spill 38=+x2
    #   40=+x3 42=+x4 44=+x6 46=-fx 48=+fx 50=-dxf 52=+dxf
    #   (fx = 5.2 temple-flare reach, dxf = 5.5 diagonal foot)
    #   y offs: 0=syt 2=dome z13 4=z10 6=fz(5.5) 8=wz(3.5) 10=dz(3) 12=syb
    off_art_helm_l0 = len(obj_art)
    obj_art += [8, 12, 38, 12]                  # nasal foot
    obj_art += [50, 12, 4, 12]                  # outer feet
    obj_art += [42, 12, 52, 12]
    obj_art += [0, 10, 50, 12]                  # DIAGONAL corners
    obj_art += [52, 12, 10, 10]
    obj_art += [4, 8, 4, 12]                    # N: eyehole outer walls
    obj_art += [42, 8, 42, 12]
    obj_art += [46, 6, 4, 8]                    # NW: temple flares
    obj_art += [42, 8, 48, 6]
    obj_art += [46, 6, 8, 6]                    # E: roofs
    obj_art += [38, 6, 48, 6]
    obj_art += [8, 6, 8, 12]                    # S: nasal walls
    obj_art += [38, 6, 38, 12]
    obj_art += [0, 4, 0, 10]                    # sides (from the diagonal top)
    obj_art += [10, 4, 10, 10]
    obj_art += _CTL(OBJ_ART_ARM)
    # AUTHORITY RUN MUST BE MONOTONIC LEFT-TO-RIGHT (2026-09-03): the fused
    # walker advances a single column cursor, so a descending arm segment
    # runs it backward and corrupts the span pool -- escaping wall
    # fragments to the screen edge (Eben's HUD repro).  One ascending
    # sweep 166->192: left arc, top, right arc.
    obj_art += [0, 4, 2, 2]                     # dome: authority (left arc)
    obj_art += [2, 2, 6, 0]
    obj_art += [6, 0, 40, 0]                    # top
    obj_art += [40, 0, 44, 2]                   # right arc (ASCENDING)
    obj_art += [44, 2, 10, 4]
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_helm_l0 == 140, f'OBJ_ART_HELM_L0 drifted: {off_art_helm_l0}'
    # WINDOW A ends here (HEX + LAMP + HELM_L0 = 228 B): pad to 256.
    # The template walker's four reads are abs,X off a window base whose
    # HIGH BYTE is the per-object SMC patch -- offsets stay bytes, and a
    # window must never exceed 256 B.
    obj_art += [0xFF] * (256 - len(obj_art))

    # -- techno pillar, thing 48 (2026-08-31) -----------------------------
    # A STACK OF COAXIAL CYLINDERS, not a drum: plinth r=19 z 0..4.90, shaft
    # r=a2*19 z 4.90..122.83, cap r=19 z 122.83..128, and FOUR drawn rims
    # each with its own ellipse depth (b = a*|z-eye|/D, so the cap is over
    # twice as open as the plinth against an eye 41 up).  obj_pillar_y builds
    # the 18 y slots; obj_X is the barrel's own {a, a2, a3} unchanged, because
    # the shaft's rims are covered top and bottom and it contributes only its
    # two sides -- which sit at a2*19, already a vertex.
    #
    # -- THE TECHNO PILLAR IS GONE (2026-08-31, Eben: "it just doesn't
    # work").  Thing 48 packs nothing; window B starts with the box.

    # -- THE PICKUP TEMPLATES (2026-08-31) -- geometry doc/billboard's,
    # ladder slots built by the obj_*_xy routines in objects.s.  All four
    # fit ONE window (228 B) now the pillar is gone -- two windows total.
    #
    # BOX (stimpack AND medikit -- one template, two kinds: the lid
    # fraction is the only difference and it lives in the LADDER, not
    # here).  Eben's L1: the rectangle with its lid line, 5 lines.
    #   x offs: 0 = cx-a, 10 = cx+a (the prologue's slots, probe-aligned)
    #   y offs: 0 = syt, 2 = lid, 4 = syb
    off_art_box = len(obj_art)
    obj_art += [0, 2, 10, 2]                    # the lid line
    obj_art += [0, 0, 0, 4]                     # left side
    obj_art += [10, 0, 10, 4]                   # right side
    obj_art += [0, 4, 10, 4]                    # bottom
    obj_art += _CTL(OBJ_ART_ARM)
    obj_art += [0, 0, 10, 0]                    # top edge: the authority
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_box == 256, f'OBJ_ART_BOX drifted: {off_art_box} (window B head)'

    # POTION L1 IS DEAD (Eben 2026-09-02: "disable L1 for potions") --
    # the dodecagon (window C) draws at every size; obj_lodh carries $FF.
    #
    # VEST L0 -- the DOUBLED outline (Eben 2026-09-02): every run split
    # through a nudged midpoint (hem ends lift, waist and armpit bow
    # out, rounded corner, crown at the top with dipped shoulder ends,
    # sagging neck rims), and the NECK LOOP: front rim + depth stubs +
    # the BACK OF THE NECK (armed -- topmost through the opening).
    #   x offs: 0=-a 2=-w(5.5) 4=-s(3) 6=+s 8=+w 10=+a; spill 42=-px(10.5)
    #   44=+px 46=-so(13.5) 48=+so 50=-w1(8.7) 52=+w1 54=-cr(8.25) 56=+cr
    #   58=-c(14.9) 60=+c 62=cx
    #   y offs: 0=syt 2=c1(16.75) 4=shd(16.7) 6=st(16) 8=bz(15) 10=bb(14.7)
    #   12=sm(14) 14=sz(13) 16=fb(12.4) 18=az(12) 20=f1(11) 22=pz(10)
    #   24=w1(5.4) 26=hem(0.8) 28=syb
    off_art_vest_l0 = len(obj_art)
    obj_art += [2, 26, 62, 28]                  # hem, ends lifted
    obj_art += [62, 28, 8, 26]
    obj_art += [50, 24, 2, 26]                  # waist bows
    obj_art += [42, 22, 50, 24]
    obj_art += [8, 26, 52, 24]
    obj_art += [52, 24, 44, 22]
    obj_art += [46, 20, 42, 22]                 # armpit flares
    obj_art += [0, 18, 46, 20]
    obj_art += [44, 22, 48, 20]
    obj_art += [48, 20, 10, 18]
    obj_art += [0, 12, 0, 18]                   # sides, split at the seam
    obj_art += [0, 6, 0, 12]
    obj_art += [10, 12, 10, 18]
    obj_art += [10, 6, 10, 12]
    obj_art += [4, 4, 4, 14]                    # scoop sides
    obj_art += [6, 4, 6, 14]
    obj_art += [4, 14, 62, 16]                  # neck: front rim, sagging
    obj_art += [62, 16, 6, 14]
    obj_art += [4, 8, 4, 14]                    # neck: depth stubs
    obj_art += [6, 8, 6, 14]
    obj_art += _CTL(OBJ_ART_ARM)
    # MONOTONIC L-to-R authority (2026-09-03): a SINGLE ascending sweep of
    # the top silhouette -- left corner up to the crown, across the neck
    # opening on the back-of-neck rim, up the right corner.  The fused
    # walker advances one column cursor; a descending segment runs it
    # backward and sprays escaping wall fragments (Eben's HUD repro).
    obj_art += [0, 6, 58, 2]                    # L corner: cx-a -> cx-c
    obj_art += [58, 2, 46, 4]                   #           cx-c -> cx-so
    obj_art += [46, 4, 54, 0]                   # L shoulder rise to crown
    obj_art += [54, 0, 4, 4]                    # crown -> scoop edge
    obj_art += [4, 8, 62, 10]                   # NECK: back-of-neck rim
    obj_art += [62, 10, 6, 8]                   #       cx -> +scoop
    obj_art += [6, 4, 56, 0]                    # R shoulder rise to crown
    obj_art += [56, 0, 48, 4]                   # crown -> cx+so
    obj_art += [48, 4, 60, 2]                   # cx+so -> cx+c
    obj_art += [60, 2, 10, 6]                   # cx+c -> cx+a
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_vest_l0 == 284, f'OBJ_ART_VEST_L0 drifted: {off_art_vest_l0}'

    # VEST L1 -- the old L0 outline (armpit flare + rounded corner kept)
    # plus the same neck loop, straight rims.
    off_art_vest = len(obj_art)
    obj_art += [2, 28, 8, 28]                   # hem
    obj_art += [42, 22, 2, 28]                  # waist slants
    obj_art += [8, 28, 44, 22]
    obj_art += [0, 18, 42, 22]                  # armpit flares
    obj_art += [44, 22, 10, 18]
    obj_art += [0, 6, 0, 18]                    # sides
    obj_art += [10, 6, 10, 18]
    obj_art += [4, 0, 4, 14]                    # scoop sides
    obj_art += [6, 0, 6, 14]
    obj_art += [4, 14, 6, 14]                   # neck: front rim
    obj_art += [4, 8, 4, 14]                    # neck: depth stubs
    obj_art += [6, 8, 6, 14]
    obj_art += _CTL(OBJ_ART_ARM)
    # MONOTONIC L-to-R authority (2026-09-03): single ascending sweep.
    obj_art += [0, 6, 46, 0]                    # L corner: cx-a -> cx-so
    obj_art += [46, 0, 4, 0]                    # L shoulder -> scoop edge
    obj_art += [4, 8, 6, 8]                     # NECK: back-of-neck rim
    obj_art += [6, 0, 48, 0]                    # R shoulder (scoop -> cx+so)
    obj_art += [48, 0, 10, 6]                   # R corner: cx+so -> cx+a
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_vest == 412, f'OBJ_ART_VEST drifted: {off_art_vest}'
    obj_art += [0xFF] * (512 - len(obj_art))    # window B done

    # -- WINDOW C: THE CLOSE-RANGE TIERS (2026-08-31, "all objects appear
    # to render at lowest LOD").  The dispatch picks per kind by projected
    # height (obj_lodh in objects.s); lamp/helmet/vest stay single-tier --
    # the lamp's L0 wants 18 x slots and the arrays hold 10, and the other
    # two ARE their tier.
    #
    # OCT: the twelve-sided barrel, back from its 2026-08-31 retirement,
    # byte-identical to what shipped 08-25..08-31.  Vertices at 15 + 30k;
    # x idx 0..5 -> cx -+ {a,a2,a3}; y idx 0..5 -> lid centre -+ {b,b2,b3},
    # 6..11 the same + dy.  17 lines, far lid arc armed.  The prologue's
    # obj_hex/obj_ycp ladder serves it unchanged.
    _XI = {0:5, 1:4, 2:3, 3:2, 4:1, 5:0, 6:0, 7:1, 8:2, 9:3, 10:4, 11:5}
    _YI = {0:3, 1:4, 2:5, 3:5, 4:4, 5:3, 6:2, 7:1, 8:0, 9:0, 10:1, 11:2}
    def _edge(k, dy=0):
        j = (k + 1) % 12
        return _ln((_XI[k], _YI[k] + dy), (_XI[j], _YI[j] + dy))
    off_art_oct = len(obj_art)
    for k in (0, 1, 2, 3, 4):                   # near half of the lid
        obj_art += _edge(k)
    for k in (0, 1, 2, 3, 4):                   # near half of the base
        obj_art += _edge(k, 6)
    obj_art += _ln((0, 2), (0, 9))              # left side, lid edge included
    obj_art += _ln((5, 2), (5, 9))              # right side
    obj_art += _CTL(OBJ_ART_ARM)
    for k in (6, 7, 8, 9, 10):                  # far half of the lid: FUSED
        obj_art += _edge(k)
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_oct == 512, f'OBJ_ART_OCT drifted: {off_art_oct}'

    # BOX L0: the trapezoid top (diagonals ARMED -- topmost outboard of
    # the rear edge) + the 12-line cross outline, doc/billboard verbatim.
    #   x offs: 0=-w 2=-cw 4=-t 6=+t 8=+cw 10=+w; spill 38=-rear 40=+rear
    #   y offs: 0=syt(rear) 2=lid(front top) 4=syb 6=yc-ch 8=yc-t
    #           10=yc+t 12=yc+ch
    off_art_boxl0 = len(obj_art)
    obj_art += [0, 2, 10, 2]                    # front top edge
    obj_art += [0, 2, 0, 4]                     # front sides
    obj_art += [10, 2, 10, 4]
    obj_art += [0, 4, 10, 4]                    # bottom
    obj_art += [4, 6, 6, 6]                     # the cross outline
    obj_art += [6, 6, 6, 8]
    obj_art += [6, 8, 8, 8]
    obj_art += [8, 8, 8, 10]
    obj_art += [6, 10, 8, 10]
    obj_art += [6, 10, 6, 12]
    obj_art += [4, 12, 6, 12]
    obj_art += [4, 10, 4, 12]
    obj_art += [2, 10, 4, 10]
    obj_art += [2, 8, 2, 10]
    obj_art += [2, 8, 4, 8]
    obj_art += [4, 6, 4, 8]
    obj_art += _CTL(OBJ_ART_ARM)
    obj_art += [0, 2, 38, 0]                    # top-face diagonals
    obj_art += [38, 0, 40, 0]                   # rear top edge
    obj_art += [40, 0, 10, 2]
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_boxl0 == 588, f'OBJ_ART_BOXL0 drifted: {off_art_boxl0}'

    # POTION L0: the dodecagon bulb + the wide stem, with the stem sides
    # SNAPPED to the +-a3 vertices -- the feet land exactly on the 12-gon
    # corners, so nothing splits and every join is a shared vertex (the
    # neck narrows from 4 to 3.75 world px, sub-pixel at any drawn size).
    #   x offs: 0=-a 2=-qa 4=-a3a 6=+a3a 8=+qa 10=+a
    #   y offs: 0=syt 2=cy-a 4=cy-qa 6=cy-a3a 8=cy+a3a 10=cy+qa 12=syb
    off_art_potl0 = len(obj_art)
    # (the top segment under the stem is GONE, Eben 2026-09-02 -- same
    #  neck-opening cut as the L1 tier)
    obj_art += [0, 8, 2, 10]                    # lower arc
    obj_art += [2, 10, 4, 12]
    obj_art += [4, 12, 6, 12]
    obj_art += [6, 12, 8, 10]
    obj_art += [8, 10, 10, 8]
    obj_art += [0, 6, 0, 8]                     # sides
    obj_art += [10, 6, 10, 8]
    obj_art += [4, 0, 4, 2]                     # stem sides
    obj_art += [6, 0, 6, 2]
    obj_art += _CTL(OBJ_ART_ARM)
    # MONOTONIC L-to-R authority (2026-09-03): left arc, stem top across
    # the neck, right arc -- the stem top belongs in the MIDDLE of the
    # sweep (its x is cx-a3..cx+a3), not appended after the right arc
    # (which ran the fused walker's cursor backward).
    obj_art += [0, 6, 2, 4]                     # left arc: cx-a -> cx-qa
    obj_art += [2, 4, 4, 2]                     #           cx-qa -> cx-a3
    obj_art += [4, 0, 6, 0]                     # stem top across the neck
    obj_art += [6, 2, 8, 4]                     # right arc: cx+a3 -> cx+qa
    obj_art += [8, 4, 10, 6]                    #            cx+qa -> cx+a
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_potl0 == 672, f'OBJ_ART_POTL0 drifted: {off_art_potl0}'

    # HELMET L1 (Eben 2026-09-02): no base indentations -- one straight
    # bottom -- and the top in THREE lines: a single armed diagonal per
    # side plus the flat top.  Window C's last 32 bytes, to the byte.
    #   y offs (helmet map): 0=syt 4=z10 12=syb; x: 0=-a 6=-x3 10=+a 40=+x3
    off_art_helm_l1 = len(obj_art)
    obj_art += [0, 12, 10, 12]                  # bottom
    obj_art += [0, 4, 0, 12]                    # sides
    obj_art += [10, 4, 10, 12]
    obj_art += _CTL(OBJ_ART_ARM)
    # MONOTONIC L-to-R authority (2026-09-03): left diagonal, top, right
    # diagonal ASCENDING -- the fused walker's single column cursor.
    obj_art += [0, 4, 6, 0]                     # dome: left diagonal (166->174)
    obj_art += [6, 0, 40, 0]                    # top (174->184)
    obj_art += [40, 0, 10, 4]                   # right diagonal (184->192)
    obj_art += _CTL(OBJ_ART_END)
    assert off_art_helm_l1 == 736, f'OBJ_ART_HELM_L1 drifted: {off_art_helm_l1}'
    assert len(obj_art) == 768, f'art blob is {len(obj_art)} B, expected 768 (window C exactly full)'
    # OBJ_E IS A BYTE -- but it is an offset WITHIN a 256-byte window now,
    # and the walker's four abs,X reads get their window high byte SMC'd
    # per object (oa_rd0..3 in objects.s).  Windows: A = HEX + LAMP
    # (byte-identical to the old whole table, so flat needs nothing),
    # B = PILLAR + BOX + POTION, C = HELMET + VEST.

    n_obj_art = 35                          # FLAT's count: window A's real
                                            # 140 B (hex + lamp), unchanged
    # LV1 BKT planes (2 x 128 B, s16 LE): the WHOLE K-residue term of the
    # banded backface, baked per record (2026-08-26 second cut — the
    # unpacked per-axis K planes lasted a day): BKT = -32*(cdy*kx - cdx*ky)
    # with (cdx,cdy) the record's CANONICAL primitive dir (cdy > 0).
    # bf_band folds it with ONE s16 add — subtract instead when the seg's
    # DIR sign plane says dy' < 0 (the twin runs the negated dir).
    # DBOUND (1 x 128 B, u8): per-DIR exactness bound sum + sum>>1 + 1
    # (sum = |dx'|+|dy'| <= 63) — one indexed load replaces bfx_bound's
    # arithmetic, and the node point-on-side band gate reads the same
    # plane. All appended at the blob end; loaders place per build
    # (layout.inc ROM_BKTLO/HI_C, ROM_DBOUND_C).
    off_bktlo = off_obj + 0x200             # PAST the 512-byte obj hole:
    off_bkthi = off_bktlo + 128             # the loaders copy the hole as
    off_dbound = off_bkthi + 128            # one piece and these planes
                                            # separately to their homes
    off_obj_art = off_dbound + 128          # the art tail region
    art_len = len(obj_art)
    rom_main_size = off_obj_art + art_len

    rom_main = bytearray(rom_main_size)

    for _i, _o in enumerate(fp_objects):
        _px, _py = _o['x'], _o['y']
        assert -512 <= _px < 512 and -512 <= _py < 512, \
            f"object {_i} {(_px, _py)} outside the page-decomposed range"
        assert 0 <= _o['ss'] < 256, "subsector id must fit u8"
        # The aspect byte is a KIND INDEX now; k is per-kind, lives in
        # the engine's obj_ktab, and doom_wireframe asserts the two agree.
        assert 0 <= _o['asp'] <= 6, "aspect byte must be a kind index"
        for _pl, _v in enumerate((_px & 0xFF, _py & 0xFF,
                                  (((_px >> 8) + 2) & 3) | ((((_py >> 8) + 2) & 3) << 2),
                                  _o['ss'], _o['asp'],
                                  _o['zt'] & 0xFF, _o['zb'] & 0xFF)):
            rom_main[off_obj + _pl * n_obj + _i] = _v
        rom_main[off_obj_bits + (_o['ss'] >> 3)] |= 1 << (_o['ss'] & 7)
        _oct = off_obj_bits + obj_bits_len + (_o['ss'] >> 3)
        if rom_main[_oct] == 0 or rom_main[_oct] > _i + 1:
            rom_main[_oct] = _i + 1          # provisional +1; fixed below
    for _oc in range(obj_bits_len):
        _v = rom_main[off_obj_bits + obj_bits_len + _oc]
        rom_main[off_obj_bits + obj_bits_len + _oc] = (_v - 1) if _v else 0xFF
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
    # (the SQR_MIRROR-in-the-VXCACHE-tail constraint died 2026-08-18: the
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
        # AXIS origins bake DOUBLED (2026-08-26, the exact-descent land):
        # the engine compares 2*nx against the staged tie-broken raw
        # (raw<<1 | frac>0), so 'px_true > nx' — ties included — costs
        # the ORIGINAL two-byte compare. General nodes keep plain nx/ny
        # (the delta arm subtracts them). Mirrors: colmap.find_ss.
        _ax_dbl = 2 if (raw_dx == 0 or raw_dy == 0) else 1
        if raw_dx == 0:
            _nx_b, _ny_b = 2 * raw_nx, raw_ny        # form 0 reads NX only
        elif raw_dy == 0:
            _nx_b, _ny_b = raw_nx, 2 * raw_ny        # form 1 reads NY only
        else:
            _nx_b, _ny_b = raw_nx, raw_ny
        assert -32768 <= _nx_b <= 32767 and -32768 <= _ny_b <= 32767, \
            f"node {i}: doubled axis origin overflows s16"
        _npg(0, i, _nx_b); _npg(1, i, _nx_b >> 8)
        _npg(2, i, _ny_b); _npg(3, i, _ny_b >> 8)
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

    # Subsectors (PG/CNT split 2026-08-29 — was one packed PC byte
    # ((page+1)<<3)|(cnt-1), whose 3-bit count field capped subsectors at
    # 8 segs and cost the prologue an AND/AND/LSRx3 unpack):
    #   PG  = page, PLAIN (the +1 sentinel bias died with the split —
    #         Eben 2026-08-29: the empty test rides the CNT plane now,
    #         so the page byte feeds the ADC base constant directly)
    #   CNT = cnt - 1 in its OWN plane (off_ss_cnt, rom_main tail with
    #         per-build homes); $FF = empty subsector — the prologue's
    #         LDY/BMI is the empty test, and cnt-1 is the loop counter
    #         verbatim. Count range is now bounded only by the page-slot
    #         invariant below (28), not the encoding
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
        # cnt <= 28: the page-slot invariant above is the real bound (a
        # subsector's header run must fit one 256-byte page at stride 9);
        # the old <= 8 came from the retired SS_PC 3-bit count field and
        # died with the PG/CNT split (cnt-1 <= 27 never collides with the
        # $FF empty sentinel, and the loop's BMI end is safe to 127).
        assert r9 == 0 and slot < 29 and page < 255 and ss[0] <= 28, \
            f"subsector {i}: PG/SI encoding out of range ({page},{slot},{ss[0]})"
        rom_main[off_ss + i] = page if ss[0] else 0
        rom_main[off_ss + 256 + i] = rem            # PLO: slot * stride
        rom_main[off_ss_cnt + i] = (ss[0] - 1) if ss[0] else 0xFF
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
            c24 = lv1[0]                         # compare constant = lv1x
        elif pdy == 0:
            form = 3 if pdx > 0 else 2
            c24 = lv1[1]                         # compare constant = lv1y
        if pdx == 0 or pdy == 0:
            # AXIS TIE BAKE (2026-08-25): the 8.8 position truncates by
            # FLOOR, so a truncated tie (coord_int == C) means the true
            # position is in [C, C+1) -- always on the '>' side. The old
            # uniform tie->BACK therefore culled the '>' twin wrongly and
            # BOTH twins of an axis portal vanished whenever the player
            # stood in the 1-unit strip on its '>' side (a standing-
            # reachable 8-world-unit band: the 1c.26/56.c3/fc show-
            # through). Resolving the tie costs ZERO cycles: ship C-1 for
            # the '>' forms so the engine's strict compare reads
            # 'coord > C-1' == 'coord >= C'. The '<' forms keep C (their
            # tie->back was already correct), so exactly one twin
            # survives in every state, frac-0 included.
            if form in (0, 2):
                c24 -= 1
                assert c24 != -32769, 'C-1 underflow: axis form 0/2 at s16 min'
            c24 &= 0xFFFFFF
        else:
            # diagonal: DELTA form (operands stay small — the C-form's
            # raw-coordinate products measured SLOWER: 4 muls vs the
            # delta form's senior-byte-clear 1-mul fast paths). Header:
            # +5/6 lv1x s16, +7 lv1y lo, +9 lv1y hi (evicting the fossil
            # L byte); primitives via the DIR tables.
            did = _dirs.setdefault((pdx, pdy), len(_dirs))
            assert did + 4 <= 255 and len(_dirs) <= MAX_DIRS
            # the exact-backface band bound (bfx_bound) computes
            # 1.5*sum + 1 in u8 with a carry-free add — and the |d|<128
            # tier tests assume the bound stays under 128
            assert abs(pdx) + abs(pdy) <= 63, \
                f'primitive sum {abs(pdx)+abs(pdy)} breaks the band bound'
            form = did + 4
            rom_main[off_dirs + did] = abs(pdx)
            rom_main[off_dirs + MAX_DIRS + did] = abs(pdy)
            rom_main[off_dirs + 2 * MAX_DIRS + did] = \
                ((0x80 if pdy < 0 else 0) | (0x40 if pdx < 0 else 0))
        # v1/v2 stored as (A = idx & 255, B = idx >> 3) — 2026-07-12: B is
        # the valid-bitmap byte index AND the VXCACHE_VALID index, consumed raw
        # by the 6502; idx*8 (vrcache) and idx*4 (verts) rebuild from A/B in
        # pure A-register shifts. Bijective: idx = B*8 + (A & 7).
        _vk = lambda v: (v & 0xFF) | ((v >> 3) << 8)
        struct.pack_into('<HH', rom_main, o, _vk(s[0]), _vk(s[1]))
        rom_main[o + 4] = form
        if form >= 4:
            # diagonal: the reference point goes in the deduped LV1 records.
            # EXACT-BACKFACE (2026-08-25): the record also carries the
            # point's sub-prescale residue k = raw_rel - PS*lv1 (one nibble
            # per axis), so the banded refinement can reconstruct the TRUE
            # line point — the rounded lv1 alone sits up to half a unit off
            # the line, which is what culled front-facing walls near
            # edge-on (the 9C.C9/4E.F8/F4 bleed witness, seg 121: dot_int
            # -4 vs true +4612). The dedupe key includes k: two raw points
            # rounding to the same lv1 must NOT share a record.
            assert prescale == 8, 'the 6502 corr math bakes 256/PS = 32'
            _rvx, _rvy = vertexes[ld[0]]
            _relx, _rely = _rvx - map_center_x, _rvy - map_center_y
            _kx = _relx - prescale * lv1[0]
            _ky = _rely - prescale * lv1[1]
            assert -8 <= _kx <= 7 and -8 <= _ky <= 7, (_kx, _ky)
            _cdx, _cdy = (pdx, pdy) if pdy > 0 else (-pdx, -pdy)
            # canonical dir joins the key: records also bake the K term
            # against (cdx,cdy), so two different LINES through the same
            # rounded point must not share a record
            key = (lv1[0] & 0xFFFF, lv1[1] & 0xFFFF, _kx, _ky, _cdx, _cdy)
            if key not in _lv1_ids:
                _lv1_ids[key] = len(_lv1_ids)
            rid = _lv1_ids[key]
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
            # mover-VALUED = the bytes are a mover's heights (half-unit
            # tier): a mover back, or a mover's own solid alias. ONLY
            # these are anim patch targets, so ONLY these need private
            # per-seg entries (the old front-OR-back privacy was over-
            # broad: a static-valued seg fronting a mover is never
            # patched and shares the common pool — 2026-08-25, when the
            # id-pool split made the distinction load-bearing).
            mover_vals = (back in _movers) or (back is None and front in _movers)
            key = ('seg', seg) if mover_vals else (bfh_v & 0xFF, bch_v & 0xFF)
            if key not in _bpal_ids:
                pool = 1 if mover_vals else 0
                rid_new = _bpal_next[pool]
                _bpal_next[pool] += 1
                _bpal_ids[key] = (rid_new, bfh_v & 0xFF, bch_v & 0xFF)
            rid = _bpal_ids[key]
            if mover_vals:
                assert _BPAL_MOVER_MIN <= rid[0] < BPAL_PER_PLANE, \
                    f'mover back-pair pool overflow (id {rid[0]})'
            else:
                assert rid[0] < _BPAL_MOVER_MIN, \
                    f'static back-pair pool overflow (id {rid[0]})'
            return rid[0]
        if back_idx is None:
            # ONE-SIDED solid: fh/ch alias — the descriptor role codes
            # bfh/bch evaluate with no runtime branch (never consumed
            # live: c2/c3 are NEEDBB/NEEDBT-gated, forever clear here).
            # A mover's own side walls alias in HALF units (the mover
            # pool) so the anim back patch keeps the alias in step.
            _afh = read_s8(rom_detail, od + SD_FH)
            _ach = read_s8(rom_detail, od + SD_CH)
            if svwh[1] in _movers:
                _afh, _ach = _afh * 2, _ach * 2
            rom_main[o + SH_BPAL] = _bpal(_afh & 0xFF, _ach & 0xFF)
        else:
            # TWO-SIDED — portal now or potentially at runtime (a closed
            # door is pack-time SOLID): TRUE back heights, NOT the alias.
            # The anim flag worker re-derives SOLID/NEEDBT/NEEDBB from
            # this quad; an alias here poisons it into SOLID forever
            # (the anim6502 phase-lockstep catch, 2026-07-25). While the
            # SOLID flag holds, c2/c3 gate off, so the alias is not
            # missed; detail SD_BFH/BCH stay 0 for pack-time solids.
            bs = fp_sectors[back_idx]
            _bfh, _bch = bs[0], bs[1]
            if back_idx in _movers:
                _bfh, _bch = _bfh * 2, _bch * 2    # half-unit tier
            rom_main[o + SH_BPAL] = _bpal(_bfh & 0xFF, _bch & 0xFF)

    # (H2 flag-worker bound assert lives in anim_sectors — it knows the
    #  mover travel endpoints; wad_packed only sees the rest pose.)

    # Diagonal LV1 records: 4 planes packed two per page at +$00/+$80 so an
    # indexed read never crosses a page boundary.
    for _key, (rid, bfh_v, bch_v) in _bpal_ids.items():
        rom_main[off_bpal + 0x00 + rid] = bfh_v
        rom_main[off_bpal + 0x80 + rid] = bch_v
    for (lx, ly, _kx, _ky, _cdx, _cdy), rid in _lv1_ids.items():
        rom_main[off_lv1 + 0x000 + rid] = lx & 0xFF
        rom_main[off_lv1 + 0x080 + rid] = (lx >> 8) & 0xFF
        rom_main[off_lv1 + 0x100 + rid] = ly & 0xFF
        rom_main[off_lv1 + 0x180 + rid] = (ly >> 8) & 0xFF
        assert -4 <= _kx <= 4 and -4 <= _ky <= 4, (_kx, _ky)
        _bkt = -32 * (_cdy * _kx - _cdx * _ky)
        assert -32768 <= _bkt <= 32767
        rom_main[off_bktlo + rid] = _bkt & 0xFF
        rom_main[off_bkthi + rid] = (_bkt >> 8) & 0xFF

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

    vrcache_size = n_verts * VRCACHE_ENTRY
    vrcache_valid = (n_verts + 7) // 8
    vwh_cache_size = n_vwh * VYCACHE_ENTRY
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

    spans_offset = vrcache_size + vrcache_valid + vwh_cache_size + vwh_valid
    ram_size = spans_offset + SPAN_TOTAL

    # DBOUND: per-dir exactness bound, one pass over the FINAL dir table
    # (seg dirs + node general dirs share it)
    for (_pdx, _pdy), _did in _dirs.items():
        _sum = abs(_pdx) + abs(_pdy)
        rom_main[off_dbound + _did] = _sum + (_sum >> 1) + 1
    layout = {
        'n_verts': n_verts, 'n_nodes': n_nodes, 'n_ss': n_ss,
        'n_segs': n_segs, 'n_vwh': n_vwh,
        'off_verts': off_verts, 'off_nodes': off_nodes,
        'off_ss': off_ss, 'off_seg_hdr': off_seg_hdr,
        'off_vwh': off_vwh,
        'off_dirs': off_dirs, 'n_dirs': len(_dirs), 'max_dirs': MAX_DIRS,
        'off_ss_fh': off_ss_fh, 'off_ss_ch': off_ss_ch,
        'off_ss_cnt': off_ss_cnt,
        'off_lv1': off_lv1, 'n_lv1': len(_lv1_ids),
        'off_obj': off_obj, 'n_obj': n_obj,
        'off_obj_bits': off_obj_bits, 'obj_bits_len': obj_bits_len,
        'off_obj_art': off_obj_art, 'n_obj_art': n_obj_art, 'art_len': art_len,
        'off_bpal': off_bpal, 'n_bpal': len(_bpal_ids),
        'off_bktlo': off_bktlo, 'off_bkthi': off_bkthi,
        'off_dbound': off_dbound,
        'lv1_krec': {rid: (k[2], k[3], k[4], k[5])
                     for k, rid in _lv1_ids.items()},   # python mirrors only
        'rom_main_size': rom_main_size,
        'rom_detail_size': len(rom_detail),
        'rom_recip_size': rom_recip_size,
        'off_sin_mag': off_sin_mag, 'off_sin_unity': off_sin_unity,
        'off_recip_m8': off_recip_m8,
        'ram_vrcache': 0,
        'ram_vrcache_valid': vrcache_size,
        'ram_vwh_cache': vrcache_size + vrcache_valid,
        'ram_vwh_valid': vrcache_size + vrcache_valid + vwh_cache_size,
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
