
; ============================================================================
; Translation-coherence vertex cache (VXC).
;
; The view transform is EXACTLY linear in the integer world deltas (br_rot_int
; products are exact integer multiplies), and the per-frame fractional terms
; are position-only constants. So between two frames with the SAME angle byte,
; every vertex's raw s24 view totals shift by the SAME per-frame constant —
; the shift of any one fixed reference point. We transform world (0,0) each
; frame; with ref_cold captured at the last cold frame,
;
;   CACC        = ref_now - ref_cold            (per-frame, s24 x2)
;   store (cold): base = total - CACC           (per vertex, on first visit)
;   load (warm):  total = base + CACC           (replaces br_to_view: ~1130cyc)
;
; The telescoping identity makes staleness a non-issue: a vertex last visited
; k frames ago still reconstructs its exact total from base + today's CACC.
; Any translation qualifies (forward/back/strafe/diagonal, fractional steps);
; a changed angle byte is a cold frame (bitmap wiped, ref_cold re-anchored).
;
; Dispatch: vxc_frame (called from br_view_setup) SMC-patches the operand of
; seg_xform's `JSR br_to_view` (vxc_jsr_site+1) between br_to_view (disabled —
; zero cost, byte-identical path) and vxc_to_view. VXC_ENABLE lives in low
; RAM ($05DB) so drivers set it without paging.
;
; Memory: valid bitmap + state at $05A0-$05FF (unbanked, both builds).
; Planes (467 bytes each, page-aligned): banked -> bank C free space
; ($9700-$A2D3; clipper ends ~$9594, rasteriser starts $A900); flat ->
; $4000/$4200/$4400/$4600 (RCACHE..MAIN gap) + $B200/$B400 (raster..FHCH gap).
; Fat load/store code: banked -> VXCODE segment (bank C $A300; runs with
; BANK_C paged, touches only low RAM + its own bank); flat -> ANG segment
; (NOT $D4C0-$DABF - that gap is the flat VWHC cache BSS). Resident stub
; (vxc_to_view) -> MAIN.
; ============================================================================

; --- data equates (unbanked) ---
VXC_VALID   = $05A0                     ; 59 bytes (467 vertices)
VXC_ENABLE  = $05DB
vxc_prev_ab = $05DC
vxc_cacc_x  = $05DD                     ; s24
vxc_cacc_y  = $05E0                     ; s24
vxc_refc_x  = $05E3                     ; s24 ref_cold
vxc_refc_y  = $05E6                     ; s24

; --- plane bases (467 bytes each; page-aligned so hi-page access is +$100) ---
.if ::BANKED
VXC_XLO  = $9700                        ; bank C
VXC_XHI  = $9900
VXC_XEXT = $9B00
VXC_YLO  = $9D00
VXC_YHI  = $9F00
VXC_YEXT = $A100
.else
VXC_XLO  = $4000
VXC_XHI  = $4200
VXC_XEXT = $4400
VXC_YLO  = $4600
VXC_YHI  = $B200
VXC_YEXT = $B400
.endif

; local duplicate (slope_div.s precedent): angle byte written per frame
.if ::BANKED
vxc_ab = $3A00+$2F                      ; = bca_ab (BCA_WS+$2F)
.else
vxc_ab = $FA00+$2F
.endif

; ============================================================================
; Resident stub — replaces br_to_view via the vxc_jsr_site SMC when enabled.
; In: zp_seg_v_idx_lo/hi (vertex index), zp_seg_v_bitm (1 << (idx&7), already
;     computed by the per-frame VCACHE check), zp_br_dx/dy loaded (ignored on
;     a warm hit). Out: zp_br_vx/vy lo/hi/ext = exact view totals.
; ============================================================================
.segment "MAIN"
vxc_to_view:
.scope
LDA zp_seg_v_idx_lo
LSR A
LSR A
LSR A
LDX zp_seg_v_idx_hi
BEQ vt_xok
ORA #32                                 ; idx>>3 for idx in 256..466 (r>>3<=26)
vt_xok:
TAX
PAGE BANK_C
LDA VXC_VALID,X
AND zp_seg_v_bitm
BEQ vt_cold
JSR vxc_warm_load                       ; VXCODE: total = base + CACC -> zp
PAGE BANK_L0
RTS
vt_cold:
LDA VXC_VALID,X
ORA zp_seg_v_bitm
STA VXC_VALID,X
PAGE BANK_L0
JSR br_to_view
PAGE BANK_C
JSR vxc_cold_store                      ; VXCODE: base = total - CACC
PAGE BANK_L0
RTS
.endscope

; ============================================================================
; Fat paths — run with BANK_C paged (flat: plain resident code in ANG).
; ============================================================================
.if ::BANKED
.segment "VXCODE"
.else
.segment "ANG"
.endif

vxc_warm_load:
.scope
LDY zp_seg_v_idx_lo
LDA zp_seg_v_idx_hi
BNE vw_hi
CLC
LDA VXC_XLO,Y
ADC vxc_cacc_x+0
STA zp_br_vxlo
LDA VXC_XHI,Y
ADC vxc_cacc_x+1
STA zp_br_vxhi
LDA VXC_XEXT,Y
ADC vxc_cacc_x+2
STA zp_br_vxext
CLC
LDA VXC_YLO,Y
ADC vxc_cacc_y+0
STA zp_br_vylo
LDA VXC_YHI,Y
ADC vxc_cacc_y+1
STA zp_br_vyhi
LDA VXC_YEXT,Y
ADC vxc_cacc_y+2
STA zp_br_vyext
RTS
vw_hi:
CLC
LDA VXC_XLO+$100,Y
ADC vxc_cacc_x+0
STA zp_br_vxlo
LDA VXC_XHI+$100,Y
ADC vxc_cacc_x+1
STA zp_br_vxhi
LDA VXC_XEXT+$100,Y
ADC vxc_cacc_x+2
STA zp_br_vxext
CLC
LDA VXC_YLO+$100,Y
ADC vxc_cacc_y+0
STA zp_br_vylo
LDA VXC_YHI+$100,Y
ADC vxc_cacc_y+1
STA zp_br_vyhi
LDA VXC_YEXT+$100,Y
ADC vxc_cacc_y+2
STA zp_br_vyext
RTS
.endscope

vxc_cold_store:
.scope
LDY zp_seg_v_idx_lo
LDA zp_seg_v_idx_hi
BNE vs_hi
SEC
LDA zp_br_vxlo
SBC vxc_cacc_x+0
STA VXC_XLO,Y
LDA zp_br_vxhi
SBC vxc_cacc_x+1
STA VXC_XHI,Y
LDA zp_br_vxext
SBC vxc_cacc_x+2
STA VXC_XEXT,Y
SEC
LDA zp_br_vylo
SBC vxc_cacc_y+0
STA VXC_YLO,Y
LDA zp_br_vyhi
SBC vxc_cacc_y+1
STA VXC_YHI,Y
LDA zp_br_vyext
SBC vxc_cacc_y+2
STA VXC_YEXT,Y
RTS
vs_hi:
SEC
LDA zp_br_vxlo
SBC vxc_cacc_x+0
STA VXC_XLO+$100,Y
LDA zp_br_vxhi
SBC vxc_cacc_x+1
STA VXC_XHI+$100,Y
LDA zp_br_vxext
SBC vxc_cacc_x+2
STA VXC_XEXT+$100,Y
SEC
LDA zp_br_vylo
SBC vxc_cacc_y+0
STA VXC_YLO+$100,Y
LDA zp_br_vyhi
SBC vxc_cacc_y+1
STA VXC_YHI+$100,Y
LDA zp_br_vyext
SBC vxc_cacc_y+2
STA VXC_YEXT+$100,Y
RTS
.endscope

; ============================================================================
; Per-frame hook — called from br_view_setup after the view context (fracs)
; is built. Banked: runs from the L2 window (caller paged BANK_L2); touches
; only low RAM, ZP and resident MAIN (br_to_view, the SMC site).
; ============================================================================
.if ::BANKED
.segment "RCCODE"
.else
.segment "ANG"
.endif

vxc_frame:
.scope
LDA VXC_ENABLE
BNE vf_on
; disabled: restore the original br_to_view target (byte-identical path)
LDA #<br_to_view
STA vxc_jsr_site+1
LDA #>br_to_view
STA vxc_jsr_site+2
RTS
vf_on:
; ref = view totals of world (0,0) under this frame's context
LDA #0
STA zp_br_dxlo
STA zp_br_dxhi
STA zp_br_dylo
STA zp_br_dyhi
JSR br_to_view
LDA vxc_ab
CMP vxc_prev_ab
BEQ vf_warm
; --- cold frame: re-anchor ref_cold, zero CACC, wipe the valid bitmap ---
STA vxc_prev_ab
LDA zp_br_vxlo
STA vxc_refc_x+0
LDA zp_br_vxhi
STA vxc_refc_x+1
LDA zp_br_vxext
STA vxc_refc_x+2
LDA zp_br_vylo
STA vxc_refc_y+0
LDA zp_br_vyhi
STA vxc_refc_y+1
LDA zp_br_vyext
STA vxc_refc_y+2
LDA #0
LDX #5
vf_zc:
STA vxc_cacc_x,X                        ; cacc_x/y are contiguous (6 bytes)
DEX
BPL vf_zc
LDX #58
LDA #0
vf_wipe:
STA VXC_VALID,X
DEX
BPL vf_wipe
JMP vf_patch
vf_warm:
; --- warm frame: CACC = ref - ref_cold (s24 x2) ---
SEC
LDA zp_br_vxlo
SBC vxc_refc_x+0
STA vxc_cacc_x+0
LDA zp_br_vxhi
SBC vxc_refc_x+1
STA vxc_cacc_x+1
LDA zp_br_vxext
SBC vxc_refc_x+2
STA vxc_cacc_x+2
SEC
LDA zp_br_vylo
SBC vxc_refc_y+0
STA vxc_cacc_y+0
LDA zp_br_vyhi
SBC vxc_refc_y+1
STA vxc_cacc_y+1
LDA zp_br_vyext
SBC vxc_refc_y+2
STA vxc_cacc_y+2
vf_patch:
LDA #<vxc_to_view
STA vxc_jsr_site+1
LDA #>vxc_to_view
STA vxc_jsr_site+2
RTS
.endscope

; restore the segment for subsequently-included parts (they inherit)
.segment "MAIN"
