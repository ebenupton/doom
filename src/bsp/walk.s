
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

; --- RECURSIVE BSP traversal on the hardware stack (2026-07-14).
; The return address IS the continuation: rc_node renders one internal
; node — it pushes two locals (node id, far side) around the near
; recursion, then bbox-checks the far side and TAIL-CALLS itself on it
; (so JSR depth accrues only down near chains: depth x 4 bytes of
; frames under the deepest render JSR nesting, against the 256-byte
; page; the game loop runs interrupt-free). is_full is checked exactly
; where the old loop checked it — before every child dispatch — and
; unwinds every pending frame with one TXS to the S saved at entry.
;
; Ids are u8 END TO END (2026-07-15): child links have no hi byte.
; Whether a child is a subsector comes from the parent's TYPE byte
; (NF_RLEAF bit 7 / NF_LLEAF bit 6), read at child-follow time — one
; ASL per side drops the flag into C while A takes the id. Dispatch is
; entrant-decided: near leaves JSR rc_leaf, near nodes JSR rc_node, far
; leaves tail straight into br_render_subsector.
   TSX
   STX zp_bsp_stack_sp                     ; saved S (is_full unwind target)
   LDA #<LAY_ROOT                          ; layout.inc constant (u8)
   STA zp_node_ch_l
; falls into rc_node (the root is an internal node by construction);
; its terminal RTS returns to our caller

; --- rc_node: render the internal node whose id is in zp_node_ch_l ---
; rc_node checks is_full first (the old loop's per-pop checkpoint);
; rc_node_nc skips it — the far tail-call path has just checked, and
; the old flow dispatched resolved far children without a re-check, so
; this keeps the is_full/bbox query sequence byte-identical (walkseq).
rc_node:
; Screen full → nothing more can become visible anywhere; unwind the
; whole recursion (mirrors Python's `if clips.is_full(): return` at
; every level). is_full is INLINE (2026-07-15): the clipper's truth is
; just zp_head == 0 (active span list empty) and ZP is unbanked — no
; JSR, and no bank-C swap in the traversal at all.
   LDA zp_head
   BEQ bsp_done_full
rc_node_nc:
   JSR br_node_setup                       ; → zp_side (0 right / 1 left)
; push the continuation locals: node id, then the FAR side (0/1)
   LDA zp_node_ch_l
   PHA
   LDA zp_side
   EOR #1                                  ; far side = near side ^ 1
   PHA
; near child: bbox + has_gap NOW (Python checks near at visit time)
   LDA zp_side
   STA zp_bbox_side
bv_site_near:                           ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible                     ; (↔ br_bbox_visible_d when D active)
   BEQ rc_near_skip                        ; near side invisible → skip subtree
; near := children[side]; the leaf bit rides the parent's TYPE byte.
; (zp_bbox_side survives the bbox call — no writer outside this file
; and br_node_setup; audited 2026-07-15.)
   PAGE BANK_L0                            ; node SoA pages live in bank L0
   LDX zp_node_ch_l
   LDA zp_bbox_side
   BNE rc_n_left
   LDA NODE_TYPE,X
   ASL                                     ; C = NF_RLEAF
   LDA NODE_CRLO,X
   BCS rc_n_leaf
   BCC rc_n_node                           ; always (C clear)
rc_n_left:
   LDA NODE_TYPE,X
   ASL
   ASL                                     ; C = NF_LLEAF
   LDA NODE_CLLO,X
   BCS rc_n_leaf
rc_n_node:
   STA zp_node_ch_l
   JSR rc_node                             ; ← the recursion
   JMP rc_near_skip
bsp_done_full:
; Unwind every pending recursion frame in one move: restore the S saved
; at frame entry. (The caller's return address is back on top.) Parked
; mid-block, in the dead space between the near arms: all three
; BNE sites reach it even with the banked PAGE expansion.
   LDX zp_bsp_stack_sp
   TXS
   RTS
rc_n_leaf:
   STA zp_node_ch_l
   JSR rc_leaf
rc_near_skip:
; --- resume: the far side of the node whose locals are on top ---
   PLA                                     ; far side (0/1)
   STA zp_bbox_side
   PLA
   STA zp_node_ch_l                        ; node id (u8)
; is_full before the far dispatch — same checkpoint the old loop had
; after popping a deferred entry. (inline: zp_head == 0, unbanked)
   LDA zp_head
   BEQ bsp_done_full
bv_site_far:                            ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible                     ; (↔ br_bbox_visible_d when D active)
   BEQ rc_done                             ; far side invisible → done here
; far := children[far side]; nodes tail-call rc_node_nc (is_full just
; checked), leaves tail straight into the subsector render — the old
; flow's far-leaf path skipped the re-check too.
   PAGE BANK_L0
   LDX zp_node_ch_l
   LDA zp_bbox_side
   BNE rc_f_left
   LDA NODE_TYPE,X
   ASL                                     ; C = NF_RLEAF
   LDA NODE_CRLO,X
   BCS rc_f_leaf
   STA zp_node_ch_l
   JMP rc_node_nc                          ; tail call — no frame accrues
rc_f_left:
   LDA NODE_TYPE,X
   ASL
   ASL                                     ; C = NF_LLEAF
   LDA NODE_CLLO,X
   BCS rc_f_leaf
   STA zp_node_ch_l
   JMP rc_node_nc                          ; tail call
rc_f_leaf:
   STA zp_node_ch_l
   JMP br_render_subsector                 ; tail call — its RTS is ours
rc_leaf:
; near-side subsector: same is_full checkpoint the old dispatch gave
; every near child before rendering. (inline: zp_head == 0, unbanked)
   LDA zp_head
   BEQ bsp_done_full
   JMP br_render_subsector
rc_done:
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
