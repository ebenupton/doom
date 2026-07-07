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

VERTEX_SIZE  = 4     # shift 2:  s16 x, s16 y
NODE_SIZE    = 16    # (legacy AoS reader stride — packed data is now SoA)
SSECTOR_SIZE = 4     # (legacy)
# SoA pages at the head of rom_main (see build_packed): 13 node pages
# (8 field bytes + 4 children bytes + type) then 3 subsector pages.
NODE_SOA_PAGES = 13
SS_SOA_PAGES   = 3
NODE_SOA_SIZE  = (NODE_SOA_PAGES + SS_SOA_PAGES) * 256
NT_GENERAL, NT_DX0, NT_DY0 = 0, 1, 2
SEG_HDR_SIZE = 12    # (idx<<3)+(idx<<2): v1,v2,lv1_x,lv1_y,ldx,ldy,flags,pad
SEG_DTL_SIZE = 20    # ×20 = (idx<<4)+(idx<<2): fh,ch + 8 VWH u16 + back heights
VWH_SIZE     = 1     # identity: s8 height
# No separate linedef table — data inlined into seg headers

# ── Offsets within seg header ───────────────────────────────────────────

SH_V1 = 0; SH_V2 = 2             # u16 vertex indices
SH_LV1X = 4; SH_LV1Y = 6        # s16 linedef v1 (for back-face)
SH_LDX = 8; SH_LDY = 9          # s8 linedef delta
SH_FLAGS = 10                    # u8 flags
SH_L = 11                        # u8 round(seg length) for option-2b (was pad)
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

SF_DIR    = 0x01   # direction (flip back-face sign)
SF_SOLID  = 0x02   # one-sided wall
SF_NEEDBT = 0x04   # back ceiling < front ceiling
SF_NEEDBB = 0x08   # back floor > front floor
SF_NOVT1  = 0x10   # suppress vertical at v1 (BSP-internal split point)
SF_NOVT2  = 0x20   # suppress vertical at v2 (BSP-internal split point)
SF_APEDGE1 = 0x40  # emit aperture edge at v1 when NOVT1 suppresses the vertical
SF_APEDGE2 = 0x80  # emit aperture edge at v2 when NOVT2 suppresses the vertical

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
    #   pg 8-11 node children right_lo,right_hi,left_lo,left_hi
    #   pg 12   node type: 0 general, 1 dx==0 (vertical), 2 dy==0
    #   pg 13-15 subsector count, first_lo, first_hi
    # Everything else follows at NODE_SOA_SIZE.
    assert n_nodes <= 256 and n_ss <= 256

    off_nodes = 0
    off_ss = NODE_SOA_PAGES * 256
    off_verts = NODE_SOA_SIZE
    off_seg_hdr = off_verts + n_verts * VERTEX_SIZE
    off_vwh = off_seg_hdr + n_segs * SEG_HDR_SIZE
    rom_main_size = off_vwh + n_vwh * VWH_SIZE

    rom_main = bytearray(rom_main_size)

    # Vertices
    for i, v in enumerate(fp_vertexes):
        struct.pack_into('<hh', rom_main, off_verts + i * VERTEX_SIZE, v[0], v[1])

    # BSP nodes — point_on_side uses raw s16 values so the prescale rounding
    # doesn't lose a weak axis (nodes where, e.g., raw dx=0 dy=8 would
    # otherwise both truncate to 0).  nx/ny are stored relative to
    # map_center so they stay in s16 range. SoA pages (see layout above),
    # with the partition type baked so the 6502 skips the axis test AND
    # the unused field loads (73% of E1M1 nodes are axis-aligned).
    def _npg(pg, i, v):
        rom_main[off_nodes + pg * 256 + i] = v & 0xFF
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
        _npg(4, i, raw_dx); _npg(5, i, raw_dx >> 8)
        _npg(6, i, raw_dy); _npg(7, i, raw_dy >> 8)
        _npg(8, i, n[12]);  _npg(9, i, n[12] >> 8)
        _npg(10, i, n[13]); _npg(11, i, n[13] >> 8)
        _npg(12, i, NT_DX0 if raw_dx == 0 else (NT_DY0 if raw_dy == 0 else NT_GENERAL))

    # Subsectors (SoA pages 13-15: count, first_lo, first_hi)
    for i, ss in enumerate(fp_ssectors):
        rom_main[off_ss + i] = ss[0] & 0xFF
        rom_main[off_ss + 256 + i] = ss[1] & 0xFF
        rom_main[off_ss + 512 + i] = (ss[1] >> 8) & 0xFF

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
        if s[4] == 1: flags |= SF_DIR
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
        struct.pack_into('<HHhhbbBB', rom_main, o,
                         s[0], s[1], lv1[0], lv1[1], ldx, ldy, flags, seg_L)

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

    # VWH heights
    for i, (vi, h) in enumerate(vwh_table):
        rom_main[off_vwh + i] = h & 0xFF

    # ── ROM Recip: sin/cos + reciprocal tables ────────────────────────────

    from fp import (_SIN_QUADRANT, _SIN_UNITY, _RECIP_X_HI, _RECIP_X_LO,
                    RECIP_TABLE_SIZE)

    # Layout: sin_mag[64] + sin_unity[64] + recip_hi[513] + recip_lo[513]
    SINCOS_SIZE = 64 + 64   # magnitude + unity flags, one quadrant
    RECIP_ENTRIES = RECIP_TABLE_SIZE + 1  # +1 guard for averaging
    rom_recip_size = SINCOS_SIZE + RECIP_ENTRIES * 2

    rom_recip = bytearray(rom_recip_size)
    off_sin_mag = 0
    off_sin_unity = 64
    off_recip_hi = SINCOS_SIZE
    off_recip_lo = SINCOS_SIZE + RECIP_ENTRIES

    for j in range(64):
        rom_recip[off_sin_mag + j] = _SIN_QUADRANT[j] & 0xFF
        rom_recip[off_sin_unity + j] = 1 if _SIN_UNITY[j] else 0

    for j in range(RECIP_ENTRIES):
        rom_recip[off_recip_hi + j] = _RECIP_X_HI[j] & 0xFF
        rom_recip[off_recip_lo + j] = _RECIP_X_LO[j] & 0xFF

    # ── RAM sizing ──────────────────────────────────────────────────────

    vcache_size = n_verts * VCACHE_ENTRY
    vcache_valid = (n_verts + 7) // 8
    vwh_cache_size = n_vwh * VWHCACHE_ENTRY
    vwh_valid = (n_vwh + 7) // 8
    spans_offset = vcache_size + vcache_valid + vwh_cache_size + vwh_valid
    ram_size = spans_offset + SPAN_TOTAL

    layout = {
        'n_verts': n_verts, 'n_nodes': n_nodes, 'n_ss': n_ss,
        'n_segs': n_segs, 'n_vwh': n_vwh,
        'off_verts': off_verts, 'off_nodes': off_nodes,
        'off_ss': off_ss, 'off_seg_hdr': off_seg_hdr,
        'off_vwh': off_vwh,
        'rom_main_size': rom_main_size,
        'rom_detail_size': len(rom_detail),
        'rom_recip_size': rom_recip_size,
        'off_sin_mag': off_sin_mag, 'off_sin_unity': off_sin_unity,
        'off_recip_hi': off_recip_hi, 'off_recip_lo': off_recip_lo,
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
    print(f"  Vertices:    {n_verts} × {VERTEX_SIZE} = {n_verts * VERTEX_SIZE}")
    print(f"  Nodes:       {n_nodes} × {NODE_SIZE} = {n_nodes * NODE_SIZE}")
    print(f"  Subsectors:  {n_ss} × {SSECTOR_SIZE} = {n_ss * SSECTOR_SIZE}")
    print(f"  Seg headers: {n_segs} × {SEG_HDR_SIZE} = {n_segs * SEG_HDR_SIZE}")
    print(f"  VWH heights: {n_vwh} × {VWH_SIZE} = {n_vwh}")
    print(f"  Seg detail:  {n_segs} × {SEG_DTL_SIZE} = {len(rom_detail)}")
    print(f"  Recip/trig:  {rom_recip_size} (sin/cos {SINCOS_SIZE} + recip {RECIP_ENTRIES*2})")
    print(f"  RAM:         {ram_size}")

    # Build prescaled bbox table (separate from rom_main so NODE_SIZE stays 16).
    # 16 bytes per node: right side (top,bot,left,right as s16) then left side.
    bbox_table = bytearray(n_nodes * 16)
    for i, n in enumerate(nodes):
        o = i * 16
        for side_base in (4, 8):  # right bbox, left bbox
            raw_top   = n[side_base]
            raw_bot   = n[side_base + 1]
            raw_left  = n[side_base + 2]
            raw_right = n[side_base + 3]
            p_top   = (raw_top   - map_center_y) // prescale
            p_bot   = (raw_bot   - map_center_y) // prescale
            p_left  = (raw_left  - map_center_x) // prescale
            p_right = (raw_right - map_center_x) // prescale
            side_off = o + (side_base - 4) * 2  # +0 for right, +8 for left
            struct.pack_into('<hhhh', bbox_table, side_off,
                             p_top, p_bot, p_left, p_right)
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
