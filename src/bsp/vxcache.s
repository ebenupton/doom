
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
; vertex per angle epoch (the birth store, inlined per side in the
; seg_xform.s vxcon islands), and every warm read is
; base' + this frame's ref (two s24 adds, inline in seg_xform's vxc_arm)
; — bit-identical to br_to_view by the linearity, verified by
; tools/vxcache_check.py (both builds, warm + rotation legs). Staleness
; is structurally impossible within an epoch; an angle change wipes
; VXC_VALID and that is the ONLY invalidation. (The earlier CACC/
; ref_cold epoch-anchor formulation was equivalent; origin form needs no
; anchor state — $05E3-$05E8 freed.)
;
; DISPATCH: vxc_frame (JSR'd from view_setup's tail, view.s) publishes
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
VXC_VALID   = $0780                     ; 57 B — on THE bitmap page
; (VXC_ENABLE comes from abi.inc)
vxc_prev_ab = $0B5E                     ; moved with the scalars block, then
                                        ; $19DC -> $19DE 2026-08-22 (with
                                        ; VXC_ENABLE) to clear $19A0-$19DF for
                                        ; the span pool's two new planes
                                        ; 2026-08-18 (the hard $05DC literal
                                        ; survived the sqr swap and wrote the
                                        ; frame angle into SQR2_HI[$DC] —
                                        ; found by the vxcache ON!=OFF gate
                                        ; via a 4-frame cold-strafe repro)
; (vxc_ref_x/y promoted to ZP 2026-07-14 — defined in zp.inc so the
; forward references in seg_xform.s assemble as zero-page: the warm
; path does six ADCs against them per vertex.)
;                                        ; s24 this frame's ref = to_view(0,0)
;                                        ; s24 (origin normalization 2026-07-12:
                                        ;  base' = total - ref stored once per
                                        ;  epoch; warm read = base' + ref.
                                        ;  ref_cold/CACC are gone - $05E3-$05E8
                                        ;  free)

; --- plane bases (467 bytes each; page-aligned so hi-page access is +$100) ---
; MAIN RAM since 2026-08-09 (Eben: all cache planes out of bank C) —
; UNFORKED, one address both builds (bottom-22K identity). The homes
; are the below-line frees: $0200-$03FF (ex-SQRH), $0600-$07FF ($0600
; ex-flat-RC_P1L_0 + $0700 vacated by TOP_RECORDS -> $0B00), and the
; EV16 pages $1600-$19FF. This spends the LAST free below-line pages.
; Payoff: the vxcon serve and cr_recover lose ALL bank-C paging
; (VXC_VALID was already main), banked frees $9700-$9EFF -> with the
; clipper tail gap a ~2.7KB contiguous bank-C block; flat frees
; $7500-$7CFF.
; BANKED: the planes moved into the BANK A window 2026-08-17, directly above
; VCACHE (see bsp/header.s for the audit that says this costs nothing). FLAT
; keeps them in main.
.if ::BANKED
VXC_BASE = $A000
.else
VXC_BASE = $4E00
.endif
VXC_XLO  = VXC_BASE + $000
VXC_XHI  = VXC_BASE + $200
.if ::BANKED
VXC_YLO  = VXC_BASE + $400
VXC_YHI  = VXC_BASE + $600
.assert VXC_YHI + $200 <= $AB00, error,  "banked VXC must fit below the vertex planes"
.else
VXC_YLO  = $5200                        ; flat: the CODE-tail cache run of the
VXC_YHI  = $5400                        ; 2026-08-26 low-RAM map ($4E00 X pair,
                                        ; $5200/$5400 Y pair); planes are
                                        ; self-contained 512 B, no cross-
                                        ; plane address arithmetic anywhere
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
SEG_HIGH
; --- birth store: base' = total - ref (= L(w), translation-invariant) ---
;   in : zp_br_vx/vy lo/hi/ext (totals just computed by br_to_view),
;        zp_seg_v_idx_l/hi, vxc_ref_x/y
;   out: this vertex's 6 plane bytes. base' + ANY later frame's ref
;        reconstructs that frame's exact totals (L is exactly linear), so
;        entries never go stale within an angle epoch.
; (the store lives INLINE in seg_xform.s vxcon islands 2026-08-09,
; side baked; it was previously a macro expanded at its single
;  call site, 2026-07-17.)

; ============================================================================
; Per-frame hook — called from view_setup after the view context (fracs)
; is built. Banked: runs from the L2 window (caller paged BANK_L2); touches
; only low RAM, ZP and resident MAIN (br_to_view, the SMC site).
; ============================================================================
SEG_HIGH
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
; (vxc_frame is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; restore the segment for subsequently-included parts (they inherit)
SEG_CODE
