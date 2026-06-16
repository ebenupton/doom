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

## Option 2b (angle-space SEG, no rotation) — DE-RISKED, ready to implement
Status (2026-06-16): math fully validated; bit-exact reference module built.
- `angle_seg.py` (+ `test_angle_seg.py`): the reference. seg_2b() returns per
  endpoint (sx, depth); proj_y(h,depth,vz) projects any height. Integer math
  identical to the planned 6502. X 99.6% within1col vs true; Y 0.60px/97.3%
  within2px (matches project_y's faithfulness, and handles clamped columns).
- Validators: validate_angle_seg.py (X), validate_2b.py (Y float, exact),
  validate_2b_fp.py (Y fixed-point).
- Design decisions locked:
  * X: world angle (point_to_angle) - viewangle, clamp +/-ANG45, VATOX. Back-face
    is free from the angle span. (All reuse the existing 6502 angle module.)
  * Y/depth: per-seg c = signed perp dist in s.4 = ((wy1-py)*ldx-(wx1-px)*ldy)*rlen>>12,
    where rlen=(1<<16)/len is a STATIC per-seg ROM constant; na = seg normal
    fine-angle, also STATIC ROM. depth = (c*COS[phi])/COS[a_fine-phi-na]
    (sign-normalise, rounded). yt/yb = HALF_H - (h-vz)*FOCAL*16/depth.
  * COS table: 256 entries, index = (fineangle>>4)&255, s16 cos*256 (512 B).
    Place COS_LO/COS_HI at $F800/$F900 (free $F701-$FA0F). cos resolution is not
    the limiter; 256 suffices.

### Remaining work (the 6502 rewrite proper -- large, do supervised)
1. asm: COS table + cos_fine. **DONE** ($E949, COS_TAB $F800, 256-entry s8
   cos*127). Unit-tested test_cos_fine.py 4096/0.
2. asm: seg_depth. **DONE** ($E94C) depth=c*cos(phi)/cos(den) via umul8 +
   u24/u8 rounded restoring divide, sign-normalise, cden==0/depth<=0 cull
   (carry=cull), u16 clamp. Unit-tested test_seg_depth.py 47520/0.
   asm: proj_yd. **DONE** ($E94F) yt=HALF_H-(hd<<11)/depth via u24/u16 rounded
   restoring divide (17th-bit handling for depth>32768), sign from hd.
   Unit-tested test_proj_yd.py 139008/0 (exhaustive over depth 11..65535, all s8 hd).
   NOTE: angle_seg._rdiv made symmetric (round |.| half up) so the 6502's
   |num|-then-sign path is exact; seg_depth unaffected (neg-num culled there).
   STILL TODO: seg_project orchestration -- point_to_angle + phi clamp + VATOX
   column (sx) + seg_depth; and the per-seg c = cross*rlen (2 muls + recip mul).
   point_to_angle/VATOX already exist in the bbox module.
3. asm: per-seg c (cross via 2 muls * rlen recip). proj_yd DONE (see above).
4. ROM tables: per-seg na + rlen (precompute in wad_packed, like the bbox table).
5. Integrate into the seg loop replacing rotation/project_x/project_y; the
   clip/draw/aperture interface is unchanged (feed sx/yt/yb as today). Two-sided
   + aperture heights all project via proj_y(h,depth).
6. Mirror in Python packed_render_seg behind _USE_ANGLE_SEG (global already
   added, default off) so the regression is pixel-exact 6502-2b vs Python-2b
   (add to run_regression), exactly like the bbox rollout. compare_traversal
   stays green (both sides use the 6502 seg processor).
Net per vertex: removes the 4-mul rotation + project_x + the separate back-face
test; adds c (per seg) + depth (mul+divide via cos tables) -- fewer muls, more
tables/divides (the DOOM trade), and X comes out more accurate.

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

### Final state (end of session)
Frame mean **431,993 -> 416,287 (-3.6%)**; bbox **2823 -> 1705 (-39.6%)**;
bsp_render.bin 3830 -> 3546 B; dead perspective-bbox cluster removed; $DC00/
TA_LO hazard gone. Verified pixel-exact across 112 positions (sweep_verify).
Everything pushed, all regression green.

### Remaining opportunities (all small or invasive — need direction)
- seg-header per-seg copy is ~1.5% of frame, but direct-from-ROM reads cost
  +2cyc/access and most fields are read-once or already ZP, so the realistic
  net is only ~0.15-0.3% and it rewrites back_face_test's 5 paths (risky).
- udiv16_8 (projection divide) ALREADY has the unrolled leading-zero-skip
  preamble; umul8 is optimal quarter-square; clipper tg_append is O(1) — all
  at their floor.
- Bigger swings would need re-architecture (e.g. full angle-space SEG pipeline
  to cut the 8 muls/vertex) or improving the vertex-cache hit rate — both are
  scope/risk that warrant supervision.
- Hot scalars are all in ZP now; remaining absolute scalars are <0.1% each and
  ZP is packed (swaps need cold-var demotion, often harness-coupled).

### State of remaining opportunities (mid-session notes)
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
