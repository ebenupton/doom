
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

; descend: id in zp_node_ch_l, N = the child's leaf bit (staged by the
; caller's TYPE load, +ASL for left arms — flags ride through JSR/JMP).
; ONE leaf test per class (2026-07-16, was 4 site copies); near and far
; stay separate entries because their is_full contracts differ (far ran
; is_full just before its bbox check). Far owns the rc_node_nc fall-in
; — its node path is the hottest of the four.
rc_descend_near:
   BMI rc_leaf                             ; near leaf: is_full + render
   IS_FULL_B bsp_done_full
   JMP rc_node_nc                          ; near node: the recursion
rc_descend_far:
   BMI rdf_leaf                            ; far leaf: straight to render
; SIDE-SPECIALISED (2026-07-15): node_setup returns side in A with Z
; live (every exit is LDA #imm / RTS), so ONE dispatch selects a
; right-then-left or left-then-right body with the child fetches
; INLINED per arm — no runtime side test in the fetches, no side on
; the stack (the continuation's side is its code position; only the id
; is pushed), and the bbox side stores reuse A / a bare immediate.
rc_node_nc:                             ; far-node fall-in (is_full done)
   JSR br_node_setup                       ; -> A = side, Z = (side == 0)
   BNE rc_n1                               ; side 1: LEFT first
; === side 0: near = RIGHT child, far = LEFT child ===
   STA zp_bbox_side                        ; A = 0
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

rc_leaf:
; descend(subsector), near side (far leaves tail straight into the
; render below — their is_full ran just before the far bbox check).
   IS_FULL_B bsp_done_full
rdf_leaf:
   JMP br_render_subsector

rc_n1:
; === side 1: near = LEFT child, far = RIGHT child === (mirror)
   STA zp_bbox_side                        ; A = 1
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
