
; ============================================================================
; br_render_frame — top-level entry. Walks the BSP from the root,
; visiting subsectors in front-to-back order, dispatching to the
; per-subsector handler (br_render_subsector).
;
; Caller must have:
;   - Loaded WAD ROM into memory.
;   - (ROM bases are layout.inc constants since 2026-07-10 — no pointer setup.)
;   - Set up player view state (zp_br_px, etc.) and called br_view_setup.
;   - Initialized the span pool (via span_init at $2000).
;   - Cleared the framebuffer.
;
; Algorithm — iterative front-to-back walk with an explicit stack.
; Recursive Python reference (packed_render_bsp, doom_wireframe.py):
;   def render(nid):
;     if clips.is_full(): return
;     if nid & 0x8000: render_subsector(nid & 0x7fff); return
;     side = point_on_side(px, py, node)               # br_node_setup
;     if bbox_visible(node, side):                     # near child, NOW
;         render(children[side])
;     if clips.is_full(): return
;     if bbox_visible(node, side ^ 1):                 # far child, LATER
;         render(children[side ^ 1])
; The 6502 flattens the recursion: visiting a node checks the NEAR child's
; bbox immediately and pushes it, but first pushes a DEFERRED (node,
; farside) entry underneath it. The far child's bbox + has_gap check runs
; when that deferred entry is POPPED — i.e. after the entire near subtree
; has rendered — so it queries exactly the span/occlusion state the Python
; recursion sees at its second bbox_visible call.
;
; The traversal is RECURSIVE on the hardware stack since 2026-07-14:
; rc_node renders one internal node; it pushes (node id, far side) as
; locals, recurses on the near child, and tail-calls on the far.
; zp_bsp_stack_sp = the saved S for the is_full unwind. Ids are u8
; end to end (2026-07-15) — a child's subsector-ness lives in its
; PARENT's TYPE byte (NF_RLEAF/NF_LLEAF), not in the link.
; (br_init_frame retired 2026-07-15: the per-frame init lives inline at
; br_render_frame entry below; the jt slot and its harness/driver
; callers are gone — partial-flow harnesses poke the state from Python,
; see bsp_render_6502.poke_init_frame_state.)

br_render_frame:
.scope bsp_walk                         ; named: br_dcache_frame SMC-patches
                                        ; bsp_walk::bv_site_near/_far operands
; L0 anchor: the traversal's bank invariant (node_setup and the
; subsector serve no longer page — every path keeps L0 until the
; clipper/angle modules page for themselves and the child follows
; restore it). One PAGE per frame covers the seed.
   PAGE BANK_L0

; --- Per-frame init (the standalone br_init_frame is retired).
; Records-pointer ground state: the lo byte is never written non-zero
; anywhere (record pages are page-aligned) and every draw site
; arms/disarms the hi byte explicitly. Then the vcache valid-bitmap
; clear — entries are player-relative, so every frame starts cold
; (the VWH projection cache, by contrast, is self-validating and
; persists). 60-byte clear (59 used + 1 pad, inside the vcache
; reservation up to $1B3F), four 15-byte stripes off one X. ---
   LDA #0
   STA zp_dcl_rec_buf
   STA zp_dcl_rec_buf_h
   LDX #14
bif_clr2:
   STA VCACHE_VALID_BASE,X
   STA VCACHE_VALID_BASE+15,X
   STA VCACHE_VALID_BASE+30,X
   STA VCACHE_VALID_BASE+45,X
   DEX
   BPL bif_clr2

; --- RECURSIVE BSP traversal on the hardware stack ------------------
; This is a direct 6502 mirror of the reference pseudocode:
;
;   def render_frame():            #  (seed)
;       rc_node(ROOT)              #  root is internal by construction
;
;   def rc_node(id):               #  id arrives in zp_node_ch_l
;       if is_full(): unwind()     #  screen solid: nothing can show
;       side = node_setup(id)      #  player side of the partition
;       push id, side^1            #  the continuation's locals
;       if bbox_visible(id, side):
;           descend(child[id][side])          # near, as a CALL
;       side, id = pop, pop
;       if is_full(): unwind()
;       if bbox_visible(id, side):
;           descend(child[id][side])          # far, as a TAIL CALL
;
;   def descend(c):                #  leaf bit lives in the PARENT's
;       if leaf: render_subsector(c)          # TYPE byte (u8 ids,
;       else:    rc_node(c)                   # no link hi bytes)
;
; unwind() = one TXS to the S saved at frame entry: every pending
; frame vanishes at once and the RTS returns to our caller. JSR depth
; accrues only down near chains (depth x 4 stack bytes; the game loop
; runs interrupt-free). is_full sits exactly where the old iterative
; loop checked it, so the serve/bbox query sequence is walkseq-
; identical; it reads zp_head directly (unbanked — no paging).

; (FETCH_CHILD retired 2026-07-15: the side-specialised rc_node bodies
; inline each arm directly — see rc_node below.)

; --- seed: rc_node(ROOT) ---
   TSX
   STX zp_bsp_stack_sp                     ; unwind target
   LDA #<LAY_ROOT                          ; layout.inc constant (u8)
   STA zp_node_ch_l
   JMP rc_node_nc                          ; frame start is provably not
                                        ; full — skip the is_full entry


; ============================================================================
; NODE_SETUP_DISPATCH s0, s1 — point-on-side, inlined (moved from lo.s
; 2026-07-16; the walk is the single caller). Tests the player against
; node zp_node_ch_l's partition and JMPs s0 (right of line) / s1
; (left/on) DIRECTLY — no A verdict, no RTS round trip.
;   Inputs:  zp_node_ch_l = node id (u8); zp_br_pxraw/pyraw = player
;            position, RAW map units (s16 — the side test must not lose
;            a weak axis to /8 truncation). Bank L0 paged (callers all
;            hold it).
;   Axis nodes (TYPE forms 0-3, 73%): ONE strict s16 compare against
;   the NX/NY origin plane, direction sign baked at pack time.
;   General (TYPE 4): DIR delta form sharing CROSS_MAG_DECIDE with the
;   back-face test. Ties -> s1 everywhere (the mirror's D==0 rule).
;   Python mirror: doom_wireframe.point_on_side (raw s16 values).
;   Clobbers A, X; the shared cross slots + t0-t5 on the general path.
; ============================================================================
.macro NODE_SETUP_DISPATCH s0, s1
.local ns_t_general, ns_py_gt, ns_x0, ns_x1
.local nsd_dx0, nsd_dy0, nsd_s0, nsd_s1, nsd_mul
   LDX zp_node_ch_l
   LDA NODE_TYPE,X
   AND #NT_MASK                            ; bits 7/6 are the child leaf flags
; --- sense-normalized dispatch (2026-07-16): the packer child-swaps
; every '<' axis node into the '>' sense at load, so only TWO axis
; forms exist and the dispatch is 3-way: 0 px> (fall), 1 py>, 2 general.
   LSR A                                   ; 0:(A0 C0) 1:(A0 C1) 2:(A1 C0)
   BNE ns_t_general
   BCS ns_py_gt
; form 0: side0 iff px > nx — REVERSED subtract (2026-07-16): testing
; nx - px puts the tie on the fall-through side for free (side0 iff
; the diff is strictly negative). Same rule for form 1 (py). Ties fall
; to side1 (D == 0 -> side 1, the mirror's rule, post-normalization).
   LDA NODE_NXLO,X
   CMP zp_br_pxraw_l                       ; borrow seed (result dead)
   LDA NODE_NXHI,X
   SBC zp_br_pxraw_h                       ; diff' = nx - px
; (no V decode: the packer asserts map axis extent < 32768, so the s16
;  diff never overflows and N IS the sign — all four arms alike)
   BMI ns_x0                               ; nx < px -> side0
   JMP s1                                  ; tie or less -> side1 (always)
ns_x0:
   JMP s0
ns_py_gt:
; form 1: side0 iff py > ny — reversed like form 0
   LDA NODE_NYLO,X
   CMP zp_br_pyraw_l
   LDA NODE_NYHI,X
   SBC zp_br_pyraw_h
   BMI ns_x0                               ; ny < py -> side0
   JMP s1                                  ; tie or less -> side1
ns_t_general:
; --- general partition: DIR delta form (2026-07-15) — the packer bakes
; the gcd-reduced primitive direction as (NODE_DIRID, NODE_DSGN —
; b7 ndy neg / b6 ndx neg), sharing the seg DIR
; tables. Deltas against the origin planes stage into the SHARED cross
; slots, the sign shortcut mirrors bf_g_both, and the magnitude tier is
; the SAME CROSS_MAG_DECIDE core the back-face test expands: side0 is
; "front" (D = ndy*dx - ndx*dy > 0), ties side1. The old raw s16 x s16
; double-smul cascade (and br_smul_s16_s16_s32) is gone.
   LDA NODE_DSGN,X
   STA zp_br_sign                          ; b7 = sgn ndy, b6 = sgn ndx
   LDA NODE_DIRID,X
   STA zp_bf_dir                           ; DIR-table index
; dx = pxraw - nx (s16); hi rides A for the zero test
   LDA zp_br_pxraw_l
   SEC
   SBC NODE_NXLO,X
   STA zp_br_dx_l
   LDA zp_br_pxraw_h
   SBC NODE_NXHI,X
   STA zp_br_dx_h
   ORA zp_br_dx_l
   BEQ nsd_dx0
; dy = pyraw - ny (s16)
   LDA zp_br_pyraw_l
   SEC
   SBC NODE_NYLO,X
   STA zp_br_dy_l
   LDA zp_br_pyraw_h
   SBC NODE_NYHI,X
   STA zp_br_dy_h
   ORA zp_br_dy_l
   BEQ nsd_dy0                             ; dy==0: D = P1
; sign shortcut (mirror of bf_g_both): opposite product signs decide
; with no multiply; sign(D) = sign(P1)
   LDA zp_br_sign                          ; b7 = sgn ndy
   EOR zp_br_dx_h                          ; b7 = sign(P1)
   TAX                                     ; ride in X across the P2 sign
   LDA zp_br_sign
   ASL A                                   ; b6 (ndx sign) -> b7
   EOR zp_br_dy_h                          ; b7 = sign(P2)
   STA zp_br_t2
   TXA
   EOR zp_br_t2                            ; b7 set = opposite signs
   BPL nsd_mul                             ; same sign -> magnitude core
   TXA                                     ; opposite: sign(D) = sign(P1)
   BMI nsd_s1
   JMP s0
; dx == 0: D = -P2 = -(ndx*dy); side0 iff P2 < 0
; (dy == 0 too -> D = 0 -> side1)
nsd_dx0:
   LDA zp_br_pyraw_l
   SEC
   SBC NODE_NYLO,X
   STA zp_br_dy_l
   LDA zp_br_pyraw_h
   SBC NODE_NYHI,X
   STA zp_br_dy_h
   ORA zp_br_dy_l
   BEQ nsd_s1                              ; dx==0 and dy==0 -> side1
   LDA zp_br_sign
   ASL A                                   ; b7 = sgn ndx
   EOR zp_br_dy_h                          ; b7 = sign(P2)
   BMI nsd_s0                              ; D = -P2 > 0 iff P2 < 0
   BPL nsd_s1                              ; (always)
; dy == 0: D = P1 = ndy*dx (nonzero: dx != 0 here)
nsd_dy0:
   LDA zp_br_sign                          ; b7 = sgn ndy
   EOR zp_br_dx_h                          ; b7 = sign(P1)
   BMI nsd_s1
; local verdict stubs (the branches above can't reach past the macro)
nsd_s0:
   JMP s0
nsd_s1:
   JMP s1
nsd_mul:
   CROSS_MAG_DECIDE s0, s1
.endmacro

; descend: id in zp_node_ch_l, N = the child's leaf bit (staged by the
; caller's TYPE load, +ASL for left arms — flags ride through JSR/JMP).
; ONE leaf test per class (2026-07-16, was 4 site copies); near and far
; stay separate entries because their is_full contracts differ (far ran
; is_full just before its bbox check). Far owns the rc_node_nc fall-in
; — its node path is the hottest of the four.
rc_descend_near:
   BMI rc_leaf                             ; near leaf: is_full + render
   IS_FULL_B bsp_done_full2
   JMP rc_node_nc                          ; near node: the recursion
bsp_done_full2:
; unwind() twin: the inlined node_setup expansion below pushed the
; original out of branch range of this cluster — 5 bytes buys locality.
   LDX zp_bsp_stack_sp
   TXS
   RTS
rc_leaf:
; descend(subsector), near side (far leaves skip is_full — theirs ran
; just before the far bbox check).
   IS_FULL_B bsp_done_full2
rdf_leaf:
   JMP br_render_subsector
rc_descend_far:
   BMI rdf_leaf                            ; far leaf: straight to render
; SIDE-SPECIALISED (2026-07-15): node_setup returns side in A with Z
; live (every exit is LDA #imm / RTS), so ONE dispatch selects a
; right-then-left or left-then-right body with the child fetches
; INLINED per arm — no runtime side test in the fetches, no side on
; the stack (the continuation's side is its code position; only the id
; is pushed), and the bbox side stores reuse A / a bare immediate.
rc_node_nc:                             ; far-node fall-in (is_full done)
   NODE_SETUP_DISPATCH rc_s0, rc_n1        ; point-on-side: JMPs straight
                                        ; to the side body (no verdict
                                        ; register, no return trip)
rc_s0:
; === side 0: near = RIGHT child, far = LEFT child ===
   LDA #0
   STA zp_bbox_side
   LDA zp_node_ch_l
   PHA                                     ; push id (side is implicit)
bv_site_near0:                          ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible                     ; (<-> br_bbox_visible_d when D active)
   BEQ r0_far                              ; near invisible: skip subtree
   PAGE BANK_L0                            ; node SoA pages live in bank L0
   LDX zp_node_ch_l
   LDA NODE_CRLO,X                         ; inline RIGHT fetch
   STA zp_node_ch_l
   LDA NODE_TYPE,X                         ; N = NF_RLEAF
   JSR rc_descend_near
r0_far:
   PLA
   STA zp_node_ch_l                        ; id
   LDA #1
   STA zp_bbox_side                        ; far = LEFT
   IS_FULL_B bsp_done_full
bv_site_far0:                           ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible
   BEQ rc_ret                              ; far invisible: this node is done
   PAGE BANK_L0
   LDX zp_node_ch_l
   LDA NODE_CLLO,X                         ; inline LEFT fetch
   STA zp_node_ch_l
   LDA NODE_TYPE,X
   ASL A                                   ; N = NF_LLEAF
   JMP rc_descend_far                      ; TAIL call either way
rc_ret:
   RTS

bsp_done_full:
; unwind(): restore the frame-entry S — every pending frame is gone
; and the caller's return address is back on top. (Parked mid-block,
; between the two side variants: keeps every IS_FULL_B in range and
; the seed fall-in.)
   LDX zp_bsp_stack_sp
   TXS
   RTS

rc_n1:
; === side 1: near = LEFT child, far = RIGHT child === (mirror)
   LDA #1
   STA zp_bbox_side
   LDA zp_node_ch_l
   PHA
bv_site_near1:                          ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible
   BEQ r1_far
   PAGE BANK_L0
   LDX zp_node_ch_l
   LDA NODE_CLLO,X                         ; inline LEFT fetch
   STA zp_node_ch_l
   LDA NODE_TYPE,X
   ASL A                                   ; N = NF_LLEAF
   JSR rc_descend_near
r1_far:
   PLA
   STA zp_node_ch_l
   LDA #0
   STA zp_bbox_side                        ; far = RIGHT
   IS_FULL_B bsp_done_full
bv_site_far1:                           ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible
   BEQ rc_ret1
   PAGE BANK_L0
   LDX zp_node_ch_l
   LDA NODE_CRLO,X                         ; inline RIGHT fetch
   STA zp_node_ch_l
   LDA NODE_TYPE,X                         ; N = NF_RLEAF
   JMP rc_descend_far                      ; TAIL call either way
rc_ret1:
   RTS
.endscope

; (bsp_resolve_child was inlined above, 2026-07-14.)

; (br_node_setup lives in lo.s — LO segment, one CODE region both builds)

; (BSP_NEAR/FAR child staging retired 2026-07-15: the walk follows
; children straight from the SoA pages; $096B-$096E are free.)

; ============================================================================
; br_render_subsector — called per subsector during walk.
;   Input: zp_node_ch_l = subsector id (u8).
;
; (Historical note: this banner predates the real implementation — the
; routine now lives in src/bsp/subsector.s and does exactly the steps
; below, plus deferred solid/tighten routing via the DEFQ op queue.)
;
; Real impl needs to:
;   1. Read subsector header from ROM_SS + id*4: (count, pad, first_seg).
;   2. For each seg in [first_seg, first_seg + count):
;      a. Read seg header from ROM_SEG_HDR + i*12.
;      b. Back-face test (skip if behind).
;      c. Transform vertices (use vcache).
;      d. Project to screen.
;      e. Emit lines based on seg flags (solid/portal/step/aperture).
;      f. Tighten span list (or mark_solid for solids).
;
; This stub just RTS's; the BSP walker still works and visits all
; subsectors. Useful for verifying traversal in isolation.
; ============================================================================
; --- Test instrumentation: subsector visit bitmap at $0A80 ---
; ($0A80-$0A9F free, 2026-07-15: the write-only visited bitmap is gone;
;  B-region code starts at $0AA0. Banked $0A80 = ANIM_SSMASK as before.)
; (Deferred mark_solid buffer replaced by the unified DEFQ op queue at
; $0600 — see DEFQ_BASE above. It preserves seg ORDER across solid and
; tighten ops, matching Python's deferred list.)

; --- Per-seg working state ---
; Per-vertex helper outputs (set by br_seg_xform_vertex)
; Back-sector heights (s8 each) — only meaningful for portal segs.
zp_seg_btop_dlt = $0A7A                 ; bch - vz
zp_seg_bbot_dlt = $0A7B                 ; bfh - vz
; Output of bv_proj_one's back-step projection (transient).
zp_seg_sy_btop_lo = $0A7C
zp_seg_sy_btop_hi = $0A7D
zp_seg_sy_bbot_lo = $0A7E
zp_seg_sy_bbot_hi = $0A7F
; Per-seg saved vertex projections live in RAM (ZP $70+ is rasteriser
; territory: RASTER_ZP_SCRSTRT=$70, RASTER_ZP_X0..Y1=$82-$85). Use the
; gap left of the B-region code at $0AA0 ($0A00-$0A9F all free now).
; (SEG_PROJ_BUF retired 2026-07-10: the per-endpoint sy pairs live in the
; packed ZP vertex structs (zp.inc VX1/VX2) — written by do_project_y via
; zp_seg_ep, read by emit through the same zp_seg_sy* names, now 1 cycle
; cheaper as ZP. $0A40-$0A7F now belongs to BBOX_CORNERS alone.)
; Per-vertex view-space integer values, for near-plane crossing math.
; Always populated by br_seg_xform_vertex into "current" slots; the seg
; loop copies into v1/v2 slots so we have both vertices' values when
; computing the crossing point.
; Hot per-vertex view coords promoted to real ZP (were $0A50.. absolute) —
; safe-free ZP (0-access incl. rasteriser; not used by the angle module).
; cross_compute reads zp_seg_v{1,2}_{evy,evx} directly. Output:
zp_clip_cx = $0A5C                      ; output: crossing-point view-x (s16 lo)
zp_clip_cx_hi = $0A5D                   ; output: crossing-point view-x (s16 hi)
; Working-saver for projecting X after project_y trashes vxlo/hi
; Per-seg back-face / linedef state
