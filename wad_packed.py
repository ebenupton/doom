"""Packed WAD data in flat byte arrays for 8-bit processor simulation.

Four arrays:
  rom_main    - vertices, BSP nodes, subsectors, seg headers, VWH heights,
                linedef back-face data, sin/cos, reciprocals (ROM bank 1)
  rom_detail  - seg detail: VWH indices for front/back (ROM bank 2)
  ram         - vertex cache, VWH cache, packed valid bitmaps (RAM)

Seg data is split: the header (8B, accessed for every traversed seg)
is in rom_main; the detail (16B, accessed only for front-facing segs)
is in rom_detail.  This keeps each ROM region under 16KB.

All multi-byte values are little-endian (6502 native).
Struct sizes are powers of 2 for fast index→offset shifts.
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
SS_SOA_PAGES   = 3
NODE_SOA_SIZE  = (NODE_SOA_PAGES + SS_SOA_PAGES) * 256
# Node partition TYPE (bits 0-2): axis-aligned partitions bake the
# direction SIGN into a bf_ax-style strict-compare form (side0 iff the
# compare holds strictly; ties -> side1, matching D=0 -> side 1):
#   0: px > nx   1: px < nx   2: py > ny   3: py < ny   4: general
NT_GEN = 2
NF_RLEAF, NF_LLEAF = 0x80, 0x40   # child-is-subsector flags, baked into the TYPE byte
SEG_HDR_SIZE = 16    # idx<<4 (pure shifts). Uniform back-face C-FORM:
                     # +4 form/dir_id: 0 front iff px>C16, 1 px<C16,
                     #    2 py>C16, 3 py<C16; >=4 diagonal (id-4 indexes
                     #    the DIR tables appended after the headers)
                     # +5..7 C24 = dy'*lv1x - dx'*lv1y (axis: C16 +5/6)
                     # +8 flags, +9 L, +10..15 INLINED heights:
                     # +10 fh +11 ch +12 bfh|apv1_ch +13 bch|apv1_fh
                     # +14 apv2_ch +15 apv2_fh
                     # DIR tables (at off_seg_hdr + n_segs*16): DIRXM
                     # |dx'| , DIRYM |dy'|, DIRS sign byte (b7=dy' neg,
                     # b6=dx' neg) — one entry per distinct primitive
                     # diagonal direction (SAMEDIR folded at pack).
SEG_DTL_SIZE = 20    # ×20 = (idx<<4)+(idx<<2): fh,ch + 8 VWH u16 + back heights
VWH_SIZE     = 1     # identity: s8 height
# No separate linedef table — data inlined into seg headers

# ── Offsets within seg header ───────────────────────────────────────────

SH_V1 = 0; SH_V2 = 2             # vertex keys: lo=idx&255, hi=idx>>3 (see pack site)
SH_FORM = 4; SH_C = 5           # back-face C-form (see SEG_HDR_SIZE note)
# (lv1x/lv1y/ldx/ldy retired 2026-07-11: the C-form + DIR tables replace them)
SH_FLAGS = 8                     # u8 flags
SH_L = 9                         # u8 round(seg length) for option-2b
SH_PAD = 11

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
SF_SOLID  = 0x02   # one-sided wall
SF_NEEDBT = 0x04   # back ceiling < front ceiling
SF_NEEDBB = 0x08   # back floor > front floor
SF_NOVT1  = 0x10   # suppress vertical at v1 (BSP-internal split point)
SF_NOVT2  = 0x20   # suppress vertical at v2 (BSP-internal split point)
SF_APEDGE1 = 0x40  # emit aperture edge at v1 when NOVT1 suppresses the vertical
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
                 seg_novt_flags=None,
                 seg_novt_aperture=None,
                 novt_rule4=None,
                 vert_covered_by_solid_ap=None,
                 anim_vert_set=None):
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
    #   pg 11-13 subsector count, first_lo, first_hi
    # Everything else follows at NODE_SOA_SIZE.
    assert n_nodes <= 256 and n_ss <= 256
    assert n_verts <= 512, \
        "VCACHE planes are page-split on the senior bit (B & 0x20)"

    off_nodes = 0
    off_ss = NODE_SOA_PAGES * 256
    off_verts = NODE_SOA_SIZE
    off_seg_hdr = off_verts + 0x800   # 4 page-split vertex planes (fixed)
    # DIR tables tail the headers: 3 parallel u8 arrays, one entry per
    # distinct primitive diagonal direction (filled during the seg loop).
    _dirs = {}          # (dx', dy') -> id  (0-based; header stores id+4)
    off_dirs = off_seg_hdr + n_segs * SEG_HDR_SIZE
    MAX_DIRS = 160
    off_vwh = off_dirs + 3 * MAX_DIRS
    # VWH heights no longer ship in rom_main (2026-07-10): the 6502 render
    # projects from the FHCH stream; VWH indices are Python-side cache keys
    # only. off_vwh == rom_main_size is kept as a layout landmark.
    rom_main_size = off_vwh

    rom_main = bytearray(rom_main_size)

    # Vertices — page-split SoA planes (XLO/XHI/YLO/YHI, 512 bytes each;
    # n_verts <= 512 asserted above): junior page idx 0-255, senior 256+.
    # br_to_view_fetch reads them through senior-bit arms (header key
    # B & $20) with the plane page baked — no idx*4 pointer build.
    for i, v in enumerate(fp_vertexes):
        pg, off = (i >> 8) * 256, i & 0xFF
        rom_main[off_verts + 0x000 + pg + off] = v[0] & 0xFF
        rom_main[off_verts + 0x200 + pg + off] = (v[0] >> 8) & 0xFF
        rom_main[off_verts + 0x400 + pg + off] = v[1] & 0xFF
        rom_main[off_verts + 0x600 + pg + off] = (v[1] >> 8) & 0xFF

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
            typ = NT_GEN                     # 2
        if cr & 0x8000: typ |= NF_RLEAF
        if cl & 0x8000: typ |= NF_LLEAF
        _npg(8, i, typ)

    # Subsectors (SoA pages 11-13: count, hdr-offset lo, hdr-offset hi).
    # The offset pages hold first_seg*16 — the seg-header BYTE offset.
    # The loaders rebase the hi page onto the per-build ROM_SEG_HDR base
    # (page-aligned), so the engine serves a subsector with two plain
    # indexed loads: no address generation at run time. n_segs <= 1024
    # keeps the offset in 14 bits (the real ceilings are tighter and
    # layout-asserted: flat headers reach verts at ~768, banked reach
    # TABL0 at ~745).
    assert n_segs <= 1024, \
        "SS hdr-offset pages assume seg-header offsets fit 14 bits"
    for i, ss in enumerate(fp_ssectors):
        off16 = ss[1] * 16
        # page-slotting invariant (doom_wireframe): a run never crosses
        # its 256-byte page — the engine's +16 advance carries no page
        # handling and the header page is subsector-constant
        assert (off16 & 0xFF) + ss[0] * 16 <= 256, \
            f"subsector {i} seg run crosses a page (slotting broken)"
        rom_main[off_ss + i] = ss[0] & 0xFF
        rom_main[off_ss + 256 + i] = off16 & 0xFF
        rom_main[off_ss + 512 + i] = (off16 >> 8) & 0xFF

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
        # Suppress verticals at BSP-internal split points (RULE 1).
        if s[0] not in ld_endpoint_verts:
            flags |= SF_NOVT1
        if s[1] not in ld_endpoint_verts:
            flags |= SF_NOVT2
        # RULE 2 contributions from the caller (colinear solid neighbour).
        if seg_novt_flags is not None:
            flags |= seg_novt_flags[i] & (SF_NOVT1 | SF_NOVT2)
        # Mover-adjacent segs (DOOM_ANIM): heights are runtime inputs, so
        # every vertical is drawn unconditionally (rule 1 included) and no
        # aperture edges are baked — the APV overlay slots stay portal
        # bfh/bch/VWH data for the runtime patcher.
        if anim_vert_set is not None and (s[0] in anim_vert_set or s[1] in anim_vert_set):
            flags &= ~(SF_NOVT1 | SF_NOVT2)

        # APEDGE flags: emit an aperture edge at NOVT endpoints where
        # the opening would otherwise have no visible boundary.
        #   Portals: the portal's own step vertical is suppressed but
        #     there is no colinear solid covering the aperture range,
        #     so the portal must draw the (bt|ft)→(bb|fb) edge itself.
        #   Solids: this solid is suppressed by RULE 2 Case C and has
        #     recorded aperture heights from the colinear portal —
        #     draw the opening frame so the suppressed side remains
        #     visible.
        # RULE 4 NOVTs never emit aperture edges (owner seg's step
        # vertical already covers the same column-range).
        if back_idx is None or (flags & SF_SOLID):
            # Solid: APEDGE driven by seg_novt_aperture entries.
            if seg_novt_aperture is not None:
                if (i, 1) in seg_novt_aperture and (flags & SF_NOVT1):
                    flags |= SF_APEDGE1
                if (i, 2) in seg_novt_aperture and (flags & SF_NOVT2):
                    flags |= SF_APEDGE2
        else:
            # Portal with visible opening: APEDGE iff NOVT AND at a
            # linedef endpoint AND not yielded to a solid AND not a
            # Rule-4 suppression AND the portal actually has steps
            # (need_bt OR need_bb).  Portal-plain segs don't emit
            # aperture edges in the Python reference — their opening
            # has no step boundary to frame, so the ft/fb horizontals
            # suffice.
            novt_rule4 = novt_rule4 if novt_rule4 is not None else set()
            solid_ap = vert_covered_by_solid_ap if vert_covered_by_solid_ap is not None else set()
            has_steps = bool(flags & (SF_NEEDBT | SF_NEEDBB))
            if (has_steps
                    and (flags & SF_NOVT1) and s[0] in ld_endpoint_verts
                    and s[0] not in solid_ap
                    and (i, 1) not in novt_rule4):
                flags |= SF_APEDGE1
            if (has_steps
                    and (flags & SF_NOVT2) and s[1] in ld_endpoint_verts
                    and s[1] not in solid_ap
                    and (i, 2) not in novt_rule4):
                flags |= SF_APEDGE2

        # L = round(seg length) in the formerly-pad byte (offset 11), for the
        # option-2b angle-space seg projection: c = (cross<<4)/L. u8 (<=89 for
        # E1M1). na is recomputed on the 6502 via point_to_angle(-ldy, ldx).
        seg_L = int(round(math.hypot(ldx, ldy)))
        assert 0 <= seg_L <= 255, f"seg {i}: L={seg_L} not u8"
        o = off_seg_hdr + i * SEG_HDR_SIZE
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
            rom_main[o + 5] = lv1[0] & 0xFF
            rom_main[o + 6] = (lv1[0] >> 8) & 0xFF
            rom_main[o + 7] = lv1[1] & 0xFF
            rom_main[o + 9] = (lv1[1] >> 8) & 0xFF
        else:
            rom_main[o + 5] = c24 & 0xFF
            rom_main[o + 6] = (c24 >> 8) & 0xFF
            rom_main[o + 7] = 0
            rom_main[o + 9] = seg_L          # fossil pad (no 6502 reader)
        rom_main[o + 8] = flags

        # For solids with aperture edges, overlay APV heights onto the
        # unused portal-only slots in seg detail.
        if (flags & SF_SOLID) and seg_novt_aperture is not None:
            o_det = i * SEG_DTL_SIZE
            ap1 = seg_novt_aperture.get((i, 1))
            if ap1 is not None and (flags & SF_APEDGE1):
                bch1, bfh1 = ap1
                rom_detail[o_det + SD_APV1_CH] = bch1 & 0xFF
                rom_detail[o_det + SD_APV1_FH] = bfh1 & 0xFF
            ap2 = seg_novt_aperture.get((i, 2))
            if ap2 is not None and (flags & SF_APEDGE2):
                bch2, bfh2 = ap2
                rom_detail[o_det + SD_APV2_CH] = bch2 & 0xFF
                rom_detail[o_det + SD_APV2_FH] = bfh2 & 0xFF

        # Heights INLINED into the header (post-APV overlay, exactly the
        # bytes the old load-time FHCH synthesis emitted): the separate
        # FHCH stream is gone — one cursor walks everything.
        od = i * SEG_DTL_SIZE
        rom_main[o + 10] = rom_detail[od + SD_FH]
        rom_main[o + 11] = rom_detail[od + SD_CH]
        rom_main[o + 12] = rom_detail[od + SD_BFH]
        rom_main[o + 13] = rom_detail[od + SD_BCH]
        rom_main[o + 14] = rom_detail[od + SD_APV2_CH]
        rom_main[o + 15] = rom_detail[od + SD_APV2_FH]

    # ── ROM Recip: sin/cos + reciprocal tables ────────────────────────────

    from fp import _SIN_QUADRANT, _SIN_UNITY, _RECIP_M8

    # Layout: sin_mag[64] + sin_unity[64] + recip_m8[1024]. The recip is a
    # normalized floating mantissa per 10-bit 9.1 index (see fp.py); the
    # shift S = bit_length(idx-1) is computed by br_recip, not stored.
    SINCOS_SIZE = 64 + 64   # magnitude + unity flags, one quadrant
    RECIP_ENTRIES = 1024
    rom_recip_size = SINCOS_SIZE + RECIP_ENTRIES

    rom_recip = bytearray(rom_recip_size)
    off_sin_mag = 0
    off_sin_unity = 64
    off_recip_m8 = SINCOS_SIZE

    for j in range(64):
        rom_recip[off_sin_mag + j] = _SIN_QUADRANT[j] & 0xFF
        rom_recip[off_sin_unity + j] = 1 if _SIN_UNITY[j] else 0

    for j in range(RECIP_ENTRIES):
        rom_recip[off_recip_m8 + j] = _RECIP_M8[j] & 0xFF

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
        did = _dirs.setdefault((pdx, pdy), len(_dirs))
        assert len(_dirs) <= MAX_DIRS, "DIR table overflow (nodes+segs)"
        rom_main[off_dirs + did] = abs(pdx)
        rom_main[off_dirs + MAX_DIRS + did] = abs(pdy)
        rom_main[off_dirs + 2 * MAX_DIRS + did] = \
            ((0x80 if pdy < 0 else 0) | (0x40 if pdx < 0 else 0))
        _npg(4, i, did)                      # NODE_DXLO := dir id
        _npg(5, i, (0x80 if pdy < 0 else 0)  # NODE_DXHI := sign byte
                   | (0x40 if pdx < 0 else 0))

    # SAME-AS-PARENT box flags (2026-07-17): DSGN bit 0 (right box) /
    # bit 1 (left box) set on child node c when box(c,side) is byte-
    # identical to the parent box the walk descended through — the
    # walk's NEAR-side check then serves the parent's has_gap interval
    # (still staged in zp_i_l/h) and skips the whole angle check; the
    # result is EXACT (same box, same viewer, same frame). The root has
    # no parent and keeps clear bits; far-side flags are baked but only
    # the near-side site tests them (interveners clobber the staging).
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
    print(f"  Seg headers: {n_segs} × {SEG_HDR_SIZE} = {n_segs * SEG_HDR_SIZE}")
    print(f"  VWH heights: {n_vwh} × {VWH_SIZE} = {n_vwh}")
    print(f"  Seg detail:  {n_segs} × {SEG_DTL_SIZE} = {len(rom_detail)}")
    print(f"  Recip/trig:  {rom_recip_size} (sin/cos {SINCOS_SIZE} + recip {RECIP_ENTRIES})")
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
                bbox_table[f * 0x400 + 0x200 + sb + i] = (v >> 8) & 0xFF
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
