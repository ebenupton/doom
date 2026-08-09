SEG_CODE
bsp_lo_start:

; ============================================================================
; reproject_at_crossing — EV16 full-precision near-plane crossing
; (2026-08-09): recover BOTH endpoints' s24 view totals from their
; vertex keys, compute the vy = NEAR crossing in 8.8, and project it
; WITH ITS REAL FRACTION straight into the clipped endpoint's STRUCT
; slots (VX1/VX2, zp.inc — stride 15; zp_seg_ep = 0 for v1, 15 for v2,
; set by the caller). Y projection is NOT done here: it is deferred to
; the post-has_gap y stage like every other endpoint (2026-07-11); this
; routine banks recip(NEAR) into the struct's +13/+14 so that stage and
; apv_stage read the right reciprocal.
;
; Called by the seg loop (seg_emit.s) when EXACTLY ONE endpoint of a
; front-facing seg is behind the near plane. Mirrors fp.fp_cross_88
; bit-exactly (v1 arg = the CLIPPED endpoint):
;     d = vy_u - vy_c; n = 256 - vy_c     (both positive; d >= 1)
;     normalize d to u8 (floor-shift n and d together)
;     t >= 256 (<=> n >= d) -> crossing = the unclipped endpoint EXACT
;     t = (n<<8 + d>>1) / d               (u8, RN)
;     cx = vx_c + sign(dvx)*((t*|dvx| + 128) >> 8)     (s24 8.8)
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
;            zp_br_sign, zp_br_t2, zp_div_*, umul8 scratch, A/X/Y.
;   Banking: arrives AND leaves BANK_L2 (the sx_vert_* exit contract —
;            v2 always transforms right before the resolution island).
;            The VP plane reads need exactly that; the math + projection
;            are main-RAM only. NO paging here (an exit PAGE BANK_L0
;            was tried 2026-08-09 and broke the banked build's
;            downstream bank state — bankedcmp caught it).
; ============================================================================
reproject_at_crossing:
.scope
; ---- recover totals: clipped endpoint -> zp_cr_*, unclipped -> the
; zp_br_vx/vy working slots ----
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
; ---- d = vy_u - vy_c (positive: the verdicts guarantee
; vy_c < 128 <= vy_u; lands in the vy working slots) ----
   SEC
   LDA zp_br_vy_l
   SBC zp_cr_vy_l
   STA zp_br_vy_l
   LDA zp_br_vy_h
   SBC zp_cr_vy_h
   STA zp_br_vy_h
   LDA zp_br_vy_x
   SBC zp_cr_vy_x
   STA zp_br_vy_x
; ---- n = 256 - vy_c (positive; overwrites vy_c — dead) ----
   SEC
   LDA #$00
   SBC zp_cr_vy_l
   STA zp_cr_vy_l
   LDA #$01
   SBC zp_cr_vy_h
   STA zp_cr_vy_h
   LDA #$00
   SBC zp_cr_vy_x
   STA zp_cr_vy_x
; ---- normalize d to u8: floor-shift n and d together ----
rp_norm:
   LDA zp_br_vy_h
   ORA zp_br_vy_x
   BEQ rp_norm_done
   LSR zp_br_vy_x
   ROR zp_br_vy_h
   ROR zp_br_vy_l
   LSR zp_cr_vy_x
   ROR zp_cr_vy_h
   ROR zp_cr_vy_l
   JMP rp_norm                             ; (rare path: clarity over the
rp_norm_done:                              ;  backward-branch save)
; ---- t >= 256 <=> n >= d (proof: n>=d -> n<<8 >= 256d; n<d ->
; n<<8 + d>>1 <= 256d - 256 + 127 < 256d): crossing degenerates to
; the UNCLIPPED endpoint exactly (python: t >= 256 -> cx = vx2) ----
   LDA zp_cr_vy_x
   ORA zp_cr_vy_h
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
   PAGE BANK_L2                            ;  ~100 bytes for a rare path);
                                           ; restore the L2 arrival state
; ---- dvx = vx_u - vx_c: sign + u24 magnitude in the vy slots ----
   ZERO zp_br_sign
   SEC
   LDA zp_br_vx_l
   SBC zp_cr_vx_l
   STA zp_br_vy_l
   LDA zp_br_vx_h
   SBC zp_cr_vx_h
   STA zp_br_vy_h
   LDA zp_br_vx_x
   SBC zp_cr_vx_x
   STA zp_br_vy_x
   BPL rp_dvx_p                            ; N rides the last SBC byte
   INC zp_br_sign
   SEC
   LDA #0
   SBC zp_br_vy_l
   STA zp_br_vy_l
   LDA #0
   SBC zp_br_vy_h
   STA zp_br_vy_h
   LDA #0
   SBC zp_br_vy_x
   STA zp_br_vy_x
rp_dvx_p:
; ---- prod = (t * |dvx| + 128) >> 8 (u8 x u24 -> u18: three umul8s,
; the top one gated on |dvx|'s rare nonzero third byte). r0/r1/r2
; accumulate the SHIFTED result: r0 = prod byte 1, etc — the +128
; rounding bias contributes only its carry out of byte 0. ----
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
   ZERO zp_br_t2                           ; r2
   LDA zp_br_vy_x                          ; m2 (nonzero only for view
   BEQ rp_prod_done                        ;  spans past +-256 units)
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8                               ; t*m2
   TAX
   LDA zp_br_res_h
   CLC
   ADC zp_prod_l                           ; r1 += p2l
   STA zp_br_res_h
   TXA
   ADC #0
   STA zp_br_t2                            ; r2 = p2h + c
rp_prod_done:
; ---- cx = vx_c +- prod, STRAIGHT INTO the projection input slots:
; zp_br_vx_l/h/x = frac/int-lo/int-hi is exactly the 8.8 layout
; br_project_x consumes — the crossing's real frac flows through
; where the old path forced 0 ----
   LDA zp_br_sign
   BNE rp_cx_sub
   CLC
   LDA zp_cr_vx_l
   ADC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_cr_vx_h
   ADC zp_br_res_h
   STA zp_br_vx_h
   LDA zp_cr_vx_x
   ADC zp_br_t2
   STA zp_br_vx_x
   JMP rp_recip
rp_cx_sub:
   SEC
   LDA zp_cr_vx_l
   SBC zp_br_res_l
   STA zp_br_vx_l
   LDA zp_cr_vx_h
   SBC zp_br_res_h
   STA zp_br_vx_h
   LDA zp_cr_vx_x
   SBC zp_br_t2
   STA zp_br_vx_x
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
   STA zp_br_r_s
   LDA rns_vec_l                           ; = rns_vec_l-1+S with S = 1
   STA rns_go_op
; ---- project + land in the clipped endpoint's struct ----
   JSR br_project_x                        ; -> zp_br_res_l/h = sx
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
; cr_recover — recover one endpoint's s24 view totals from its vertex
; key (EV16 2026-08-09). total := widen(q64(rot(w))) + ref — the same
; join every fetch tier computes (SXV_BODY vfoff / vxcon), so recovery
; is bit-identical to the transform that produced the endpoint's clip
; verdict, in BOTH vxc modes: the base is a pure function of (vertex,
; angle epoch) and ref is staged unconditionally by vxc_frame.
;   In:  A = idx_l, X = idx_b (senior side bit $20); BANK_L2 paged
;        (reproject's arrival contract — never re-paged here).
;   Out: zp_br_vx_l/h/x, zp_br_vy_l/h/x = totals (s24 8.8).
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
cr_cp:                                     ; $E3-$E6 (zp.inc order contract)
   LDA zp_br_vx_l,X
   STA zp_cr_vx_l,X
   DEX
   BPL cr_cp
   LDA zp_br_vx_x                          ; + the $2E/$2F ext pair
   STA zp_cr_vx_x
   LDA zp_br_vy_x
   STA zp_cr_vy_x
   RTS
.endscope

cr_recover:
.scope
; ---- VXC-aware claw-back (2026-08-09): when the translation cache is
; on and holds this vertex, serve base16 from the planes + widen + ref
; (~90cyc) instead of the full fetch+rotate (~330). Bit-identical BY
; CONSTRUCTION (the V16 join: every tier computes (base16<<2)+ref).
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
   LDA VXC_XLO,Y                           ; warm: base16 -> the working
   STA zp_br_vx_l                          ; slots (junior side)
   LDA VXC_XHI,Y
   STA zp_br_vx_h
   LDA VXC_YLO,Y
   STA zp_br_vy_l
   LDA VXC_YHI,Y
   STA zp_br_vy_h
   JMP cr_widen
cr_w_hi:
   LDA VXC_XLO+$100,Y                      ; senior side twins
   STA zp_br_vx_l
   LDA VXC_XHI+$100,Y
   STA zp_br_vx_h
   LDA VXC_YLO+$100,Y
   STA zp_br_vy_l
   LDA VXC_YHI+$100,Y
   STA zp_br_vy_h
cr_widen:
; widen base16 << 2, sign-extended into the ext bytes (the vxq_join
; form — BIT reads the hi sign without disturbing A's accumulator)
   LDA #0
   BIT zp_br_vx_h
   BPL cw_xp
   LDA #$FF
cw_xp:
   ASL zp_br_vx_l
   ROL zp_br_vx_h
   ROL A
   ASL zp_br_vx_l
   ROL zp_br_vx_h
   ROL A
   STA zp_br_vx_x
   LDA #0
   BIT zp_br_vy_h
   BPL cw_yp
   LDA #$FF
cw_yp:
   ASL zp_br_vy_l
   ROL zp_br_vy_h
   ROL A
   ASL zp_br_vy_l
   ROL zp_br_vy_h
   ROL A
   STA zp_br_vy_x
   JMP cr_ref                              ; shared ref add
cr_cold:
   LDA zp_div_l                            ; restore idx_l (X untouched)
cr_plain:
   TAY                                     ; Y = plane index
   TXA
   AND #$20
   BNE cr_hi
   LDA VP_YLO,Y                            ; junior side (pg 0): stage the
   STA zp_br_dy_l                          ; vertex verbatim, like vfoff
   LDA VP_YHI,Y
   STA zp_br_dy_h                          ; sign-magnitude hi (core resolves)
   ZERO zp_ri_sgn
   LDA VP_XLO,Y
   STA zp_ri_d_l
   LDA VP_XHI,Y                            ; sign-mag: N = wx sign, bit 7
   BPL cr_xp0
   INC zp_ri_sgn
   AND #$7F
cr_xp0:
   STA zp_ri_d_h
   JMP cr_rot
cr_hi:
   LDA VP_YLO+$100,Y                       ; senior side (pg $100)
   STA zp_br_dy_l
   LDA VP_YHI+$100,Y
   STA zp_br_dy_h
   ZERO zp_ri_sgn
   LDA VP_XLO+$100,Y
   STA zp_ri_d_l
   LDA VP_XHI+$100,Y
   BPL cr_xp1
   INC zp_ri_sgn
   AND #$7F
cr_xp1:
   STA zp_ri_d_h
cr_rot:
   JSR rot_w_signed                        ; widened q64 base in the s24 slots
cr_ref:
; ref add — totals := base + ref (the vxq_add join; those expansions
; live inside SXV_BODY's macro scopes, unreachable from here)
   CLC
   LDA zp_br_vx_l
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA zp_br_vx_h
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   LDA zp_br_vx_x
   ADC vxc_ref_x+2
   STA zp_br_vx_x
   CLC
   LDA zp_br_vy_l
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA zp_br_vy_h
   ADC vxc_ref_y+1
   STA zp_br_vy_h
   LDA zp_br_vy_x
   ADC vxc_ref_y+2
   STA zp_br_vy_x
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
