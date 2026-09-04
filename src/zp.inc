.include "abi.inc"
; ============================================================================
; ENGINE ENTRIES THE DRIVER LINKS AGAINST (2026-08-30).  walk_drv is a ca65
; link unit now, so it IMPORTS these by name instead of reading addresses
; out of a generated engine_syms.inc.  .global exports them from whichever
; unit defines them -- and a moved or renamed entry becomes a LINK ERROR
; rather than a stale literal in a generated file.
; ============================================================================
.global view_setup
.global render_frame
.global span_init
.global anim_tick
.globalzp LC_TGT_LO
.global t0
.global ANIM_FIELDS
.global anim_init
.global bca_tail_postrc
.global box_classify
.global pq_pump_op
.global plotq_drain
.global plotq_arm
.global plotq_off
.global sqr_fill_cold
.global obj_anyb_fill
.global fb_clr0
.global fb_clr1
.global fb_clr_back
.global pmove_try
.global pmove_use
.global pm_oldx
.global pm_vz
.global pm_ux
.global pmove_zonly
.global pm_frame
          ; cross-language ABI constants (generated)
; ============================================================================
; ZERO PAGE REGISTRY — single source of truth for every ZP assignment in the
; engine (span_clip + bsp_render + angle module). Included first by all three
; link units, so any collision between units is a duplicate-symbol error at
; assembly time and any layout change propagates everywhere (the Python
; harness reads these through the linker symbol map — see symmap.py).
;
; Addresses with more than one name are DELIBERATE overlays: the users are
; phase-disjoint (their live ranges never overlap). Keep new symbols out of
; a group unless you have proven phase-disjointness.
;
; Run tools/zpcheck.py for a rendered map + free-slot list.
;
; ZP SWEEP (2026-08-11, profiled promotion of hot $06xx scalars —
; equates live in clip/tfr.s, logged HERE so the free-list can't rot):
;   $1F TFS_T_CUR      $2B TFS_B_CUR     $52 LC_REM_LO   $53 LC_REM_HI
;   $8F TFS_CUR_X      $94 TFS_NEXT_X    $98 LC_DEN_LO   $99 LC_DEN_HI
;   $A6 LC_QUOT_LO     $A7 LC_QUOT_HI    $C6 LC_TMP_LO   $CE TFS_TOP_DOM
;   $D3 LC_M_R0        $D4 LC_M_R1       $D6 TFS_BOT_DOM $D8 TFS_PEND_ACT
;   $E1 TFS_X_HI       $FC LC_DY_LO      $FD LC_DY_HI    $FE LC_OFF_LO
;   $FF LC_OFF_HI
; FUSED walker hot state (2026-08-25 grind): the records sweep's death
; freed its 34 promoted bytes; the walker takes 30 of them (listing-scan
; verified free — $CC/$CD/$CF were already re-squatted by t0/t1/
; rc_bytehi). Same liveness class as the TFS set: live only inside
; render_frame, so the drivers'/pm's zp never sees them. Cold walker
; bytes (touch/saves/splits) stay on the FW page in clip/fusedw.s.

; ============================================================================
; ZERO PAGE -- LINKER-ALLOCATED (2026-08-30).  Was 209 literal equates; the
; addresses are now RESERVED in the ZEROPAGE segment and ld65 assigns them,
; so a "free" byte is one the linker has not handed out rather than one
; nobody happened to name.  That kills the free-note trap class outright
; (see feedback-zp-free-traps: the VX-block stride rot ate $F8/$F9 while
; both looked free).  Order is BY ADDRESS and the gaps are explicit .res
; pads, so the layout is byte-identical to the map it replaces -- the
; bottom-22K rule covers zero page too.
;
; zp.inc is included by more than one link unit, so the reservations are
; emitted ONCE, by whichever unit defines ZP_OWNER; every unit sees the
; names through .globalzp.  Without that guard each includer would reserve
; its own copy and the whole page would triple.
;
; OVERLAYS are symbolic aliases now, not two literals that happen to match:
; the second name is defined as the first, so they cannot drift apart.
; ============================================================================
.globalzp LC_OY1_LO
.global zp_br_px
.globalzp zp_br_px_h
.globalzp bca_px
.globalzp LC_OY1_HI
.global zp_br_py
.globalzp zp_br_py_h
.globalzp bca_py
.globalzp zp_br_vz
.globalzp zp_br_smag
.globalzp zp_br_sneg
.globalzp zp_br_sone
.globalzp zp_br_cmag
.globalzp zp_br_cneg
.globalzp zp_br_cone
.globalzp zp_br_fvx_l
.globalzp zp_br_fvx_h
.globalzp zp_br_fvy_l
.globalzp zp_br_fvy_h
.globalzp zp_br_dx_l
.globalzp zp_br_dy_l
.globalzp zp_br_vx_l
.globalzp zp_br_vx_h
.globalzp zp_br_vy_l
.globalzp zp_br_vy_h
.globalzp zp_br_a
.globalzp zp_br_b
.globalzp zp_br_res_l
.globalzp zp_br_res_h
.globalzp zp_br_sign
.globalzp zp_br_r_m8
.globalzp zp_br_r_s
.global zp_br_px2_l
.globalzp DCLV_S16VY
.global zp_br_px2_h
.globalzp zp_rs_l
.globalzp zp_rc1_l, zp_rc1_h, zp_rc2_l, zp_rc2_h
.globalzp zp_rws_l, zp_rws_m
.globalzp FW_SLOT
.globalzp zp_br_t0
.globalzp zp_br_t1
.globalzp zp_br_t2
.globalzp zp_br_t3
.global zp_br_t4
.global zp_br_t5
.globalzp zp_seg_ep
.globalzp ANIM_VAL
.globalzp zp_tw
.globalzp zp_ri_d_l
.globalzp ANIM_CUR
.globalzp zp_rs_h
.globalzp FW_NEXT
.globalzp zp_ri_d_h
.globalzp fwl_xl
.globalzp fwl_yl
.globalzp fwl_xr
.globalzp pa_dx
.globalzp pa_dy
.globalzp zp_bbox_side
.globalzp zp_br_dx_h
.globalzp zp_br_dy_h
.globalzp fwl_yr
.globalzp fwl_dy
.globalzp pa_res
.globalzp bca_afn
.globalzp zp_bf_dir
.globalzp zp_cpm_slot
.globalzp zp_seg_flags
.globalzp pa_ptr
.globalzp zp_ys_done
.globalzp zp_ys_v1ok
.globalzp fwl_dx
.globalzp zp_v1i_l
.globalzp zp_v1i_b
.globalzp zp_seg_v_bitm
.globalzp fwl_lo
.globalzp fwl_hi
.globalzp fwl_run
.globalzp fwl_ry0
.globalzp zp_ss_eskip
.globalzp zp_vs_x
.globalzp fwl_rend
.globalzp LC_OX2_LO
.global zp_vs_i
.globalzp LC_OX2_HI
.global zp_vs_hl
.globalzp LC_RES_LO
.global zp_vs_hh
.globalzp LC_REM_LO
.globalzp LC_REM_HI
.globalzp fwl_rendv
.globalzp fwl_zx0
.globalzp fwl_zx1
.global fwl_leftf
.globalzp zp_node_ch_l
.globalzp zp_pm_p
.globalzp zp_hg_ihi
.globalzp zp_seg_count
.globalzp zp_anim_p
.globalzp zp_anim_w
.globalzp zp_prev
.globalzp zp_bv_entry
.globalzp zp_seg_end_x
.global zp_seg_fh
.global zp_seg_ch
.global val_hi
.globalzp zp_seg_top_dlt
.globalzp zp_seg_bot_dlt
.globalzp zp_save0
.globalzp LC_OX1_LO
.global fwl_pend
.globalzp zp_save2
.globalzp zp_new_tail
.globalzp zp_old_cur
.globalzp zp_ox0
.globalzp zp_ox1
.globalzp RASTER_ZP_SCRSTRT
.globalzp zp_seg_v_idx_l
.globalzp zp_seg_v_idx_b
.globalzp zp_vf_vec0
.globalzp zp_vf_vec1
.globalzp obj_ctr_l
.global zp_br_py2_l
.globalzp RASTER_ZP_X0
.globalzp RASTER_ZP_Y0
.globalzp RASTER_ZP_X1
.globalzp RASTER_ZP_Y1
.globalzp bca_boxp
.globalzp zp_cr_vx_l
.globalzp zp_cr_vx_h
.globalzp zp_cr_vy_l
.globalzp zp_cr_vy_h
.globalzp bca_pxs
.global fw_pol
.globalzp zp_br_pxraw_l
.globalzp zp_br_pxraw_h
.globalzp zp_br_pyraw_l
.globalzp zp_br_pyraw_h
.globalzp DCLS_FIRST
.global fw_top1
.globalzp zp_plot_i
.globalzp zp_seg_hdr_p
.globalzp zp_seg_hdr_p_h
.globalzp LC_DEN_LO
.globalzp LC_DEN_HI
.globalzp zp_pyc_idx
.globalzp bca_pys
.globalzp zp_br_px_x
.globalzp zp_br_py_x
.globalzp zp_dcl_out
.globalzp plotq_n
.globalzp plotq_mode
.globalzp vxcache_ref_x
.globalzp vxcache_ref_y
.globalzp LC_QUOT_LO
.globalzp LC_QUOT_HI
.globalzp zp_line_xl_l
.globalzp zp_line_yl_l
.globalzp zp_line_xr_l
.globalzp zp_line_yr_l
.globalzp zp_line_dx
.globalzp zp_line_dy
.globalzp zp_line_y_l
.globalzp zp_line_y_h
.globalzp zp_seg_start_x
.globalzp zp_seg_start_y
.globalzp zp_cb_cx1
.globalzp zp_line_xl_h
.globalzp zp_cb_cy1
.globalzp zp_line_yl_h
.globalzp zp_cb_cx2
.globalzp zp_line_xr_h
.globalzp zp_cb_cy2
.globalzp zp_line_yr_h
.global zp_cb_top1
.globalzp obj_hcnt
.global fw_top2
.globalzp LC_OY2_HI
.global zp_cb_bot1
.globalzp cp_vx0
.globalzp obj_ctr_h
.global zp_br_py2_h
.globalzp cp_vy0
.globalzp LC_OY2_LO
.global zp_bf_lv1
.globalzp zp_ys_bs
.globalzp zp_vs_cfh
.globalzp cp_vx1
.globalzp zp_head
.globalzp zp_free
.globalzp zp_i_l
.globalzp zp_i_h
.globalzp cp_vev
.globalzp fw_ax0
.globalzp LC_TMP_LO
.globalzp LC_OX1_HI
.global zp_vxcache_on
.globalzp zp_bca_p1
.globalzp zp_bca_p1_h
.globalzp zp_tail_vec
.globalzp fw_ax1
.globalzp zp_hg_cache
.globalzp zp_i_x0
.globalzp zp_i_y0
.globalzp LC_M_R0
.globalzp LC_M_R1
.globalzp zp_i_y1
.globalzp fw_rslot
.globalzp zp_clr_save_x
.globalzp FW_SIDE
.globalzp zp_mul_b
.globalzp zp_prod_l
.globalzp zp_div_l
.globalzp zp_prod_h
.globalzp zp_div_h
.globalzp zp_div_den
.globalzp FW_MODE
.globalzp zp_tmp0
.globalzp zp_tmp1
.globalzp zp_tmp2
.globalzp zp_vs_cch
.globalzp VX1
.globalzp LC_DY_LO
.globalzp LC_DY_HI
.globalzp LC_OFF_LO
.globalzp LC_OFF_HI

.globalzp obj_e
.globalzp obj_t
.globalzp obj_pu
.globalzp obj_cx_h
.globalzp obj_cx_l
.globalzp obj_px
.globalzp obj_yt_l
.globalzp obj_yt_h
.globalzp obj_fused
.global obj_ss

.ifdef ZP_OWNER
.segment "ZEROPAGE"
LC_OY1_LO:                 .res 1 ; ROTATED IN (zprotate): 27.9 vs zp_br_px's 0.1
zp_br_px_h:                 .res 1 ; [bsp]
LC_OY1_HI:                 .res 1 ; ROTATED IN (zprotate): 27.8 vs zp_br_py's 0.1
zp_br_py_h:                 .res 1 ; [bsp]
zp_br_vz:                   .res 1 ; [bsp]; s8 eye-height (prescaled)
zp_br_smag:                 .res 1 ; [bsp]; u8 sin magnitude
zp_br_sneg:                 .res 1 ; [bsp]; 1 if sin negative
zp_br_sone:                 .res 1 ; [bsp]; 1 if |sin| == 1
zp_br_cmag:                 .res 1 ; [bsp]
zp_br_cneg:                 .res 1 ; [bsp]
zp_br_cone:                 .res 1 ; [bsp]
zp_br_fvx_l:                .res 1 ; [bsp]; s16 frac_vx (0.8 contribution)
zp_br_fvx_h:                .res 1 ; [bsp]
zp_br_fvy_l:                .res 1 ; [bsp]
zp_br_fvy_h:                .res 1 ; [bsp]
zp_br_dx_l:                 .res 1 ; [bsp]
zp_br_dy_l:                 .res 1 ; [bsp]
zp_br_vx_l:                 .res 1 ; [bsp]
zp_br_vx_h:                 .res 1 ; [bsp]
zp_br_vy_l:                 .res 1 ; [bsp]
zp_br_vy_h:                 .res 1 ; [bsp]
zp_br_a:                    .res 1 ; [bsp]; multiplicand A (s8 input)
zp_br_b:                    .res 1 ; [bsp]; multiplicand B
zp_br_res_l:                .res 1 ; [bsp]; s24 result lo
zp_br_res_h:                .res 1 ; [bsp]; s24 result mid (the s16 path stops here)
zp_br_sign:                 .res 1 ; [bsp]; 0 = positive, non-0 = negative
zp_br_r_m8:                 .res 1 ; [bsp]; u8 hi of reciprocal
zp_br_r_s:                  .res 1 ; [bsp]; u8 lo
obj_cx_l:                   .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_br_px2_l
DCLV_S16VY:                .res 1 ; ROTATED IN (zprotate): 16.3 vs zp_br_px2_h's 15.5
zp_rs_l:                    .res 1 ; [bsp] sin-side rotate result lo (res-slot
                                  ; split 2026-07-19: sin cores/variants write
                                  ; rs_*, cos keeps zp_br_res — the s1 res->vx
                                  ; copy died; s2 combines from both slots)
FW_SLOT:                    .res 1 ; [clip]
zp_br_t0:                   .res 1 ; [bsp]
zp_br_t1:                   .res 1 ; [bsp]
zp_br_t2:                   .res 1 ; [bsp]
zp_br_t3:                   .res 1 ; [bsp]
obj_yt_l:                   .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_br_t4
obj_yt_h:                   .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_br_t5
zp_seg_ep:                  .res 1 ; [bsp]; per-endpoint STRUCT offset into
ANIM_VAL:                   .res 1 ; [bsp]; anim: patch value (registered
zp_ri_d_l:                  .res 1 ; [bsp]
ANIM_CUR:                   .res 1 ; [bsp]; anim: mover index (was $F1)
zp_rs_h:                    .res 1 ; [bsp] sin-side rotate result hi (pairs $1E)
FW_NEXT:                    .res 1 ; [clip]
zp_ri_d_h:                  .res 1 ; [bsp]; (was unused; s16 hi byte of d)
fwl_xl:                     .res 1 ; [clip]; the armed line (fw_walk_line)
fwl_yl:                     .res 1 ; [clip]
fwl_xr:                     .res 1 ; [clip]
pa_dx:                      .res 1 ; [ang]; s16 in ; w=2
   .res 1                               ; FREE $31-$31
pa_dy:                      .res 1 ; [ang]; s16 in ; w=2
   .res 1                               ; FREE $33-$33
zp_bbox_side:               .res 1 ; [bsp]
zp_br_dx_h:                 .res 1 ; [bsp]
zp_br_dy_h:                 .res 1 ; [bsp]
fwl_yr:                     .res 1 ; [clip]
fwl_dy:                     .res 1 ; [clip]
pa_res:                     .res 1 ; [ang]; u16 out (fineangle) ; w=2
   .res 1                               ; FREE $3A-$3A
bca_afn:                    .res 1 ; [ang]; a_fine (s16) -- ZP (freed from pa_adx); hot in corner_phi ; w=2
   .res 1                               ; FREE $3C-$3C
zp_bf_dir:                  .res 1 ; [bsp]; diagonal back-face DIR-table index;
zp_cpm_slot:                .res 1 ; [ang]; memo hash slot, probe -> store
zp_seg_flags:               .res 1 ; [bsp]; u8
pa_ptr:                     .res 1 ; [ang]; 16-bit table pointer ; w=2
   .res 1                               ; FREE $41-$41
zp_ys_done:                 .res 1 ; [bsp]; 1 = the PREVIOUS seg ran the
zp_ys_v1ok:                 .res 1 ; [bsp]; 1 = this seg's chained v1
fwl_dx:                     .res 1 ; [clip]
zp_v1i_l:                   .res 1 ; [bsp]; v1 vertex key lo (idx & 255) banked
zp_v1i_b:                   .res 1 ; [bsp]; ... key B (idx >> 3) across the v2
                                  ; transform for the vertex-span emitter
zp_seg_v_bitm:              .res 1 ; [bsp]; valid-bitmap mask (1 << (idx & 7));
fwl_lo:                     .res 1 ; [clip]; minmax pair = the apply's extremes
fwl_hi:                     .res 1 ; [clip]
fwl_run:                    .res 1 ; [clip]; run state ($FF = closed)
fwl_ry0:                    .res 1 ; [clip]
zp_ss_eskip:                .res 1 ; [bsp]; subsector eyeline edge-skip:
                                  ; $80 = ch <= vz (no top edges),
                                  ; $40 = fh >= vz (no bottom edges);
                                  ; built in the subsector prologue,
                                  ; BIT-tested at the ft/fb arm heads
zp_vs_x:                    .res 1 ; [bsp]; vs_vertex: struct offset save
fwl_rend:                   .res 1 ; [clip]
LC_OX2_LO:                 .res 1 ; ROTATED IN (zprotate): 18.6 vs zp_vs_i's 13.2
LC_OX2_HI:                 .res 1 ; ROTATED IN (zprotate): 18.6 vs zp_vs_hl's 12.7
LC_RES_LO:                 .res 1 ; ROTATED IN (zprotate): 20.4 vs zp_vs_hh's 8.3
LC_REM_LO:                  .res 1 ; [clip]
LC_REM_HI:                  .res 1 ; [clip]
fwl_rendv:                  .res 1 ; [clip]; $80 = open end
fwl_zx0:                    .res 1 ; [clip]; current overlap
fwl_zx1:                    .res 1 ; [clip]
obj_pu:                     .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went obj_ss
zp_node_ch_l:               .res 1 ; [bsp]; current child (lo, hi: 16-bit id)
zp_pm_p:                    .res 2 ; [bsp]; pmove: collision list pointer ; w=2
                                  ; SURVIVES DRAWS (the old $79 home was
                                  ; raster scratch — reads were only safe
                                  ; adjacent to the store); the vs2 serve
                                  ; site + vs_fresh2 now reuse it across
                                  ; the emit cascade ($47 = zp_vs_d's
                                  ; slot, freed 98fc1b3)
zp_hg_ihi:                  .res 1 ; [clip]; has_gap: stashed interval hi
zp_seg_count:               .res 1 ; [bsp]; remaining segs in subsector
zp_anim_p:                  .res 2 ; [bsp]; anim table cursor (2; was the
zp_anim_w:                  .res 2 ; [bsp]; anim write pointer (2; was $ED/$EE)
zp_prev:                    .res 1 ; [clip]; pool-walk prev (from $E2 — structs)
   .res 1                               ; FREE $62-$62
zp_bv_entry:                .res 1 ; [ang] 2-byte entry vector: bbox_visible
                                  ; is JMP (zp_bv_entry) -> bbox_check_angle
                                  ; (standing: probe) or box_classify (moving:
                                  ; pristine). Paired with zp_tail_vec; w=2
                                  ; (valid bits armed, probe+serve+store);
                                  ; nonzero = moving/unknown (pristine
                                  ; passthru, no probe, no stores). Written
                                  ; by bca_frame; the stop EDGE wipes the
                                  ; bitmap and clears this. Driver init
                                  ; seeds $FF (boot garbage safety).
   .res 1                               ; FREE $64-$64
zp_seg_end_x:               .res 1 ; [clip]; DCL: right end of the open
                                  ; segment's VISIBLE run so far.  The emit
                                  ; is DEFERRED to the moment the line is
                                  ; proven to leave the chain of spans, so a
                                  ; contiguous run is never split (see
                                  ; dcl.s "NEVER SPLIT A LINE").
                                  ; WAS $5E for one day (2026-08-22) — which
                                  ; is zp_anim_p's HIGH byte ($5D is "(2)").
                                  ; zpcheck reported it free because it keys
                                  ; on DECLARED addresses and does not know
                                  ; widths; $65 is genuinely free ($64 is
                                  ; zp_bv_entry's hi, $66 is zp_seg_fh).
obj_cx_h:                   .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_seg_fh
obj_fused:                  .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_seg_ch
zp_seg_top_dlt:             .res 1 ; [bsp]; s8 ch - vz (height delta for top edge)
zp_seg_bot_dlt:             .res 1 ; [bsp]; s8 fh - vz (height delta for bottom edge)
zp_save0:                   .res 1 ; [clip]; DCL line-clip scratch (also
LC_OX1_LO:                 .res 1 ; ROTATED IN (zprotate): 27.8 vs fwl_pend's 3.9
zp_save2:                   .res 1 ; [clip]
zp_old_cur:                 .res 1 ; [clip]; tighten cursor scratch (tfr.s)
zp_ox0:                     .res 1 ; [clip]; subspan extent scratch (dcl+tfr)
zp_ox1:                     .res 1 ; [clip]
RASTER_ZP_SCRSTRT:          .res 1 ; [clip]
zp_rc1_l:                   .res 1 ; [bsp]; rotate product P3 (ox*Mc)
zp_rc1_h:                   .res 1 ; [bsp]
zp_rc2_l:                   .res 1 ; [bsp]; rotate product P4 (oy*Ms)
zp_rc2_h:                   .res 1 ; [bsp]
zp_rws_l:                   .res 1 ; [bsp]; rotate 3-byte sum workspace lo
zp_rws_m:                   .res 1 ; [bsp]; rotate 3-byte sum workspace mid
zp_seg_v_idx_l:             .res 1 ; [bsp]; cached: vertex index (u16)
zp_seg_v_idx_b:             .res 1 ; [bsp]; B = idx>>3 (bitmap/VXCACHE byte
   .res 2                               ; FREE $79-$7A
zp_vf_vec0:                 .res 2 ; [bsp]; VXCACHE fetch vector, junior side —
                                  ; vxcache_frame aims it at sxv0_vfoff (off)
                                  ; or sxv0_vxcache_on (on); bca VECTORED idiom.
                                  ; (Briefly deleted for TRUE16 always-on
                                  ; 2026-08-10, restored same day: the off
                                  ; arm is compute-only per the canonical
                                  ; cache contract.) $7B-$7E were the
                                  ; boot-time tube-detect scratch — phase-
                                  ; disjoint.
zp_vf_vec1:                 .res 2 ; [bsp]; senior-side twin ($7D/$7E)
obj_ctr_l:                 .res 1 ; ROTATED IN (zprotate): 17.9 vs zp_br_py2_l's 14.6
   .res 2                               ; FREE $80-$81
RASTER_ZP_X0:               .res 1 ; [clip]
RASTER_ZP_Y0:               .res 1 ; [clip]
RASTER_ZP_X1:               .res 1 ; [clip]
RASTER_ZP_Y1:               .res 1 ; [clip]
bca_boxp:                   .res 2 ; [ang]; ROM box pointer: caller points this at the 8-byte box
   .res 1                               ; FREE $88-$88
zp_cr_vx_l:                 .res 1 ; [bsp]; clipped total vx (s16 counts)
zp_cr_vx_h:                 .res 1 ; [bsp]
zp_cr_vy_l:                 .res 1 ; [bsp]; clipped total vy (s16 counts)
zp_cr_vy_h:                 .res 1 ; [bsp]
bca_pxs:                    .res 1 ; [ang]; px sign-extended (s16) ; w=2
   .res 1                               ; FREE $8E-$8E
obj_e:                      .res 1 ; ROTATED IN (zprotate): 32.2
                                   ; accesses/frame vs fw_pol's 0.6
zp_br_pxraw_l:              .res 1 ; [bsp]; s16 player x relative to map_center (raw)
zp_br_pxraw_h:              .res 1 ; [bsp]
zp_br_pyraw_l:              .res 1 ; [bsp]
zp_br_pyraw_h:              .res 1 ; [bsp]
DCLS_FIRST:                .res 1 ; ROTATED IN (zprotate): 24.7 vs fw_top1's 4.8
zp_plot_i:                  .res 1 ; [clip]; plot_h byte-index scratch
zp_seg_hdr_p:               .res 1 ; [bsp]; persistent seg-header ptr (advances +12/seg)
zp_seg_hdr_p_h:             .res 1 ; [bsp]
LC_DEN_LO:                  .res 1 ; [clip]
LC_DEN_HI:                  .res 1 ; [clip]
zp_pyc_idx:                 .res 1 ; [bsp]; projection-cache probe index (X save)
bca_pys:                    .res 1 ; [ang]; py sign-extended (s16) ; w=2
   .res 1                               ; FREE $9C-$9C
zp_br_px_x:                 .res 1 ; [bsp]; s16 player int x HIGH byte (px_h is lo)
zp_br_py_x:                 .res 1 ; [bsp]; s16 player int y HIGH byte (py_h is lo)
zp_dcl_out:                 .res 1 ; [clip]; per-line outcome accumulator
                                  ; (clipper-feedback abort, 2026-08-14):
                                  ; $80 = saw off-top reject, $40 = saw
                                  ; off-bottom, $01 = real recorded segment
                                  ; emitted, $C0 tagged conservatively by
                                  ; the CB-clip + vertical recorded paths.
                                  ; Tapped in RECORDS-ARMED forks only.
plotq_n:                    .res 1 ; [clip]; plot queue write index (bytes,
                                  ; wraps at 256 = 64 entries full)
plotq_mode:                 .res 1 ; [clip]; $80 = enqueue (driver arms per
                                  ; frame until the flip vsync passes),
                                  ; $00 = draw direct (harness default)
vxcache_ref_x:                  .res 1 ; [bsp] s16 COUNT frame ref = rns(to_view(0,0),3)
   .res 1                               ; FREE $A3-$A3
vxcache_ref_y:                  .res 1 ; [bsp] s16 count ref (y); TRUE16 2026-08-10
                                  ; ($A6-$A7 FREE — the s24 third bytes died)
                                  ; absolute — six warm-path ADCs per vertex
   .res 1                               ; FREE $A5-$A5
LC_QUOT_LO:                 .res 1 ; [clip]
LC_QUOT_HI:                 .res 1 ; [clip]
zp_line_xl_l:               .res 1 ; [bsp+clip]; u8, left X (oriented left-to-right)
zp_line_yl_l:               .res 1 ; [bsp+clip]; u8, Y at xl
zp_line_xr_l:               .res 1 ; [bsp+clip]; u8, right X
zp_line_yr_l:               .res 1 ; [bsp+clip]; u8, Y at xr
zp_line_dx:                 .res 1 ; [clip]; u8, xr - xl (>= 0)
zp_line_dy:                 .res 1 ; [clip]; s8, yr - yl
zp_line_y_l:                .res 1 ; [clip]; u8, min(yl, yr) — running Y bbox
zp_line_y_h:                .res 1 ; [clip]; u8, max(yl, yr) — running Y bbox
zp_seg_start_x:             .res 1 ; [clip]; u8, $FF = NULL (no segment started)
zp_seg_start_y:             .res 1 ; [clip]; u8, Y at seg_start_x
zp_cb_cx1:                  .res 1 ; [clip]; u8, clipped left X
zp_cb_cy1:                  .res 1 ; [clip]; u8, clipped left Y (line Y at cx1)
zp_cb_cx2:                  .res 1 ; [clip]; u8, clipped right X
zp_cb_cy2:                  .res 1 ; [clip]; u8, clipped right Y (line Y at cx2)
obj_px:                     .res 1 ; ROTATED IN 2026-09-04 (zprotate): the object block is
                                    ; the hottest absolute set; out went zp_cb_top1
obj_hcnt:                  .res 1 ; ROTATED IN (zprotate): 20.4 vs fw_top2's 4.8
LC_OY2_HI:                 .res 1 ; ROTATED IN (zprotate): 18.6 vs zp_cb_bot1's 10.4
cp_vx0:                     .res 1 ; [clip]; visible piece staging
obj_ctr_h:                 .res 1 ; ROTATED IN (zprotate): 17.9 vs zp_br_py2_h's 14.4
                                 ;   ($F8/$F9 were the free-list's THIRD
                                 ;   rot: VX2+9/+10 live there — ysb
                                 ;   writes them every mover back pair)
cp_vy0:                     .res 1 ; [clip]
LC_OY2_LO:                 .res 1 ; ROTATED IN (zprotate): 19.0 vs zp_bf_lv1's 8.6
                                  ; (stashed for bf_band's K-plane read;
                                  ; $BC was zp_dcl_rec_buf until the FUSED
                                  ; walker killed the records, 2026-08-25)
zp_ys_bs:                   .res 1 ; [bsp]; per-seg back-pair S bump (0 static /
                                  ; nonzero mover): ys back projections re-stage
                                  ; S+1 + kernel when set
zp_vs_cfh:                  .res 1 ; [bsp]; vsx_expl clamp copy of fh (doubled
                                  ; for H2 mover-jamb entries, 2026-08-25)
cp_vx1:                     .res 1 ; [clip]
zp_head:                    .res 1 ; [clip]
zp_free:                    .res 1 ; [clip]
zp_i_l:                     .res 1 ; [clip+ang]; interval lo (= bca_ilo)
zp_i_h:                     .res 1 ; [clip+ang]; interval hi (= bca_ihi)
                                  ; directly; $BB/$BF freed)
cp_vev:                     .res 1 ; [clip]
fw_ax0:                     .res 1 ; [clip]; apply range
LC_TMP_LO:                  .res 1 ; [clip]
LC_OX1_HI:                     .res 1 ; ROTATED IN (zprotate): 27.8 vs zp_vxcache_on's 3.3
                                  ; from VXCACHE_ENABLE; the vertex-fetch entry
                                  ; branches — vxcache_jsr_site SMC retired
                                  ; 2026-07-18)
zp_bca_p1:                  .res 1 ; [ang]; s16 pair with $C9
zp_bca_p1_h:                .res 1 ; [ang]
zp_tail_vec:                .res 2 ; [ang] 2-byte tail vector: the corner arms
                                  ; end JMP (zp_tail_vec) -> bt_store (armed:
                                  ; store psis + COMPUTED) or bca_tail_postrc
                                  ; (moving: nothing stored). Set per frame by
                                  ; bca_frame; REPLACES the zp_rc_moved flag
                                  ; ($CB is the high byte -- it was carried
                                  ; as a FREE pad until 2026-08-31)
LC_TGT_LO:                  .res 1 ; ROTATED IN (zprotate): 18.6 vs t0's 2.4
   .res 1                               ; $CD = t1 (hand-baked)
fw_ax1:                     .res 1 ; [clip]
obj_t:                      .res 1 ; ROTATED IN 2026-09-04 (zprotate): 35.1
                                   ; accesses/frame vs val_hi's 1.9.  RENAMED
                                   ; IN PLACE -- $CC/$CD/$C8 are hand-baked
                                   ; equates that a shift would collide.
zp_hg_cache:                .res 1 ; [clip]; has_gap coherence cache: last-matching span offset
zp_i_x0:                    .res 1 ; [clip]
zp_i_y0:                    .res 1 ; [clip]
LC_M_R0:                    .res 1 ; [clip]
LC_M_R1:                    .res 1 ; [clip]
zp_i_y1:                    .res 1 ; [clip]
fw_rslot:                   .res 1 ; [clip]; span slot at run open
zp_clr_save_x:              .res 1 ; [clip]; tighten X-save (tfr.s; the name
FW_SIDE:                    .res 1 ; [clip]; 0 top / $80 bot
zp_mul_b:                   .res 1 ; [bsp+clip]
zp_prod_l:                  .res 1 ; [bsp+clip]
zp_prod_h:                  .res 1 ; [bsp+clip]
zp_div_den:                 .res 1 ; [bsp+clip]
FW_MODE:                    .res 1 ; [clip]; s16 dispatch redirect (b7)
zp_tmp0:                    .res 1 ; [bsp+clip]; umul8 scratch (matches span_clip); free outside span_clip
zp_tmp1:                    .res 1 ; [clip]
zp_tmp2:                    .res 1 ; [clip]
zp_vs_cch:                  .res 1 ; [bsp]; vsx_expl clamp copy of ch (doubled
                                  ; for H2 mover-jamb entries, 2026-08-25)
VX1:                        .res 1
   .res 25                              ; FREE $E3-$FB
LC_DY_LO:                   .res 1 ; [clip]
LC_DY_HI:                   .res 1 ; [clip]
LC_OFF_LO:                  .res 1 ; [clip]
LC_OFF_HI:                  .res 1 ; [clip]

; --- deliberate overlays: alias, never a second literal ---
bca_px = zp_br_px_h ; [ang]; zp_br_px_h (player int x, s8)
bca_py = zp_br_py_h ; [ang]; zp_br_py_h
zp_tw = ANIM_VAL ; [debug]; tripwire latch, 0 = not tripped
zp_new_tail = zp_save2 ; [clip]; OVERLAY (pre-existing pair):
zp_line_xl_h = zp_cb_cx1 ; [clip]
zp_line_yl_h = zp_cb_cy1 ; [clip]
zp_line_xr_h = zp_cb_cx2 ; [clip]
zp_line_yr_h = zp_cb_cy2 ; [clip]
zp_div_l = zp_prod_l ; [bsp+clip]
zp_div_h = zp_prod_h ; [bsp+clip]
; ($E1 free — the set's spare)
; s16 clipper working set (LIVE — these shared the old TFS block's home)
; REJECTED bytes (the listing scan + pyref are the arbiters, NOT the
; free notes): $CB = zp_tail_vec+1; $7C = zp_vf_vec0 HI BYTE (the $64
; trap again — the 'separately FREE' note below rotted when the off-arm
; restore brought the vectors back, and pyref caught it); $9F/$A0 left
; for the visibility hooks.
; ============================================================================

; --- ROTATED OUT to absolute by tools/zprotate (2026-08-31) ---------------
; Zero page is 256 bytes, so its right occupants are simply the 256
; most-accessed scalars.  Each name below was measured COLDER (accesses
; per frame, render suite + movement) than the scalar that took its slot;
; the incoming name is recorded on the .res line it replaced.  Evicting to
; absolute is always sound -- absolute addressing reaches the byte from
; anywhere, it just costs a cycle and a byte per access.
;
; THE RESERVATIONS ARE RENAMED IN PLACE, never deleted, so no other zp
; address moves.  Several hand-baked equates elsewhere (t0 = $CC, val_hi =
; $CF, bca_p1 = $C8) sit in the pads between them and would collide the
; moment this block shifted.
;
; PUSH/POP the segment -- leaving it set to WORK sends everything the
; including unit emits next into the wrong segment, which put flat code
; over the BKT planes on the first attempt.
; A POINTER PAIR.  The high byte was carried as a FREE pad, which is
; how three of them ended up on tools/zptrawl's free list; the width
; is declared now so no rotation can take one.
.pushseg
.segment "WORK"
.global zp_br_px, zp_br_py       ; the DRIVER stages these (2026-09-01)
.global pmt_blk                  ; pmove's survivor-replay block: LINKER-
pmt_blk:     .res 13             ; allocated since 2026-09-02 -- it was a
                                 ; baked $0ED0 in the "WORK free run",
                                 ; and the obj_Y ladder growth slid
                                 ; zp_br_px/py UNDER it (pm_frame stomped
                                 ; the pose fractions; the bare_boot /
                                 ; walkdrv / pm_fuzz triple-red).  The
                                 ; free-note trap, again.
fw_pol:      .res 1     ; 0.6 accesses/frame
fwl_leftf:   .res 1     ; 2.3
zp_br_px:    .res 1     ; 0.1 -- the 8.8 FRACTION of the player x; the
                        ;   hot half is zp_br_px_h (= bca_px), still in zp
zp_br_py:    .res 1     ; 0.1
zp_vxcache_on: .res 1   ; 3.3 -- a per-frame gate flag
fwl_pend:    .res 1     ; 3.9
fw_top1:     .res 1     ; 4.8
fw_top2:     .res 1     ; 4.8
zp_vs_hh:    .res 1     ; 8.3
zp_bf_lv1:   .res 1     ; 8.6
zp_cb_bot1:  .res 1     ; 10.4
zp_vs_hl:    .res 1     ; 12.7
zp_vs_i:     .res 1     ; 13.2
; The tie-broken doubled raws.  px2_l stays in zero page -- it is the byte
; the two-byte compare hits FIRST and the only one read on the fast arm.
zp_br_py2_h: .res 1     ; 14.4
zp_br_py2_l: .res 1     ; 14.6
zp_br_px2_h: .res 1     ; 15.5
; t0 was `t0 = $CC`, hand-baked in ang/header_div.s.  Its slot is a
; linker-allocated .res now (LC_TGT_LO), so this is one baked address
; fewer as well as a faster byte.
t0:          .res 1     ; 2.4
.popseg


; --- EVICTED FROM ZERO PAGE 2026-09-04 (zprotate rotation) -------------
; Cold occupants displaced by the object block.  They stay DECLARED here
; so every includer still sees the name -- only the segment changed, so
; the references assemble as absolute (1 cycle, 1 byte dearer each).
.segment "WORK"
obj_ss:                     .res 1 ; ROTATED IN (zprotate): 27.4
                                   ; accesses/frame vs fwl_leftf's 2.3
zp_seg_fh:                  .res 1 ; [bsp]; s8 prescaled front floor height
zp_br_px2_l:                .res 1 ; [bsp]; tie-broken doubled raw x:
zp_cb_top1:                 .res 1 ; [clip]; u8, span top at cx1
zp_br_t4:                   .res 1 ; [bsp]; back-face u24 product hi bytes —
zp_br_t5:                   .res 1 ; [bsp]; |P1|=(t2,t3,t4) |P2|=(t0,t1,t5),
zp_seg_ch:                  .res 1 ; [bsp]; s8 prescaled front ceiling height
val_hi:                     .res 1 ; was $CF (hand-baked in ang/header_div.s);
                                   ; rcache reads it as rc_bytehi

.endif                            ; ZP_OWNER


; --- $01: overlay group (2 phase-disjoint users) ---
; --- $03: overlay group (2 phase-disjoint users) ---
; --- BCA angle-module hot slots (moved from BCA_WS absolutes 2026-07-08;
; equates live in ang/header_div.s + bsp/backface.s, names kept there) ---
; $BB bca_ilo   $BF bca_ihi   $C8-$C9 bca_p1   $CA-$CB zp_tail_vec
; $CC t0        $CD t1        $CE val_lo       $CF val_hi
; $F5 bca_vis   $F6 bca_ccsave                 $F7 DEFQ_TAIL
; $CA FREE (zp_cpm_s2 died with the rcache wrapper scavenge 2026-07-20).
; $CE free (was zp_bca_val_lo, 2026-07-11)
; $C4/$C5: OWNED by ang/rcache.s (position-keyed rotation cache) — was an
; unregistered squatter; registered 2026-07-10. Do not allocate.
; $C6 FREE 2026-08-10: zp_px_s_save died with the ps_rns24 arm (the
; rns_s1..s4 bake — no dispatch arm writes r_s any more)
; (was) zp_px_s_save = $C6        ; [bsp]; br_project_x shrink path: the
                                  ; vertex's TRUE S across the shrunken
                                  ; projection (callers bank rlo AFTER)
; --- $C4/$C5: rc_psilo/rc_psihi (ang/rcache.s) — UNREGISTERED SQUATTER,
; registered 2026-07-08 after zp_rns_vec landed on them and the walk disc
; jammed (cached-bbox frames clobbered the vector). anim.s similarly owns
; $EB-$EE/$F0-$F1. Do not trust "free" without grepping ang/anim/drivers.
; (was zp_bca_zone — zone byte killed 2026-07-19: the inside
;   signal rides the p1/p2 full-span sentinel now)
; $1F FREE (zp_bv_mode retired 2026-07-21: the frame class IS the
;  zp_bv_entry vector — pristine/rcache/dcache all dispatch through it)
; $52/$53 FREE (EV16 took them 2026-08-09; TRUE16 freed them 2026-08-10). (zp_vs_il/ib retired 2026-07-25: call sites probe VDONE
; inline and the fresh path re-reads the key from its home pair)
; $47 free (zp_vs_d retired 2026-07-25: vs_go dispatches on A directly)
;   2026-07-10 — was an unregistered squatter at $F0)
; FREE 2026-07-16 (deferral removed): zp_defq_tail = $2B
; ============================================================
; $E2-$FF: the two PACKED PER-ENDPOINT VERTEX STRUCTS (2026-07-10).
; br_seg_xform_vertex + do_project_y write every vertex output
; here DIRECTLY (no staging); the near-plane reproject overwrites
; the clipped endpoint in place. X = zp_seg_ep = 0 (v1) / 15 (v2)
; indexes VX1+ofs,X. All legacy consumer names below are ALIASES
; into these structs — the emit/near-clip code is unchanged.
;   +0 clip  +1 sx_lo  +2 sx_hi
;   +3 sy_top_lo/hi +5 sy_bot_lo/hi +7 sy_btop_lo/hi +9 sy_bbot_lo/hi
;   +11 rhi +12 rlo   (recip banked for apv_stage / the y-stage)
; COMPACTED 2026-08-09 (Eben): the dead evy/evx head slots (EV16)
; squeezed out — stride 15 -> 13, $FC-$FF freed. $EB-$F0 remain a
; deliberate phase-disjoint overlay with hud.s scratch (HUD draws
; between frames; the structs are per-seg).
; ============================================================
VX_STRIDE = 13
VX2 = VX1+VX_STRIDE
zp_seg_v1_clipped = VX1+0
zp_seg_sx1_l = VX1+1
zp_seg_sx1_h = VX1+2
zp_seg_sy1_top_l = VX1+3
zp_seg_sy1_top_h = VX1+4
zp_seg_sy1_bot_l = VX1+5
zp_seg_sy1_bot_h = VX1+6
zp_seg_sy1_btop_l = VX1+7
zp_seg_sy1_btop_h = VX1+8
zp_seg_sy1_bbot_l = VX1+9
zp_seg_sy1_bbot_h = VX1+10
zp_seg_v1_r_m8 = VX1+11
zp_seg_v1_r_s = VX1+12
zp_seg_v2_clipped = VX2+0
zp_seg_sx2_l = VX2+1
zp_seg_sx2_h = VX2+2
zp_seg_sy2_top_l = VX2+3
zp_seg_sy2_top_h = VX2+4
zp_seg_sy2_bot_l = VX2+5
zp_seg_sy2_bot_h = VX2+6
zp_seg_sy2_btop_l = VX2+7
zp_seg_sy2_btop_h = VX2+8
zp_seg_sy2_bbot_l = VX2+9
zp_seg_sy2_bbot_h = VX2+10
zp_seg_v2_r_m8 = VX2+11
zp_seg_v2_r_s = VX2+12
; $FC-$FF FREE (2026-08-09 struct compaction)

; --- Tighten record buffers (4-byte records, count at byte 0) ---
; CROSS-UNIT: written by clip/dcl.s via the zp_dcl_rec_buf pointer,
; ARMED (hi byte + count reset) by bsp/seg_emit.s, read by clip/tfr.s.
; Registry home since 2026-08-09: the arm sites used to hardcode the
; page numbers (clip-local equate) — the trap that bit the VXCACHE move.
; Records arenas moved UP 2026-08-14 (Eben: 'move the records up, keep
; the span state down for has_gap'): banked = the bank C free block left
; by the VXCACHE-planes-to-main move (all touchers run under the emit
; cascade's PAGE BANK_C — the ONE seg-context count reset moved below
; the page); flat = the empty flat side of the driver-reservation zone.
; $0200-$03FF freed in the SHARED map (both builds) — the movement-code
; space fund. Page-aligned: the records machinery rides zero lo bytes.
; (TOP/BOT_RECORDS retired 2026-08-25 — the FUSED walker owns the two
;  pages now: FW_BASE in clip/fusedw.s = the ex-BOT_RECORDS page.)
                                        ; SSMASK ($0B00 sat INSIDE the
                                        ; 221-byte $0A80 mask — the near
                                        ; miss anim6502 didn't catch) and
                                        ; of the $0700-$19FF cache region
; VX1 (0 = v1, 15 = VX_STRIDE = v2): the generators write evy/evx/sx/sy/
; recip DIRECTLY into the endpoint structs via ,X = this offset. Set by
; the seg loop before each transform / projection / reprojection.
; $27 -> zp_tw (TRIPWIRE, debug). Verified free by poisoning it and
; running the full render + anim_tick + pm_frame: zero writes, unlike
; $4C/$7C/$CA/$C6/$1F which all carry stale FREE notes and ARE written.
; $29 FREE (2026-07-09): zp_seg_bfh retired — back floor read on demand
; from header+12 via (zp_seg_hdr_p),Y (stride-16 heights; solids never
; touch it).
; (was zp_par_zone — zone inheritance removed 2026-07-18)
; (was zp_v_x_l)
; the |dx'|/|dy'| magnitudes load lazily in the mul tier via this stash
; (dead-write tracker 2026-07-11: sign-shortcut exits never read them).
; (was zp_cpm_frame; briefly free 2026-07-17 when the epoch died — the
;  slot stash saves the store-side hash recompute, X dies in the miss
;  pipeline)
; post-has_gap y stage (its VX2 sy pairs are live for the chain);
; cleared per seg at the chain decision, set at y-stage end
; already carries a valid front sy pair (copied from an emitted prev
; seg) — the y stage skips v1's front projection
; constant-base abs,X; layout constants live in layout.inc)
; (sd_num/sd_den alias names DELETED 2026-07-19 — the converters use
;  pa_dx/pa_dy directly; the fossil slope_div naming was confusing.)
; $4C FREE (was zp_ap2_dlt — died with the apv_stage macro text, 2026-08-12)
; between its two projections (one L0 page-in reads both header bytes)
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pym_l = $4D
; back-face diagonal C-form reads both per call)
; $4F-$51 = zp_vs_i / zp_vs_hl / zp_vs_hh — the vertex-span descriptor
; walk's variables (98fc1b3, defined locally in subsector.s): the 2026-
; 07-15 'FREE' comments here were STALE and cost a corrupted-vector
; hang on 2026-07-27. $52-$53 freed again 2026-08-10 (TRUE16).
; FREE 2026-07-15 (cross-core unification): zp_node_dy_h = $53
; $59 free (was zp_node_ch_h — ids are u8 end to end, 2026-07-15)
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pym_h = $5B
; $5A FREE (was zp_sx_ord — the reversal latch died when the drop
;     moved into the stage-3 range gate, 2026-08-12)
; --- $5D: overlay group (2 phase-disjoint users) ---
;   unregistered $EB/$EC squatter). Anim hub runs BETWEEN seg emits —
;   no live seg scratch here since zp_seg_v1 retired.
; --- $5F: overlay group (2 phase-disjoint users) ---
; --- $61: overlay group (2 phase-disjoint users) ---
; --- $63: overlay group (2 phase-disjoint users) ---
; --- $65: overlay group (2 phase-disjoint users) ---
; --- $66: overlay group (2 phase-disjoint users) ---
; --- $69: overlay group (2 phase-disjoint users) ---
bca_ab = BCA_AB                   ; [ang+bsp]; = $62 (zp_buf's slot, freed
                                  ; with span_read 2026-07-26): per-frame
                                  ; view angle byte (was BCA_WS+$2F). ONE
                                  ; truth: the value lives in the generated
                                  ; abi.inc (included above) — drivers
                                  ; poke the same constant. vxcache_ab aliases.
                                  ; NOT $64: despite the old 'bca_vis $64
                                  ; free' note, $64 is zp_bv_entry's HI
                                  ; byte ($63/$64 pair, w=2) — the drivers
                                  ; seed it and bca_frame rewrites it per
                                  ; frame (the 2026-07-26 black-screen
                                  ; lesson: trust widths, not free-notes).
.assert BCA_AB < $100, error, "bca_ab must stay ZP (drivers STA it zp; engine reads assume 3-cycle)"
; $65: bca_ccsave lives here via a LOCAL equate in
; ang/header_div.s (keep in sync) — sole owner
; (from the old $F5/$F6 squat inside the structs).
; $6A-$6F: OWNED BY THE CLIP UNIT — zp_save0/1/2, zp_old_cur,
; zp_ox0/zp_ox1 live here via clip-local equates (REGISTERED
; 2026-07-26: the old 'retired/unallocated' note here described the
; BSP unit's dead sy/sx staging, not the addresses — the vclip-memo
; experiment allocated on top of them and read the span walk's ox0 as
; its arm flag. Grep the MERGED dbg, not this registry, before
; claiming ZP.)
; $73 free (was pa_sx — lf_ns reads L8_TAB,Y direct, 2026-07-19)
; index, stored pre-derived in the header; idx = B*8 + (lo&7))
; $79 free — INSIDE THE RASTERIZER'S SCRATCH RANGE (measured 2026-07-25:
; RASTER_ENTRY writes it mid-frame; nothing may live here across draws)
; $7A free for bsp use (was zp_seg_v_cache_l; NB the NJ rasteriser
; scratches $7A as errs — phase-disjoint). $7B free (was _cache_h) —
; the vrcache is page-split SoA with baked senior arms, no pointer.
; FREE 2026-07-15 (cross-core unification): zp_seg_dxraw_l = $7C
; ($7D NOT free despite the old dxraw_h note: zp_vf_vec1 = $7D-$7E.)
; ($7E/$7F: zp_vf_vec1 hi byte — see the $7B block)
; (were the dyraw pair, free since the cross-core unification).
; $89-$8C TAKEN 2026-08-09: zp_cr_* EV16 crossing scratch (see the
; block above the div slots) — were pa_sy / pa_oct / bca_hi frees.
; $94 free (was zp_v_x_x)
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pxm_l = $98
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pxm_h = $99
; back-face C-form magnitudes (signs read live from px_e/py_e bit7)
; --- $A8: overlay group (3 phase-disjoint users) ---
; ($A8 shared: zp_line_xl_l below — the old zp_ms_emit flag was GC'd
; 2026-07-12: no 6502 reader existed)
; --- $A9: overlay group (2 phase-disjoint users) ---
; --- $AA: overlay group (2 phase-disjoint users) ---
; --- $AB: overlay group (2 phase-disjoint users) ---
; --- $B2: overlay group (3 phase-disjoint users) ---
; --- $B3: overlay group (3 phase-disjoint users) ---
; --- $B4: overlay group (3 phase-disjoint users) ---
; --- $B5: overlay group (3 phase-disjoint users) ---
; --- $B6: overlay group (4 phase-disjoint users) ---
; --- $B7: overlay group (3 phase-disjoint users) ---
; --- $B8: overlay group (3 phase-disjoint users) ---
; --- $B9: overlay group (3 phase-disjoint users) ---
; --- $BA: FREE (zp_tg_cont retired 2026-08-23 -- the portal-continuation
;     state had no reader anywhere in the tree; storescan found the store)
; SPAN_IS_NOT_FULL (2026-07-26, replaces IS_FULL_B and the retired
; span_is_full routine): the clipper's whole occlusion truth is
; zp_head == 0 (active span list empty) and ZP is unbanked — no JSR,
; no bank-C page, no materialized 0/1. The macro JUST TESTS zp_head:
; A = zp_head, Z = screen fully solid. Callers branch themselves
; (BEQ done / BNE continue).
.macro SPAN_IS_NOT_FULL
   LDA zp_head
.endmacro
; --- THE INTERVAL ABI ($C2/$C3) -------------------------------------
; zp_i_l/zp_i_h is the CANONICAL closed column interval [lo, hi] —
; the argument pair of span_mark_solid and tighten_from_records, and
; the OUTPUT slots of the bbox check (bca_ilo/bca_ihi alias here,
; 2026-07-18). span_has_gap A-hi ABI (2026-07-26, Eben's call —
; supersedes the 2026-07-20 ZP-only audit and the same-day A-lo cut):
; has_gap takes HI IN A and LO in zp_i_l; zp_i_h is NEITHER READ NOR
; WRITTEN by has_gap (Eben's pure-register rewrite: A carries ihi
; through probe, walk and hit checks — the lo compares ride the idle
; cursor register via CPY/CPX zp_i_l). Post-call consumers of $C3 own
; their writes: mark_solid/tfr read the seg emit-path clamp (ms_hist),
; and the dst*_ext record store reads bca_ihi landed by the bca
; classify tail (ct_ih / ct_f_r2out / full_vis). The dcv serve arms
; leave bca_ihi stale BY DESIGN — serves feed no record store and
; pass ihi to has_gap in A. Writers of zp_i_l stay as before: bca
; tail cells, D-serve arms, seg emit path, mark_solid callers.
; RETURN ABI (C-only, 2026-07-26 — the A=0/1 materialization is
; retired): C = has_gap's verdict (C=1 gap / C=0 none); A returns the
; caller's ihi untouched; Z/N undefined. The bca classify exits add
; V = record kind for the dcap store (V=0 extent / V=1 angle cull:
; CLV at visok/full_vis, CLC + BIT-an-RTS-opcode at cull — $60 has
; bit6 set and can never change). Three states, two flags:
;   gap C=1/V=0, no-gap C=0/V=0, cull C=0/V=1.
; The walk and the seg gate branch BCS/BCC and never read V; V is
; DEFINED ONLY at uncached-classify (bcls_*) exits — serve arms
; return C alone (full scope note at bca.s's C/V-CONTRACT block).
; has_gap itself must never gain an instruction that writes V (the
; CLV has to survive the fused call) — asserted in its header.
; --- $D3: overlay group (2 phase-disjoint users) ---
; --- $D4: overlay group (2 phase-disjoint users) ---
; --- $D6: overlay group (2 phase-disjoint users) ---

; --- $D7: overlay group (3 phase-disjoint users) ---
; --- $D8: overlay group (3 phase-disjoint users) ---
; --- $DA: overlay group (2 phase-disjoint users) ---
; --- $DB: overlay group (2 phase-disjoint users) ---
; --- $DD: overlay group (2 phase-disjoint users) ---
; --- $E1: vsx_expl clamp copy (both prior users died) ---

; EV16 crossing scratch (2026-08-09): the CLIPPED endpoint's recovered
; s24 view totals, banked across the second cr_recover call (which
; lands the unclipped endpoint in the zp_br_vx/vy working slots).
; Live only inside reproject_at_crossing; free everywhere else.
; ORDER MIRRORS the zp_br working slots ($11-$14 pair block + $2E/$2F
; ext pair) so cr_recover_clipped's stash is an indexed loop.
; NOT $E3+: that range sits INSIDE the VX1/VX2 endpoint structs
; ($E2-$FF, stride 15) — zpcheck's free list does not expand w= struct
; widths (the $64 trap, again). NOT $7E: zp_vf_vec1 spans $7D-$7E
; (the dxraw_h 'free' note was stale — vector hi byte, VXCACHE dispatch
; corrupts). Homes: the ang module's registered free singles $89-$8C
; + the twice-audited $52/$53 pair.
; ($52/$53 FREE again 2026-08-10: the zp_cr ext bytes died with TRUE16
;  — totals are s16 counts)
;   carries bca_vis's old duty? NO — bca_vis/ccsave own $64/$65 solo)
;   mark_solid vs tighten phases
;   is historic — NOT the frame clear; concurrently live with zp_old_cur)
; --- $EB: overlay group (3 phase-disjoint users) ---
; --- $EC: overlay group (3 phase-disjoint users) ---
; --- $ED: overlay group (3 phase-disjoint users) ---
; --- $EE: overlay group (3 phase-disjoint users) ---
; --- $EF: overlay group (3 phase-disjoint users) ---
; --- $F0: overlay group (2 phase-disjoint users) ---
; --- $F1: overlay group (3 phase-disjoint users) ---
; --- $F2: overlay group (2 phase-disjoint users) ---
; --- $F3: overlay group (2 phase-disjoint users) ---
; --- $F4: overlay group (2 phase-disjoint users) ---
; --- $F5: overlay group (2 phase-disjoint users) ---
; --- $F7: overlay group (2 phase-disjoint users) ---
; --- $F8: overlay group (2 phase-disjoint users) ---

; EPSILON_F — the certified worst-case atanexp error (fine units).
; ONE SOURCE: tools/atanexp_cert.py prints it and writes it into
; tools/atanexp_tables.json (the mirror reads it from there);
; engine_load.py pins the drift guard. 15 -> 12 on 2026-07-19 (half-
; bit recovery in the >>3 L reductions). The afn hoist (view.s)
; carries +EPSILON_F, so corner_phi emits r = phi+512+EPS and the
; bca_tail biases are: span +2*EPSILON_F, left window -2*EPSILON_F
; against the pre-biased p1'. Lives here because BOTH assembly units
; consume it.
EPSILON_F = 12

; ============================================================================
; SEGMENT MAP (2026-07-20, the great consolidation): THREE segments.
;   SEG_CODE  — the one code blob. Flat: $2000-$54FF (CPM at $5500).
;               Banked: $2C00-$57FF.
;   SEG_HIGH  — flat-only high island $E740-$F0FF (RCACHE_STATE pins
;               $F100); banked: folds into CODE.
;   SEG_HIGHX — flat-only high island $F200-$F5FF (VATOX pins $F600);
;               banked: folds into CODE.
;   SEG_BANKC — span_clip: bank C window banked ($8000), CODE flat.
; Content order within a segment = object order (slope_div, span_clip,
; bsp_render) then include order — ONE file to read for layout. The
; old 25-name zoo (MAIN/LO/B/D/W/ZC/RNSPG/RPAIR/ZZTAIL/SEL/LOX/ANG/
; ANGX/ANIM*/RCCODE/VXCACHE_CODE/.._BK twins) died here; so did its landmine
; class (ZZTAIL fall-through, cfg-order region shifts).
Y_BIAS = 48                             ; bias Y so visible [0,159] maps to [48,207] within u8
VIS_YMAX = Y_BIAS + 159                 ; = 207: maximum biased visible Y
; --- span-pool layout (moved from clip/arith.s 2026-08-29: BOTH units
;     need it — the clipper owns the pool, bsp/objects.s probes it) ---
POOL = SPAN_POOL                        ; abi.inc ($1800 since the 2026-08-19
                                        ; window slide; $1C00 before, $0400
                                        ; before the sqr swap); ships as
                                        ; LOW-image zeros, span_init owns
                                        ; the per-frame ground state
; field equates DERIVE from POOL (they were hard $04xx literals until
; 2026-08-18 — the pool kept writing its old home after POOL moved and the
; sqr HI pages took the corruption; only the pixel-exact pyref saw it)
POOL_NEXT   = POOL + $000
POOL_TXLO   = POOL + $020               ; TOP line's anchor x  (pairs with
POOL_TDEN   = POOL + $040               ;  POOL_BXLO/BDEN below); DEN is the
                                        ;  precomputed xhi - xlo, i.e. the
                                        ;  interp denominator
POOL_TL     = POOL + $060
POOL_BL     = POOL + $080
POOL_TR     = POOL + $0A0
POOL_BR     = POOL + $0C0
POOL_XSTART = POOL + $0E0
POOL_XEND   = POOL + $100
POOL_OT     = POOL + $120
POOL_OB     = POOL + $140
POOL_IT     = POOL + $160
POOL_IB     = POOL + $180
; SEPARATE TOP/BOTTOM ANCHORS (2026-08-22). TXLO/TDEN anchor the TOP line
; only; the BOTTOM line carries its own BXLO/BDEN pair below. (They were
; the unprefixed XLO/DEN until 2026-08-22, from the days when there was
; only one anchor pair — renamed so the two sides read symmetrically.) Each boundary is
; stored at its SOURCE line's own extent, so the sweep no longer has to
; interpolate both sources onto a common anchor when it emits a span —
; see the note in clip/tfr.s flush_pending. (VXCACHE_ENABLE/vxcache_prev_ab
; moved $19DB/DC -> $19DD/DE to clear the room.)
POOL_BXLO   = POOL + $1A0
POOL_BDEN   = POOL + $1C0

; ============================================================================
; SEG_WORK — THE data segment: writable scratch/workspace/scalars.
; It exists so storage stops being written as literals.  A baked address
; is a COPY OF A FACT: when the real thing moves the copy does not, and
; nothing tells you -- obj_fused's first home sat INSIDE obj_sasp's array
; and every armed stamp wrote asp=$01 over whichever object held slot 1.
; Declare it here with .res and reference the LABEL; ld65 places it.
; (Eben 2026-08-30: forbidden to ever create a baked address.)
; SEGMENT COLLAPSE (2026-08-30): PMB1/PMB2/PMB4 were separate segment
; NAMES that both cfgs loaded into the SAME region (CODE).  They bought
; nothing and cost a name each to keep straight, so they are gone.  The
; rest cannot follow until the flat build has room -- see the note on
; SEG_OBJX.  Goal is ONE code segment (Eben 2026-08-30).
.macro SEG_WORK
.segment "WORK"
.endmacro
.macro SEG_CODE
.segment "CODE"
.endmacro
.macro SEG_HIGH
.segment "CODE"                   ; (islands merged 2026-07-21: ONE code
.endmacro                         ;  region both builds — the map reshuffle
.macro SEG_HIGHX                  ;  moved CPM/FB out of CODE's way)
.segment "CODE"
.endmacro
.macro SEG_PMOVE
.segment "PMOVE"                  ; player movement (pmove.s): banked =
.endmacro                         ;  the driver-zone slice $2600, flat =
                                  ;  the tube-map pocket $7E40
; pm_frame (35Hz momentum) lives in BANK B free windows banked (Eben
; blessed movement code into bank WALK 2026-08-15 — it already runs
; entirely under that bank's paging); flat = one $2300-$28FF region.
; Fragmented by necessity: the windows are what the bank B census left.
.macro SEG_PMB1
.segment "CODE"                   ; (was "PMB1" -- a separate NAME for the
.endmacro
.macro SEG_PMB2
.segment "CODE"                   ; (was "PMB2" -- a separate NAME for the
.endmacro
.macro SEG_PMB3
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_PMB4
.segment "CODE"                   ; (was "PMB4" -- a separate NAME for the
.endmacro                         ;  shadow (dirs<=118 asserted)
.macro SEG_PMH
.segment "PMH"                    ; pm single-step: banked = the
.endmacro                        ;  PMOVE area, flat = PMBF
.macro SEG_PMEXT
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro                         ;  (banked: CODE tail; flat: $DF80)
.macro SEG_PMZ
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro                         ;  render-untouched, audited 2026-08-29)
.macro SEG_PMMU
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_PMWO
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_PQ
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_OBJB
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_OBJG
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_OBJX
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro                         ;  walled tail and RCACHE_STATE
.macro SEG_PMSF
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro
.macro SEG_PMCND
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro                         ;  the loader POKES dbound there and the
                                  ;  ang-module region reload would serve
                                  ;  code bytes as bounds; 2026-08-29)
.macro SEG_PMCOL
.segment "CODE"                   ; collapsed 2026-08-30
.endmacro                         ;  (PMOVE slack went to pm_walkover)
.macro SEG_BANKC
.segment "BANKC"                  ; banked: the $8000 bank C window; flat:
                                  ; the CBITS region $D600+ (parasite map —
                                  ; one segment name, the cfg re-homes it)
.endmacro
.macro SEG_BANKCHOST
.segment "BANKCHOST"              ; HOST-ONLY bank-C machinery (banked
.endmacro                         ; rasteriser bodies + framebuffer clears):
                                  ; packs AFTER segment BANKC in the same
                                  ; region, so the parasite's shipped
                                  ; clipper is a pure PREFIX of banked's
                                  ; (single +$5600 relocation -- the
                                  ; 2026-09-02 flat-first-class purge).
                                  ; The flat build emits ZERO bytes here.


; --- TRIPWIRE call macro (see layout.inc / tw_check in bsp/header.s) ---
; TW id  -- id must be NON-ZERO. Fully transparent: A, X, Y and the flags
; all survive, so a site can be dropped anywhere, including between a
; compare and its branch.
.macro TW id
.if TRIPWIRE
   PHP
   PHA
   LDA #id
   JSR tw_check
   PLA
   PLP
.endif
.endmacro
