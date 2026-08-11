SEG_CODE
bsp_lo_start:

; ============================================================================
; reproject_at_crossing — full-precision near-plane crossing (EV16
; 2026-08-09; TRUE16 counts 2026-08-10): recover BOTH endpoints' s16
; count totals from their vertex keys, compute the vy = NEAR crossing
; in counts, and project it
; WITH ITS REAL FRACTION straight into the clipped endpoint's STRUCT
; slots (VX1/VX2, zp.inc — stride 15; zp_seg_ep = 0 for v1, 15 for v2,
; set by the caller). Y projection is NOT done here: it is deferred to
; the post-has_gap y stage like every other endpoint (2026-07-11); this
; routine banks recip(NEAR) into the struct's +13/+14 so that stage and
; apv_stage read the right reciprocal.
;
; Called by the seg loop (seg_emit.s) when EXACTLY ONE endpoint of a
; front-facing seg is behind the near plane. Mirrors fp.fp_cross_t16
; bit-exactly (v1 arg = the CLIPPED endpoint):
;     d = vy_u - vy_c; n = 32 - vy_c      (both positive; d >= 1)
;     normalize d to u8 (floor-shift n and d together)
;     t >= 256 (<=> n >= d) -> crossing = the unclipped endpoint EXACT
;     t = (n<<8 + d>>1) / d               (u8, RN)
;     cx = vx_c + sign(dvx)*((t*|dvx| + 128) >> 8)     (s16 counts)
; The old s8 evy/evx tier died with this: the crossing was its LAST
; consumer, and its integer resolution (frac forced to 0) was the
; near-clip's remaining precision loss — toward-float verdict
; tools/nc88_verdict.py, gate PASSED 2026-08-09.
;
;   Inputs:  zp_seg_ep = the CLIPPED endpoint's struct offset (0 | 15),
;            zp_v1i_l/b + zp_seg_v_idx_l/b = the endpoints' vertex keys
;              (both live at crossing time — seg_emit banks v1's key in
;              zp_v1i_* during the chain compare).
;   Outputs: struct +3/+4 = sx of the crossing point (s16),
;            struct +13/+14 and zp_br_r_m8/rlo = recip(NEAR) = (M8=0, S=1);
;            chain key killed by the caller (VX2 no longer holds a vertex).
;   Clobbers: fetch/rot scratch (via cr_recover), zp_cr_*, zp_br_a,
;            zp_br_sign, zp_div_*, umul8 scratch, A/X/Y.
;   Banking: SELF-CONTAINED (2026-08-09, exit-contract retirement):
;            arrival bank is arbitrary (the transform's hit arm is
;            bank-preserving now). cr_plain pages L2 for the VP reads;
;            the t divide pages C (udiv16_8 = clipper segment); the
;            math + projection are main-RAM only and the exit bank is
;            whatever ran last — every downstream consumer pages
;            explicitly. (History: an exit PAGE BANK_L0 under the OLD
;            always-L2 contract broke banked — bankedcmp caught it.)
; ============================================================================
reproject_at_crossing:
.scope
; ---- recover count totals: clipped endpoint -> zp_cr_*, unclipped ->
; the zp_br_vx/vy working slots ----
   LDA zp_seg_ep
   BNE rp_v2c
   LDA zp_v1i_l                            ; ep = 0: v1 is the clipped one
   LDX zp_v1i_b
   JSR cr_recover_clipped
   LDA zp_seg_v_idx_l
   LDX zp_seg_v_idx_b
   JSR cr_recover
   JMP rp_math
rp_v2c:
   LDA zp_seg_v_idx_l                      ; ep = 15: v2 is the clipped one
   LDX zp_seg_v_idx_b
   JSR cr_recover_clipped
   LDA zp_v1i_l
   LDX zp_v1i_b
   JSR cr_recover
rp_math:
; ---- d = vy_u - vy_c (s16, positive: the verdicts guarantee
; vy_c < 16 <= vy_u counts; lands in the vy working slots) ----
   SEC
   LDA zp_br_vy_l
   SBC zp_cr_vy_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   SBC zp_cr_vy_h
   STA zp_br_vy_h
; ---- n = 32 - vy_c (s16 positive: NEAR = 32 counts = 1.0 unit;
; overwrites vy_c — dead) ----
   SEC
   LDA #32
   SBC zp_cr_vy_l
   STA zp_cr_vy_l
   LDA #0
   SBC zp_cr_vy_h
   STA zp_cr_vy_h
; ---- normalize d to u8: floor-shift n and d together ----
rp_norm:
   LDA zp_br_vy_h
   BEQ rp_norm_done
   LSR zp_br_vy_h
   ROR zp_br_vy_l
   LSR zp_cr_vy_h
   ROR zp_cr_vy_l
   JMP rp_norm                             ; (rare path: clarity over the
rp_norm_done:                              ;  backward-branch save)
; ---- t >= 256 <=> n >= d (proof: n>=d -> n<<8 >= 256d; n<d ->
; n<<8 + d>>1 <= 256d - 256 + 127 < 256d): crossing degenerates to
; the UNCLIPPED endpoint exactly (python: t >= 256 -> cx = vx2) ----
   LDA zp_cr_vy_h
   BNE rp_use_u_j
   LDA zp_cr_vy_l
   CMP zp_br_vy_l
   BCC rp_t_ok
rp_use_u_j:
   JMP rp_use_u                            ; (math block outgrows the span)
rp_t_ok:
; ---- t = (n<<8 + d>>1) / d (u8, RN; n < d proven -> fast path) ----
   STA zp_div_h                            ; A = n (CMP preserved it)
   LDA zp_br_vy_l
   STA zp_div_den
   LSR A
   STA zp_div_l                            ; d>>1 seeds the RN bias
   PAGE BANK_C                             ; udiv16_8 lives in the CLIPPER
   JSR udiv16_8                            ; segment = bank C when banked
   STA zp_br_a                             ; (the JSR, not the SC_ inline:
   PAGE BANK_L2                            ;  ~100B for a rare path)
; ^ EMPIRICALLY LOAD-BEARING (2026-08-09): removing this restore
; crashes banked on the crossing seg's SECOND draw (raster PC runs off
; the blob end, misaligned) — some consumer between here and the next
; explicit PAGE still wants L2, and the audit (has_gap main, y-stage
; self-paged, emits PAGE_X C) has not identified it. Do NOT delete
; without root-causing; bankedcmp is the catcher. (~6 cyc, ~1.7x/frame.)
; ---- dvx = vx_u - vx_c: sign + u16 magnitude in the vy slots
; (TRUE16: totals are s16 counts — the third byte and its gated
; third mul DIED) ----
   ZERO zp_br_sign
   SEC
   LDA zp_br_vx_l
   SBC zp_cr_vx_l
   STA zp_br_vy_l
   LDA zp_br_vx_h
   SBC zp_cr_vx_h
   STA zp_br_vy_h
   BPL rp_dvx_p                            ; N rides the last SBC byte
   INC zp_br_sign
   SEC
   LDA #0
   SBC zp_br_vy_l
   STA zp_br_vy_l
   LDA #0
   SBC zp_br_vy_h
   STA zp_br_vy_h
rp_dvx_p:
; ---- prod = (t * |dvx| + 128) >> 8 (u8 x u16 -> u16: two umul8s;
; t < 256 so prod < |dvx| fits u16). r0/r1 accumulate the SHIFTED
; result: r0 = prod byte 1, etc — the +128 rounding bias contributes
; only its carry out of byte 0. ----
   LDA zp_br_vy_l
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8                               ; t*m0 -> A = hi, zp_prod_l = lo
   TAX
   LDA zp_prod_l
   CLC
   ADC #128                                ; bias: only C survives
   TXA
   ADC #0
   STA zp_br_res_l                         ; r0 = p0h + c (p0h <= 254:
                                           ;   no carry out)
   LDA zp_br_vy_h
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8                               ; t*m1
   TAX
   LDA zp_br_res_l
   CLC
   ADC zp_prod_l                           ; r0 += p1l
   STA zp_br_res_l
   TXA
   ADC #0
   STA zp_br_res_h                         ; r1 = p1h + c (<= 255)
; ---- cx = vx_c +- prod, STRAIGHT INTO the projection input slots:
; s16 counts in zp_br_vx_l/h — exactly what br_project_x_c consumes —
; and the crossing's real (count-grain) fraction flows through ----
   LDA zp_br_sign
   BNE rp_cx_sub
   CLC
   LDA zp_cr_vx_l
   ADC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_cr_vx_h
   ADC zp_br_res_h
   STA zp_br_vx_h
   JMP rp_recip
rp_cx_sub:
   SEC
   LDA zp_cr_vx_l
   SBC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_cr_vx_h
   SBC zp_br_res_h
   STA zp_br_vx_h
rp_use_u:
; (falls in; t >= 256 arrivals: the crossing IS the unclipped
; endpoint, whose totals already sit in the projection input slots)
rp_recip:
; CONSTANT-FOLDED crossing reciprocal (recip split 2026-07-27): vy ==
; NEAR exactly -> (M8, S) = (0, 1) are the M8 table's baked [0..2]
; entries, and the select collapses to one absolute load of the S=1
; kernel vector. r_m8/r_s stores stay: r_s doubles as the VWHC rlo key
; and the rlo-writer invariant requires the true value.
   LDA #0
   STA zp_br_r_m8
   LDA #1
   STA zp_br_r_s                           ; (the hand kernel fold died: the
                                           ; counts projector selects itself)
; ---- project + land in the clipped endpoint's struct ----
   JSR br_project_x_c                      ; -> zp_br_res_l/h = sx
   LDX zp_seg_ep
   LDA zp_br_res_h
   STA VX1+2,X                             ; sx -> the clipped endpoint's
   LDA zp_br_res_l                         ; struct slots
   STA VX1+1,X
   LDA zp_br_r_m8                          ; bank recip(NEAR) = (M8=0, S=1)
   STA VX1+11,X                            ; into the struct: the deferred
   LDA zp_br_r_s                           ; y stage (and apv_stage) project
   STA VX1+12,X                            ; the crossing with THIS recip
   RTS
.endscope

; ============================================================================
; cr_recover — recover one endpoint's s16 count totals from its vertex
; key (EV16 2026-08-09; TRUE16 2026-08-10). total := rns(rot(w),3) +
; ref_c — the same join the fetch computes (SXV_BODY vxcon), so
; recovery is bit-identical to the transform that produced the
; endpoint's clip verdict, in BOTH vxc modes: the base is a pure
; function of (vertex, angle epoch) and ref is staged unconditionally
; by vxc_frame.
;   In:  A = idx_l, X = idx_b (senior side bit $20); any bank —
;        cr_plain pages L2 itself (warm serves need no paging at all).
;   Out: zp_br_vx_l/h, zp_br_vy_l/h = totals (s16 counts).
;   Clobbers: A/X/Y, fetch scratch (zp_br_dy_*, zp_ri_*), rot scratch.
; cr_recover_clipped: same, then banks the result into the zp_cr_*
; slots — the clipped endpoint recovers FIRST, so the second call
; lands the unclipped one in the working slots.
; (Python mirror: fp.fp_to_view_totals — the _NC88 block recomputes
; for both endpoints exactly like this, hit or miss.)
; ============================================================================
cr_recover_clipped:
.scope
   JSR cr_recover
   LDX #3                                  ; the $11-$14 pair block mirrors
cr_cp:                                     ; the zp_cr block (zp.inc order
   LDA zp_br_vx_l,X                        ; contract). TRUE16: the ext pair
   STA zp_cr_vx_l,X                        ; copies DIED — totals are s16
   DEX
   BPL cr_cp
   RTS
.endscope

cr_recover:
.scope
; ---- VXC-aware claw-back (2026-08-09): when the translation cache is
; on and holds this vertex, serve base counts from the planes + ref
; (~70cyc) instead of the full fetch+rotate (~330). Bit-identical BY
; CONSTRUCTION (the TRUE16 join: every tier computes base_c + ref_c).
; Cold does NOT birth — recovery is read-only, so cache state
; invariants (vxcache_check/walkseq) are untouched; the rare cold
; crossing just pays the plain path like before. ----
   LDY zp_vxc_on
   BEQ cr_plain                            ; cache off -> plain
   STA zp_div_l                            ; idx_l stash (div scratch, dead
   AND #7                                  ;  until the t divide)
   TAY
   LDA vc_bit_mask,Y
   AND VXC_VALID,X                         ; VALID is main RAM — no paging
   BEQ cr_cold
   LDY zp_div_l                            ; Y = idx_l (planes are MAIN
   TXA                                     ; since 2026-08-09 — the PAGE_Y
                                           ; BANK_C/L2 pair died)
   AND #$20
   BNE cr_w_hi
   LDA VXC_XLO,Y                           ; warm: base counts -> the
   STA zp_br_vx_l                          ; working slots (junior side)
   LDA VXC_XHI,Y
   STA zp_br_vx_h
   LDA VXC_YLO,Y
   STA zp_br_vy_l
   LDA VXC_YHI,Y
   STA zp_br_vy_h
   JMP cr_ref
cr_w_hi:
   LDA VXC_XLO+$100,Y                      ; senior side twins
   STA zp_br_vx_l
   LDA VXC_XHI+$100,Y
   STA zp_br_vx_h
   LDA VXC_YLO+$100,Y
   STA zp_br_vy_l
   LDA VXC_YHI+$100,Y
   STA zp_br_vy_h
   JMP cr_ref                              ; counts ARE the working form
                                           ; (TRUE16: the <<2 widen DIED)
cr_cold:
   LDA zp_div_l                            ; restore idx_l (X untouched)
cr_plain:
   PAGE_Y BANK_L2                          ; VP planes (self-paged since the
                                           ; transform exit contract died —
                                           ; arrival bank is now arbitrary;
                                           ; Y dead, A = idx_l survives)
   TAY                                     ; Y = plane index
   TXA
   AND #$20
   BNE cr_hi
   LDA VP_OX,Y                             ; junior side (pg 0): the page-
   STA zp_ri_d_l                           ; decomposed fetch (2026-08-11)
   LDA VP_OY,Y
   STA zp_br_dy_l
   LDA VP_PG,Y
   JMP cr_rot
cr_hi:
   LDA VP_OX+$100,Y                        ; senior side (pg $100)
   STA zp_ri_d_l
   LDA VP_OY+$100,Y
   STA zp_br_dy_l
   LDA VP_PG+$100,Y
cr_rot:
   STA zp_ri_d_h                           ; page nibble
::cr_rwp:
   JSR rot_w_pages                         ; SMC: rot_select picks the body
cr_ref:
; ref add — totals := base_c + ref_c, s16 (the vxq_add join; those
; expansions live inside SXV_BODY's macro scopes, unreachable from here)
   CLC
   LDA zp_br_vx_l
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA zp_br_vx_h
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   CLC
   LDA zp_br_vy_l
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC vxc_ref_y+1
   STA zp_br_vy_h
   RTS
.endscope

; (br_node_setup moved to walk.s as the NODE_SETUP_DISPATCH macro,
; 2026-07-16 — single caller, inlined; exits JMP straight to the side
; bodies, no A/RTS round trip.)


; (br_project_x_wide moved to project.s 2026-07-12; rns32 — its
; round-to-nearest shifter — stays below.)


; (rns32 followed br_project_x_wide to project.s 2026-07-12 — its only
; caller; the projection family is complete in one file.)

; (ev_clamp_evy16 moved to the B region.)



; (flat LO ceiling retired 2026-07-12: LO floats in the one CODE region
; in BOTH builds now.)


; ============================================================================
; (ap_edges/ap_edge_one/ap_emit_y RETIRED 2026-07-24: verticals come
; from the per-vertex span descriptors — vs_vertex in subsector.s.)

; (ap2_solid_proj DELETED 2026-07-11: apv_stage projects BOTH endpoints'
; aperture pairs into the structs post-visibility — one uniform solid
; path in ap_edge_one, no emit-time special case.)

; ============================================================================
; apv_stage — post-visibility APV aperture projections (2026-07-11).
; Called once per VISIBLE solid seg carrying APEDGE1/2, from the seg
; loop right after has_gap passes and BEFORE any canonicalizing endpoint
; swap — seg-endpoint identity still equals struct identity here, so the
; header offsets are unambiguous (+12/13 = APV1 ch/fh, +14/15 = APV2).
; Projects with the endpoint's OWN recip (VXk+13/14 — for a near-clipped
; endpoint that is the crossing recip the reprojection banked), filling
; VXk+9/10 (FH projection) and +11/12 (CH projection): the same slots
; and orientation the old dpy(APEDGE1)/ap2_solid_proj paths produced.
; Replaces TRANSFORM-TIME speculation: has_gap-culled segs pay nothing.
; Arrives under BANK_C; pages L0 for the header reads; br_project_y
; pages L2 itself; the emits re-page C per draw as always.
; ============================================================================
; (apv_stage is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)




; ============================================================================
; chain_reuse_v1 — the seg loop's vertex-chain hit path (2026-07-10).
; This seg's v1 == the previous transform's v2 (same subsector): copy
; VX2 -> VX1 wholesale — evy/evx/clip always; sx + front sy pair (same
; subsector => same fh/ch) + rhi/rlo when unclipped — then project just
; the flag-gated back pair with the vertex's recip restored. ep = 0 set
; by the caller. Replaces the whole VCACHE hit path + 2 VWHC lookups.
; ============================================================================
; (History: LO-resident body until 2026-07-17, then a macro in
; inline.s; moved BODILY into subsector.s at its single site
; 2026-07-26 — the doc block above describes the semantics.)

bsp_lo_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_lo_bk.bin", $1B40, bsp_lo_end, $1B40)
.else
; (ld65 writes this: SAVE "bsp_render_lo.bin", $1B40, bsp_lo_end, $1B40)
.endif
