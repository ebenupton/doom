
; ============================================================================
; br_render_frame — top-level entry. Walks the BSP from the root,
; visiting subsectors in front-to-back order, dispatching to the
; per-subsector handler (br_render_subsector).
;
; Caller must have:
;   - Loaded WAD ROM into memory.
;   - Set up zp_rom_*, zp_root_node_*.
;   - Set up player view state (zp_br_px, etc.) and called br_view_setup.
;   - Initialized the span pool (via span_init at $2000).
;   - Cleared the framebuffer.
; ============================================================================
; br_init_frame — clear vcache valid bitmap (so a fresh frame rebuilds
; vertex transforms). Exposed so the hybrid Python-BSP harness can call
; it before its first subsector pass.
br_init_frame:
; The VWH projection cache is self-validating: its key is the COMPLETE
; input (rhi,rlo,h) to br_project_y_raw, a pure function — so a hit is
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
.scope
JSR br_init_frame

; Initialize BSP stack: push root node id.
ZERO zp_bsp_stack_sp
LDX zp_bsp_stack_sp
LDA zp_root_node_lo
STA BSP_STACK,X
INX
LDA zp_root_node_hi
STA BSP_STACK,X
INX
STX zp_bsp_stack_sp

bsp_loop:
LDA zp_bsp_stack_sp
BNE bsp_pop
RTS                                     ; stack empty → done
bsp_pop:
DEC zp_bsp_stack_sp                     ; pop hi byte
LDX zp_bsp_stack_sp
LDA BSP_STACK,X
STA zp_node_chhi
DEC zp_bsp_stack_sp                     ; pop lo byte
LDX zp_bsp_stack_sp
LDA BSP_STACK,X
STA zp_node_chlo

PAGE BANK_C
JSR SC_IS_FULL
BNE bsp_done_full
bsp_dispatch:
; Entry kinds (hi byte): $80|sshi = subsector, $40|side<<5 = deferred
; far child (bbox-checked at pop time), else plain node id.
LDA zp_node_chhi
AND #$40
BNE bsp_deferred
LDA zp_node_chhi
AND #$80
BEQ bsp_node
LDA zp_node_chhi
AND #$7F
STA zp_node_chhi
JSR br_render_subsector
JMP bsp_loop
bsp_done_full:
LDA #0
STA zp_bsp_stack_sp
JMP bsp_loop

bsp_deferred:
; Deferred far child of node (chlo, chhi&$1F), side = bit 5.
; Python checks the far side AFTER the near subtree has rendered —
; this pop-time check sees exactly that span state.
LDA zp_node_chhi
AND #$20
BEQ bsp_df_s0
LDA #1
BNE bsp_df_have
bsp_df_s0:
LDA #0
bsp_df_have:
STA zp_bbox_side
LDA zp_node_chhi
AND #$1F
STA zp_node_chhi
JSR br_bbox_visible
BEQ bsp_loop_j                          ; far side invisible/occluded → skip
JSR bsp_resolve_child                   ; ch := node.children[side]
JMP bsp_dispatch
bsp_loop_j:
JMP bsp_loop

bsp_node:
JSR br_node_setup
; Push the far child as a DEFERRED (node, farside) entry — its
; bbox/has_gap runs at pop time, after the near subtree.
LDX zp_bsp_stack_sp
LDA zp_node_chlo
STA BSP_STACK,X
INX
LDA zp_side
EOR #1
ASL A
ASL A
ASL A
ASL A
ASL A
; farside << 5
ORA #$40
ORA zp_node_chhi
STA BSP_STACK,X
INX
STX zp_bsp_stack_sp
; Near child: bbox + has_gap NOW (Python checks near at visit time;
; the old walk pushed near unconditionally and over-visited).
LDA zp_side
STA zp_bbox_side
JSR br_bbox_visible
BEQ bsp_loop_j                          ; near side invisible → skip subtree
LDX zp_bsp_stack_sp
LDA BSP_NEAR_LO
STA BSP_STACK,X
INX
LDA BSP_NEAR_HI
STA BSP_STACK,X
INX
STX zp_bsp_stack_sp
JMP bsp_loop
.endscope

; (bsp_resolve_child lives in the D region.)

; (br_node_setup moved to bsp_render_lo.bin overflow region — see end of file)

; --- Children-id slots (set per bsp_node visit, used after bbox checks).
BSP_NEAR_LO = $096B
BSP_NEAR_HI = $096C
BSP_FAR_LO = $096D
BSP_FAR_HI = $096E

; ============================================================================
; br_render_subsector — placeholder; called per subsector during walk.
;   Input: zp_node_chlo:hi = subsector id (with high bit cleared).
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
SEG_PROJ_BUF = $0A40
zp_seg_sy1_top_lo = SEG_PROJ_BUF + 0
zp_seg_sy1_top_hi = SEG_PROJ_BUF + 1
zp_seg_sy1_bot_lo = SEG_PROJ_BUF + 2
zp_seg_sy1_bot_hi = SEG_PROJ_BUF + 3
zp_seg_sy2_top_lo = SEG_PROJ_BUF + 4
zp_seg_sy2_top_hi = SEG_PROJ_BUF + 5
zp_seg_sy2_bot_lo = SEG_PROJ_BUF + 6
zp_seg_sy2_bot_hi = SEG_PROJ_BUF + 7
; Per-vertex saved back-step projections.
zp_seg_sy1_btop_lo = SEG_PROJ_BUF + 8
zp_seg_sy1_btop_hi = SEG_PROJ_BUF + 9
zp_seg_sy1_bbot_lo = SEG_PROJ_BUF + 10
zp_seg_sy1_bbot_hi = SEG_PROJ_BUF + 11
zp_seg_sy2_btop_lo = SEG_PROJ_BUF + 12
zp_seg_sy2_btop_hi = SEG_PROJ_BUF + 13
zp_seg_sy2_bbot_lo = SEG_PROJ_BUF + 14
zp_seg_sy2_bbot_hi = SEG_PROJ_BUF + 15
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
