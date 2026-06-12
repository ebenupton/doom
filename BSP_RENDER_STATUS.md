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

## Performance (2026-06-13)

Profiled with `profile_frame.py` (py65 cycle deltas bucketed by
top-level routine). 3-frame profile set baseline 4,002,663 cycles →
**3,518,511 (-12.1%)**, output-identical throughout. Full-suite frame
costs now 65k (trivial view) to 1.79M (1500,-3700,0).

Optimizations landed:
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

## Next

1. Hardware bring-up: jsbeeb/SSD integration of the standalone module
   (memory map per the table above — note the X region in the stack
   page and the harness-loaded tables at $B600+/$C600+/$E000+).
