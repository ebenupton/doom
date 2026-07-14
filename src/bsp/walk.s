
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
; rc_child renders one child id; internal nodes push (node_lo,
; farside) as locals, recurse on the near child, and tail-call
; on the far. zp_bsp_stack_sp = the saved S for the is_full unwind.
; Child ids (hi byte):
;   $80 | ss_hi           : subsector id (bit 15 of the WAD child id)
;   $40 | side<<5 | nd_hi : deferred far child of node (lo, hi & $1F)
;   otherwise             : plain node id
; ============================================================================
; br_init_frame — clear vcache valid bitmap (so a fresh frame rebuilds
; vertex transforms). Exposed so the hybrid Python-BSP harness can call
; it before its first subsector pass.
;   Inputs:  none (VCACHE_VALID_BASE fixed at $1B00).
;   Output:  VCACHE_VALID_BASE[0..58] = 0 (one valid bit per vertex,
;            59 bytes covering 467 vertices).
;   Clobbers: A, X.
br_init_frame:
; once-per-frame records-pointer ground state (2026-07-11): the lo byte
; is never written non-zero anywhere (record pages are page-aligned) and
; every draw site arms/disarms the hi byte explicitly — the old per-seg
; zeroing was dead stores on culled segs.
   LDA #0
   STA zp_dcl_rec_buf
   STA zp_dcl_rec_buf_h
; The VWH projection cache is self-validating: its key is the COMPLETE
; input (rhi,rlo,h) to br_project_y's raw body, a pure function — a hit is
; correct regardless of age (stale key -> mismatch -> miss). Per-frame
; invalidation is therefore unnecessary; we skip the 256-byte clear and
; let entries persist (a free cross-frame hit-rate bonus under motion).
; (VWHC_VALID must be zeroed ONCE at boot; the key check is the backstop
;  for any residual garbage. The vcache below IS player-relative and must
;  still clear every frame.)
   LDA #0
   LDX #59
bif_clr:
   DEX
   STA VCACHE_VALID_BASE,X
   BNE bif_clr
   RTS

br_render_frame:
.scope bsp_walk                         ; named: br_dcache_frame SMC-patches
   JSR br_init_frame                       ; bsp_walk::bv_site_near/_far operands

; --- RECURSIVE BSP traversal on the hardware stack (2026-07-14).
; The return address IS the continuation: rc_child renders one child id
; (subsector or node); an internal node pushes two locals — node_lo and
; side<<5|node_hi, the old deferred-tag byte minus its now-redundant $40
; marker — recurses on the visible near child, and on return decodes the
; locals, bbox-checks the far side and TAIL-CALLS itself on it (so JSR
; depth accrues only down near chains: depth x 4 bytes of frames under
; the deepest render JSR nesting, against the 256-byte page; the game
; loop runs interrupt-free). is_full is checked exactly where the old
; loop checked it — before every child dispatch — and unwinds every
; pending frame with one TXS to the S saved at frame entry.
   TSX
   STX zp_bsp_stack_sp                     ; saved S (is_full unwind target)
   LDA #<LAY_ROOT                          ; layout.inc constant
   STA zp_node_ch_l
   LDA #>LAY_ROOT
   STA zp_node_ch_h
; falls into rc_child; its terminal RTS returns to our caller

; --- rc_child: render the child id in zp_node_ch_l/h ---
; rc_child checks is_full first (the old loop's per-pop checkpoint);
; rc_child_nc skips it — the far tail-call path has just checked, and
; the old flow dispatched resolved far children without a re-check, so
; this keeps the is_full/bbox query sequence byte-identical (walkseq).
rc_child:
; Screen full → nothing more can become visible anywhere; unwind the
; whole recursion (mirrors Python's `if clips.is_full(): return` at
; every level).
   PAGE BANK_C
   JSR SC_IS_FULL
   BNE bsp_done_full
rc_child_nc:
   LDA zp_node_ch_h
   BMI rc_subsector                        ; bit 15 = subsector leaf
; --- internal node ---
   JSR br_node_setup                       ; → zp_side, BSP_NEAR/FAR ids
; push the continuation locals: node_lo, then the FAR side, already
; canonical 0/1 (node ids fit u8 — the packer asserts n_nodes <= 256 —
; so the old side<<5|node_hi pack carried an identically-zero hi byte;
; the resume-time decode/canonicalise is gone with it)
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
   LDA BSP_NEAR_LO
   STA zp_node_ch_l
   LDA BSP_NEAR_HI
   STA zp_node_ch_h
   JSR rc_child                            ; ← the recursion
rc_near_skip:
; --- resume: the far side of the node whose locals are on top ---
   PLA                                     ; far side (0/1, canonical)
   STA zp_bbox_side
   PLA
   STA zp_node_ch_l
   LDA #0                                  ; node ids are u8 (the near
   STA zp_node_ch_h                        ; subtree clobbered ch_h)
; is_full before the far dispatch — same checkpoint the old loop had
; after popping a deferred entry.
   PAGE BANK_C
   JSR SC_IS_FULL
   BNE bsp_done_full
bv_site_far:                            ; operand SMC-patched by br_dcache_frame
   JSR br_bbox_visible                     ; (↔ br_bbox_visible_d when D active)
   BEQ rc_done                             ; far side invisible → done here
; ch := node.children[side] — resolve from the SoA pages and tail-call
   PAGE BANK_L0                            ; node SoA pages live in bank L0
   LDX zp_node_ch_l
   LDA zp_bbox_side
   BNE rc_left
   LDA NODE_CRLO,X
   STA zp_node_ch_l
   LDA NODE_CRHI,X
   STA zp_node_ch_h
   JMP rc_child_nc                         ; tail call — no frame accrues
rc_left:
   LDA NODE_CLLO,X
   STA zp_node_ch_l
   LDA NODE_CLHI,X
   STA zp_node_ch_h
   JMP rc_child_nc                         ; tail call
rc_subsector:
; Subsector: strip the tag bit and render its segs. (WAD id $FFFF is
; pre-normalized to subsector 0 by the packer/wrapper.)
   AND #$7F
   STA zp_node_ch_h
   JMP br_render_subsector                 ; tail call — its RTS is ours
rc_done:
   RTS
bsp_done_full:
; Unwind every pending recursion frame in one move: restore the S saved
; at frame entry. (The caller's return address is back on top.)
   LDX zp_bsp_stack_sp
   TXS
   RTS
.endscope

; (bsp_resolve_child was inlined above, 2026-07-14.)

; (br_node_setup lives in lo.s — LO segment, one CODE region both builds)

; --- Children-id slots (set per bsp_node visit, used after bbox checks).
; Raw WAD 16-bit child ids (bit 15 = subsector), NEAR = children[zp_side],
; FAR = children[zp_side^1]. Absolute slots: they must survive the bbox
; check (which clobbers most of the ZP scratch) between setup and push.
BSP_NEAR_LO = $096B
BSP_NEAR_HI = $096C
BSP_FAR_LO = $096D
BSP_FAR_HI = $096E

; ============================================================================
; br_render_subsector — called per subsector during walk.
;   Input: zp_node_ch_l:hi = subsector id (with high bit cleared).
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
SS_VISITED_BITMAP = $0A80               ; 30 bytes used (237 subsectors); B-region code starts at $0AA0
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
; gap between BSP_STACK ($0A00-$0A3F) and SS_VISITED_BITMAP ($0A80).
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
