
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
; seg_xform's `JSR br_to_view_fetch` (vxc_jsr_site+1) between br_to_view_fetch (disabled —
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
; (VXC_ENABLE comes from abi.inc)
vxc_prev_ab = $05DC
vxc_ref_x   = $05DD                     ; s24 this frame's ref = to_view(0,0)
vxc_ref_y   = $05E0                     ; s24 (origin normalization 2026-07-12:
                                        ;  base' = total - ref stored once per
                                        ;  epoch; warm read = base' + ref.
                                        ;  ref_cold/CACC are gone - $05E3-$05E8
                                        ;  free)

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

; the frame angle byte: abi.inc's BCA_AB (the old private vxc_ab copy
; shipped the 2026-07-10 broken-turn disc)
vxc_ab = BCA_AB

; ============================================================================
; (vxc_to_view + vxc_warm_load flattened into seg_xform.s as vxc_arm,
; 2026-07-12 — the per-vertex hot path lives in ONE file now. This file
; keeps the data planes, the cold-store leaf and the per-frame hook.)
; ============================================================================

; ============================================================================
; Fat paths — run with BANK_C paged (flat: plain resident code in ANG).
; ============================================================================
.if ::BANKED
.segment "VXCODE"
.else
.segment "ANG"
.endif


; --- vxc_cold_store: base' = total - ref (= L(w), translation-invariant) ---
;   in : zp_br_vx/vy lo/hi/ext (totals just computed by br_to_view),
;        zp_seg_v_idx_lo/hi, vxc_ref_x/y
;   out: this vertex's 6 plane bytes. base' + ANY later frame's ref
;        reconstructs that frame's exact totals (L is exactly linear), so
;        entries never go stale within an angle epoch.
vxc_cold_store:
.scope
   LDY zp_seg_v_idx_lo
   LDA zp_seg_v_idx_b
   AND #$20                                ; idx >= 256  <=>  B >= 32
   BNE vs_hi
   SEC
   LDA zp_br_vxlo
   SBC vxc_ref_x+0
   STA VXC_XLO,Y
   LDA zp_br_vxhi
   SBC vxc_ref_x+1
   STA VXC_XHI,Y
   LDA zp_br_vxext
   SBC vxc_ref_x+2
   STA VXC_XEXT,Y
   SEC
   LDA zp_br_vylo
   SBC vxc_ref_y+0
   STA VXC_YLO,Y
   LDA zp_br_vyhi
   SBC vxc_ref_y+1
   STA VXC_YHI,Y
   LDA zp_br_vyext
   SBC vxc_ref_y+2
   STA VXC_YEXT,Y
   RTS
vs_hi:
   SEC
   LDA zp_br_vxlo
   SBC vxc_ref_x+0
   STA VXC_XLO+$100,Y
   LDA zp_br_vxhi
   SBC vxc_ref_x+1
   STA VXC_XHI+$100,Y
   LDA zp_br_vxext
   SBC vxc_ref_x+2
   STA VXC_XEXT+$100,Y
   SEC
   LDA zp_br_vylo
   SBC vxc_ref_y+0
   STA VXC_YLO+$100,Y
   LDA zp_br_vyhi
   SBC vxc_ref_y+1
   STA VXC_YHI+$100,Y
   LDA zp_br_vyext
   SBC vxc_ref_y+2
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

;   in : VXC_ENABLE; vxc_ab (this frame's angle byte — alias of bca_ab,
;        written per frame by the caller); vxc_prev_ab; the frame view
;        context (read by br_to_view)
;   out: vxc_jsr_site operand patched; vxc_ref_x/y, vxc_refc_x/y,
;        vxc_prev_ab and VXC_VALID maintained
; pseudocode:
;   if not ENABLE: restore JSR br_to_view_fetch; return
;   ref = to_view(0,0)                      # this frame's reference shift
;   if ab != prev_ab:                       # cold: angle byte changed
;     prev_ab = ab; ref_cold = ref; CACC = 0; VALID[:] = 0
;   else:                                   # warm: same-angle translation
;     CACC = ref - ref_cold
;   patch JSR -> vxc_to_view
vxc_frame:
.scope
   LDA VXC_ENABLE
   BNE vf_on
; disabled: restore the original fetch+rotate target (byte-identical path)
   LDA #<br_to_view_fetch
   STA vxc_jsr_site+1
   LDA #>br_to_view_fetch
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
; --- publish this frame's ref (ORIGIN NORMALIZATION: stored bases are
; total - ref, i.e. the exactly-linear L(w); the warm arm adds the
; current ref back. No ref_cold, no CACC - the epoch anchor was a
; historical artifact, not a numerical need.) ---
   LDA zp_br_vxlo
   STA vxc_ref_x+0
   LDA zp_br_vxhi
   STA vxc_ref_x+1
   LDA zp_br_vxext
   STA vxc_ref_x+2
   LDA zp_br_vylo
   STA vxc_ref_y+0
   LDA zp_br_vyhi
   STA vxc_ref_y+1
   LDA zp_br_vyext
   STA vxc_ref_y+2
   LDA vxc_ab
   CMP vxc_prev_ab
   BEQ vf_patch
; --- angle changed: new epoch - wipe the valid bitmap ---
   STA vxc_prev_ab
   LDX #58
   LDA #0
vf_wipe:
   STA VXC_VALID,X
   DEX
   BPL vf_wipe
vf_patch:
   LDA #<vxc_arm
   STA vxc_jsr_site+1
   LDA #>vxc_arm
   STA vxc_jsr_site+2
   RTS
.endscope

; restore the segment for subsequently-included parts (they inherit)
.segment "MAIN"
