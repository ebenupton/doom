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

# ── Struct sizes (all powers of 2) ──────────────────────────────────────

VERTEX_SIZE  = 4     # shift 2:  s16 x, s16 y
NODE_SIZE    = 16    # shift 4:  s16 x,y,dx,dy + u16 children + pad
SSECTOR_SIZE = 4     # shift 2:  u8 count, u8 pad, u16 first_seg
SEG_HDR_SIZE = 12    # (idx<<3)+(idx<<2): v1,v2,lv1_x,lv1_y,ldx,ldy,flags,pad
SEG_DTL_SIZE = 24    # ×24 = (idx<<4)+(idx<<3): fh,ch + 8 VWH u16 + back heights + pad
VWH_SIZE     = 1     # identity: s8 height
# No separate linedef table — data inlined into seg headers

# ── Offsets within seg header ───────────────────────────────────────────

SH_V1 = 0; SH_V2 = 2             # u16 vertex indices
SH_LV1X = 4; SH_LV1Y = 6        # s16 linedef v1 (for back-face)
SH_LDX = 8; SH_LDY = 9          # s8 linedef delta
SH_FLAGS = 10                    # u8 flags
SH_PAD = 11

# ── Offsets within seg detail (24 bytes) ─────────────────────────────────

SD_FH = 0; SD_CH = 1             # s8 prescaled front floor/ceil
SD_BFH = 2; SD_BCH = 3           # s8 prescaled back floor/ceil (0 if solid)
SD_VWH_FT1 = 4; SD_VWH_FB1 = 6   # u16 front VWH
SD_VWH_FT2 = 8; SD_VWH_FB2 = 10
SD_VWH_BT1 = 12; SD_VWH_BB1 = 14 # u16 back VWH ($FFFF if solid)
SD_VWH_BT2 = 16; SD_VWH_BB2 = 18
# +20..23 padding


# ── Seg flags ───────────────────────────────────────────────────────────

SF_DIR    = 0x01   # direction (flip back-face sign)
SF_SOLID  = 0x02   # one-sided wall
SF_NEEDBT = 0x04   # back ceiling < front ceiling
SF_NEEDBB = 0x08   # back floor > front floor

# ── Vertex cache (RAM) ─────────────────────────────────────────────────

VCACHE_ENTRY = 8    # shift 3
VC_VX = 0; VC_VY = 2; VC_VYIDX = 4; VC_SX = 6  # all s16/u16

# ── VWH cache (RAM) ────────────────────────────────────────────────────

VWHCACHE_ENTRY = 2  # s16 screen_y (needs 16-bit for off-screen)


def build_packed(vertexes, fp_vertexes, nodes, fp_ssectors, fp_segs,
                 fp_segs_vwh, vwh_table, fp_sectors, linedefs, sidedefs,
                 prescale, map_center_x, map_center_y):
    """Build the byte arrays from parsed WAD data.

    Returns (rom_main, rom_detail, rom_recip, layout).
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
        struct.pack_into('<bbbbHHHHHHHHxxxx', rom_detail, o,
                         fh, ch, bfh, bch,
                         vft1, vfb1, vft2, vfb2,
                         vbt1, vbb1, vbt2, vbb2)

    # ── ROM Main: everything else ───────────────────────────────────────

    off_verts = 0
    off_nodes = off_verts + n_verts * VERTEX_SIZE
    off_ss = off_nodes + n_nodes * NODE_SIZE
    off_seg_hdr = off_ss + n_ss * SSECTOR_SIZE
    off_vwh = off_seg_hdr + n_segs * SEG_HDR_SIZE
    rom_main_size = off_vwh + n_vwh * VWH_SIZE

    rom_main = bytearray(rom_main_size)

    # Vertices
    for i, v in enumerate(fp_vertexes):
        struct.pack_into('<hh', rom_main, off_verts + i * VERTEX_SIZE, v[0], v[1])

    # BSP nodes (prescaled partition)
    for i, n in enumerate(nodes):
        o = off_nodes + i * NODE_SIZE
        px = (n[0] - map_center_x) // prescale
        py = (n[1] - map_center_y) // prescale
        pdx = n[2] // prescale
        pdy = n[3] // prescale
        struct.pack_into('<hhhhHH', rom_main, o, px, py, pdx, pdy, n[12], n[13])

    # Subsectors
    for i, ss in enumerate(fp_ssectors):
        struct.pack_into('<BxH', rom_main, off_ss + i * SSECTOR_SIZE, ss[0], ss[1])

    # Seg headers (with inlined linedef data)
    for i, svwh in enumerate(fp_segs_vwh):
        s = svwh[0]
        front_idx, back_idx = svwh[1], svwh[2]
        fh, ch = svwh[3], svwh[4]

        # Linedef data for back-face test
        ld = linedefs[s[3]]
        lv1 = fp_vertexes[ld[0]]
        lv2 = fp_vertexes[ld[1]]
        ldx = max(-128, min(127, lv2[0] - lv1[0]))
        ldy = max(-128, min(127, lv2[1] - lv1[1]))

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

        o = off_seg_hdr + i * SEG_HDR_SIZE
        struct.pack_into('<HHhhbbBx', rom_main, o,
                         s[0], s[1], lv1[0], lv1[1], ldx, ldy, flags)

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
    ram_size = vcache_size + vcache_valid + vwh_cache_size + vwh_valid

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

    return rom_main, rom_detail, rom_recip, layout


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

def clear_valid(ram, offset, n_bytes):
    for i in range(n_bytes):
        ram[offset + i] = 0

def is_valid(ram, offset, idx):
    return (ram[offset + (idx >> 3)] >> (idx & 7)) & 1

def set_valid(ram, offset, idx):
    ram[offset + (idx >> 3)] |= (1 << (idx & 7))
