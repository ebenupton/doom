# bsp_render.asm — overnight progress

## What's working

**Phase A-E: arithmetic foundation + transforms**, all unit-tested via
`test_bsp_render.py` against `fp.py` reference. 100+ test cases pass:

- `br_umul8` — u8 × u8 → u16
- `br_smul8` — s8 × s8 → s16
- `br_smul_s8_u8` — s8 × u8 → s16
- `br_smul_s8_s16` — s8 × s16 → s16 (low 16 of s24)
- `br_smul_s16_s16_s32` — s16 × s16 → s32 (full precision, sign tracked)
- `br_recip` — reciprocal lookup with 1-bit fractional averaging
- `br_frac_rot_term` — fractional rotation contribution
- `br_rot_int` — signed integer rotation (s16 × u8 → s16)
- `br_view_setup` — frac_vx, frac_vy for the frame
- `br_to_view` — world (s16 wx, wy) → view (s16 vx, vy in 8.8)
- `br_project_x_subpx` — view vx → screen sx (3 muls)
- `br_project_y` — height → screen sy (2 muls)

**BSP traversal** is iterative + stack-based (`$0A00`, 64 bytes) and
uses a real side test (`s16×s16 → s32` cross product) to walk in
front-to-back order. `test_bsp_walk.py` confirms 237/237 subsectors
visited; the side computation matches Python's `point_on_side`
exactly for all 236 nodes at the test position.

**Per-seg pipeline** (front-to-back):

1. Read seg header (v1/v2/lv1x/lv1y/ldx/ldy/flags).
2. Back-face cull via `dot = ldy*(px-lv1x) - ldx*(py-lv1y)` —
   matches Python (345/660 front-facing at the test position).
3. Read fh/ch from a packed 2-byte-per-seg table.
4. Transform v1, v2 with vertex cache lookup; compute reciprocal,
   project x once, project y twice (top + bot heights per seg).
5. Emit lines:
   - SOLID walls: top + bottom horizontals + L/R verticals,
     then `JSR span_mark_solid` to punch out the X range.
   - PORTAL walls: just verticals (skip front-sector horizontals).
   - SF_NOVT1/NOVT2 suppress verticals at BSP-internal splits.

**Vertex transform cache** at `$0C00` (8B × 467) with valid bitmap at
`$1B00` (59B). Caches rhi/rlo, sx, and a near-clip flag. Cleared at
the start of each frame. Saves the transform + reciprocal +
project_x for shared vertices: ~17% cycle reduction.

## End-to-end render

`test_bsp_render_frame.py` produces **~1000 pixels** of recognizable
DOOM geometry at the test position — distinct rooms, vertical wall
edges, a clean horizon, and receding floor lines. Solid walls
correctly occlude geometry behind them. 10 different positions
render cleanly in 1.7-2.2 M cycles each.

## Memory map (6502)

| Region | Address | Notes |
|---|---|---|
| Span pool / clipper code | $2000-$4737 | span_clip.asm |
| bsp_render code | $4800-$4F33 (~1.8K) | this module |
| Multiply tables | $5000-$57FF | quarter-square |
| Screen | $5800-$6BFF | mode 4 |
| ROM main (no VWH) | $6C00-$A4B0 | 15K |
| Rasteriser | $A900-$B55E | DCL backend |
| FH/CH table | $B600-$BB28 | 1320B |
| Recip table | $E000-$E483 | 1156B |
| VWH heights | $E484-$E939 | 1206B |
| Vertex cache | $0C00-$1AB7 | 8B × 467 |
| Vertex valid bitmap | $1B00-$1B3A | 59B |
| BSP stack | $0A00-$0A3F | 64B |
| Per-seg projection scratch | $0A40-$0A4F | 16B |
| Side test scratch | $0A50-$0A53 | 4B |
| Subsector visited bitmap | $0A80-$0BFF | 384B |

## Test files

- `test_bsp_render.py` — 5 primitive tests (all pass).
- `test_bsp_walk.py` — BSP traversal smoke test (237/237).
- `test_bsp_render_frame.py` — end-to-end render: ~1000 pixels of
  recognizable DOOM geometry. Stable across 10 test positions.
- `dump_framebuffer.py` — ASCII dump of the rendered frame.

## Not yet wired in

1. **Portal aperture tightening** (the "tighten" call in Python).
   Currently solid walls occlude correctly via `mark_solid`, but
   distant geometry visible through a portal opening doesn't get
   clipped to the aperture's Y range. Need to integrate
   `tighten_from_records` (which the s16 line clipper records into
   per-line buffers).
2. **Step edges at portals** (NEEDBT/NEEDBB flags). When the back
   ceiling is lower than the front, a horizontal "back ceiling"
   line should be drawn. Same for back floor higher than front.
3. **BBox-based subtree culling**. `fp_bbox_visible_fixed` in Python
   skips subtrees whose entire bbox is off-screen / fully occluded.
   No equivalent yet.
4. **VWH cache** — Python caches projected screen-Y per (vertex,
   height) pair. We currently re-project Y every seg even if a
   different seg already hit the same (v_idx, h) combination.
5. **Pixel-perfect comparison to Python reference**. We confirm
   geometry/walking matches Python at the building-block level
   (back-face count, side test) but haven't done a full
   line-by-line / pixel-by-pixel comparison.
