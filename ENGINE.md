# Engine guide — READ THIS FIRST

6502 DOOM (E1M1 wireframe) for the BBC Micro. This file is the map: what
lives where, how to build, how to verify, and the invariants that are not
visible in the code. It is written so a fresh session can work safely
without re-deriving tribal knowledge.

## The one-paragraph architecture

Two lock-stepped pipelines over shared prescaled WAD data: a **Python
packed reference** (`doom_wireframe.packed_render_bsp` + `fp.py`, all
arithmetic through the 8×8-multiply primitive) and the **native 6502
engine** (this repo's product). Hidden-surface removal is analytical 2D
**trapezoid clip spans** (not DOOM's column arrays): the visible region is
a linked list of spans with linear top/bot boundaries; solid walls
`mark_solid` columns, portals `tighten` boundaries, and the BSP walk
prunes subtrees with `has_gap`/`is_full`. BBox visibility runs in **angle
space** (DOOM-style checkcoord, `SlopeDiv` + `tantoangle` + `viewangletox`
tables — 0 muls, 1 divide per corner); seg vertices project in
**Cartesian** space (s24 view transform → 9.1 reciprocal table → screen X).
Lines are clipped by the DCL (draw-clipped-line) walk against the span
list and rasterised by the vendored NJ line drawer.

## Source layout

    src/zp.inc           ZERO-PAGE REGISTRY — every ZP symbol, one file.
                         Overlay groups are deliberate; see "Zero page".
    src/slope_div.s      Angle module: SlopeDiv, point_to_angle (inlined
                         into corner_phi), bbox_check_angle, straddle flag.
    src/span_clip.s      Span clipper unit = ordered .includes of src/clip/:
      clip/header.s        build flags, jump table (+ .exports)
      clip/arith.s         umul8 (pinned $2030), udiv16_8
      clip/pool.s          span_init, alloc/free (32 slots @ $0400)
      clip/interp.s        interp_store (round-to-nearest lerp)
      clip/mark_solid.s    lazy column removal (split/truncate/shrink)
      clip/query.s         has_gap (+coherence cache), is_full, span_read
      clip/dcl.s           draw_clipped_line: per-span CB clip + emission
      clip/tfr.s           tighten_from_records (3-cursor event walk,
                           tg_append_x merge) — THE production tighten
      clip/dcl_s16.s       s16 front-end: clips to u8, tail-calls DCL
    src/bsp_render.s     Renderer unit = ordered .includes of src/bsp/:
      bsp/header.s         equates, macros (ZERO/BUMP/PAGE), jump table,
                           imports of clipper entries
      bsp/arith.s          local umul/udiv copies, br_umul8/br_smul8, recip
      bsp/view.s           br_view_setup, br_to_view (s24), rot_int, fracs
      bsp/project.s        br_project_x_subpx, br_project_y_raw
      bsp/walk.s           br_init_frame, br_render_frame (BSP stack @ $0A00,
                           deferred far children, is_full early-exit)
      bsp/backface.s       back-face test (see "Known risks"), SC_/BCA imports
      bsp/bbox.s           br_bbox_visible -> angle module -> has_gap
      bsp/subsector.s      seg loop: headers, FHCH heights, emits, deferred ops
      bsp/seg_xform.s      per-vertex transform + vertex cache ($0C00)
      bsp/seg_project.s    do_project_y consumer gating
      bsp/main_tail.s      vc_bit_mask + end_code assert
      bsp/defq.s           deferred solid/tighten op queue ($0600) — B region
      bsp/resolve_crossing.s  child resolver + crossing divide — D region
      bsp/ycache.s         Y-projection cache (VWHC) — W region
      bsp/lo.s             overflow region: reproject_at_crossing, ap-edge
                           verticals, wide projection — LO region
    src/engine_flat.cfg  ld65 config, flat build (harness/regression)
    src/engine_banked.cfg  ld65 config, BANKED build (Model B disc)

The engine is **one ld65 link** of three objects; cross-module calls are
`.import`ed jump-table labels (`jt_*`), so a reordered/removed entry is a
link error, never a silent wrong address.

## Building

    import asmbuild; asmbuild.build_all()        # flat (default variant)
    asmbuild.build_all(banked=1)                 # Model B layout

- Everything goes through `asmbuild.py` (ca65 + ld65). It is fail-loud and
  memoized per session. NEVER call the assembler directly from new code.
- Output binaries land in the repo root under their historical names
  (span_clip.bin, bsp_render*.bin, bsp_render_ang.bin) — the py65
  harnesses load those.
- `DOOM_CPU=65c02` selects the C02=1 build AND the matching py65 core
  everywhere (tests included).
- Disc images: `build_modelb_ssd.py` (plain B + SWRAM, the main artifact),
  `build_banked_ssd.py` (Master), `build_anim_ssd.py`. The tiny boot/anim
  shims still use beebasm (vendored, stable); the engine does not.

## Addresses: use the symbol map, never literals

`symmap.sym('name')` returns the linked address of any label or equate
(per build variant). The whole Python harness resolves entry points, ZP
slots, and buffer bases this way. `python3 -c "import symmap; symmap.dump()"`
writes `build/symbols.json` for browsing. If you find yourself typing a
hex address into a Python file, stop and use the map.

## Zero page

`src/zp.inc` is the registry (included first by all three units).
After the dead-code strip: 206 addresses claimed, **43 free slots**
(run tools/zpcheck.py for the current map), 12 deliberate overlay groups.

- New variable: declare `name = ?` in zp.inc, run
  `python3 tools/zpcheck.py --alloc` (the build refuses while a `?` is
  pending).
- Overlay groups exist — multiple names on one address, deliberate
  phase-disjoint reuse (e.g. bbox-visibility scratch overlays the seg-loop
  block; both never live at once). Do not join a group without proving
  phase-disjointness; the group comments say who the users are.
- Reserved: $70-$76, $79-$7A, $80-$88 are **rasteriser-owned** scratch,
  clobbered on every line draw. Engine symbols inside those ranges are
  documented borrowings that are dead across every draw call.
- `python3 tools/zpcheck.py --map` renders the full picture.

## Verification (the contract for ANY change)

    python3 run_regression.py              # must print ALL GREEN
    python3 run_regression.py --rebaseline # after a DELIBERATE cycle/verify
                                           # change, with justification

GREEN means: unit tests (slope_div / bca / straddle / arithmetic) pass;
`check_angle_calls` sees no in-frame corruption; `compare_traversal` and
`compare_subsector` are 0px vs the Python packed reference; the two-sided
ground-truth verify at 5 fixed positions has not worsened vs
`baseline.json`; suite frame cycles have not regressed >0.25%.

- Cycle counts come from py65 execution only — never estimate.
- `verify_6502_vs_python.py X Y AB` for one position; no args for the
  147-position sweep. Its metric is two-sided: `over` = 6502-only pixels,
  `miss` = Python-only pixels. **Missing lines are bugs** — never dismiss
  either direction as "BSP divergence".
- The float `render_bsp` is ground truth; `render_bsp_fp` is a legacy
  approximation used by the verifier as a proxy; the packed path is the
  bit-exact spec the 6502 must match. When two fixed-point walks
  disagree, arbitrate with the float renderer (this method found the
  2026-07 corner-reference bugs).
- Unit-test individual stages first (the per-primitive tests exist —
  extend them); debug integrated frames only when isolation fails.

## Invariants you cannot see in the code

- **Interval conventions differ by module** (all match the Python
  reference): has_gap treats [xstart,xend] closed; tighten uses
  pixel-centre strict overlap and fragments share boundary columns;
  mark_solid removes closed [ilo,ihi] with ±1 fragment boundaries.
- **Carry-chaining across JSRs**: mark_solid's middle split and the
  ev_clamp_evy16 call rely on C surviving from flag-setting code through
  JSR/STA sequences. Documented at the sites; inserting any instruction
  there breaks them silently.
- **Phase-disjoint memory overlays**: BBOX_CORNERS ($0A40) overlays the
  seg projection buffer; the crossing scratch overlays seg-loop ZP.
  Both are safe only because bbox checks happen BETWEEN subsectors.
- **Deferred op queue**: seg solid/tighten ops queue at $0600 and apply at
  subsector end with records snapshots (later segs overwrite the records
  buffers — the snapshot is load-bearing). DEFQ_OVF flags dropped ops.
- **Records**: the format is 4-byte per surviving DCL segment
  (xl,yl,xr,yr). (The old 6-byte verdict path was deleted; note the defq
  snapshot code still STRIDES at 6 bytes on both sides — consistent,
  exact, but wasteful of queue capacity. Fix both sides together.)
- The BSP stack entry encoding requires node ids < $2000 and subsector
  hi-byte bit 6 clear (fine for E1M1; unstated elsewhere).

## Known risks / open items

- **Back-face test truncation**: `br_smul_s8_s16` keeps 16 bits; large
  diagonal products can wrap sign and drop a front-facing seg. Latent,
  data-dependent, invisible to self-consistency tests. Fix = s24 sign.
- **Over-traversal robustness: RESOLVED (2026-07-05).** Over-descent
  provably costs cycles only, never pixels (certificates:
  overtraversal_probe.py — occluded visits must be perfect no-ops;
  angle_race.py — angle walk vs corner walk). The apparent
  non-robustness was two bugs in the Python corner REFERENCE (raw
  product where 0.8-t needed >>8 in the near-plane crossing; missing
  conservative ±1 on the extent). The angle bbox is now a faithful DOOM
  R_CheckBBox (unsigned-BAM wraparound) on BOTH sides, bit-exact,
  replacing the buggy signed-sort. Any future bbox change must keep the
  test conservative: frustum rejects + never under-report the extent.
- Pool exhaustion (32 span slots) silently drops visible fragments;
  LINE_OUT_BUF wraps past 63 lines. Both are latent, not observed.

## Performance

Suite cycle counts are gated by baseline.json (currently 4,098,167 total
over 10 positions ≈ 2 MHz → ~4.9 fps mean). The cost structure and the
optimisation history (measured-and-rejected ideas included — read before
re-proposing one) are in BSP_RENDER_STATUS.md and CLIP_OPTIMISE.md.

## Legacy

`doom_fe.asm` / `fe6502.py` / `build_ssd.py` are the pre-BSP-renderer
generation (magic line peripheral, Python raster). Kept for history;
not part of the regression; do not extend.
