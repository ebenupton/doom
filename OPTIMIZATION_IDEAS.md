# 6502 DOOM — optimization ideas & log

Running record of cycle/byte optimization opportunities, parked ideas, and a
log of what's been done. Every change must stay under the regression suite
(see `run_regression.py` / the "Regression" section).

## Regression invariants (must stay green after every change)
- `./beebasm -i bsp_render.asm` / `span_clip.asm` / `slope_div.asm` build clean (no ASSERT).
- `test_slope_div.py`, `test_bca.py` — angle module bit-exact (0 mismatches).
- `test_bsp_render.py` — renderer arithmetic primitives pass.
- `compare_traversal.py` — Python(angle) vs 6502: **10/10 ss-seq MATCH, fb diff=0 px**.
- `check_angle_calls.py` — 0 mismatch vs Python angle, 0 corruption.
- `compare_subsector.py` — 0 pixel/span-affecting divergences.

## Parked ideas
- (DONE 2026-06-16) ~~Unroll slope_div's 10-iteration loop~~. UNBLOCKED: the
  beebasm label problem is sidestepped with `BCC/BCS P%+N` relative branches
  (no label) inside a `FOR` loop. Done: bbox 1839 -> 1736.

## Open candidates (from profile_cycles.py, 10 reference frames)
- point_to_angle 12.4% (heavily optimised; abs/octant/lookup/combine).
- br_render_subsector 7.9%, br_seg_xform_vertex 7.1% (seg loop/transform glue).
- umul8 6.4% (near-optimal quarter-square; count frozen).
- tg_append_x 4.4% (span-list append; span_clip, risky).
- DEAD CODE to remove (bytes + removes $DC00/TA_LO latent hazard): the whole
  perspective-bbox subsystem is orphaned (0 calls) -- bv_corner_products,
  rot_pair_cached + rpc_* (RPC at $DC00 == angle TA_LO!), bv_proj_one,
  bv_corner_view, crx_* near-plane, bv_classify_sx, cp_* tables, plus dead
  helpers load_val/val_lo/val_hi/pa_base_lo in slope_div.asm. Spread across
  regions x/d/y/w + main; remove carefully under regression.
- More hot absolute scalars -> ZP: SEG_PROJ_BUF ($0A40-$0A4F, ~600 acc each)
  once more ZP is freed by demoting cold ZP scalars.

## Method: hot/cold ZP analysis
Goal: hot scalar values accessed outside ZP → move into ZP; shuffle cold ZP
scalars out to absolute to make room. `profile_mem.py` counts per-address
read+write accesses over representative frames and flags:
- hot absolute scalars ($0100+) = candidates to promote to ZP.
- cold ZP scalars ($00-$FF) = candidates to demote to absolute.

## Autonomous grind session (2026-06-16) — results
Frame mean (10 ref frames): **431,993 -> 416,919 cyc (-3.5%)**. bbox_check_angle
**2823 -> 1705 cyc/call (-39.6%)** cumulative. All steps under regression
(10/10 pixel-exact, bit-exact angle module). Commits:
- slope_div fast paths: 8-bit (den<256), den<128 (drop overflow), r-in-A,
  8+2 phase split, **unrolled (BCC/BCS P%+N, no labels)**.
- point_to_angle: abs writes divide operands directly; tantoangle hi-pointer
  reuse; drop zero base_lo add; afn/cy -> ZP.
- corner_phi: fold &4095 mask + 4096 wrap into one hi-byte pass.
- VATOX: fold +512 bias into base. bbox box-copy unrolled.
- Vertex-cache + visited bitmask: shift-loop -> table lookup.
- Hot per-vertex seg view-coords ($0A50..) -> ZP.
- Tooling: run_regression.py, profile_mem.py, profile_cycles.py (v3 = PC
  attributed to nearest JSR-target; the accurate one).

### State of remaining opportunities
- ZP promotion is **exhausted** for meaningful wins: the hot scalars are in ZP;
  remaining absolute scalars are <800 acc/10-frames (<0.1% each). Only $29/$2B/$FF
  are free (and $29/$2B are unreferenced reclaims).
- Frame is now ~28% bbox (optimised), ~30% seg transform (multiply-bound, count
  frozen), 8% rasteriser (fixed $A900 blob, no source), ~10% clipper (span_clip,
  tg_append already O(1)), rest node-setup/init.
- DEAD-CODE REMOVAL: **DONE** (2026-06-16). Removed the whole orphaned
  perspective-bbox cluster across main + x/y/z (whole regions) + d/w (partial)
  + all RPC_* defs; recip load moved out of the x-bin block; stale x/y/z bins
  deleted. bsp_render.bin 3830 -> 3531 B; $DC00/TA_LO latent hazard gone. Build
  clean (no dangling refs => cluster was fully self-contained), all green.

## Completed (earlier)
- angle bbox visibility: 2823 → 1868 cyc/call (-34%) via slope_div fast paths
  (den<256, den<128, r-in-A, 8+2 phase split), tantoangle/VATOX pointer folds,
  load_val inlining, a_fine register shifts, ZP placement of hot bbox vars.
