
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
.macro VC_HIT_ARM pg
.local ok, pgx
   LDY zp_seg_v_idx_l
   LDA VC_EVY+pg,Y
   STA VX1+0,X
   LDA VC_EVX+pg,Y
   STA VX1+1,X
   LDA VC_CLIP+pg,Y                        ; cached near-clip verdict —
   STA VX1+2,X                             ; served UNCONDITIONALLY (the
   BNE pgx                                 ; head's ZERO died 2026-07-27);
                                           ; clipped: skip the dead serves
ok:
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
pgx:
   PAGE BANK_L2                            ; exit contract (see head)
   RTS
.endmacro

; (VC_FILL_ARM macro ABSORBED into SXV_BODY 2026-07-27 — the fills
; fused around one shared evy/evx tail per side.)

; (NC_FILL_ARM macro ABSORBED into SXV_BODY 2026-07-27 — the fills
; fused around one shared evy/evx tail per side.)

; ============================================================================
; SXV_BODY — one full SIDE (senior page BAKED) of the vertex transform:
; probe -> hit serve | miss: fetch/rotate -> evy clamp -> near-clip ->
; recip -> project -> armed fill. Exits: VC_HIT_ARM / VC_FILL_ARM /
; NC_FILL_ARM, all RTS-terminated, all leaving BANK_L2 paged (the
; L2-exit contract is per-arm, unchanged by the hoist).
; ============================================================================
.macro SXV_BODY pg
.scope
   LDA VCACHE_VALID_BASE,Y
   AND zp_seg_v_bitm
   BEQ vmiss
   VC_HIT_ARM pg
; rare islands (side-local; the hit arm above exits, nothing falls in)
ec_clamp:
   LDA #$7F                                ; 128..255 → clamp
   STA VX1+0,X
   BNE ec_done                             ; (A = $7F: always taken)
ec_hi_nz:
   ev_clamp_hi_nz
   JMP ec_done
vmiss:
; mark valid now (fill lands the bytes below; even a near-clipped
; path leaves a usable evy/evx entry; clip lands in the fills — both
; verdicts store plane+struct symmetrically, 2026-07-27)
   LDA VCACHE_VALID_BASE,Y
   ORA zp_seg_v_bitm
   STA VCACHE_VALID_BASE,Y
.if pg = 0
   JSR vertex_fetch_0                      ; side-baked plain fetch (vxc
.else                                      ; path keeps its internal test —
   JSR vertex_fetch_1                      ; 0 exec on the suite)
.endif
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
   STA VC_CLIP+pg,Y                        ; the nc prelude's mirror)
   STA VX1+2,X
fill_tail:
   LDA VX1+0,X                             ; evy/evx: struct -> plane
   STA VC_EVY+pg,Y                         ; (shared by both verdicts)
   LDA VX1+1,X
   STA VC_EVX+pg,Y
   RTS
nc_fail:
   LDY zp_seg_v_idx_l
   LDA #1                                  ; clip = 1 (plane + struct)
   STA VC_CLIP+pg,Y
   STA VX1+2,X
   BNE fill_tail                           ; (A = 1: always taken)
ncr_far:
   JSR br_recip_hi                         ; A = idx hi, Y = idx lo
   JMP ncr_done
.endscope
.endmacro

.macro SXV_HEAD
   LDY zp_seg_v_idx_b                      ; Y rides to the probe/set-bit
   LDA zp_seg_v_idx_l
   AND #7
   TAX
   LDA vc_bit_mask,X                       ; bit mask = 1 << (idx_lo & 7)
   STA zp_seg_v_bitm
   LDX zp_seg_ep                           ; X = struct offset from here on
.endmacro                                  ; (clip zeroing moved OUT of the
                                           ; head 2026-07-27, Eben: the hit
                                           ; arm serves it unconditionally,
                                           ; the miss arm stores the probe's
                                           ; own zero — see vmiss)

; CALLER-SIDE DISPATCH (Eben, 2026-07-27 round 2): the side test lives
; at the CALL SITES (subsector stages idx_b with the byte in A — the
; test piggybacks); these are two complete side-baked routines with NO
; internal senior test anywhere (probe, fetch, VXC, fills all baked).
::sx_vert_lo:                              ; (page-aligning both sides was
   SXV_HEAD                                ; tried 2026-07-27: the ~370 pad
   SXV_BODY 0                              ; bytes overflow BOTH regions —
::sx_vert_hi:                              ; unaligned round-2 form kept)
   SXV_HEAD
   SXV_BODY $100



.macro VXC_WARM_ARM pg
; warm: total = base + ref, two s24 adds (senior page baked)
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
   PAGE BANK_L2                            ; exit L2 = the OFF-path's exit
   RTS                                     ; state (br_to_view_fetch): one
                                           ; contract, and br_recip's
                                           ; per-call PAGE dies (2026-07-21)
.endmacro

; ============================================================================
; vxc_arm — the coherence-cache tier of the vertex pipeline (2026-07-12:
; the old vxc_to_view wrapper + vxc_warm_load hop, flattened into THIS
; file so the whole per-vertex path — frame-cache probe, coherence probe,
; warm reconstruction, rotate fallback — reads top to bottom in one
; place). JSR'd from vxc_jsr_site above when VXC is enabled (vxc_frame
; patches the operand; disabled frames call br_to_view_fetch directly,
; zero overhead). Ends RTS; the caller falls into the evy/evx compute.
;
; In:  zp_seg_v_idx_l/b (vertex key), zp_seg_v_bitm (1 << (idx&7)),
;      vxc_ref_x/y (this frame's to_view(0,0), s24 each)
; Out: zp_br_vx/vy lo/hi/ext = exact view totals (bit-identical to
;      br_to_view: base' = L(w) is translation-invariant, see vxcache.s)
; ============================================================================
.macro VXC_ARM_SIDE pg, vfp
.scope
   LDX zp_seg_v_idx_b                      ; VXC_VALID index = B (header key)
   PAGE BANK_C
   LDA VXC_VALID,X
   AND zp_seg_v_bitm
   BEQ va_cold
; warm: total = base + ref, two s24 adds — side page BAKED (the
; internal TXA/AND #$20 dispatch died with the caller-side hoist)
   LDY zp_seg_v_idx_l
   VXC_WARM_ARM pg
va_cold:
; cold: mark valid, fetch + rotate for real, snapshot the base
   LDA VXC_VALID,X
   ORA zp_seg_v_bitm
   STA VXC_VALID,X
   JSR vfp                                 ; the side's plain fetch (pages L2)
   PAGE BANK_C
   vxc_cold_store                      ; leaf (vxcache.s): base = total-ref
   PAGE BANK_L2                        ; (same exit contract as the warm arm)
   RTS
.endscope
.endmacro
vxc_arm_lo:
   VXC_ARM_SIDE 0, vf_plain0
vxc_arm_hi:
   VXC_ARM_SIDE $100, vf_plain1
