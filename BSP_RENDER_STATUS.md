# bsp_render.asm — status

## Current state (2026-06-12)

The pure-6502 renderer (BSP walk + seg processor + span clipper + DCL)
is **framebuffer-identical to the Python reference pipeline** at 9 of
the 10 standard suite positions, and within 7 px at the tenth — when
both pipelines rasterise through the 6502 DCL. Measured by:

- `compare_subsector.py` — per-subsector differential (runs the 6502
  and Python seg processors from identical clipper state, diffs calls,
  span state, and FB; continues from the reference state):
  **0 pixel/span-affecting subsectors, 0 px** across all 178 suite
  subsectors.
- `compare_traversal.py` — pure-6502 walk vs Python-BSP hybrid (same
  seg processor, 6502-backed visibility): **identical visit sequences
  and 0 px FB diff at all 10 positions**.
- `test_bsp_walk.py` — visited-subsector sets match the Python walk.
- Full-frame FB compare (6502 DCL on both sides): 0 px at 9 positions,
  7 px at (1056,-3616,64) — see "Known residual" below.
- `test_hybrid.py` headline: py-vs-asm 96.2% pixel agreement — the gap
  is pygame-vs-NJ *rasterisation* in the metric (Python's surface uses
  pygame lines), not renderer divergence.

## Known residual

7 asm-only pixels at (1056,-3616,64): a flat horizontal lying exactly
ON a span bottom. Python's `line_below_spans` AP-skip treats the
boundary as occluded and skips the draw; the DCL keeps the boundary
row when the line is submitted. Exact reproduction requires the
AP-skip predicates (`line_above_spans` / `line_below_spans` /
`vertical_outside_spans`) in 6502 — which is also the planned cycle
optimisation (the 6502 currently draws every line Python AP-skips and
lets the DCL clip them; pure cycle waste). Acceptance test: the 7 px
at this position go to zero.

## Memory map (6502, test harness layout)

| Region | Address | Notes |
|---|---|---|
| X region | $0100-$01DF | bbox edge-crossing math (stack page low half; stack stays ≥ $01E0, observed min $01F1) |
| Span read buffer | $0300 | test harness only |
| Span pool | $0400-$059F | span_clip |
| Deferred op queue | $0600-$06FF | seg-ordered solid/tighten ops + records snapshots |
| DCL records | $0700 / $0800 | TOP/BOT verdict records |
| span_clip LC scratch | $0900-$0958 | |
| BBOX corners/vars | $0960-$0976 | corners (rounded s16), DEFQ_TAIL/OVF |
| D region | $0978-$09FF | crossing divide, classify, child resolver |
| BSP stack | $0A00-$0A3F | |
| Seg/bbox scratch | $0A40-$0A6B | |
| Visited bitmap | $0A80-$0A9D | 30 bytes (237 subsectors) |
| B region | $0AA0-$0BFF | deferred-op queue code, ev_clamp, project_x_auto |
| Vertex cache | $0C00-$1A98 | 8B × 467 |
| Vcache valid bitmap | $1B00-$1B3A | |
| lo region | $1B40-$1FFF | xform helpers, crossing, ap_edges, fhch ptr |
| span_clip + pool code | $2000-$4737 | |
| bsp_render main | $4800-$57FF | ASSERT-bounded |
| Screen | $5800-$6BFF | mode 4 |
| ROM main (no VWH) | $6C00-$A4B0 | |
| Rasteriser | $A900-$B55E | NJ DCL backend — **owns ZP $74-$76, $79-$7A, $80-$88** |
| FHCH table | $B600-$C577 | **6 bytes/seg**: fh, ch, bfh\|apv1_ch, bch\|apv1_fh, apv2_ch, apv2_fh |
| BBox table | $C600-$D4BF | 16B per node |
| Recip table | $E000-$E483 | |
| VWH heights | $E484-$E939 | |

ZP: $90-$95 hold pxraw/pyraw/v_xext/t4 (moved out of the rasteriser's
$71-$76 range — the rasteriser clobbers $74-$76 on every line).

## Architecture notes

- **BSP walk** mirrors Python's `packed_render_bsp` exactly: near
  children are bbox+has_gap checked at node-visit time; far children
  are pushed as deferred `(node, side)` entries ($40-flagged) and
  checked at pop time, i.e. against the span state after the near
  subtree rendered. is_full at every pop.
- **bbox visibility** mirrors `fp_bbox_visible_fixed` bit-exactly:
  rounded evx/evy16, frustum tests on rounded values, full-width
  projection (24-bit sx classification), near-plane edge crossings
  (t via 24/16 restoring divide; at NEAR the recip is constant
  (127,255) so the crossing sx classifies by cx ∈ {≤-2,-1,0,1,≥2}),
  and the all-off-one-side reject via "any sx ≥ 0 / ≤ 255" flags.
- **Seg processor**: wide view-x projection (`br_project_x_auto`
  narrow 3-mul / wide 5-mul, mod-2^16 exact vs Python, s24 result);
  near-plane crossing for portals AND solids (s16 cx); s24-aware
  reciprocal index; deferred solid/tighten op queue applied in seg
  order at subsector end with records snapshots (Python's `deferred`
  list semantics); NOVT aperture-edge verticals via SF_APEDGE1/2.
- **span_clip**: has_gap coherence cache is invalidated on every pool
  mutation (stale freed-slot extents previously produced false
  positives — invisible to the Python-driven pipeline, which discards
  the 6502 has_gap result).

## Test files

- `test_bsp_render.py` — arithmetic primitives (all pass).
- `test_project_x_wide.py` — wide projection vs full-width formula,
  3200 cases (addresses resolved from the beebasm listing).
- `test_bsp_walk.py` — visited set vs Python walk, 4 positions.
- `compare_subsector.py` — per-subsector differential (the workhorse).
- `compare_traversal.py` — traversal isolation (asm vs hybrid).
- `drill_seg.py` — verbose one-subsector drill (both sides, AP-skip
  predicate logging).
- `test_hybrid.py` — three-way pixel agreement table.

## Performance (2026-07-05 session)

Post-refactor grind (ca65/ld65 source in src/; every step measured by
py65 via measure_cycles.py, gated by run_regression.py, committed only
on ALL GREEN). 10-position suite totals:

| Change | Total | Δ |
|---|---:|---|
| session start (post-strip) | 4,097,401 | |
| R_CheckBBox angle bbox (correctness fix, also faster) | 4,059,215 | −0.93% |
| B1: point-on-side + back-face sign shortcuts; defq 4-byte stride | 3,978,045 | −2.00% |
| B2: lazy seg header; rhi==0/frac==0 projection gates | 3,931,582 | −1.02% |
| B3: merged box classifier; octant fold; pre-doubled cc table | 3,891,285 | −1.02% |
| B4: rot_int zero-delta gate; corner-load fold | 3,866,537 | −0.64% |

| axis plotters (H/V = ~70% of cardinal-view pixels) | 3,793,143 | −1.90% |
| plot_v cell unroll + plot_h byte-walk | 3,761,193 | −0.84% |

Suite broadened 2026-07-05 to 14 positions (4 far-from-spawn in-spec
added after the s16 8.8 position-range investigation); new baseline
total 4,737,588. Subsequent deltas are against that suite.

| steep de-unroll (STEEP_COMPACT; frees ~880B raster budget) | 4,737,747 | +0.003% |

Mean frame 376,119 ≈ 5.3 fps at 2 MHz (was 4.9 at session start). The
OFF-AXIS variant of the suite (all angles nudged +3) measures 3,969,615
(mean 396,961 ≈ 5.0 fps) — the honest number for the rotating demo;
cardinal angles flatter the engine ~5% (axis-aligned walls project to
exact horizontals, which the axis plotters eat). Gradient censuses
(cardinal + off-axis) in the perf-grind memory: verticals are
structural (~37% of pixels at any angle); off-axis, horizontals halve
into the <1:4 shallow band (34.8% of pixels), A run-based shallow
plotter was built, proven pixel-exact (16k-sequence oracle check +
15,872-draw battery — tools/run_oracle.py / run_battery.py), and
MEASURED AND REJECTED: NJ's shallow path is already run-accumulating
(~11 cyc/px), so the win only exists below ~1:33 gradient and every
dispatch threshold netted +0.2%. Code preserved in the 'experiment:
run-slice' commit; revival needs ~2.5x cheaper per-row plotting.
All changes are output-exact by construction (sign identities, x*0=0,
load reordering, predicate merges) — verified by the full differential
suite each batch, not assumed.

Cost structure after the angle-bbox fix (profile_subsystems, 6 off-axis
positions): vertex transform 28.4%, walk+glue 22.1%, bbox 24.1%,
clipper 16.9%, rasteriser 8.4%. The old "bbox is 52%" figure predates
the angle conversion — do not plan against it.

Measured and rejected: **2-3 band Hamiltonian shallow module**
(raster/shallow_23_hamiltonian-or.asm, HAMILTONIAN_23, off by default;
'experiment:' commit 643fac6). Oracle-proven run protocol (first run
always 2, interior {2,3} by one ADC/SBC per run, final run always 2
drawn up-front at the far endpoint so the machine terminates on pure
row count), exhaustively pixel-exact (54,760-draw on/off A/B, corpus,
fb_gate). Suite verdict -0.036% only: the band is 4.9% of pixels / 32
lines, and the ~4.2k machine win is eaten by the ~9 cyc/line dispatch
tax on the 154 non-band shallow lines plus ~35 cyc/line heavier entry
(deltas + far-end prologue + row anchor). Revival needs either a free
dispatch discriminator or a materially larger band share; the module
itself is correct and 1,030 bytes.

Measured-and-rejected this session: slope_div reciprocal-multiply and
leading-zero-skip variants (restoring divide already ~breaks even);
per-frame trig product tables (build cost exceeds use); rasteriser
short-line fast path (deferred: must reproduce Hamiltonian pixels
exactly; per-line SMC setup ~96 cyc is the cost to beat).

## Performance (2026-06-13)

Profiled with `profile_frame.py` (py65 cycle deltas bucketed by
top-level routine), output-identical throughout.

Measured on the off-axis suite (cardinal angles nudged +1 — see "Test
set" below; the old cardinal-heavy suite understated multiply-caching).
6-position off-axis suite: no-cache 5,686,684 → **5,239,656 (-7.86%)**
with the rotation-product cache, bit-exact (compare_subsector /
compare_traversal 0 px). Per-view -7.86% holds broadly; heaviest off-axis
view (1500,-3700,1) 1.79M → 1.71M.

Optimizations landed:
- bbox rotation-product cache (W region; `rot_pair_cached` +
  RPC_* arrays $DC00): bv_corner_products rotates 4 bbox-edge deltas
  d=(coord-player) by sin/cos; d is a pure function of the edge within
  a frame and ~80% of deltas recur across node-sides (child bbox ⊂
  parent; equal x/y deltas share a product). Per-frame direct-mapped
  N=64 cache of the (sin,cos) s24 pair turns ~80% of those rotations
  into a 6-byte copy. Full key (d lo,hi) checked → collisions
  miss-and-recompute, never corrupt. bv_corner_products 275k→129k,
  br_rot_int 135k→57k.
- `br_smul_s8_u8` split sign paths (no flag, no writeback, single copy)
- bbox corners share rotation products: 8 `rot_int` per node-side
  instead of 16 (Y region $4740; `tv_add_fracs` shared tail)
- bbox two-pass: all-behind/frustum rejects fire before any
  recip/projection/classify work (Python's own order)
- `do_project_y` gates back-pair projections on their only consumers
  (plain solid walls skip 2 of 4 Y projections per vertex)
- seg loop: persistent header/FHCH pointers (+12/+6 per seg) replace
  per-seg multiplies
- `br_project_y` emits HALF_H+Y_BIAS; per-store bias adds dropped
- `br_rot_int` reads trig via Y index (callers stop staging 3 ZP bytes)
- `umul8` pinned at $2030; bsp_render skips the jump-table dispatch
- Y-projection cache (W region $DAC0): key = the full input set
  (rhi, rlo, h) → hits are bit-identical pure-function results; 58-64%
  of projections repeat per frame, ~315 cycles each vs ~45 per hit

Measured and rejected: Python's AP-skip predicates — a zero-pixel DCL
call averages only ~341 cycles on the 6502 (measured per-call), so the
predicates would not pay for themselves. They remain solely the route
to the last 7 px of exactness if ever wanted.

Measured and rejected: **reciprocal cache** (br_recip front-end keyed on
clamped vy_idx). Looked like -1.84% on the old cardinal-heavy suite, but
on representative off-axis views it *regresses* +0.5% (5 of 6 views
slower, up to +2%): off-axis the hit rate falls to 75% (vs 88% cardinal)
and only 46% of calls take the averaging path (vs 63%), so the per-call
clamp+probe overhead outweighs the savings. recip is already a table
lookup; caching it only pays when the averaging path dominates AND the
depth distribution clusters — both true only for axis-aligned views.

Measured and rejected: **corner-view cache** (cache the per-corner view
transform keyed on the (dx,dy) pair). 60% pair-reuse, but with the
rotation cache already making the products cheap, the probe + lost
product-sharing nets ~0 on the suite and *regresses the heaviest frame*
(the fps floor) by ~1%. The bbox corner pipeline is at its practical
floor once rotation products are cached.

## Cost structure (where the cycles go)

Call-stack-attributed profile (`profile_subsystems.py` — each cycle is
charged to the subsystem whose *call frame* it runs under, so shared leaf
routines (umul8, br_recip, br_project_x) are billed to the caller, not to
the module they physically live in). Off-axis suite, rotation-cache build:

| Subsystem | % of frame |
|---|---|
| BSP traversal (total) | **66.7%** |
| — bbox visibility | 52.4% |
| — walk + seg-processor glue | 14.3% |
| Vertex transform & cache | 18.5% |
| Windowed clipped renderer | 9.6% |
| NJ rasteriser backend | 5.2% |

**bbox visibility (52%) is the dominant cost** and it is *necessary*, not
waste. Per-child accounting (`measure_child_math.py`): each bbox test
averages ~11.8 8×8 multiplies, ~3.1 reciprocal lookups and ~5,600 cycles
— about the cost of rendering a subsector — and 56% of every multiply in
the frame is bbox culling. After the rotation cache, ~3 of those 12 muls
are corner rotations; the rest are the perspective projection (recip +
project_x) of the in-front corners.

Why it's necessary — outcome of all 495 children across the suite:

| Outcome | % |
|---|---|
| descend (visible — projection feeds the has_gap that says "yes") | 80% |
| frustum reject (cheap, pre-projection — two-pass already handles it) | 9% |
| projected, then occlusion-culled by has_gap | 11% |

The walk reaches only 4.6–21.5% of the 237 subsectors per scene
(`test_bsp_walk.py`, set-identical to Python's `packed_render_bsp`), but
to get there it tests ~3.5 in-frustum children per rendered subsector and
**80% of children are genuinely visible**. has_gap needs the screen-X
extent [ilo,ihi], whose only source is projecting the corners — so the
projection cannot be skipped for visible children.

Measured and rejected: **cheaper-reject for bbox** (a conservative
pre-test to kill children before projecting corners). The addressable
pool is only the 11% that project-then-occlusion-cull; the 80% visible
children must project regardless, and even the 11% need *some* extent to
be occlusion-tested. Upside is a few percent of bbox at best with real
divergence risk — not worth it. The bbox pipeline is doing real
front-to-back occlusion work, not spinning.

Remaining levers, in rough priority: (1) the 18.5% vertex-transform path
(seg-vertex projection); (2) a genuinely cheaper *exact* screen-extent
for in-frustum children (the corner-view cache was the obvious attempt
and didn't pay — would need a different formulation); (3) the clipped
renderer / rasteriser are already small (15% combined).

## Angle-space pipeline conversion (in progress)

Decision (user): convert the whole projection from perspective (rotation +
recip + project_x) to DOOM-style **angle space** — bbox *and* segs — re-based
for correctness against the **float reference** within ±1 column, not against
the current perspective renderer. Motivation: angle space folds the rotation
into an angle subtract and replaces per-corner projection multiplies with a
single divide + table lookups. Per corner/vertex: **0 muls, 1 divide,
depth ~2** vs perspective's rotation (≤8 muls) + project_x (2–5 muls).

Why it is correct (not just cheaper): validated (`validate_angle.py`) that the
angle column tracks the **true float projection within ±1 col for 100%** of
934k sampled points, *including near-plane*. The current perspective `sx`
(128·vx/vy) is the one that misbehaves at small vy (diverges up to 19 col);
angle space (`atan2`) is well-conditioned everywhere — it is the *more*
faithful basis.

Module `angle_bbox.py` (Python prototype, validated): `point_to_angle`
(octant + `SlopeDiv` + `tantoangle`), `viewangletox` conservative bracket,
`view_col(vx,vy)` (column from view coords), `bbox_check_angle` (DOOM
`checkcoord` 2-corner, rotation-free). FINEANGLES=8192, ANG45=1024 (90° FOV),
SLOPERANGE=2048. φ-convention: φ = view_angle − atan2(dy,dx), φ>0 = right.

Milestones (Python-first behind `doom_wireframe._USE_ANGLE_COL` /
`_USE_ANGLE_BBOX`, default False so the perspective path + all 0px tests are
untouched — `compare_traversal` still 10/10):
- **Foundation** ✅ angle column ≈ float ±1 (validated).
- **M1** ✅ angle column for bbox + segs (`view_col`). Faithful vs perspective
  (`compare_angle_frames.py`): lit-pixel counts within 0.6%, line counts
  within 1.4%, 87% of submitted lines within 2px; residual ~8% is
  clip-boundary re-fragmentation from sub-pixel shifts (same pixels), not
  breakage.
- **M2 (bbox)** ✅ `bbox_check_angle` — rotation-free, 2 silhouette corners,
  0 muls + 2 divides. Produces **identical visit decisions** to the
  rotation-based bbox (same 352/357 line numbers as M1). (A first
  convention bug — DOOM angle sign opposite to `view_col` → mirrored columns
  → 43% over-cull — was caught by the harness and fixed before commit.)
- **M2 (seg)** ⏳ drop the seg rotation: column from world-delta angle, depth
  via `point_to_dist`/`finecosine` (or a 2-term vy), near-plane handled by
  DOOM-style angle-span clip (R_AddLine). The harder remaining Python piece.
- **M3 (6502)** ⏳ port: `tantoangle`/`viewangletox` tables into the image,
  `SlopeDiv` (a u≤24/u8 divide), `point_to_angle`, `checkcoord`, replace
  bbox + seg projection; validate 6502 == angle-Python, measure cycles;
  retire the rotation-product cache (bbox no longer rotates) and recip's X
  role. Validated Python angle path is the spec.

Validation harnesses: `validate_angle.py` (angle vs float vs perspective at
the column level), `compare_angle_frames.py` (full-frame submitted-line diff,
angle vs perspective; the "did angle-space break Python?" check).

## Test set

Profiling/exactness suites use **off-axis** view angles only. Cardinal
angles (ab % 64 == 0) take the sin/cos unity fast path in br_rot_int and
render atypically — they understated the value of multiply-caching and
flattered the recip cache. Every cardinal angle in the suite is nudged
+1 (0→1, 64→65, 128→129, 192→193); 32/96/224 were already off-axis.

## Next

1. Hardware bring-up: jsbeeb/SSD integration of the standalone module
   (memory map per the table above — note the X region in the stack
   page and the harness-loaded tables at $B600+/$C600+/$E000+).
