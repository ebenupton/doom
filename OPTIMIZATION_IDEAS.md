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

## Completed (this session)
- angle bbox visibility: 2823 → 1868 cyc/call (-34%) via slope_div fast paths
  (den<256, den<128, r-in-A, 8+2 phase split), tantoangle/VATOX pointer folds,
  load_val inlining, a_fine register shifts, ZP placement of hot bbox vars.
