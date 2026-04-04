"""Packed WAD data in flat byte arrays for 8-bit processor simulation.

Three arrays:
  tables  - sin/cos + reciprocal tables (ROM)
  wad     - vertices, BSP nodes, subsectors, segs, VWH heights (ROM)
  ram     - vertex cache, VWH cache, valid bitmaps (RAM, reset per frame)

All multi-byte values are little-endian (6502 native).
Struct sizes are powers of 2 for fast index→offset shifts.

Intermediates: screen coordinates can exceed 8-bit for off-screen
geometry (e.g., sx = 128 + 128*127 = 16384). These are handled as
16-bit signed during projection, clamped only at draw time.
"""

import struct

# ── Struct sizes (all powers of 2) ──────────────────────────────────────

VERTEX_SIZE  = 4     # shift 2:  s16 x, s16 y
NODE_SIZE    = 12    # shift 3+: s16 x,y,dx,dy + u16 children (not power of 2, use 16)
NODE_SIZE    = 16    # pad to 16 for shift 4
SSECTOR_SIZE = 4     # shift 2:  u8 count, u8 pad, u16 first_seg
SEG_SIZE     = 32    # shift 5:  see below
VWH_SIZE     = 1     # identity: s8 height

# ── Offsets within structs ──────────────────────────────────────────────

# Vertex (+0: s16 x, +2: s16 y)
V_X = 0; V_Y = 2

# BSP Node
N_X = 0; N_Y = 2; N_DX = 4; N_DY = 6   # s16 partition
N_RIGHT = 8; N_LEFT = 10                  # u16 children
# +12..15 padding

# Subsector
SS_COUNT = 0; SS_FIRST = 2               # u8 count, u16 first_seg

# Seg
S_V1 = 0; S_V2 = 2                       # u16 vertex indices
S_LV1X = 4; S_LV1Y = 6                   # s16 linedef v1 (for back-face)
S_LDX = 8; S_LDY = 9                     # s8 linedef delta (fits 8-bit)
S_FLAGS = 10                              # u8 flags
S_FH = 11; S_CH = 12                     # s8 prescaled heights
S_PAD = 13
S_VWH_FT1 = 14; S_VWH_FB1 = 16          # u16 VWH indices
S_VWH_FT2 = 18; S_VWH_FB2 = 20
S_VWH_BT1 = 22; S_VWH_BB1 = 24
S_VWH_BT2 = 26; S_VWH_BB2 = 28
# +30..31 padding

# Seg flags
SF_DIR    = 0x01   # direction (flip back-face sign)
SF_SOLID  = 0x02   # one-sided wall
SF_NEEDBT = 0x04   # back ceiling < front ceiling
SF_NEEDBB = 0x08   # back floor > front floor

# ── RAM layout ──────────────────────────────────────────────────────────

VCACHE_ENTRY = 8    # shift 3: s16 vx, s16 vy, u16 vy_idx, s16 sx
VC_VX = 0; VC_VY = 2; VC_VYIDX = 4; VC_SX = 6

VWHCACHE_ENTRY = 2  # s16 screen_y (needs 16-bit for off-screen)


def build_packed(vertexes, fp_vertexes, nodes, fp_ssectors, fp_segs,
                 fp_segs_vwh, vwh_table, fp_sectors, linedefs, sidedefs,
                 prescale, map_center_x, map_center_y):
    """Build the three byte arrays from parsed WAD data.

    Returns (tables, wad, ram_size, layout) where layout is a dict
    of base offsets within wad.
    """

    n_verts = len(vertexes)
    n_nodes = len(nodes)
    n_ss = len(fp_ssectors)
    n_segs = len(fp_segs)
    n_vwh = len(vwh_table)

    # ── WAD array ───────────────────────────────────────────────────────

    # Section offsets
    off_verts = 0
    off_nodes = off_verts + n_verts * VERTEX_SIZE
    off_ss = off_nodes + n_nodes * NODE_SIZE
    off_segs = off_ss + n_ss * SSECTOR_SIZE
    off_vwh = off_segs + n_segs * SEG_SIZE
    wad_size = off_vwh + n_vwh * VWH_SIZE

    wad = bytearray(wad_size)

    # Pack vertices (prescaled, 16-bit signed)
    for i, v in enumerate(fp_vertexes):
        o = off_verts + i * VERTEX_SIZE
        struct.pack_into('<hh', wad, o, v[0], v[1])

    # Pack BSP nodes (16-bit partition + children, padded to 16)
    for i, n in enumerate(nodes):
        o = off_nodes + i * NODE_SIZE
        # Prescale partition for 8-bit point_on_side
        px = (n[0] - map_center_x) // prescale
        py = (n[1] - map_center_y) // prescale
        pdx = n[2] // prescale
        pdy = n[3] // prescale
        struct.pack_into('<hhhhHH', wad, o,
                         px, py, pdx, pdy, n[12], n[13])

    # Pack subsectors
    for i, ss in enumerate(fp_ssectors):
        o = off_ss + i * SSECTOR_SIZE
        struct.pack_into('<BxH', wad, o, ss[0], ss[1])

    # Pack segs with pre-baked linedef data, flags, and VWH indices
    for i, svwh in enumerate(fp_segs_vwh):
        s = svwh[0]
        front_idx, back_idx = svwh[1], svwh[2]
        fh, ch = svwh[3], svwh[4]

        # Linedef data for back-face test
        ld = linedefs[s[3]]
        lv1 = fp_vertexes[ld[0]]
        lv2 = fp_vertexes[ld[1]]
        ldx = lv2[0] - lv1[0]
        ldy = lv2[1] - lv1[1]

        # Clamp ldx/ldy to signed 8-bit
        ldx = max(-128, min(127, ldx))
        ldy = max(-128, min(127, ldy))

        # Flags
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

        # VWH indices
        vft1, vfb1 = svwh[5], svwh[6]
        vft2, vfb2 = svwh[7], svwh[8]
        vbt1, vbb1 = svwh[9], svwh[10]
        vbt2, vbb2 = svwh[11], svwh[12]
        # Use 0xFFFF for invalid back-sector VWH
        if vbt1 == -1: vbt1 = vbb1 = vbt2 = vbb2 = 0xFFFF

        o = off_segs + i * SEG_SIZE
        struct.pack_into('<HHhhbbbbx', wad, o,
                         s[0], s[1],          # v1, v2
                         lv1[0], lv1[1],      # lv1 x,y (16-bit)
                         ldx, ldy,            # 8-bit
                         flags,
                         fh)
        struct.pack_into('<b', wad, o + S_CH, ch)
        struct.pack_into('<HHHHHHHH', wad, o + S_VWH_FT1,
                         vft1, vfb1, vft2, vfb2,
                         vbt1, vbb1, vbt2, vbb2)

    # Pack VWH heights (1 byte each)
    for i, (vi, h) in enumerate(vwh_table):
        wad[off_vwh + i] = h & 0xFF

    # ── RAM sizing ──────────────────────────────────────────────────────

    vcache_size = n_verts * VCACHE_ENTRY
    vcache_valid_bytes = (n_verts + 7) // 8
    vwh_cache_size = n_vwh * VWHCACHE_ENTRY
    vwh_valid_bytes = (n_vwh + 7) // 8
    ram_size = vcache_size + vcache_valid_bytes + vwh_cache_size + vwh_valid_bytes

    layout = {
        'n_verts': n_verts,
        'n_nodes': n_nodes,
        'n_ss': n_ss,
        'n_segs': n_segs,
        'n_vwh': n_vwh,
        'off_verts': off_verts,
        'off_nodes': off_nodes,
        'off_ss': off_ss,
        'off_segs': off_segs,
        'off_vwh': off_vwh,
        'wad_size': wad_size,
        # RAM offsets
        'ram_vcache': 0,
        'ram_vcache_valid': vcache_size,
        'ram_vwh_cache': vcache_size + vcache_valid_bytes,
        'ram_vwh_valid': vcache_size + vcache_valid_bytes + vwh_cache_size,
        'ram_size': ram_size,
    }

    print(f"Packed WAD: {wad_size} bytes ROM, {ram_size} bytes RAM")
    print(f"  Vertices: {n_verts} × {VERTEX_SIZE} = {n_verts * VERTEX_SIZE}")
    print(f"  Nodes:    {n_nodes} × {NODE_SIZE} = {n_nodes * NODE_SIZE}")
    print(f"  SSectors: {n_ss} × {SSECTOR_SIZE} = {n_ss * SSECTOR_SIZE}")
    print(f"  Segs:     {n_segs} × {SEG_SIZE} = {n_segs * SEG_SIZE}")
    print(f"  VWH:      {n_vwh} × {VWH_SIZE} = {n_vwh * VWH_SIZE}")
    print(f"  RAM:      vcache={vcache_size} + valid={vcache_valid_bytes} + "
          f"vwh={vwh_cache_size} + valid={vwh_valid_bytes} = {ram_size}")

    return wad, layout


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
    """Clear n_bytes of valid bitmap (fast: memset equivalent)."""
    for i in range(n_bytes):
        ram[offset + i] = 0

def is_valid(ram, offset, idx):
    """Check if bit idx is set in bitmap at offset."""
    return (ram[offset + (idx >> 3)] >> (idx & 7)) & 1

def set_valid(ram, offset, idx):
    """Set bit idx in bitmap at offset."""
    ram[offset + (idx >> 3)] |= (1 << (idx & 7))
