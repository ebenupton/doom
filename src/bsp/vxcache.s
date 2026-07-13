
; ============================================================================
; Translation-coherence vertex cache (VXC) — DATA + frame hook + cold-store
; leaf. THE PER-VERTEX HOT PATH IS NOT HERE: it lives in seg_xform.s
; (vxc_arm — coherence probe + inline warm reconstruction), so the whole
; vertex pipeline reads top-to-bottom in one file. This file keeps what
; is per-FRAME or storage.
;
; PRINCIPLE (origin normalization, 2026-07-12): the view transform is
; EXACTLY linear in the integer world deltas (rot products are exact
; integer multiplies) and the per-frame fractional terms are position-
; only constants. So for a fixed angle byte,
;
;   total(w, frame m) = L(w) + ref_m,   ref_m = to_view(0,0) at frame m
;
; with L exactly linear. We store base' = total - ref = L(w) ONCE per
; vertex per angle epoch (vxc_cold_store below), and every warm read is
; base' + this frame's ref (two s24 adds, inline in seg_xform's vxc_arm)
; — bit-identical to br_to_view by the linearity, verified by
; tools/vxcache_check.py (both builds, warm + rotation legs). Staleness
; is structurally impossible within an epoch; an angle change wipes
; VXC_VALID and that is the ONLY invalidation. (The earlier CACC/
; ref_cold epoch-anchor formulation was equivalent; origin form needs no
; anchor state — $05E3-$05E8 freed.)
;
; DISPATCH: vxc_frame (JSR'd from br_view_setup's tail, view.s) publishes
; ref into vxc_ref_x/y and SMC-patches the operand of seg_xform's
; vxc_jsr_site JSR between br_to_view_fetch (disabled — zero cost,
; byte-identical path) and vxc_arm (enabled). VXC_ENABLE lives in low
; RAM ($05DB, abi.inc) so drivers set it without paging.
;
; MEMORY: valid bitmap + state $05A0-$05FF (unbanked, both builds).
; Six planes, 467 entries each, PAGE-SPLIT (entry idx<256 in page k,
; idx>=256 in page k+1 — each plane needs two consecutive pages):
;   banked -> bank C $9700-$A2D3 (clipper ends below, rasteriser $A900+)
;   flat   -> $9800/$9A00, $1C00/$1E00, $B200/$B400 (2026-07-12 merge;
;             see the trap notes below — the first placement hit both
;             the DEFQ vars at $09FB and the $A900 rasteriser)
; Plane index = the vertex KEY: Y = idx&255 (= header key byte A), page
; select = B & $20 (B = idx>>3, header key byte B; B >= 32 <=> idx >= 256).
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
; (flat planes relocated 2026-07-12: $4000-$47D3 vacated for the one
; flat CODE region; each plane needs pages k,k+1 for the +$100 split.
; Verified-free pairs: $98/$99 $9A/$9B (above the header tail $9740),
; $1C-$1F (the freed LO island's tail; flat sqr lives at $A500),
; $B2-$B5 (below the node SoA at $B600). Page $09 holds live DEFQ vars
; at $09FB and $A900-$B1EE is the NJ rasteriser — both are traps that
; caught the first placement attempt.)
VXC_XLO  = $9800
VXC_XHI  = $9A00
VXC_XEXT = $1C00
VXC_YLO  = $1E00
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
;        zp_seg_v_idx_l/hi, vxc_ref_x/y
;   out: this vertex's 6 plane bytes. base' + ANY later frame's ref
;        reconstructs that frame's exact totals (L is exactly linear), so
;        entries never go stale within an angle epoch.
vxc_cold_store:
.scope
   LDY zp_seg_v_idx_l
   LDA zp_seg_v_idx_b
   AND #$20                                ; idx >= 256  <=>  B >= 32
   BNE vs_hi
   SEC
   LDA zp_br_vx_l
   SBC vxc_ref_x+0
   STA VXC_XLO,Y
   LDA zp_br_vx_h
   SBC vxc_ref_x+1
   STA VXC_XHI,Y
   LDA zp_br_vx_x
   SBC vxc_ref_x+2
   STA VXC_XEXT,Y
   SEC
   LDA zp_br_vy_l
   SBC vxc_ref_y+0
   STA VXC_YLO,Y
   LDA zp_br_vy_h
   SBC vxc_ref_y+1
   STA VXC_YHI,Y
   LDA zp_br_vy_x
   SBC vxc_ref_y+2
   STA VXC_YEXT,Y
   RTS
vs_hi:
   SEC
   LDA zp_br_vx_l
   SBC vxc_ref_x+0
   STA VXC_XLO+$100,Y
   LDA zp_br_vx_h
   SBC vxc_ref_x+1
   STA VXC_XHI+$100,Y
   LDA zp_br_vx_x
   SBC vxc_ref_x+2
   STA VXC_XEXT+$100,Y
   SEC
   LDA zp_br_vy_l
   SBC vxc_ref_y+0
   STA VXC_YLO+$100,Y
   LDA zp_br_vy_h
   SBC vxc_ref_y+1
   STA VXC_YHI+$100,Y
   LDA zp_br_vy_x
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
   STA zp_br_dx_l
   STA zp_br_dx_h
   STA zp_br_dy_l
   STA zp_br_dy_h
   JSR br_to_view
; --- publish this frame's ref (ORIGIN NORMALIZATION: stored bases are
; total - ref, i.e. the exactly-linear L(w); the warm arm adds the
; current ref back. No ref_cold, no CACC - the epoch anchor was a
; historical artifact, not a numerical need.) ---
   LDA zp_br_vx_l
   STA vxc_ref_x+0
   LDA zp_br_vx_h
   STA vxc_ref_x+1
   LDA zp_br_vx_x
   STA vxc_ref_x+2
   LDA zp_br_vy_l
   STA vxc_ref_y+0
   LDA zp_br_vy_h
   STA vxc_ref_y+1
   LDA zp_br_vy_x
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
