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
; ============================================================================

zp_br_px = $00                    ; [bsp]; s16 player x_88 (8.8 fixed, prescaled)
; --- $01: overlay group (2 phase-disjoint users) ---
zp_br_px_h = $01                  ; [bsp]
bca_px = $01                      ; [ang]; zp_br_px_h (player int x, s8)
zp_br_py = $02                    ; [bsp]
; --- $03: overlay group (2 phase-disjoint users) ---
zp_br_py_h = $03                  ; [bsp]
bca_py = $03                      ; [ang]; zp_br_py_h
zp_br_vz = $04                    ; [bsp]; s8 eye-height (prescaled)
zp_br_px_e = $9D                  ; [bsp]; s16 player int x HIGH byte (px_h is lo)
zp_br_py_e = $9E                  ; [bsp]; s16 player int y HIGH byte (py_h is lo)
zp_br_smag = $05                  ; [bsp]; u8 sin magnitude
zp_br_sneg = $06                  ; [bsp]; 1 if sin negative
zp_br_sone = $07                  ; [bsp]; 1 if |sin| == 1
zp_br_cmag = $08                  ; [bsp]
zp_br_cneg = $09                  ; [bsp]
zp_br_cone = $0A                  ; [bsp]
zp_br_fvxlo = $0B                 ; [bsp]; s16 frac_vx (0.8 contribution)
zp_br_fvxhi = $0C                 ; [bsp]
zp_br_fvylo = $0D                 ; [bsp]
zp_br_fvyhi = $0E                 ; [bsp]
zp_br_dxlo = $0F                  ; [bsp]
zp_br_dylo = $10                  ; [bsp]
zp_br_vxlo = $11                  ; [bsp]
zp_br_vxhi = $12                  ; [bsp]
zp_br_vylo = $13                  ; [bsp]
zp_br_vyhi = $14                  ; [bsp]
zp_br_a = $15                     ; [bsp]; multiplicand A (s8 input)
zp_br_b = $16                     ; [bsp]; multiplicand B
zp_br_resl = $17                  ; [bsp]; s24 result lo
zp_br_resh = $18                  ; [bsp]; s24 result mid (the s16 path stops here)
zp_br_sign = $19                  ; [bsp]; 0 = positive, non-0 = negative
zp_br_rhi = $1A                   ; [bsp]; u8 hi of reciprocal
zp_br_rlo = $1B                   ; [bsp]; u8 lo
; --- BCA angle-module hot slots (moved from BCA_WS absolutes 2026-07-08;
; equates live in ang/header_div.s + bsp/backface.s, names kept there) ---
; $BB bca_ilo   $BF bca_ihi   $C8-$C9 bca_p1   $CA-$CB bca_p2
; $CC t0        $CD t1        $CE val_lo       $CF val_hi
; $F5 bca_vis   $F6 bca_ccsave                 $F7 DEFQ_TAIL
zp_bca_ilo = $BB                  ; [ang]
zp_bca_ihi = $BF                  ; [ang]
zp_bca_p1 = $C8                   ; [ang]; s16 pair with $C9
zp_bca_p1_hi = $C9                ; [ang]
zp_bca_p2 = $CA                   ; [ang]; s16 pair with $CB
zp_bca_p2_hi = $CB                ; [ang]
zp_bca_t0 = $CC                   ; [ang]
zp_bca_t1 = $CD                   ; [ang]
zp_bca_val_lo = $CE               ; [ang]
zp_bca_val_hi = $CF               ; [ang]
; $C4/$C5: OWNED by ang/rcache.s (position-keyed rotation cache) — was an
; unregistered squatter; registered 2026-07-10. Do not allocate.
zp_rcache_c4 = $C4                ; [bsp]; rcache internal (see ang/rcache.s)
zp_rcache_c5 = $C5                ; [bsp]; rcache internal
zp_rns_vec = $C6                  ; [bsp]; RNS shifter vector lo (per-vertex,
zp_rns_vec_hi = $C7               ; [bsp]; set by rns_select from S; JMP (ind))
; --- $C4/$C5: rc_psilo/rc_psihi (ang/rcache.s) — UNREGISTERED SQUATTER,
; registered 2026-07-08 after zp_rns_vec landed on them and the walk disc
; jammed (cached-bbox frames clobbered the vector). anim.s similarly owns
; $EB-$EE/$F0-$F1. Do not trust "free" without grepping ang/anim/drivers.
zp_br_p = $1C                     ; [bsp]
zp_br_p_h = $1D                   ; [bsp]
bca_lo = $1E                      ; [ang]; lo_phi (s16) ; w=2
zp_br_t0 = $20                    ; [bsp]
zp_br_t1 = $21                    ; [bsp]
zp_br_t2 = $22                    ; [bsp]
zp_br_t3 = $23                    ; [bsp]
zp_br_t4 = $24                    ; [bsp]; back-face u24 product hi bytes —
zp_br_t5 = $25                    ; [bsp]; |P1|=(t2,t3,t4) |P2|=(t0,t1,t5),
ANIM_VAL = $27                    ; [bsp]; anim: patch value (registered
;   2026-07-10 — was an unregistered squatter at $F0)
ANIM_CUR = $29                    ; [bsp]; anim: mover index (was $F1)
zp_defq_tail = $2B                ; [bsp]; deferred-op queue tail (was $F7)
; ============================================================
; $E2-$FF: the two PACKED PER-ENDPOINT VERTEX STRUCTS (2026-07-10).
; br_seg_xform_vertex + do_project_y write every vertex output
; here DIRECTLY (no staging); the near-plane reproject overwrites
; the clipped endpoint in place. X = zp_seg_ep = 0 (v1) / 15 (v2)
; indexes VX1+ofs,X. All legacy consumer names below are ALIASES
; into these structs — the emit/near-clip code is unchanged.
;   +0 evy  +1 evx  +2 clip  +3 sx_lo  +4 sx_hi
;   +5 sy_top_lo/hi +7 sy_bot_lo/hi +9 sy_btop_lo/hi +11 sy_bbot_lo/hi
;   +13 rhi +14 rlo   (recip banked for ap2_solid_proj)
; ============================================================
VX1 = $E2
VX2 = $F1
VX_STRIDE = 15
zp_seg_v1_evy = VX1+0
zp_seg_v1_evx = VX1+1
zp_seg_v1_clipped = VX1+2
zp_seg_sx1_lo = VX1+3
zp_seg_sx1_hi = VX1+4
zp_seg_sy1_top_lo = VX1+5
zp_seg_sy1_top_hi = VX1+6
zp_seg_sy1_bot_lo = VX1+7
zp_seg_sy1_bot_hi = VX1+8
zp_seg_sy1_btop_lo = VX1+9
zp_seg_sy1_btop_hi = VX1+10
zp_seg_sy1_bbot_lo = VX1+11
zp_seg_sy1_bbot_hi = VX1+12
zp_seg_v1_rhi = VX1+13
zp_seg_v1_rlo = VX1+14
zp_seg_v2_evy = VX2+0
zp_seg_v2_evx = VX2+1
zp_seg_v2_clipped = VX2+2
zp_seg_sx2_lo = VX2+3
zp_seg_sx2_hi = VX2+4
zp_seg_sy2_top_lo = VX2+5
zp_seg_sy2_top_hi = VX2+6
zp_seg_sy2_bot_lo = VX2+7
zp_seg_sy2_bot_hi = VX2+8
zp_seg_sy2_btop_lo = VX2+9
zp_seg_sy2_btop_hi = VX2+10
zp_seg_sy2_bbot_lo = VX2+11
zp_seg_sy2_bbot_hi = VX2+12
zp_seg_v2_rhi = VX2+13
zp_seg_v2_rlo = VX2+14
zp_seg_ep = $26                   ; [bsp]; per-endpoint SEG_PROJ_BUF offset
; (0 = v1, 4 = v2): the generators write sx/sy DIRECTLY into the endpoint
; dedicated so the two magnitude products get 6 clean bytes and never reuse
; the live dx/dy delta slots (2026-07-09). $26-$27 still FREE (were the
; lv1x/lv1y stage). $27 still FREE.
zp_ri_dlo = $28                   ; [bsp]
; $29 FREE (2026-07-09): zp_seg_bfh retired — back floor read on demand
; from FHCH+2 via (zp_fhch_p),Y (rule 2b; solid walls never touch it).
zp_ri_neg = $2A                   ; [bsp]
; $2B FREE (2026-07-09): zp_seg_bch retired — back ceil read on demand
; from FHCH+3 via (zp_fhch_p),Y.
zp_ri_dhi = $2C                   ; [bsp]; (was unused; s16 hi byte of d)
zp_br_resext = $2D                ; [bsp]; s24 result high byte (rot_int + to_view extension)
zp_br_vxext = $2E                 ; [bsp]; total view-space x sign-extension byte
zp_br_vyext = $2F                 ; [bsp]; total view-space y sign-extension byte
pa_dx = $30                       ; [ang]; s16 in ; w=2
pa_dy = $32                       ; [ang]; s16 in ; w=2
zp_bbox_side = $34                ; [bsp]
zp_br_dxhi = $35                  ; [bsp]
zp_br_dyhi = $36                  ; [bsp]
zp_v_xint = $37                   ; [bsp]; saved integer view-x (s8)
zp_v_xfrac = $38                  ; [bsp]; saved fractional view-x (u8)
pa_res = $39                      ; [ang]; u16 out (fineangle) ; w=2
bca_afn = $3B                     ; [ang]; a_fine (s16) -- ZP (freed from pa_adx); hot in corner_phi ; w=2
zp_seg_ldx = $3D                  ; [bsp]; s8 linedef delta x — the back-face
zp_seg_ldy = $3E                  ; [bsp]; s8 ldy. NOT caller-staged: the test
; loads each from the header (+8/+9) on first use and STASHES here from A
; only when the taken path reuses it downstream (2026-07-09).
zp_seg_flags = $3F                ; [bsp]; u8
pa_ptr = $40                      ; [ang]; 16-bit table pointer ; w=2
; ($42/$43 freed 2026-07-10: zp_rom_nodes retired — node SoA reads are
; constant-base abs,X; layout constants live in layout.inc)
sd_num = $44                      ; [ang] ; w=2
sd_den = $46                      ; [ang] ; w=2
sd_q = $48                        ; [ang] ; w=2
sd_r = $4A                        ; [ang] ; w=2
; ($4C/$4D freed 2026-07-10: zp_root_node retired — LAY_ROOT constant)
zp_bsp_stack_sp = $4E             ; [bsp]; stack pointer (offset into BSP_STACK)
zp_side = $4F                     ; [bsp]; 0 = front, 1 = back
zp_node_dxlo = $50                ; [bsp]
zp_node_dxhi = $51                ; [bsp]
zp_node_dylo = $52                ; [bsp]
zp_node_dyhi = $53                ; [bsp]
zp_node_nxlo = $54                ; [bsp]
zp_node_nxhi = $55                ; [bsp]
zp_node_nylo = $56                ; [bsp]
zp_node_nyhi = $57                ; [bsp]
zp_node_chlo = $58                ; [bsp]; current child (lo, hi: 16-bit id)
zp_node_chhi = $59                ; [bsp]
zp_sx_ord = $5A                   ; [bsp]; min-endpoint struct offset (0 =
; sx1 is min, VX_STRIDE = sx2): latched by the has_gap prelude, reread by
; the ms/tighten range so the s16 order compare runs once per seg.
; ($5B freed 2026-07-10: zp_seg_first retired — the subsector prologue
; computes both ROM cursors straight from the SS SoA pages via X)
zp_seg_count = $5C                ; [bsp]; remaining segs in subsector
; --- $5D: overlay group (2 phase-disjoint users) ---
zp_anim_p = $5D                   ; [bsp]; anim table cursor (2; was the
;   unregistered $EB/$EC squatter). Anim hub runs BETWEEN seg emits —
;   no live seg scratch here since zp_seg_v1 retired.
zp_anim_w = $5F                   ; [bsp]; anim write pointer (2; was $ED/$EE)
; --- $5F: overlay group (2 phase-disjoint users) ---
; --- $61: overlay group (2 phase-disjoint users) ---
; --- $63: overlay group (2 phase-disjoint users) ---
; --- $65: overlay group (2 phase-disjoint users) ---
; --- $66: overlay group (2 phase-disjoint users) ---
zp_seg_fh = $66                   ; [bsp]; s8 prescaled front floor height
zp_seg_ch = $67                   ; [bsp]; s8 prescaled front ceiling height
zp_seg_top_dlt = $68              ; [bsp]; s8 ch - vz (height delta for top edge)
; --- $69: overlay group (2 phase-disjoint users) ---
zp_seg_bot_dlt = $69              ; [bsp]; s8 fh - vz (height delta for bottom edge)
zp_prev = $61                     ; [clip]; pool-walk prev (from $E2 — structs)
zp_buf = $62                      ; [clip]; u16 pointer $62/$63 (from $E3/$E4)
; $64/$65: bca_vis / bca_ccsave live here via LOCAL equates in
; ang/header_div.s (keep in sync) — persistent across checks, so they
; get sole ownership (from the old $F5/$F6 squat inside the structs).
; ($6A-$6F retired 2026-07-10 — sy/sx staging dead; BISECT: temporarily
; unallocated while hunting the divergence)
RASTER_ZP_SCRSTRT = $70           ; [clip]
pa_sx = $73                       ; [ang]
zp_seg_v_idx_lo = $77             ; [bsp]; cached: vertex index (u16)
zp_seg_v_idx_hi = $78             ; [bsp]
zp_seg_v_bitm = $79               ; [bsp]; valid-bitmap mask (1 << (idx & 7))
zp_seg_v_cache_lo = $7A           ; [bsp]; cached: pointer to this vertex's cache entry
zp_seg_v_cache_hi = $7B           ; [bsp]
zp_seg_dxraw_lo = $7C             ; [bsp]
zp_seg_dxraw_hi = $7D             ; [bsp]
zp_seg_dyraw_lo = $7E             ; [bsp]
zp_seg_dyraw_hi = $7F             ; [bsp]
RASTER_ZP_X0 = $82                ; [clip]
RASTER_ZP_Y0 = $83                ; [clip]
RASTER_ZP_X1 = $84                ; [clip]
RASTER_ZP_Y1 = $85                ; [clip]
bca_boxp = $86                    ; [ang]; ROM box pointer: caller points this at the 8-byte box
pa_sy = $89                       ; [ang]
pa_oct = $8A                      ; [ang]
bca_hi = $8B                      ; [ang]; hi_phi (s16) ; w=2
bca_pxs = $8D                     ; [ang]; px sign-extended (s16) ; w=2
zp_br_pxraw_lo = $90              ; [bsp]; s16 player x relative to map_center (raw)
zp_br_pxraw_hi = $91              ; [bsp]
zp_br_pyraw_lo = $92              ; [bsp]
zp_br_pyraw_hi = $93              ; [bsp]
zp_v_xext = $94                   ; [bsp]; saved view-x s24 extension byte (wide-vx path)
zp_seg_hdr_p = $96                ; [bsp]; persistent seg-header ptr (advances +12/seg)
zp_seg_hdr_p_h = $97              ; [bsp]
zp_fhch_p = $98                   ; [bsp]; persistent FHCH ptr (advances +6/seg)
zp_fhch_p_h = $99                 ; [bsp]
zp_pyc_idx = $9A                  ; [bsp]; projection-cache probe index (X save)
bca_pys = $9B                     ; [ang]; py sign-extended (s16) ; w=2
; --- $A8: overlay group (3 phase-disjoint users) ---
zp_ms_emit = $A8                  ; [clip]; mark_solid: $FF = emit wall edge lines, $00 = skip
zp_line_xl = $A8                  ; [bsp+clip]; u8, left X (oriented left-to-right)
; --- $A9: overlay group (2 phase-disjoint users) ---
zp_line_yl = $A9                  ; [bsp+clip]; u8, Y at xl
; --- $AA: overlay group (2 phase-disjoint users) ---
zp_line_xr = $AA                  ; [bsp+clip]; u8, right X
; --- $AB: overlay group (2 phase-disjoint users) ---
zp_line_yr = $AB                  ; [bsp+clip]; u8, Y at xr
zp_line_dx = $AC                  ; [clip]; u8, xr - xl (>= 0)
zp_line_dy = $AD                  ; [clip]; s8, yr - yl
zp_line_ylo = $AE                 ; [clip]; u8, min(yl, yr) — running Y bbox
zp_line_yhi = $AF                 ; [clip]; u8, max(yl, yr) — running Y bbox
zp_seg_start_x = $B0              ; [clip]; u8, $FF = NULL (no segment started)
zp_seg_start_y = $B1              ; [clip]; u8, Y at seg_start_x
; --- $B2: overlay group (3 phase-disjoint users) ---
zp_cb_cx1 = $B2                   ; [clip]; u8, clipped left X
zp_line_xl_hi = $B2                    ; [clip]
; --- $B3: overlay group (3 phase-disjoint users) ---
zp_cb_cy1 = $B3                   ; [clip]; u8, clipped left Y (line Y at cx1)
zp_line_yl_hi = $B3                    ; [clip]
; --- $B4: overlay group (3 phase-disjoint users) ---
zp_cb_cx2 = $B4                   ; [clip]; u8, clipped right X
zp_line_xr_hi = $B4                    ; [clip]
; --- $B5: overlay group (3 phase-disjoint users) ---
zp_cb_cy2 = $B5                   ; [clip]; u8, clipped right Y (line Y at cx2)
zp_line_yr_hi = $B5                    ; [clip]
; --- $B6: overlay group (4 phase-disjoint users) ---
zp_cb_top1 = $B6                  ; [clip]; u8, span top at cx1
; --- $B7: overlay group (3 phase-disjoint users) ---
zp_cb_top2 = $B7                  ; [clip]; u8, span top at cx2
; --- $B8: overlay group (3 phase-disjoint users) ---
zp_cb_bot1 = $B8                  ; [clip]; u8, span bot at cx1
; --- $B9: overlay group (3 phase-disjoint users) ---
zp_cb_bot2 = $B9                  ; [clip]; u8, span bot at cx2
zp_tg_cont = $BA                  ; [clip]; portal continuation: $FF=inactive, else=prev span xend
zp_dcl_rec_buf = $BC              ; [clip]; lo byte of buffer ptr ; w=2
zp_dcl_rec_buf_h = $BD            ; [clip]; hi byte of buffer ptr ($00 = records disabled)
zp_dcl_rec_off = $BE              ; [clip]; current write offset (1-based) within buffer
zp_head = $C0                     ; [clip]
zp_free = $C1                     ; [clip]
zp_ilo = $C2                      ; [clip]
zp_ihi = $C3                      ; [clip]
zp_hg_cache = $D0                 ; [clip]; has_gap coherence cache: last-matching span offset
zp_i_x0 = $D1                     ; [clip]
zp_i_y0 = $D2                     ; [clip]
; --- $D3: overlay group (2 phase-disjoint users) ---
; --- $D4: overlay group (2 phase-disjoint users) ---
zp_i_y1 = $D5                     ; [clip]
; --- $D6: overlay group (2 phase-disjoint users) ---

; --- $D7: overlay group (3 phase-disjoint users) ---
; --- $D8: overlay group (3 phase-disjoint users) ---
zp_mul_b = $D9                    ; [bsp+clip]
; --- $DA: overlay group (2 phase-disjoint users) ---
zp_prod_lo = $DA                  ; [bsp+clip]
zp_div_lo = $DA                   ; [bsp+clip]
; --- $DB: overlay group (2 phase-disjoint users) ---
zp_prod_hi = $DB                  ; [bsp+clip]
zp_div_hi = $DB                   ; [bsp+clip]
zp_div_den = $DC                  ; [bsp+clip]
; --- $DD: overlay group (2 phase-disjoint users) ---
zp_div_rem = $DD                  ; [clip]
zp_tmp0 = $DE                     ; [bsp+clip]; umul8 scratch (matches span_clip); free outside span_clip
zp_tmp1 = $DF                     ; [clip]
zp_tmp2 = $E0                     ; [clip]
zp_plot_i = $95                     ; [clip]; plot_h byte-index scratch
; --- $E1: overlay group (2 phase-disjoint users) ---

; --- $E5: overlay group (3 phase-disjoint users) ---
zp_save0 = $6A                    ; [clip]; DCL line-clip scratch (also
;   carries bca_vis's old duty? NO — bca_vis/ccsave own $64/$65 solo)
zp_save1 = $6B                    ; [clip]
zp_save2 = $6C                    ; [clip]
zp_new_tail = $6C                 ; [clip]; OVERLAY (pre-existing pair):
;   mark_solid vs tighten phases
zp_old_cur = $6D                  ; [clip]; tighten cursor scratch (tfr.s)
zp_ox0 = $6E                      ; [clip]; subspan extent scratch (dcl+tfr)
zp_ox1 = $6F                      ; [clip]
zp_clr_save_x = $D7               ; [clip]; tighten X-save (tfr.s; the name
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
