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
   asm: seg_c. **DONE** ($E952) c = (cross<<4)/L via 2 signed u16xu8 products
   (4 umul8) into a signed-24 cross, then u24/u8 rounded divide by L (u8 ROM).
   Unit-tested test_seg_c.py 23760/0.
   asm: seg_project. **DONE** ($E955) one endpoint -> (sx, depth): corner_phi
   (point_to_angle + a_fine-psi) + clamp +/-512 + VATOX column + seg_depth.
   c stashed at $42/$43 across point_to_angle (reuses $30), restored before
   seg_depth so $30=c survives both endpoints. Unit-tested test_seg_project.py
   47520/0 (full per-seg flow: seg_c then both endpoints).
   MEMORY MAP: angle code grew past $EF00; relocated TA_HI $EF00->$F200,
   VATOX $F300->$F601, COS $F800->$FB00 (bca stays $FA10). ASSERT end<=TA_HI.
   ALL FIVE 2b primitives now bit-exact: cos_fine, seg_depth, proj_yd, seg_c,
   seg_project. bsp_render_ang.bin = 2139 B.
3. (done -- see seg_c above)
4. ROM tables: per-seg na + L (precompute in wad_packed, like the bbox table). TODO
   - na = seg normal fine-angle (s16/u16), L = round(len) (u8, <=89). 3 B/seg x
     660 = 1980 B. Add as a separate bytearray returned from build_packed (like
     bbox_table) and thread through callers (bsp_render_6502 loads it to 6502 RAM;
     doom_wireframe holds it). Both are pure functions of ldx/ldy already in the
     seg header, so seg_consts(ldx,ldy) computes them -- no new WAD data.
5. INTEGRATION (the large, supervised step -- NOT a drop-in). The 2b path
   restructures the front half of packed_render_seg / fp_render_seg / the 6502
   seg loop. It is NOT a projection swap; these change:
   - REMOVE per-vertex fp_to_view rotation (4 muls), fp_near_clip (view-space),
     fp_recip + fp_project_x. ADD seg_c (once/seg) + seg_project (per endpoint).
   - vcache contents change: cache per-vertex (wa or phi, sx, and a per-(vertex,
     seg) depth) instead of view coords evx/evy. depth depends on the seg (c,na),
     so it is NOT a pure per-vertex value -- only sx/wa cache per vertex; depth
     recomputes per seg endpoint (cheap: one seg_depth).
   - FOV: angle path clamps phi to +/-ANG45 (no view-space near clip). Segs
     crossing behind the player: point_to_angle handles all quadrants; the phi
     clamp + back-face (dot<=0) cover culling. Verify vs near-clip cases.
   - Y: every height (ch,fh, two-sided bh/bt, aperture APV) projects via
     proj_y(h, depth) = HALF_H - (h-vz)*FOCAL*16/depth  (the proj_yd divide).
     Replaces fp_project_y(hd, recip). vwh-cache keys on depth now.
   - Do Python first behind _USE_ANGLE_SEG (global exists, default off) so the
     default path stays green; then 6502 (bsp_render.asm br_render_subsector /
     br_seg_xform_vertex / br_project_*); then a new pixel-exact 6502-2b vs
     Python-2b check in run_regression. compare_traversal must stay green.
   PYTHON SIDE: **DONE** (2026-06-16). packed_render_seg branches on
   _USE_ANGLE_SEG: 2b computes (sx,depth) via angle_seg.seg_2b (== the 6502
   seg_c+seg_project), Y via _AS.proj_y(h,depth,vz) (== proj_yd); vwh/vcache
   fast-paths bypassed (ey!=evy) since depth is per-seg-endpoint. Recip lines
   gated. Harness must set _VIEW_AB=ab per frame. Flag-OFF path byte-identical
   (full regression green). VALIDATED flag-ON across 10 ref frames:
   - in-FOV segs match the fp perspective within ~2-3 col; the offset is the
     fp recip/rotation QUANTISATION error -- 2b matches ideal-perspective
     columns exactly (VATOX centre == 128+128*tan(phi)) and is MORE accurate
     than the fp path (earlier: 99.4% vs 42.6% within 1col of true).
   - all culls (seg_2b->None) are segs the fp path ALSO discards (off-screen
     or back-face) -- NO visible wall dropped.
   - FOV-crossing endpoints clamp to the FOV-edge column (DOOM-correct;
     clamped-endpoint Y validated 0.000px in validate_2b).
   So the 2b frame legitimately differs from the old perspective frame (~2px
   on every wall, 2b being the more accurate one) -- this is the projection
   change, not a bug. The binding contract is 6502-2b == Python-2b (pending
   the 6502 seg-loop integration).
   REMAINING: 6502 seg-loop integration + na/L ROM table + pixel-exact
   6502-2b vs Python-2b regression.
   ROM L: **DONE** packed into the seg-header pad byte (offset 11, SH_L);
   na recomputed on-6502 via point_to_angle(-ldy,ldx).
   6502 SEG LOOP: **scaffolded + per-seg bit-exact** (2026-06-16).
   - br_seg_project_2b ($481E, bsp_render.asm): projects the seg's v1/v2 via
     seg_c + seg_project + proj_yd (8 Y projections), writing the SAME sx1/sx2 +
     SEG_PROJ_BUF sy slots as the perspective xform, Y_BIAS-added. Saves/restores
     the 5 traversal ZP bytes the angle module clobbers ($42/$43 rom_nodes,
     $4C/$4D root_node, $4E bsp_stack_sp) on the stack.
   - Wired into the seg loop behind `_USE_ANGLE_SEG_6502` (beebasm IF, DEFAULT
     FALSE so the perspective bin + full regression stay green). Build the 2b
     bin by flipping the flag TRUE.
   - BspRender6502 now also loads the COS table ($FB00) for seg_depth.
   - VALIDATED (frame 1024,-3500,64 etc): the per-seg projection is BIT-EXACT
     6502-2b vs Python-2b -- front (sx1,sx2,ft1,fb1,ft2,fb2) 0 mismatches over
     all segs; portal step bt 0 mismatches. (Captured per-si by stepping the
     6502 frame and via doom_wireframe _seg2b_debug/_seg2b_debug_bt.)
   - RECONCILED (2026-06-16): the 6502-2b renderer IS pixel-exact. The earlier
     ~50-150px "diff" was a render_python rasterisation artifact (it draws lines
     to a pygame surface, not via the 6502 clipper) -- the SAME ±1 diff appears
     for the PERSPECTIVE path (render_python vs render_6502 = 54px @
     (1024,-3500,64)), so it is a harness artifact, NOT a 2b error. On the real
     6502 framebuffer the 2b path is exact:
       * compare_traversal with the 2b bin: 10/10 ss-seq MATCH, fb diff = 0 px
         (full-6502 == Python-traversal + 6502-2b-seg). trace_compare.setup_wad
         now loads the COS table ($FB00).
       * per-seg projection (sx, ft, fb, bt, bb) BIT-EXACT 6502-2b vs Python-2b
         (0 mismatches over all segs).
   - *** DECISION: 2b stays flag-OFF; perspective is the default. ***
     2b is CORRECT but 2.05x SLOWER: frame mean 851,410 cyc vs perspective
     416,331 (10 ref frames). The angle path trades the 8-mul/vertex rotation
     for per-vertex DIVIDES -- point_to_angle (slope_div), seg_depth (mul +
     u24/u8 divide) and 8x proj_yd (u24/u16 divides) per seg -- which cost far
     more than the perspective recip-TABLE + multiply (+ VWH proj cache). DOOM
     itself avoids per-vertex divides via a per-column interpolated scale; this
     port does full per-vertex divides. Making 2b competitive needs: depth-recip
     via TABLE then multiply for proj_yd (earlier ~1.1px, too lossy as-is),
     per-vertex depth-recip caching, and removing the slope_div in
     point_to_angle. Until then 2b is a validated, parked alternative kept
     in-tree behind _USE_ANGLE_SEG_6502; the angle math primitives stay for it.

### CORRECTION (2026-06-16): divide-free 2b will NOT beat perspective
The "floor 354k" below was a FALSE SIGNAL. Stubbing seg_depth/proj_yd to
constants collapses every wall (depth/Y constant -> clipped), so the stubbed
frame draws only 2,211 lit px vs the real 2b's 13,989 -- the 354k excluded
~84% of the raster/clip/tighten work. The REAL divide-free cost = full 2b
(851k) minus only the divide time (proj_yd ~127k + seg_depth ~29k ≈ 156k)
plus the replacement recip+mul, i.e. ~700-750k -- still ~1.8x perspective
(416k). Root cause is structural: 2b computes X (point_to_angle/atan2) and Y
(depth) SEPARATELY per vertex, while perspective's single 4-mul rotation
yields BOTH vx and vy, and its recip is a table. Eliminating divides can't
close a gap that is mostly the redundant per-vertex angle+depth work. 2b is
PARKED (correct + pixel-exact, but ~2x slower); perspective stays default.
Pursue cycle wins elsewhere (the perspective hot path).

### Divide-free 2b investigation (2026-06-16) — [superseded by CORRECTION above]
Profiled the 851k/frame 2b (the profiler mis-attributes the whole angle-module
arithmetic to "cos_fine" 51%; real call counts/frame: proj_yd 264 [8/seg],
point_to_angle 221, seg_depth 67, seg_c 34, seg_project 67, cos_fine 134).
The DIVIDES dominate. Cycle floors (stubbing divides, 10 ref frames):
  - proj_yd stubbed:            518k  (still > perspective 416k)
  - proj_yd + seg_depth stubbed: 354k  (BELOW perspective 416k)  <-- the target
So eliminating BOTH the depth and Y divides is necessary AND sufficient to beat
perspective (~15% at the floor; realistically ~390-430k after the replacement
muls -- a modest win or near-wash).
DESIGN (validated in Python, accuracy 0.48px mean vs true, == the divide form):
  recip = (FOCAL*CFRAC/c) * cden * recip_cph[cph]     [no per-vertex divide]
  - Rc = K/c : ONE reciprocal PER SEG (c is per-seg). 1 divide/seg (or a
    normalised recip). Replaces the 2 seg_depth + 8 proj_yd divides/seg.
  - recip_cph[cph] : small TABLE; phi clamped +/-512 => cph in [90,127] only
    (no near-zero -> well-behaved). cden is a NUMERATOR (no divide by it).
  - per vertex: 2 muls (Rc*cden, *recip_cph) -> recip(hi,lo); then the EXISTING
    br_project_y (mul + VWH cache) for all 4 heights. Reuses perspective Y path.
  - GUARDS: keep the depth<=0 cull and u16 clamp (small-c gives ~59px outliers
    unguarded; the divide path already culls/clamps these).
  Net divides/seg: ~4 (Rc + seg_c + 2x point_to_angle) down from ~14.
REMAINING TO BUILD: 6502 per-seg reciprocal of c, recip_cph table, the
per-vertex recip mul-chain, rewire br_seg_project_2b to emit (rhi,rlo) and call
br_project_y, then re-validate (compare_traversal fb=0) + measure. Large but
de-risked. Payoff is modest, so weigh against effort before committing.
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

## Autonomous micro-opt session (2026-06-17) — plan + reliable profile
Built a call-stack EXCLUSIVE-time profiler (/tmp/prof.py) — the nearest-label
attribution in profile_cycles.py is unreliable (it mis-blamed cos_fine and
br_init_frame this week). Self-time over 10 ref frames (total 4,131,823):
  draw_clipped_line_s16  9.4%   br_render_subsector 8.8%  br_seg_xform_vertex 7.3%
  point_to_angle 6.5%    umul8 6.4% (4672 calls)  bbox_check_angle 6.4%
  slope_div 5.7%         br_bbox_visible 4.0%     emit_vert_sx1/2 5.2%
  br_to_view/rot_int/smul 7.2%
Targets (self-time x tractability): umul8 (broad), seg-loop glue (~21%),
bbox glue (~16% non-atan2). Plus: remove jump tables (user ask). Method:
measure (call-bracket) -> change -> regression green -> measure -> commit.

## Parked 2b REMOVED from the build (2026-06-17)
bsp_render.bin was exactly full ($5800, 0 headroom), blocking any code-adding
micro-opt. The parked option-2b 6502 path (br_seg_project_2b + the IF-gated
seg-loop branch + the 5 angle routines cos_fine/seg_depth/proj_yd/seg_c/
seg_project + 6 jump-table entries + COS table) was consuming it, is 2.05x
slower (won't ship), and is the source of the jump tables to remove. Removed
it: bsp_render.bin 4096->3561 B (535 B headroom), angle bin 2139->1265 B,
6 jump entries gone. Perspective behaviour byte-identical (2b was flag-off);
regression GREEN, mean 411,504. Fully recoverable from git history (the 2b
work + bit-exact unit tests are at the commits tagged "6502 2b:" / "option-2b").
The Python-side reference (angle_seg.py + packed_render_seg _USE_ANGLE_SEG,
flag-off) is kept as documentation of the validated-but-slower approach.
