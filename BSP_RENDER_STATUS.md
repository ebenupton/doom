# bsp_render.asm — overnight progress

## What's working

**Phase A-E: arithmetic foundation + transforms**, all unit-tested via
`test_bsp_render.py` against `fp.py` reference. 100+ test cases pass:

- `br_umul8` — u8 × u8 → u16 (wraps span_clip's `umul8`)
- `br_smul8` — s8 × s8 → s16
- `br_smul_s8_u8` — s8 × u8 → s16
- `br_recip` — reciprocal lookup with 1-bit fractional averaging
- `br_frac_rot_term` — fractional rotation contribution
- `br_rot_int` — signed integer rotation (s16 × u8 → s16)
- `br_view_setup` — frac_vx, frac_vy for the frame
- `br_to_view` — world (s16 wx, wy) → view (s16 vx, vy in 8.8)
- `br_project_x_subpx` — view vx → screen sx (3 muls)
- `br_project_y` — height → screen sy (2 muls)

**BSP traversal** works via `test_bsp_walk.py` — visits all 237
subsectors of the test WAD using an iterative stack-based walk
(no recursion, 64-byte stack at $0A00). Side test is currently a
stub (always picks front), so traversal order isn't geometrically
correct — but every leaf is reached.

## End-to-end render works

`test_bsp_render_frame.py` produces **151 pixels** in the
framebuffer — the BSP walks all 237 subsectors and each emits a
hardcoded horizontal line (50, 128) → (200, 128) via the existing
s16 clipper / DCL / rasteriser pipeline. All 237 visits succeed
(no stack imbalance). The proof-of-concept end-to-end pipeline is
working.

### Bug found and fixed

The earlier "stack underflow" was actually a memory-overlap bug:
the WAD ROM main was loaded at `$9000` (15 KB), which extended to
`$CD66` and OVERWROTE the rasteriser at `$A900-$B55E`. The
rasteriser code became garbage; calling DCL hit a corrupted
instruction at `$A925` ($00 = BRK), which trampolined to the BRK
vector ($0000) and looped.

The fix: load ROM main at `$6C00` (excluding VWH, ending at
`$A4B0`, safely below the rasteriser), and put VWH separately at
`$E484` (after the recip table). ROM detail goes at `$B600` for
now (overlaps with recip but isn't read by the current stub
render_subsector — needs proper relocation when seg-detail
processing comes online).

## Test files

- `test_bsp_render.py` — 5 primitive tests (all pass).
- `test_bsp_walk.py` — BSP traversal smoke test (passes: 237/237).
- `test_bsp_render_frame.py` — end-to-end render: 151 pixels for
  the test position. Proof that BSP walk + DCL pipeline works.

## Next steps

1. Wire in real seg processing in `br_render_subsector`:
   read each seg's vertex indices, call `br_to_view` to transform
   them, project to screen X via `br_project_x_subpx`, emit the
   line via `JSR SC_DRAW_S16` (`$201E`).
2. Project Y values from VWH heights via `br_project_y`.
3. Emit four lines per seg (top, bottom, left vertical, right
   vertical) per the seg flags.
4. Add proper back-face test (s16 cross product).
5. Add proper side test in BSP traversal (currently always picks
   the right child first — geometry will be wrong until this is
   fixed).
6. Add vertex caching with valid-bitmap (`ram_vcache` /
   `ram_vcache_valid`).
7. Compare framebuffer to Python reference — debug divergences.

The hardest part (stack/memory bug + arithmetic primitives + BSP
walk) is now done.
