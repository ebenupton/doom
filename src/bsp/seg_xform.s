
; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;
; One call per seg endpoint (subsector.s seg loop). Mirrors the "View
; transform with RAM vcache" + reciprocal + X-projection phase of Python's
; packed_render_seg (fp_to_view / fp_recip / fp_project_x_subpx), with a
; per-frame VERTEX CACHE so a vertex shared by several segs is transformed
; and X-projected only once per frame.
;
;   Input:  zp_seg_v_idx_l/hi = vertex index (u16), written by the caller
;             (doubles as the cache-write index — no staging copy).
;   Output: THE ENDPOINT STRUCT (zp.inc VX1/VX2, X = zp_seg_ep = 0/15):
;             +0 evy  +1 evx (ALWAYS — crossing math needs both endpoints)
;             +2 clip (1 = behind near plane; rest then undefined)
;             +3/+4 sx  +5..+12 the flag-gated sy pairs (do_project_y tail)
;             +13/+14 rhi/rlo (banked for apv_stage / the y-stage)
;           zp_br_r_m8/rlo also hold the recip (projection working slots).
;           NOTHING is staged — every result stores once, struct-direct.
;   Uses:   br_to_view (view.s, s24 rotation), br_recip, br_project_x.
;
; Vertex cache: VCACHE_BASE + idx*8, one 8-byte entry per vertex, plus a
; 1-bit-per-vertex valid bitmap at VCACHE_VALID_BASE (cleared per frame).
; 6502 entry layout (differs from Python's VCACHE_ENTRY, which stores
; vx/vy/vy_idx/sx — here the post-recip results are cached instead):
;   +0 evy (s8)  +1 evx (s8)  +2 rhi  +3 rlo  +4 sx_lo  +5 sx_hi
;   +6 near-clip flag (1 = vertex behind near plane)  +7 unused
;
; Pseudocode:
;   if valid[idx]:                          # cache hit
;       evy, evx = cache[0..1]
;       if cache[6]: skip = 1; return       # cached near-clip verdict
;       rhi, rlo, sx = cache[2..5]
;   else:                                   # cache miss
;       valid[idx] = 1
;       wx, wy = ROM_VERTS[idx]             # s16 prescaled world coords
;       vx, vy = br_to_view(wx, wy)         # s24 view space (8.8 + ext)
;       evx = vx >> 8 (trunc); evy = clamp_s8((vy + 128) >> 8)
;       cache[0..1] = evy, evx              # pre-write: hit path needs them
;       if vy < NEAR (s24 test): cache[6] = 1; skip = 1; return
;       rhi, rlo = br_recip(vy >> 7)        # 9.1 index into recip table
;       sx = br_project_x(vx)          # narrow 3-mul / wide 5-mul
;       cache[2..6] = rhi, rlo, sx, 0
;   do_project_y()                          # per-seg heights, tail call
; ============================================================================

; ============================================================================
; LO/HI PLANE-ARM MACROS (2026-07-26, the bca CROSS_MAG_DECIDE lesson:
; ONE source, TWO expansions). Every vertex-plane twin below is
; generated from a single body with the senior page offset as the
; parameter — the pairs cannot drift (the hi hit-clip arm already had:
; it carried a private PAGE/RTS where the lo shared its exit branch).
; ============================================================================
; (VC_HIT_ARM macro ABSORBED into SXV_BODY 2026-08-09 — its single
; expansion point; the one-source-two-expansions anti-drift property
; is carried by SXV_BODY itself, like the fills before it.)

; (VC_FILL_ARM macro ABSORBED into SXV_BODY 2026-07-27 — the fills
; fused around one shared evy/evx tail per side.)

; (NC_FILL_ARM macro ABSORBED into SXV_BODY 2026-07-27 — the fills
; fused around one shared evy/evx tail per side.)

; (VXC_WARM_ARM folded into the vxcon island 2026-08-09 — single use)

; ============================================================================
; SXV_BODY — one full SIDE (senior page BAKED) of the vertex transform:
; probe -> hit serve | miss: fetch/rotate -> evy clamp -> near-clip ->
; recip -> project -> armed fill. Exits: VC_HIT_ARM / VC_FILL_ARM /
; NC_FILL_ARM, all RTS-terminated, all leaving BANK_L2 paged (the
; L2-exit contract is per-arm, unchanged by the hoist).
; ============================================================================
.macro SXV_BODY pg, vfoff, vxcon
.scope
; --- head (was SXV_HEAD, folded 2026-08-09): probe staging. (clip
; zeroing moved OUT of the head 2026-07-27, Eben: the hit arm serves it
; unconditionally, the miss arm stores the probe's own zero — see vmiss)
   LDY zp_seg_v_idx_b                      ; Y rides to the probe/set-bit
   LDA zp_seg_v_idx_l
   AND #7
   TAX
   LDA vc_bit_mask,X                       ; bit mask = 1 << (idx_lo & 7)
   STA zp_seg_v_bitm
   LDX zp_seg_ep                           ; X = struct offset from here on
   LDA VCACHE_VALID_BASE,Y
   AND zp_seg_v_bitm
   BEQ vmiss
; --- vcache hit serve (was VC_HIT_ARM, absorbed 2026-08-09) ---
   LDY zp_seg_v_idx_l
   LDA VC_EVY+pg,Y
   STA VX1+0,X
   LDA VC_EVX+pg,Y
   STA VX1+1,X
   LDA VC_CLIP+pg,Y                        ; cached near-clip verdict —
   STA VX1+2,X                             ; served UNCONDITIONALLY (the
   BNE vh_pgx                              ; head's ZERO died 2026-07-27);
                                           ; clipped: skip the dead serves
; (hit arm de-larded 2026-07-25: no working-recip stores, no select —
; every projector downstream restages from the STRUCT copies)
   LDA VC_SXL+pg,Y
   STA VX1+3,X                             ; sx_lo
   LDA VC_SXH+pg,Y
   STA VX1+4,X                             ; sx_hi
   LDA VC_RHI+pg,Y
   STA VX1+13,X                            ; rhi (apv_stage / the y-stage
                                           ; read the endpoint's own recip
                                           ; from +13/14)
   LDA VC_RLO+pg,Y
   STA VX1+14,X                            ; rlo (= S)
vh_pgx:
   PAGE BANK_L2                            ; exit contract (see head)
   RTS
; rare islands (side-local; the hit arm above exits, nothing falls in)
ec_clamp:
   LDA #$7F                                ; 128..255 → clamp
   STA VX1+0,X
   BNE ec_done                             ; (A = $7F: always taken)
ec_hi_nz:
; --- s8 SATURATE for an out-of-range evy (was the ev_clamp_hi_nz
; macro; inlined 2026-08-09 — the expansion had been paying 3-byte
; abs,X for the two VX1 accesses, and its BNE-to-next died too).
;
; WHAT: evy is the rounded s24->s8 narrowing of view-Y — the main
; path computed evy16 = (vy + 128) >> 8, stored its LOW byte in
; VX1+0,X, and branched here because the rounded HI byte (in A) is
; nonzero, i.e. the true value is outside 0..127. Every downstream
; reader (near-clip, recip index, y projection) treats VX1+0 as s8,
; so out-of-range values must SATURATE to +127/-128 — the Python
; mirror clamps identically, and under-/over-shooting here shows up
; directly as verify-vs-float divergence.
;
; HOW: case analysis on the hi byte, cheapest test first —
;   hi = $FF        value in -256..-1: may still FIT s8. Re-read the
;                   stored low byte: bit 7 set means -128..-1, and
;                   the stored byte already IS the s8 answer (the
;                   low 8 bits of a value that fits) -> exit, no
;                   store. Bit 7 clear means -256..-129 -> $80.
;   hi = $01..$7F   value >= +256 -> clamp $7F (+127).
;   hi = $80..$FE   value <= -257 -> clamp $80 (-128).
; The sign split needs no CMP: ASL A pushes the hi byte's sign bit
; into C (BCS = negative). The clamp immediates are nonzero, so the
; BNE-always idiom reaches the shared store without a JMP.
   CMP #$FF
   BEQ ev_case_ff
   ASL A                                   ; C = hi sign
   BCS ev_clamp_neg
   LDA #$7F                                ; >= +256: clamp +127
   BNE ev_store                            ; (always: A = $7F)
ev_clamp_neg:
   LDA #$80                                ; <= -257: clamp -128
   BNE ev_store                            ; (always: A = $80)
ev_case_ff:
   LDA VX1+0,X                             ; hi = $FF: the stored low byte
   BMI ev_done                             ; %1xxxxxxx = -128..-1, already
                                           ; the s8 value -> keep it
   LDA #$80                                ; %0xxxxxxx = -256..-129: clamp
ev_store:                                  ; (falls in)
   STA VX1+0,X
ev_done:
   JMP ec_done
; (vxcon island moved to the BODY END 2026-08-09: the inlined serve
;  outgrew the ec_clamp/ec_hi_nz branch spans here — it is vector-
;  entered and JMP-exited, so placement is free)
vmiss:
; mark valid now (fill lands the bytes below; even a near-clipped
; path leaves a usable evy/evx entry; clip lands in the fills — both
; verdicts store plane+struct symmetrically, 2026-07-27)
   LDA VCACHE_VALID_BASE,Y
   ORA zp_seg_v_bitm
   STA VCACHE_VALID_BASE,Y
; --- VECTORED fetch dispatch (Eben, 2026-07-27: the bca-cache idiom —
; pointer, not flag; vxc_frame aims it once per frame). Cache off:
; straight into the inline plain fetch below. Cache on: the vxcon
; stub (island above) probes/serves the translation cache. ---
.if pg = 0
   JMP (zp_vf_vec0)
.else
   JMP (zp_vf_vec1)
.endif
::vfoff:
; plain fetch INLINE (JMP-to-JSR pull-through, 2026-07-27): the
; rotate's RTS returns into the body; the SBC's N flag rides the JSR.
   PAGE BANK_L2                            ; vert planes live in L2
   LDY zp_seg_v_idx_l
   LDA VP_YLO+pg,Y
   STA zp_br_dy_l
   LDA VP_YHI+pg,Y
   STA zp_br_dy_h
   ZERO zp_ri_sgn
   LDA VP_XLO+pg,Y
   SEC
   SBC zp_br_px_h
   STA zp_ri_d_l
   LDA VP_XHI+pg,Y
   SBC zp_br_px_x
   STA zp_ri_d_h
   JSR btv_dx_signed                       ; rotate; RTS returns here
fetch_done:
   LDX zp_seg_ep                           ; struct offset
   LDA zp_br_vx_h
   STA VX1+1,X                             ; evx
   LDA zp_br_vy_l
   ASL A                                   ; carry = bit 7 of vylo
   LDA zp_br_vy_h
   ADC #0
   STA VX1+0,X                             ; evy = (vy + 128) >> 8
   LDA zp_br_vy_x
   ADC #0                                  ; rounded evy16 hi byte
   BNE ec_hi_nz                            ; hi != 0 → rare (island above)
   LDA VX1+0,X
   BMI ec_clamp                            ; 128..255 → rare clamp (island)
ec_done:
; near-clip on full s24: clipped iff total_vy < NEAR_88
   LDA zp_br_vy_x
   BMI nc_fail
   BNE nc_ok
   LDA VX1+0,X
   BMI nc_fail
   BEQ nc_fail                             ; evy == 0 -> below NEAR
nc_ok:
; recip: vy_idx = s24 total_vy >> 7 (9.1); junior arm inlined
   LDA zp_br_vy_l
   ASL A
   LDA zp_br_vy_h
   ROL A
   TAY                                     ; idx lo rides Y
   LDA zp_br_vy_x
   ROL A
   BNE ncr_far                             ; idx >= 256: rare (island below)
   LDA RECIP_BASE,Y
   STA zp_br_r_m8
   LDA srecip_tab,Y
   STA zp_br_r_s
   RNS_SELECT
ncr_done:
   JSR br_project_x                        ; -> Y = sx lo, A = sx hi
   LDX zp_seg_ep                           ; (recip/project clobbered X)
   STA VX1+4,X                             ; sx_hi
   STY VX1+3,X                             ; sx_lo (STY zp,X)
; --- armed fills, FUSED (Eben, 2026-07-27): the ok-miss part carries
; only what a near-clipped entry must not get (recip, sx, clip=0) and
; FALLS INTO the shared evy/evx tail; the near-clip prelude (rare)
; re-enters it with a branch-always. One copy of the shared stores
; per side instead of two. ---
   LDY zp_seg_v_idx_l
   LDA zp_br_r_m8
   STA VX1+13,X                            ; rhi/rlo: the endpoint's own
                                           ; recip for apv_stage / y-stage
   STA VC_RHI+pg,Y
   LDA zp_br_r_s
   STA VX1+14,X
   STA VC_RLO+pg,Y
   LDA zp_br_res_l                         ; sx from ZP (the store-backs'
   STA VC_SXL+pg,Y                         ; consumer)
   LDA zp_br_res_h
   STA VC_SXH+pg,Y
   LDA #0                                  ; clip = 0 (plane + struct —
fill_tail:
   STA VC_CLIP+pg,Y                        ; the nc prelude's mirror)
   STA VX1+2,X
   LDA VX1+0,X                             ; evy/evx: struct -> plane
   STA VC_EVY+pg,Y                         ; (shared by both verdicts)
   LDA VX1+1,X
   STA VC_EVX+pg,Y
   RTS                                     ; (a fill_tail birth-fill hook
                                           ; was tried 2026-07-27 and is
                                           ; IMPOSSIBLE: px_shrink halves
                                           ; wide zp_br_vx in place during
                                           ; projection — bases must
                                           ; snapshot PRE-projection, i.e.
                                           ; in the vxc cold arm = birth)
nc_fail:
   LDY zp_seg_v_idx_l
   LDA #1                                  ; clip = 1 (plane + struct)
   BNE fill_tail                           ; (A = 1: always taken)
ncr_far:
   JSR br_recip_hi                         ; A = idx hi, Y = idx lo
   JMP ncr_done
::vxcon:
; --- VXC serve INLINE (vxc_serve_lo/hi discarded 2026-08-09): probe +
; warm serve; cold = BIRTH. Warm exits inside VXC_WARM_ARM (PAGE L2 +
; JMP fetch_done: the old JSR/RTS/JMP glue — 12 cyc/warm serve — dies).
; Cold marks valid, fetches via the side's vf_plain (pages L2), then
; snapshots the base through the ONE shared store tail — JSR'd, since
; one tail serves both sides and fetch_done binds per side. The store
; must run PRE-projection: px_shrink corrupts wide vx totals in place.
   LDX zp_seg_v_idx_b                      ; VXC_VALID index = B (header key)
   PAGE BANK_C
   LDA VXC_VALID,X
   AND zp_seg_v_bitm
   BEQ vs_cold
   LDY zp_seg_v_idx_l
; warm: total = base + ref, two s24 adds (senior page baked; was
; VXC_WARM_ARM, folded 2026-08-09)
   CLC
   LDA VXC_XLO+pg,Y
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA VXC_XHI+pg,Y
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   LDA VXC_XEXT+pg,Y
   ADC vxc_ref_x+2
   STA zp_br_vx_x
   CLC
   LDA VXC_YLO+pg,Y
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA VXC_YHI+pg,Y
   ADC vxc_ref_y+1
   STA zp_br_vy_h
   LDA VXC_YEXT+pg,Y
   ADC vxc_ref_y+2
   STA zp_br_vy_x
   PAGE BANK_L2                            ; exit L2 = the fetch path's exit
   JMP fetch_done                          ; state
vs_cold:
   LDA VXC_VALID,X
   ORA zp_seg_v_bitm
   STA VXC_VALID,X
; plain fetch INLINE (vf_plain0/1 discarded 2026-08-09 — single caller
; each, so the standalone arms in view.s die; their tail JMP
; btv_dx_signed becomes a JSR so the birth store below runs on return).
; Plane fetch + merged dx subtract: the last SBC leaves N for btv's
; sign branch (STA/JSR preserve it).
   PAGE BANK_L2                            ; vert planes live in L2
   LDY zp_seg_v_idx_l
   LDA VP_YLO+pg,Y
   STA zp_br_dy_l
   LDA VP_YHI+pg,Y
   STA zp_br_dy_h
   ZERO zp_ri_sgn
   LDA VP_XLO+pg,Y
   SEC
   SBC zp_br_px_h
   STA zp_ri_d_l
   LDA VP_XHI+pg,Y
   SBC zp_br_px_x
   STA zp_ri_d_h
   JSR btv_dx_signed                       ; rotate; RTS returns here
; birth store INLINE, side baked (2026-08-09: was JSR vxc_store_tail →
; the generic vxc_cold_store macro — its senior test, hi-half JMP and
; the JSR/RTS all die with the side parameter; banked -4 B / flat -14 B
; net). base' = total - ref = L(w), translation-invariant (vxcache.s);
; the store must run PRE-projection: px_shrink corrupts wide vx totals
; in place.
   PAGE BANK_C
   LDY zp_seg_v_idx_l
   SEC
   LDA zp_br_vx_l
   SBC vxc_ref_x+0
   STA VXC_XLO+pg,Y
   LDA zp_br_vx_h
   SBC vxc_ref_x+1
   STA VXC_XHI+pg,Y
   LDA zp_br_vx_x
   SBC vxc_ref_x+2
   STA VXC_XEXT+pg,Y
   SEC
   LDA zp_br_vy_l
   SBC vxc_ref_y+0
   STA VXC_YLO+pg,Y
   LDA zp_br_vy_h
   SBC vxc_ref_y+1
   STA VXC_YHI+pg,Y
   LDA zp_br_vy_x
   SBC vxc_ref_y+2
   STA VXC_YEXT+pg,Y
   PAGE BANK_L2
   JMP fetch_done
.endscope
.endmacro

; (SXV_HEAD folded into SXV_BODY 2026-08-09 — it was expanded exactly
; once before each body and nothing could enter between them.)

; CALLER-SIDE DISPATCH (Eben, 2026-07-27 round 2): the side test lives
; at the CALL SITES (subsector stages idx_b with the byte in A — the
; test piggybacks); these are two complete side-baked routines with NO
; internal senior test anywhere (probe, fetch, VXC, fills all baked).
::sx_vert_lo:                              ; (page-aligning both sides was
   SXV_BODY 0, sxv0_vfoff, sxv0_vxcon      ; tried 2026-07-27: the ~370 pad
::sx_vert_hi:                              ; bytes overflow BOTH regions —
   SXV_BODY $100, sxv1_vfoff, sxv1_vxcon   ; unaligned round-2 form kept)

; (vxc_store_tail deleted 2026-08-09 — birth store inlined per side in
;  the vxcon islands, side baked)



; (VXC_WARM_ARM moved above SXV_BODY 2026-08-09 — it expands inside it now)

; ============================================================================
; (VXC serve INLINED into SXV_BODY's vxcon islands 2026-08-09 — the
; VXC_SERVE_SIDE macro and the standalone vxc_serve_lo/hi bodies are
; gone. In/out contract unchanged: in zp_seg_v_idx_l/b + zp_seg_v_bitm
; + vxc_ref_x/y; out zp_br_vx/vy lo/hi/ext, bit-identical to
; br_to_view — base' = L(w) is translation-invariant, see vxcache.s.)
; ============================================================================
