# Engine guide — READ THIS FIRST

6502 DOOM (E1M1 wireframe) for the BBC Micro. This file is the map: what
lives where, how to build, how to verify, and the invariants that are not
visible in the code. It is written so a session with NO other context can
work safely without re-deriving tribal knowledge. Every source file also
carries a CONTEXT header stating its place in the pipeline, its callers,
its register/ZP/bank contracts, and the layout pins it relies on — when
in doubt, the source header is the local truth and this file is the map
between them.

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
**Cartesian** space (s24 view transform → floating-mantissa reciprocal →
screen X). The reciprocal FOCAL/vy is stored as (M8, S): m9 = 256+M8, a
9-bit mantissa with implicit leading 1, R ≈ m9/2^S with S =
bit_length(idx-1) computed, not stored (1024-byte table, 9.1 index).
Relative error ≤ 2^-10 (≤1/8 px on screen — quarter-pixel is the design
budget). Y projection is ONE 8×8 mul + a round-to-nearest shift; X is two
muls (wide three); the near-plane crossing recip (M8=0, S=1) projects
with pure shifts. Lines are clipped by the DCL (draw-clipped-line) walk
against the span list and rasterised by the vendored NJ line drawer, with
dedicated axis plotters taking ~70% of pixels.

## The per-seg pipeline (hot path, in execution order)

For every seg of every visited subsector (`bsp/subsector.s` owns the
loop; one 16-byte header cursor `zp_seg_hdr_p` rides the whole loop):

1. **Back-face test** (`bsp/backface.s`, tail-dispatched: JMPs to
   `bf_seg_front` or straight to `s_advance`). Axis-aligned segs are one
   s16 compare against a pack-time constant (header form 0-3); diagonals
   dot a DIR-table primitive direction with the player delta (sign
   shortcut first, u24 magnitude compare only when signs agree).
2. **Vertex pipeline**, per endpoint (`bsp/seg_xform.s`, ONE file
   top-to-bottom): chain check (previous seg's v2 == this v1: reuse the
   whole VX2 struct) → frame vertex-cache probe (VCACHE $0C00, valid
   bitmap) → on miss, `vxc_jsr_site` dispatch: VXC translation cache
   (warm: two s24 adds reconstruct view coords) or fetch+rotate
   (`br_to_view_fetch` → `br_to_view`, view.s) → evy/evx, near-clip,
   reciprocal, screen-X → results land in the endpoint struct (VX1/VX2)
   AND the vcache entry.
3. **Near-plane crossing** (`bsp/resolve_crossing.s` via subsector.s):
   if exactly one endpoint is clipped, reproject from the vy=NEAR
   crossing point into that endpoint's struct slots.
4. **has_gap cull** (clipper query via jt): fused hi-byte range prelude
   in subsector.s; culled segs stop here — Y is never projected for them.
5. **y_stage** (subsector.s): pages L2 once, projects the flag-gated sy
   pairs per endpoint via `do_project_y` (seg_project.s) through the
   VWHC memo (project.s — front + inlined body, one routine). The chain
   donates the previous seg's front sy pair when valid (zp_ys_* flags).
6. **apv_stage** (`bsp/lo.s`): aperture-vertical pairs for solid segs
   with APEDGE flags, projected post-visibility.
7. **Endpoint canonicalization**: the seg layer OWNS left-to-right —
   `seg_swap_vx` deep-swaps the 15-byte endpoint structs on the rare
   reversal (~1/frame) and kills the chain key.
8. **Emission**: ft/fb/bt/bb horizontals via `SC_DRAW_S16_H` (X carries
   the sy-pair struct offset), endpoint/aperture verticals per NOVT/
   APEDGE flags, then a deferred solid/tighten op is queued (defq.s) and
   applied at subsector end IN SEG ORDER.

## Vertex key encoding (2026-07-12) — pervasive, easy to trip on

Header v1/v2 slots store **(A = idx & 255, B = idx >> 3)**, NOT (lo, hi).
B is consumed RAW as both the VCACHE valid-bitmap byte index and the
VXC_VALID index; the scaled forms rebuild in pure A-register shifts
(idx*8: lo = A<<3 mod 256, hi = B>>2 · idx*4: lo = A<<2, hi = B>>3); the
VXC page split is `B & $20` (idx >= 256 ⇔ B >= 32; B ≤ 58). Bijective:
idx = B*8 + (A & 7); the chain compare and the $FF-in-B invalidation work
unchanged. Producers/consumers that MUST stay in lockstep: wad_packed.py
`_vk` (pack), doom_wireframe.py packed_render_seg decode (~line 2176),
subsector.s staging, seg_xform.s prologue, view.s br_to_view_fetch,
vxcache.s.

## Source layout

    src/zp.inc           ZERO-PAGE REGISTRY — every ZP symbol, one file.
                         Overlay groups are deliberate; see "Zero page".
    src/layout.inc       Generated (tools/gen_layout_inc.py): ROM data
                         base constants per build, gated against
                         dw.packed_layout on harness import.
    src/abi.inc          Generated (tools/gen_abi.py): every cross-file
                         ADDRESS CONSTANT (banks, jt bases, driver vars,
                         cache switches, sqr bases). Also emits
                         abi_beeb.inc (drivers) and abi.py (harness).
                         "Private copies of addresses are forbidden" —
                         if two files need an address, it goes here.
    src/slope_div.s      Angle unit = ordered .includes of src/ang/:
      ang/header_div.s     jump table, SlopeDiv (exact, unrolled; the
                           slope_div_le entry skips the num<den re-proof
                           for corner_phi, which guarantees it)
      ang/bca.s            bbox_check_angle (angle-space visibility)
      ang/rcache.s         rotation-coherence psi cache (frame classifier,
                           cached check path)
      ang/corner_phi.s     box_classify + corner_phi (point_to_angle
                           inlined; returns phi hi in A, lo in Y)
    src/span_clip.s      Span clipper unit = ordered .includes of src/clip/:
      clip/header.s        build flags, jump table (+ .exports)
      clip/arith.s         umul8 (pinned $2030), udiv16_8
      clip/pool.s          span_init, alloc/free (32 slots @ $0400)
      clip/interp.s        interp_store (round-to-nearest lerp)
      clip/mark_solid.s    lazy column removal (split/truncate/shrink)
      clip/query.s         has_gap (+coherence cache), is_full, span_read
      clip/dcl.s           draw_clipped_line: per-span CB clip + emission
                           (LINE_OUT capture is HARNESS-ONLY, gated on
                           LINE_OUT_EN — the buffer overlaps the D-cache)
      clip/plot_axis.s     dedicated horizontal/vertical plotters (~70% of
                           rasterised pixels; byte strips / constant mask,
                           biased self-terminating descending runs)
      clip/tfr.s           tighten_from_records (3-cursor event walk,
                           tg_append_x merge) — THE production tighten
      clip/dcl_s16.s       s16 front-end: clips to u8, tail-calls DCL.
                           Callers guarantee x-order (seg layer owns it).
    src/bsp_render.s     Renderer unit = ordered .includes of src/bsp/:
      bsp/header.s         equates, macros (ZERO/BUMP/PAGE), jump table
                           (link-asserted vs abi ENGINE_JT both builds),
                           imports of clipper entries
      bsp/arith.s          br_umul8/br_smul8/br_smul_am, br_recip, rot
                           variants (rot_zero/unity/gen thunks/rot_core —
                           trig sign seeds zp_br_t1 via thunk SMC, one
                           XOR-folded tail negate)
      bsp/view.s           br_view_setup (frame hooks fan out from its
                           tail), br_to_view_fetch/br_to_view (s24),
                           br_smul_s8_u8/_am, rot_select target comments
      bsp/project.s        br_project_x, br_project_y_raw, the RNS
                           block (rns_go SMC'd JMP + rns_select + unrolled
                           shifter bodies s6-s10 + generic rns24)
      bsp/walk.s           br_init_frame, br_render_frame (BSP stack @
                           $0A00, deferred far children, is_full exit)
      bsp/backface.s       back-face test (C-form + DIR tables, u24 exact)
      bsp/bbox.s           br_bbox_visible -> angle module -> has_gap;
                           br_bbox_visible_d = forward-coherence D cache
      bsp/subsector.s      THE SEG LOOP (see pipeline above)
      bsp/seg_xform.s      vertex pipeline: vcache probe + vxc_arm +
                           compute tail (one file, one flow)
      bsp/seg_project.s    do_project_y consumer gating (front always,
                           back pairs flag-gated, solids RTS)
      bsp/main_tail.s      end_code assert (flat $5000 = RCACHE carve
                           fence; banked $5800 = FB)
      bsp/defq.s           deferred solid/tighten op queue ($0600)
      bsp/resolve_crossing.s  crossing resolver + VWHC array equates
      bsp/lo.s             br_node_setup (SoA reads), chain_reuse_v1,
                           apv_stage, reproject_at_crossing, wide X
                           projection (rns32), ap-edge verticals
      bsp/vxcache.s        VXC data planes + cold-store leaf + vxc_frame
                           (the per-vertex hot path lives in seg_xform)
      bsp/anim.s           animated sectors: mover tick state machines +
                           lazy visibility-driven table patching
    src/hud.s            debug HUD (banked: bank C window $A400)
    src/engine_flat.cfg  ld65 config, flat build (harness/regression)
    src/engine_banked.cfg  ld65 config, BANKED build (Model B disc)

The engine is **one ld65 link** of three objects; cross-module calls are
`.import`ed jump-table labels (`jt_*`), so a reordered/removed entry is a
link error, never a silent wrong address.

## Memory maps (2026-07-12, post flat-merge — the current truth)

Segment names describe WHAT code is; the per-build cfg decides WHERE it
goes. There are no `.if BANKED` segment aliases left to add — placement
belongs in the configs.

**Flat** (harness/regression; 5 regions, was 13):

    $0000-$00FF  ZP (src/zp.inc registry)
    $0100-$01FF  RESERVED FREE (stack + future; do not squat — Eben)
    $0200-$05FF  span pool / D-cache $0210-$03F7 / VXC state $05A0
    $0600-$08FF  DEFQ queue / TOP+BOT_RECORDS
    $09FB-$09FD  DEFQ_TAIL/OVF + corner idx  ** LIVE VARS, page 9 trap **
    $0A00-$0BD2  VXC YEXT plane pair ($0BE8 = LINE_OUT_EN flag, clear)
    $0C00-$1B3F  VCACHE (480×8) + valid bitmap $1B00
    $1B40-$1BFF  free
    $1C00-$1FFF  VXC XEXT/YLO plane pairs
    $2000-$366F  CLIPJT+CLIP (jt $2000 + umul8 $2030 = ABI pins)
    $3670-$4FFF  CODE: JT(=$3670, ENGINE_JT flat) MAIN LO B D W ANIML2
                 (end_code <= $5000 link-asserted)
    $5000-$57E8  RCACHE carve (the assert above is its fence)
    $5800-$6BFF  framebuffer
    $6C00-$973F  seg headers (stride 16) + DIR tables
    $9800-$9BFF  VXC XLO/XHI plane pairs
    $9C00-$A34B  verts
    $A400-$A4FF  SEL island (rot_select; cold, once per frame)
    $A500-$A8FF  sqr quarter-square tables (4 pages)
    $A900-$B1EE  NJ rasteriser  ** loaded by span_clip_6502.py, NOT in
                 any cfg — invisible to the linker, a placement trap **
    $B200-$B5FF  VXC YHI/YEXT... (YHI/YLO pairs; see vxcache.s)
    $B600-$C5FF  node/ss SoA pages
    $C600-$D4BF  bbox corner table
    $D500-$D9FF  VWHC arrays (page-aligned — the $C0 offset cost +1/probe)
    $DC00-$DFFF  TA_LO   $E000-$E3FF recip M8
    $E484-$E93F  anim tables ($E484 SSMASK..) + ACOLD island $E740
    $E940-$F1FF  ANG region (angle module)
    $F200-$FA01  TA_HI + VATOX    $FA10 BCA_WS    $FB00 VWH mover slots

**Banked** (Model B disc; banks = DATA ONLY, one code region):

    $0100-$01FF  RESERVED FREE (as flat)
    $1B40-$1B7F  BCA_WS (bca_ab $1B6F, driver-poked)
    $1C00-$1FFF  sqr tables (loader-seeded; TWIN equates in clip/arith.s
                 and bsp/header.s — keep in sync)
    $2000-$2BFF  beebasm drivers (drv $2000, vars $2180, glue $21A0,
                 sincos $2200, clears+input $2400)
    $2C00-$57FF  CODE: jt PINNED $2C00 (link-asserted), everything floats
    $5800-$7FFF  screen (double-buffered $5800/$6C00)
    $8000-$BFFF  sideways window; banks 4/6/7 = L0/C/L2:
      L0: SoA $8000 / seg headers $9000 / TABL0 $BE90
      C:  clipper $8000 / VXC planes $9700-$A2D3 / HUD $A400 window /
          rasteriser $A900
      L2: TA_LO $8000 / TA_HI $8400 / VATOX $8900 / bbox $8E00 / recip
          $9D00 / verts $A200 / RCACHE $AD00-$B4E8 / VWHC $B500-$B9FF /
          anim CFG $BA00
    SSMASK $0A80 = documented main-RAM exception (read under any bank).

RULES (absolute unless renegotiated): no level data in main RAM; no code
in a sideways bank without explicit permission (only clipper/raster/HUD
are blessed in C); page 1 stays free; validate ANY banked placement with
FB lockstep + a jsbeeb disc boot — harness green alone is not evidence
(PAGE is a no-op flat, so flat builds cannot catch wrong-bank calls).

## Building

    import asmbuild; asmbuild.build_all()        # flat (default variant)
    asmbuild.build_all(banked=1)                 # Model B layout

- Everything goes through `asmbuild.py` (ca65 + ld65). It is fail-loud and
  memoized per session. NEVER call the assembler directly from new code.
- Output binaries land in the repo root (span_clip.bin, bsp_render.bin,
  bsp_render_ang.bin + the *_bk variants + tiny island bins); the py65
  harnesses load them via `engine_load._regions`, which PARSES THE CFG —
  a new MEMORY area can never be silently missing from the loaders.
- `DOOM_CPU=65c02` selects the C02=1 build AND the matching py65 core.
- Disc image: `build_walk_ssd.py` (the playable artifact — cursor keys;
  bank images from build_anim_ssd.build_images, boot from modelb_boot.asm).
  The rotating spin/modelb discs were GC'd 2026-07-12 (git history has
  them). Boot shims use beebasm (vendored, stable); the engine does not.

## Addresses: use the symbol map, never literals

`symmap.sym('name')` returns the linked address of any label or equate
(per build variant). The whole Python harness resolves entry points, ZP
slots, and buffer bases this way. If you find yourself typing a hex
address into a Python file, stop and use the map (or abi.py for the
generated constants). Two hardcoded addresses cost half a day each on
2026-07-12: span_clip's sqr seed and test_bsp_render's jt entries.

## Zero page

`src/zp.inc` is the registry (included first by all three units).
Currently 200 symbols on 189 addresses, **58 free slots**
(`python3 tools/zpcheck.py` for the live map), 11 overlay groups.

- New variable: declare `name = ?` in zp.inc, run
  `python3 tools/zpcheck.py --alloc` (the build refuses while `?` pends).
- Overlay groups are deliberate phase-disjoint reuse. Do not join one
  without proving phase-disjointness; the group comments name the users.
- $70-$76, $79-$7A, $80-$88 are **rasteriser-owned** scratch, clobbered
  on every line draw.
- Unregistered squatters exist OUTSIDE the registry: ang/rcache.s owns
  $C4/$C5; bsp/anim.s owns $EB-$EE/$F0-$F1. zpcheck calls them "free".
  Grep ang/, anim and the drivers before claiming a "free" slot.

## Verification (the contract for ANY change)

    python3 run_regression.py              # must print ALL GREEN
    python3 run_regression.py --rebaseline # after a DELIBERATE cycle
                                           # change, with justification

GREEN = unit tests pass, check_angle_calls clean, compare_traversal /
compare_subsector 0px vs the Python packed reference, ground-truth verify
not worsened vs baseline.json, suite cycles within 0.25% of baseline.

- Cycle counts come from py65 execution only — NEVER estimate.
- The standard landing chain for engine changes: run_regression ALL GREEN
  → tools/vxcache_check.py (banked warm frames — THE warm-path metric;
  prints warm cycles, currently ~9.0M/20f = -9.9% vs disabled) →
  test_bare_boot.py → test_lockstep.py → tools/anim6502_check.py →
  tools/walkseq_check.py → tools/rotcache_check.py → rebaseline → commit
  → rebuild discs → push. Driver or region changes ADD a jsbeeb boot.
- Cold-vs-warm skew: the regression corpus renders isolated frame-1s
  (all caches cold, VXC off). It over-weights the angle pipeline (~12%
  cold, RCACHE-served warm) and CANNOT see warm-path wins (the fetch
  push-down measured -0.00% cold and -5% warm). Track both numbers.
- verify_6502_vs_python.py: float render_bsp is ground truth. Standing
  residue: 3px over at (911,-3366,13), 3px miss at (1057,-3809,135) —
  pre-existing, do not chase into unrelated changes.
- test_lockstep prints an FB nz mismatch line (model 4586 vs bare 557)
  and a $0063 diff — PRE-EXISTING diagnostic noise; test_bare_boot is
  the actual pass gate of that pair.
- walkseq_check warns "no warm speedup" at (1500,-3700) — pre-existing.
- Unit-test individual stages first; debug integrated frames only when
  isolation fails. Contracts enforced only in Python wrapper preludes are
  silent native traps — mirror them at the jt entry.

## Invariants you cannot see in the code

- **Interval conventions differ by module** (all match Python): has_gap
  closed [xstart,xend]; tighten pixel-centre strict overlap, fragments
  share boundary columns; mark_solid closed removal with ±1 fragments.
- **Carry-chaining across JSRs**: mark_solid's middle split and
  ev_clamp_evy16 rely on C surviving JSR/STA sequences. Also
  br_smul_am's entry consumes the N flag set by the CALLER's LDA
  (flags survive JSR). Documented at the sites; inserting instructions
  breaks them silently.
- **Flags-through-PAGE**: PAGE clobbers A and flags ONLY — X/Y ride
  through it (several dispatch sites depend on this).
- **Phase-disjoint memory overlays**: BBOX_CORNERS ($0A40) overlays the
  seg projection buffer; crossing scratch overlays seg-loop ZP. Safe only
  because bbox checks happen BETWEEN subsectors.
- **Deferred op queue**: solid/tighten ops queue at $0600, apply at
  subsector end with records SNAPSHOTS (later segs overwrite the records
  buffers — the snapshot is load-bearing). DEFQ_OVF flags drops.
- The BSP stack entry encoding requires node ids < $2000 and subsector
  hi-byte bit 6 clear (fine for E1M1).
- **VWHC purity**: the y-cache key is the complete input tuple of a pure
  function — entries survive frames and positions by design; only boot
  scrubs it. RLO doubles as the valid flag (live S is never 0).
- **RNS invariants**: S ∈ [1,10], never 0 (also the VWHC valid flag);
  the vector tables index `-1,X`; rns_select and the three INLINED
  selects in subsector.s all SMC `rns_go+1/+2` — a new rlo writer must
  re-vector or projections dispatch through a stale shifter.
- **seg_swap_vx** must stay AFTER s_advance's .endscope (a mid-loop
  splice once made ms_skip fall through into it).

## Cross-frame caches (all exactness-gated)

Three caches, driver-enabled (harness default off, byte-identical when
off):

- **VXC** (translation-coherent vertex transforms): ORIGIN-NORMALIZED
  (2026-07-12): stored base' = total − ref = L(w), exactly linear in
  integer arithmetic; warm read = base' + this frame's ref (published by
  vxc_frame = to_view(0,0)); angle change wipes VXC_VALID. The per-vertex
  path is IN seg_xform.s (vxc_arm); vxcache.s keeps planes + cold-store
  leaf + vxc_frame. Warm frames -9.9% vs disabled (vxcache_check).
- **RCACHE** (rotation-coherence bbox psi cache): position-keyed; caches
  RAW pre-clip p1/p2 per box; stable-position frames re-derive phi from
  cached psi (cp_havepsi). Flat data = the $5000 CODE-tail carve.
- **D cache** (forward-coherence bbox verdicts+extents): serves while
  movement stays in the view cone at fixed angle; 1/8 round-robin
  refresh; pixel-preserving ONLY because of the 2026-07-08 rounding gate
  (projection RN + outward-rounded/inflated packed bbox corners).
  Walking -10..-19%.

Also per-frame (not cross-frame): VCACHE (vertex results, $0C00, bitmap
cleared per frame in br_init_frame) and VWHC (Y-projection memo, pure-
function keyed, never cleared after boot).

## Known risks / open items

- **Pool exhaustion** (32 span slots) silently drops visible fragments;
  latent, not observed.
- **Flat placement traps** (all found the hard way 2026-07-12): page 9
  tail holds live DEFQ vars ($09FB-$09FD); $A900-$B1EE is the NJ
  rasteriser, loaded by span_clip_6502.py and INVISIBLE to the cfg; the
  VXC plane pairs need pages k,k+1 free per plane. Consult the memory
  map above before placing anything.
- **Soak divergence backlog**: 272k-position soak found 2.67%
  engine-vs-reference fails, engine UNDER-draws at far-west positions;
  triage via soak_triage.py (toolchain tag). Not a crash class.
- The walk build's VZ is spawn-constant (floor lookup TODO).
- dcl_yband_clip is a band-aid: off-screen segments mean the span
  clipper over-extends spans somewhere; find that bug, then re-evaluate.

## Performance

Suite cycles are gated by baseline.json: currently **4,359,539 total /
242,196 mean** over 18 positions (cold frames). Warm-path metric:
vxcache_check banked warm frames ~9.0M/20 (-9.9% vs disabled). The
optimisation history INCLUDING measured-and-rejected ideas lives in the
session memory notes and old commit messages — before re-proposing an
idea, `git log --grep` for it: rejected ideas include per-frame product
tables, y-cache associativity/S-boxes (birthday-bound), diagonal C-form
on raw coords (4-mul regression), VWH interpolation, lip staging, D-cache
gap-skips (angle-vs-Cartesian rounding), and slope_div skip chains.

## Legacy

`doom_fe.asm` is the pre-BSP-renderer generation; its Python side was
garbage-collected 2026-07-07; the rotating spin/modelb discs followed
2026-07-12 (recover any of it from git history). The full verification toolchain
(soak, profilers, comparators) lives at the `full-toolchain` git tag.
