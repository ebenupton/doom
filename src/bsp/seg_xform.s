
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
;   Output: THE ENDPOINT STRUCT (zp.inc VX1/VX2, X = zp_seg_ep = 0/13):
;             +0 clip (1 = behind near plane; rest then undefined)
;             +1/+2 sx  +3..+10 the flag-gated sy pairs (do_project_y tail)
;             +11/+12 rhi/rlo (banked for apv_stage / the y-stage)
;           (COMPACTED 2026-08-09: the dead EV16 evy/evx head slots
;           squeezed out — stride 13; crossing recovers s24 totals
;           via cr_recover.)
;           zp_br_r_m8/rlo also hold the recip (projection working slots).
;           NOTHING is staged — every result stores once, struct-direct.
;   Uses:   br_to_view (view.s, s24 rotation), br_recip, br_project_x.
;
; Vertex cache: five 512-byte SoA planes (CLIP, SXL, SXH, RHI, RLO —
; header.s) plus a 1-bit-per-vertex valid bitmap at VCACHE_VALID_BASE
; (cleared per frame). A clipped entry stores clip = 1 ONLY; the other
; planes stay undefined for that vertex (nothing reads them).
;
; Pseudocode:
;   if valid[idx]:                          # cache hit
;       if clip[idx]: skip = 1; return      # cached near-clip verdict
;       rhi, rlo, sx = planes[idx]
;   else:                                   # cache miss
;       valid[idx] = 1
;       wx, wy = ROM_VERTS[idx]             # s16 prescaled world coords
;       vx, vy = total view (s24 8.8)       # rot + q64-widen + ref add
;       if vy < 128: clip[idx] = 1; skip = 1; return
;       rhi, rlo = br_recip(vy >> 7)        # 9.1 index into recip table
;       sx = br_project_x(vx)          # narrow 3-mul / wide 5-mul
;       planes[idx] = rhi, rlo, sx, clip=0
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
; NC_FILL_ARM, all RTS-terminated, ALL exiting BANK_L2 (the exit-L2
; contract is LOAD-BEARING — two independent bisects (hit-arm PAGE,
; the crossing's post-div restore) each break banked when removed,
; consumer unidentified; see vh_pgx).
; ============================================================================
; SPLIT MACROS (2026-08-13): SXV_TOP = head/probe/hit-serve/vmiss up to
; the vectored fetch dispatch; SXV_BOT = everything the vectors enter
; (vfoff plain fetch, near-clip, recip, fills, the vxcon island). The
; halves only connect through JMP (vec) -> the ::-global vfoff/vxcon
; labels, so the four expansions lay out top0, top1, bot0, bot1 — both
; tops fit under the entry's branch range and the hi trampoline died.
.macro SXV_TOP pg, vec
.scope
; --- head (was SXV_HEAD, folded 2026-08-09): probe staging. (clip
; zeroing moved OUT of the head 2026-07-27, Eben: the hit arm serves it
; unconditionally, the miss arm stores the probe's own zero — see vmiss)
; ABI (2026-08-13): callers enter via sx_vert with A = the just-loaded
; idx_b header byte; the entry stores zp_seg_v_idx_b, sets Y = idx_b
; and side-dispatches on bit 5. Y RIDES through the probe, vmiss and
; into vxcon's VXC_VALID accesses.
; BANK CONTRACT (flip 2026-08-13): callers PAGE_X BANK_L2 before the
; side dispatch (they finish their L0 header reads first), the body
; assumes L2 throughout and pages NOTHING; every exit leaves L2
; paged (the load-bearing exit postcondition, unchanged).
   LDA zp_seg_v_idx_l
   AND #7
   TAX
   LDA vc_bit_mask,X                       ; bit mask = 1 << (idx_lo & 7)
   STA zp_seg_v_bitm
   LDX zp_seg_ep                           ; X = struct offset from here on
   AND VCACHE_VALID_BASE,Y
   BEQ vmiss
; --- vcache hit serve (was VC_HIT_ARM, absorbed 2026-08-09) ---
; EV16: the evy/evx serves DIED — clip is the whole near verdict, and
; the crossing recovers s24 totals itself (cr_recover).
   LDY zp_seg_v_idx_l
   LDA VC_RLO+pg,Y                         ; S, with 0 = the CLIPPED
   BEQ vh_clipped                          ; sentinel (real S is in [1,10]
                                           ; — the VC_CLIP plane folded
                                           ; into RLO, 2026-08-13)
   STA VX1+12,X                            ; rlo (= S, riding A)
   LDA VC_RHI+pg,Y
   STA VX1+11,X                            ; rhi (apv_stage / the y-stage
                                           ; read the endpoint's own recip
                                           ; from +13/14)
   LDA VC_SXL+pg,Y
   STA VX1+1,X                             ; sx_lo
   LDA VC_SXH+pg,Y
   STA VX1+2,X                             ; sx_hi
   LDA #0
   STA VX1+0,X                             ; clip = 0 (unconditional stage)
vh_pgx:
   RTS                                     ; L2 rides from the caller's
                                           ; entry PAGE (contract flip
                                           ; 2026-08-13) — the exit-L2
                                           ; POSTCONDITION is LOAD-BEARING:
                                           ; the consumer (found by poison
                                           ; bisect 2026-08-13) is
                                           ; project_y's VWHC planes
                                           ; ($B100/$B200 = bank L2), read
                                           ; by the y-stage's NO-BACK arc
                                           ; which pages nothing.
vh_clipped:
   LDA #1
   STA VX1+0,X                             ; clip = nonzero; the other
   RTS                                     ; slots are undefined for a
                                           ; clipped vertex (unchanged)
; (vxcon island lives at the BODY END — vector-entered and JMP-exited,
;  so placement is free)
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
; stub (island below) probes/serves the translation cache. (The off
; arm was briefly deleted for TRUE16 always-on 2026-08-10 and
; RESTORED same day: the canonical cache-off contract is compute-
; only — same result, no probe, no store.) ---
   JMP (vec)                               ; the per-side fetch vector,
                                        ; passed in (the pg=0 fork died
                                        ; 2026-08-13)
.endscope
.endmacro

.macro SXV_BOT pg, vfoff, vxcon, rwpa, rwpb
.scope
::vfoff:
; TRUE16 plain fetch: stage the PAGE-DECOMPOSED vertex (unsigned u8
; offsets + senior nibble, 2026-08-11), rotate via the epoch-selected
; body (SMC site — general/cardinal), then the same 16-bit ref add as
; vxq_add. Bit-identical to the cached path by construction: every
; tier computes base_c + ref_c.  (L2 arrives from the caller — the
; contract flip 2026-08-13; the vert planes live there.)
   LDY zp_seg_v_idx_l
   LDA VP_OX+pg,Y
   STA zp_ri_d_l
   LDA VP_OY+pg,Y
   STA zp_br_dy_l
   LDA VP_PG+pg,Y
   STA zp_ri_d_h                           ; page nibble
::rwpa:
   JSR rot_w_pages                         ; SMC: rot_select picks the body
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
   STA zp_br_vy_h                          ; A/N/Z = vy count hi — fetch_
                                           ; done RIDES these (STA is flag-
                                           ; transparent; falls straight in)
fetch_done:
; near-clip on the s16 count total (TRUE16): clipped iff vy < 16
; counts (0.5 unit) — the count twin of the old vy_88 < 128 test.
; ARRIVAL CONTRACT (register-out): A/N/Z = zp_br_vy_h from the ref
; add's final ADC — BOTH arrivals (vfoff falls in, vxq_add JMPs) end
; with that add. Nothing may slip between the STA and here.
   BMI nc_fail                             ; negative -> behind
   BNE nc_ok                               ; >= 256 counts (8.0) -> visible
   LDA zp_br_vy_l
   CMP #16
   BCC nc_fail                             ; < 0.5 unit -> behind
nc_ok:
; recip: vy_idx = counts >> 4 (the same half-unit 9.1 index — counts
; >>4 == vy_88 >> 7); junior arm inlined. PERMUTED page-0 layout
; (Eben, 2026-08-10): in the fast-path domain idx < 256 BOTH nibbles
; of the index live in one byte, so the M8/S junior pages are stored
; NIBBLE-SWAPPED and the index is a mask + OR:
;   Y = (vy_l & $F0) | vy_h   ( = swap(vy >> 4) )
; — the 4xASL + 4xLSR splice died. Far pages stay linear
; (recip_hi's ladder).
   LDA zp_br_vy_h
   CMP #16
   BCS ncr_far                             ; idx >= 256: rare (island below)
   LDA zp_br_vy_l
   AND #$F0
   ORA zp_br_vy_h
   TAY                                     ; swapped idx rides Y
   LDA RECIP_M8,Y
   STA zp_br_r_m8
   LDA RECIP_S,Y
   STA zp_br_r_s                           ; (no RNS_SELECT: the counts
                                           ; projector selects net = S-3)
ncr_done:
   JSR project_x_c                      ; -> zp_br_res_l/h = rns(b123);
                                           ; the KERNEL RTSes straight here
                                           ; (px tail-jumps, 2026-08-12) —
                                           ; sx = 128 + res, biased in the
                                           ; landing adds below (lo FIRST:
                                           ; the carry feeds the hi pair)
   LDX zp_seg_ep                           ; struct offset
   LDY zp_seg_v_idx_l                      ; plane index
   LDA zp_br_res_l
   CLC
   ADC #128
   STA VX1+1,X                             ; sx_lo -> struct
   STA VC_SXL+pg,Y                         ; sx_lo -> plane
   LDA zp_br_res_h
   ADC #0
   STA VX1+2,X                             ; sx_hi -> struct
   STA VC_SXH+pg,Y                         ; sx_hi -> plane
; --- armed fills, FUSED (Eben, 2026-07-27): the ok-miss part carries
; only what a near-clipped entry must not get (recip, sx, clip=0) and
; FALLS INTO the shared evy/evx tail; the near-clip prelude (rare)
; re-enters it with a branch-always. One copy of the shared stores
; per side instead of two. ---
   LDA zp_br_r_m8
   STA VX1+11,X                            ; rhi/rlo: the endpoint's own
                                           ; recip for apv_stage / y-stage
   STA VC_RHI+pg,Y
   LDA zp_br_r_s
   STA VX1+12,X
   STA VC_RLO+pg,Y
   LDA #0                                  ; clip = 0 (struct only: the
fill_tail:                                 ;  PLANE verdict is RLO != 0,
   STA VX1+0,X                             ;  just stored above)
   RTS                                     ; (a fill_tail birth-fill hook
                                           ; was tried 2026-07-27 and is
                                           ; IMPOSSIBLE: px_shrink halves
                                           ; wide zp_br_vx in place during
                                           ; projection — bases must
                                           ; snapshot PRE-projection, i.e.
                                           ; in the vxc cold arm = birth)
nc_fail:
   LDX zp_seg_ep                           ; struct offset — ONLY this arm
                                           ; needs it before fill_tail; the
                                           ; ok path reloads after project
                                           ; (dead fetch_done LDX: Eben)
   LDY zp_seg_v_idx_l
   LDA #0
   STA VC_RLO+pg,Y                         ; S := 0 — the plane's CLIPPED
   LDA #1                                  ; sentinel; clip = 1 to the
   BNE fill_tail                           ; struct (A = 1: always taken)
ncr_far:
; rare: vy >= 128 units (idx >= 256). idx = counts>>4 split by nibble:
; vy_l is dead scratch for the lo half, vy_h stays whole for the hi.
   LDA zp_br_vy_l
   LSR A
   LSR A
   LSR A
   LSR A
   STA zp_br_vy_l                          ; l>>4
   LDA zp_br_vy_h
   ASL A
   ASL A
   ASL A
   ASL A                                   ; (h&15)<<4
   ORA zp_br_vy_l
   TAY                                     ; Y = idx lo
   LDA zp_br_vy_h
   LSR A
   LSR A
   LSR A
   LSR A                                   ; A = idx hi
   JSR recip_hi
   JMP ncr_done
; (the ec_clamp/ec_hi_nz s8-saturate islands DIED with the evy/evx
; tier — EV16 2026-08-09: no consumer treats anything as s8 any more)
::vxcon:
; --- VXC serve, TRUE16 (2026-08-10): the cache memoizes base counts =
; rns(rot(w), 3) — a pure function of (vertex, angle epoch) — in FOUR
; s16 planes, main RAM. Counts ARE the working form: warm = 4 loads +
; the 16-bit ref add (the <<2 widen DIED); cold = birth: fetch + rot
; (counts out of the vq3 tail) + 4 plane stores DIRECT (the >>2/<<2
; dance DIED), same add. Every tier computes total := base_c +
; ref_c, so warm == birth == Python bit-exactly BY CONSTRUCTION.
   LDA VXC_VALID,Y                         ; Y = B RIDES from the head
                                           ; (planes + VALID are main; the
                                           ; cold VP fetch uses the
                                           ; caller's L2)
   AND zp_seg_v_bitm                       ; (the X reload died — the
   BEQ vs_cold                             ;  X/Y roles flipped 2026-08-13)
   LDX zp_seg_v_idx_l
   LDA VXC_XLO+pg,X                        ; warm: base counts -> the
   STA zp_br_vx_l                          ; working slots
   LDA VXC_XHI+pg,X
   STA zp_br_vx_h
   LDA VXC_YLO+pg,X
   STA zp_br_vy_l
   LDA VXC_YHI+pg,X
   STA zp_br_vy_h
   JMP vxq_add
vs_cold:
   LDA VXC_VALID,Y
   ORA zp_seg_v_bitm
   STA VXC_VALID,Y
; birth: page-decomposed fetch + the epoch-selected rotate body
   LDY zp_seg_v_idx_l
   LDA VP_OX+pg,Y
   STA zp_ri_d_l
   LDA VP_OY+pg,Y
   STA zp_br_dy_l
   LDA VP_PG+pg,Y
   STA zp_ri_d_h                           ; page nibble
::rwpb:
   JSR rot_w_pages                         ; SMC: rot_select picks the body
   LDY zp_seg_v_idx_l
   LDA zp_br_vx_l
   STA VXC_XLO+pg,Y                        ; birth store: counts verbatim
   LDA zp_br_vx_h
   STA VXC_XHI+pg,Y
   LDA zp_br_vy_l
   STA VXC_YLO+pg,Y
   LDA zp_br_vy_h
   STA VXC_YHI+pg,Y
vxq_add:
; shared tail: totals := base_c + ref_c, s16 (overflow impossible:
; the pack range assert bounds |total| <= 32767)
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
   STA zp_br_vy_h                          ; A/N/Z = vy count hi —
   JMP fetch_done                          ; fetch_done's arrival contract
                                           ; (JMP is flag-transparent; the
                                           ; island never leaves L2)
.endscope
.endmacro

; (SXV_HEAD folded into SXV_BODY 2026-08-09 — it was expanded exactly
; once before each body and nothing could enter between them.)

; Common entry (2026-08-13, dispatch pushed DOWN from the call sites —
; no caller knows the side statically, so the caller-side test only
; bought two 6-byte islands in seg_emit). A = idx_b (the TAY in the
; SXV ABI staging preserves it); bit 5 selects the side-baked body.
; The lo body sits between the test and sx_vert_hi, far past branch
; range — the hi arm pays a JMP trampoline, exactly what the old
; caller-side islands paid, so cycles are unchanged (lo 10, hi 14).
::sx_vert:
   TAY                                     ; ABI: A = idx_b (= id>>3);
   AND #$20                                ; Y = bitmap index for the probe,
   BNE sx_vert_hi                          ; bit 5 = senior plane (256>>3);
                                        ; top1 is in branch range (the
                                        ; split macros — trampoline died).
                                        ; zp_seg_v_idx_b is NOT stored here:
                                        ; every consumer wants V2's value
                                        ; (v1's lives in zp_v1i_b) — the v2
                                        ; call site banks it
; fall into the lo top — the side-baked halves below have NO internal
; senior test anywhere (probe, fetch, VXC, fills all baked).
::sx_vert_lo:
   SXV_TOP 0, zp_vf_vec0
::sx_vert_hi:
   SXV_TOP $100, zp_vf_vec1
   SXV_BOT 0, sxv0_vfoff, sxv0_vxcon, sxv0_rwpa, sxv0_rwpb
   SXV_BOT $100, sxv1_vfoff, sxv1_vxcon, sxv1_rwpa, sxv1_rwpb

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
