# Engine guide — READ THIS FIRST

6502 DOOM (E1M1 wireframe) for the BBC Micro. This file is the map: what
lives where, how to build, how to verify, and the invariants that are not
visible in the code. It is written so a fresh session can work safely
without re-deriving tribal knowledge.

## The one-paragraph architecture

> Data note: node and subsector tables live at the HEAD of ROM_MAIN as
> page-aligned structure-of-arrays (13 node pages incl. a baked partition
> type + 3 subsector pages; `NODE_SOA` in bsp/header.s). Every consumer
> indexes them with a constant-base `LDA abs,X`; keep n_nodes, n_ss <= 256.


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
**Cartesian** space (s24 view transform → floating-mantissa reciprocal →
screen X). The reciprocal FOCAL/vy is stored as (M8, S): m9 = 256+M8, a
9-bit mantissa with implicit leading 1, R ≈ m9/2^S with S =
bit_length(idx-1) computed, not stored (1024-byte table, 9.1 index).
Relative error ≤ 2^-10 (≤1/8 px on screen — quarter-pixel is the design
budget): Y projection is ONE 8x8 mul + a round-to-nearest shift
(per-vertex VECTORED: rns_select picks an unrolled body S6-S10 through
zp_rns_vec whenever zp_br_rlo changes; generic rns24/rns32 take the rest),
X is two muls (wide three), and the near-plane crossing recip (M8=0,
S=1) projects with pure shifts.
Lines are clipped by the DCL (draw-clipped-line) walk against the span
list and rasterised by the vendored NJ line drawer.

## Source layout

    src/zp.inc           ZERO-PAGE REGISTRY — every ZP symbol, one file.
                         Overlay groups are deliberate; see "Zero page".
    src/slope_div.s      Angle unit = ordered .includes of src/ang/:
      ang/header_div.s     jump table, workspace, SlopeDiv (exact, unrolled)
      ang/bca.s            bbox_check_angle (angle-space visibility)
      ang/rcache.s         rotation-coherence psi cache (frame classifier,
                           cached check path; RCCODE segment when banked)
      ang/corner_phi.s     box_classify + corner_phi/point_to_angle
    src/span_clip.s      Span clipper unit = ordered .includes of src/clip/:
      clip/header.s        build flags, jump table (+ .exports)
      clip/arith.s         umul8 (pinned $2030), udiv16_8
      clip/pool.s          span_init, alloc/free (32 slots @ $0400)
      clip/interp.s        interp_store (round-to-nearest lerp)
      clip/mark_solid.s    lazy column removal (split/truncate/shrink)
      clip/query.s         has_gap (+coherence cache), is_full, span_read
      clip/dcl.s           draw_clipped_line: per-span CB clip + emission
      clip/plot_axis.s     dedicated horizontal/vertical plotters (~70% of
                           rasterised pixels; byte strips / constant mask)
      clip/tfr.s           tighten_from_records (3-cursor event walk,
                           tg_append_x merge) — THE production tighten
      clip/dcl_s16.s       s16 front-end: clips to u8, tail-calls DCL
    src/bsp_render.s     Renderer unit = ordered .includes of src/bsp/:
      bsp/header.s         equates, macros (ZERO/BUMP/PAGE), jump table,
                           imports of clipper entries
      bsp/arith.s          local umul/udiv copies, br_umul8/br_smul8, recip,
                           rot variants (rot_zero/unity/gen thunks/rot_core)
      bsp/view.s           br_view_setup, br_to_view (s24), rot_select
                           (SEL region: per-frame SMC of the rot_s1..s4
                           call sites — trig config is frame-constant, so
                           the zero/unity/general variant choice and the
                           general thunks' mag/neg immediates are patched
                           once per frame, not tested ~200x; -0.86%)
      bsp/project.s        br_project_x_subpx, br_project_y_raw
      bsp/walk.s           br_init_frame, br_render_frame (BSP stack @ $0A00,
                           deferred far children, is_full early-exit)
      bsp/backface.s       back-face test (see "Known risks"), SC_/BCA imports
      bsp/bbox.s           br_bbox_visible -> angle module -> has_gap;
                           br_bbox_visible_d = forward-coherence cache
                           wrapper (walk JSRs SMC-patched per frame;
                           D_ENABLE, data $0210-$03F7 in old OS space)
      bsp/subsector.s      seg loop: headers, FHCH heights, emits, deferred ops
      bsp/seg_xform.s      per-vertex transform + vertex cache ($0C00)
      bsp/seg_project.s    do_project_y consumer gating
      bsp/main_tail.s      vc_bit_mask + end_code assert
      bsp/defq.s           deferred solid/tighten op queue ($0600) — B region
      bsp/resolve_crossing.s  child resolver + rns_fast/half tables — D region
                           (banked W_BK/D_BK: see the BCA_WS note below)
      bsp/ycache.s         Y-projection cache (VWHC) — W region
      bsp/lo.s             overflow region: br_node_setup (SoA node reads,
                           baked partition types), reproject_at_crossing,
                           ap-edge verticals, wide projection — LO region
      bsp/vxcache.s        translation-coherence vertex cache (base+CACC
                           telescoping; VXCODE segment = bank C when banked)
      bsp/anim.s           animated sectors: mover tick state machines +
                           lazy visibility-driven table patching (ANIMH
                           resident hub, ANIML0/ANIML2 bank workers)
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

    # The verification toolchain (run_regression, soak, cache gates,
    # comparators, profilers) lives at the `full-toolchain` git tag —
    # this minimal tree keeps only the build + play closure.
    git checkout full-toolchain -- run_regression.py baseline.json  # to restore
    python3 run_regression.py              # must print ALL GREEN
    python3 run_regression.py --rebaseline # after a DELIBERATE cycle/verify
                                           # change, with justification

GREEN means: unit tests (slope_div / bca / straddle / arithmetic) pass;
`check_angle_calls` sees no in-frame corruption; `compare_traversal` and
`compare_subsector` are 0px vs the Python packed reference; the two-sided
ground-truth verify at 5 fixed positions has not worsened vs
`baseline.json`; suite frame cycles have not regressed >0.25%.

- Cycle counts come from py65 execution only — never estimate.
- Rasteriser/pixel changes: the differential suite renders BOTH sides
  through the same 6502 rasteriser and cannot see a pixel change that
  affects both equally — use fb_gate.py (capture golden framebuffers
  before, byte-compare after).
- `verify_6502_vs_python.py X Y AB` for one position; no args for the
  147-position sweep.
- `tools/walkseq_check.py` (in the regression) drives multi-frame WALK
  sequences with the forward-coherence bbox cache enabled and demands
  pixel equality vs the fresh reference each frame — the gate for any
  cross-frame caching of walk decisions. Its metric is two-sided: `over` = 6502-only pixels,
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

- **SEL region ($A400)**: rot_select rides the HUD's bank C window slack
  (banked; flat = the free page below the sqr tables). Runs once per frame
  from br_view_setup with bank C paged; its stores all target resident
  MAIN, so only the FETCH needs the bank.
- **STK region ($0100-$01BF)**: the RNS vectoring block lives in the
  BOTTOM OF THE HARDWARE STACK PAGE. Measured SP floor is $F1 (12 bytes
  used); the region cap leaves $01C0-$01FF (64 bytes) for the stack. If
  call depth ever grows (new nested JSR chains), re-measure — a stack
  descending into $01BF silently corrupts these routines. The disc cannot
  *LOAD page 1 (the OS owns the stack during loading): the image is staged
  in bank L2 at $A100 and both drivers copy it down at boot (walk_drv
  anim_glue_init / banked_boot init).
- **Bank-window eviction hazard** (learned the hard way, then reverted):
  code moved into a paged window is only correct if EVERY caller pages the
  window first — an L2-paged call into a bank C routine executes table
  bytes as code, and FLAT BUILDS CANNOT CATCH IT (PAGE is a no-op flat).
  Grep every caller of every relocated label; validate with bare-boot +
  jsbeeb. (The debug HUD's vacated $A400 bank C window is currently FREE.)
- **Unregistered ZP squatters**: ang/rcache.s owns $C4/$C5 and bsp/anim.s
  owns $EB-$EE/$F0-$F1 outside zp.inc's registry — tools/zpcheck.py calls
  them "free". Grep ang/, anim, the drivers and the NJ reloc wrapper
  before claiming a "free" slot (zp_rns_vec landed on $C4 first and the
  rotation-cache clobbered it on stable frames).
- **Banked main-RAM map (2026-07-10 one-region merge)**: ALL engine code
  is ONE ld65 memory area, CODE $2C00-$57FF, with the MAIN segment first
  so the driver-facing jump table is PINNED at $2C00 (link asserts in
  bsp/header.s; jt_anim_tick/init live in the same table at +$1E/+$21).
  Everything after MAIN floats — there is no more per-region byte-Tetris.
  Data anchors below the code: BCA_WS $1B40-$1B7F (bca_ab = $1B6F, poked
  by drivers/harness), sqr quarter-square tables $1C00-$1FFF (both
  banks' code multiplies through them; TWIN equates in clip/arith.s AND
  bsp/header.s — keep in sync), beebasm drivers $2000-$2BFF (drv $2000,
  vars $2180, glue $21A0, sincos $2200, clears+input $2400; !BOOT CALLs
  &2000). Level data lives in the banks (L0 = SoA $8000 / seg_hdr $9000 /
  FHCH $9000+n_segs*12 / TABL0 $BE90; L2 adds verts $A200, VWHC
  $B500-$B9FF, CFG $BA00). SSMASK is a documented main-RAM exception at
  $0A80 (per-subsector read under arbitrary banks). SEL+HUD remain in
  the bank C window. RULE: no level data in main unless the banked
  placement has a measured-unacceptable paging cost; validate any banked
  placement with the flat-vs-banked FB lockstep AND a jsbeeb disc boot —
  harness green alone is not evidence. (Historical black-screen classes
  now retired by the merge: the W_BK/BCA_WS $3A00 overlay and the flat
  $0BE8 ROM-pointer ceiling — the pointer block itself is gone; ROM
  bases are src/layout.inc assembly-time constants gated against
  dw.packed_layout on import.)

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
- **Playable-area box: FIXED 2026-07-06** — player integer position is
  now s16 (zp_br_px_e/py_e), the whole map is representable, and
  doom_walk.ssd walks it (cursor keys). Historical note follows; the
  remaining v1 limitation is spawn-constant VZ in the walk build.
- **(historical) Playable area was a ±1023-unit box around MAP_CENTER
  (measured 2026-07-05).** Player position is s16 8.8 fixed-point: after PRESCALE=8
  the integer part must fit s8, so only positions within ±1023 world
  units of MAP_CENTER (1200,-3250) are representable — 67% of walkable
  E1M1 (489/729 grid samples) is OUT of range. Verified empirically:
  6/6 far in-spec positions render pixel-exact (CLEAN even at prescaled
  ±126, i.e. no distance-dependent accuracy loss inside the box), 3/3
  out-of-spec positions are catastrophically wrong (wraparound; e.g.
  (3648,-2368) → over 841px). This is the long-remembered "moves far
  from start and breaks" symptom. PRESCALE=16 doubles the box to ±2047
  but E1M1 spans 4576×2816, so full-map coverage needs a wider player
  representation (s16.8 / per-region re-centering), not just prescale.
  Far in-spec corners are in the standing suites since 2026-07-05.

## Cross-frame caches

Three caches, all driver-enabled (harness default off, byte-identical):
VXC (translation-coherent vertex transforms), RCACHE (position-keyed bbox
corner angles; rotation/stationary frames), and the D cache (forward-
coherence bbox verdicts+extents, bbox.s: serves while movement stays in
the view cone at a fixed angle; 1/8 round-robin refresh; invisible
verdicts exact by the convex-cone theorem, extents FOE-opened supersets).
The D cache is pixel-preserving ONLY because of the 2026-07-08 gate
invariant: projection round-to-nearest + outward-rounded/inflated packed
bbox corners make every seg's drawn columns lie inside its ancestors'
gate extents (153-view sweep, 100%). Walking frames measured -10..-19%
(deep views) / -16% (spawn); stationary -1..-4% on top of RCACHE.

## Performance

Suite cycle counts are gated by baseline.json (currently ~4.74M total
over 14 positions — 10 near-spawn + 4 far in-spec — ≈ 2 MHz). The cost structure and the
optimisation history (measured-and-rejected ideas included — read before
re-proposing one) are in BSP_RENDER_STATUS.md and CLIP_OPTIMISE.md.

## Legacy

`doom_fe.asm` is the pre-BSP-renderer generation (magic line peripheral,
Python raster). Its Python side (`fe6502.py` / `spans6502.py` /
`build_ssd.py`, plus `doom_fe.bin` / `doom_loader.bin` /
`clipper_bank2.bin` and the H/J/P/O modes in `doom_wireframe.py`) was
garbage-collected 2026-07-07; recover from git history if ever needed.
Not part of the regression; do not extend.
