.include "abi.inc"          ; cross-language ABI constants (generated)
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
FW_SLOT  = $1F                    ; [clip]
FW_NEXT  = $2B                    ; [clip]
fwl_xl   = $2D                    ; [clip]; the armed line (fw_walk_line)
fwl_yl   = $2E                    ; [clip]
fwl_xr   = $2F                    ; [clip]
fwl_yr   = $37                    ; [clip]
fwl_dy   = $38                    ; [clip]
fwl_dx   = $44                    ; [clip]
fwl_lo   = $48                    ; [clip]; minmax pair = the apply's extremes
fwl_hi   = $49                    ; [clip]
fwl_run  = $4A                    ; [clip]; run state ($FF = closed)
fwl_ry0  = $4B                    ; [clip]
fwl_rend = $4E                    ; [clip]
fwl_rendv = $54                   ; [clip]; $80 = open end
fwl_zx0  = $55                    ; [clip]; current overlap
fwl_zx1  = $56                    ; [clip]
fwl_leftf = $57                   ; [clip]; left-flat frontier
fwl_pend = $6B                    ; [clip]; right-pend pol ($80 = none)
fw_pol   = $8F                    ; [clip]; flat polarity
fw_top1  = $94                    ; [clip]; CB boundary values
fw_top2  = $B7                    ; [clip]
cp_vx0   = $B9                    ; [clip]; visible piece staging
cp_vy0   = $BB                    ; [clip]
cp_vx1   = $BF                    ; [clip]
cp_vev   = $C4                    ; [clip]
fw_ax0   = $C5                    ; [clip]; apply range
fw_ax1   = $CE                    ; [clip]
fw_rslot = $D6                    ; [clip]; span slot at run open
FW_SIDE  = $D8                    ; [clip]; 0 top / $80 bot
FW_MODE  = $DD                    ; [clip]; s16 dispatch redirect (b7)
; ($E1 free — the set's spare)
; s16 clipper working set (LIVE — these shared the old TFS block's home)
LC_REM_LO = $52                   ; [clip]
LC_REM_HI = $53                   ; [clip]
LC_DEN_LO = $98                   ; [clip]
LC_DEN_HI = $99                   ; [clip]
LC_QUOT_LO = $A6                  ; [clip]
LC_QUOT_HI = $A7                  ; [clip]
LC_TMP_LO = $C6                   ; [clip]
LC_M_R0 = $D3                     ; [clip]
LC_M_R1 = $D4                     ; [clip]
LC_DY_LO = $FC                    ; [clip]
LC_DY_HI = $FD                    ; [clip]
LC_OFF_LO = $FE                   ; [clip]
LC_OFF_HI = $FF                   ; [clip]
; REJECTED bytes (the listing scan + pyref are the arbiters, NOT the
; free notes): $CB = zp_tail_vec+1; $7C = zp_vf_vec0 HI BYTE (the $64
; trap again — the 'separately FREE' note below rotted when the off-arm
; restore brought the vectors back, and pyref caught it); $9F/$A0 left
; for the visibility hooks.
zp_dcl_out = $9F                  ; [clip]; per-line outcome accumulator
                                  ; (clipper-feedback abort, 2026-08-14):
                                  ; $80 = saw off-top reject, $40 = saw
                                  ; off-bottom, $01 = real recorded segment
                                  ; emitted, $C0 tagged conservatively by
                                  ; the CB-clip + vertical recorded paths.
                                  ; Tapped in RECORDS-ARMED forks only.
plotq_n = $A0                     ; [clip]; plot queue write index (bytes,
                                  ; wraps at 256 = 64 entries full)
plotq_mode = $A1                  ; [clip]; $80 = enqueue (driver arms per
                                  ; frame until the flip vsync passes),
                                  ; $00 = draw direct (harness default)
vxc_ref_x = $A2                   ; [bsp] s16 COUNT frame ref = rns(to_view(0,0),3)
vxc_ref_y = $A4                   ; [bsp] s16 count ref (y); TRUE16 2026-08-10
                                  ; ($A6-$A7 FREE — the s24 third bytes died)
                                  ; absolute — six warm-path ADCs per vertex
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
zp_br_px_x = $9D                  ; [bsp]; s16 player int x HIGH byte (px_h is lo)
zp_br_py_x = $9E                  ; [bsp]; s16 player int y HIGH byte (py_h is lo)
zp_br_smag = $05                  ; [bsp]; u8 sin magnitude
zp_br_sneg = $06                  ; [bsp]; 1 if sin negative
zp_br_sone = $07                  ; [bsp]; 1 if |sin| == 1
zp_br_cmag = $08                  ; [bsp]
zp_br_cneg = $09                  ; [bsp]
zp_br_cone = $0A                  ; [bsp]
zp_br_fvx_l = $0B                 ; [bsp]; s16 frac_vx (0.8 contribution)
zp_br_fvx_h = $0C                 ; [bsp]
zp_br_fvy_l = $0D                 ; [bsp]
zp_br_fvy_h = $0E                 ; [bsp]
zp_br_dx_l = $0F                  ; [bsp]
zp_br_dy_l = $10                  ; [bsp]
zp_br_vx_l = $11                  ; [bsp]
zp_br_vx_h = $12                  ; [bsp]
zp_br_vy_l = $13                  ; [bsp]
zp_br_vy_h = $14                  ; [bsp]
zp_br_a = $15                     ; [bsp]; multiplicand A (s8 input)
zp_br_b = $16                     ; [bsp]; multiplicand B
zp_br_res_l = $17                  ; [bsp]; s24 result lo
zp_br_res_h = $18                  ; [bsp]; s24 result mid (the s16 path stops here)
zp_br_sign = $19                  ; [bsp]; 0 = positive, non-0 = negative
zp_br_r_m8 = $1A                   ; [bsp]; u8 hi of reciprocal
zp_br_r_s = $1B                   ; [bsp]; u8 lo
; --- BCA angle-module hot slots (moved from BCA_WS absolutes 2026-07-08;
; equates live in ang/header_div.s + bsp/backface.s, names kept there) ---
; $BB bca_ilo   $BF bca_ihi   $C8-$C9 bca_p1   $CA-$CB zp_tail_vec
; $CC t0        $CD t1        $CE val_lo       $CF val_hi
; $F5 bca_vis   $F6 bca_ccsave                 $F7 DEFQ_TAIL
zp_bca_p1 = $C8                   ; [ang]; s16 pair with $C9
zp_bca_p1_h = $C9                ; [ang]
; $CA FREE (zp_cpm_s2 died with the rcache wrapper scavenge 2026-07-20).
zp_tail_vec = $CA                 ; [ang] 2-byte tail vector: the corner arms
                                  ; end JMP (zp_tail_vec) -> bt_store (armed:
                                  ; store psis + COMPUTED) or bca_tail_postrc
                                  ; (moving: nothing stored). Set per frame by
                                  ; bca_frame; REPLACES the zp_rc_moved flag
zp_bv_entry = $63                 ; [ang] 2-byte entry vector: bbox_visible
                                  ; is JMP (zp_bv_entry) -> bbox_check_angle
                                  ; (standing: probe) or box_classify (moving:
                                  ; pristine). Paired with zp_tail_vec; w=2
                                  ; (valid bits armed, probe+serve+store);
                                  ; nonzero = moving/unknown (pristine
                                  ; passthru, no probe, no stores). Written
                                  ; by bca_frame; the stop EDGE wipes the
                                  ; bitmap and clears this. Driver init
                                  ; seeds $FF (boot garbage safety).
; $CE free (was zp_bca_val_lo, 2026-07-11)
; $C4/$C5: OWNED by ang/rcache.s (position-keyed rotation cache) — was an
; unregistered squatter; registered 2026-07-10. Do not allocate.
; $C6 FREE 2026-08-10: zp_px_s_save died with the ps_rns24 arm (the
; rns_s1..s4 bake — no dispatch arm writes r_s any more)
; (was) zp_px_s_save = $C6        ; [bsp]; br_project_x shrink path: the
                                  ; vertex's TRUE S across the shrunken
                                  ; projection (callers bank rlo AFTER)
zp_vxc_on = $C7                   ; [bsp]; VXC gate flag (vxc_frame sets it
                                  ; from VXC_ENABLE; the vertex-fetch entry
                                  ; branches — vxc_jsr_site SMC retired
                                  ; 2026-07-18)
; --- $C4/$C5: rc_psilo/rc_psihi (ang/rcache.s) — UNREGISTERED SQUATTER,
; registered 2026-07-08 after zp_rns_vec landed on them and the walk disc
; jammed (cached-bbox frames clobbered the vector). anim.s similarly owns
; $EB-$EE/$F0-$F1. Do not trust "free" without grepping ang/anim/drivers.
zp_rs_l = $1E                     ; [bsp] sin-side rotate result lo (res-slot
                                  ; split 2026-07-19: sin cores/variants write
                                  ; rs_*, cos keeps zp_br_res — the s1 res->vx
                                  ; copy died; s2 combines from both slots)
; (was zp_bca_zone — zone byte killed 2026-07-19: the inside
;   signal rides the p1/p2 full-span sentinel now)
; $1F FREE (zp_bv_mode retired 2026-07-21: the frame class IS the
;  zp_bv_entry vector — pristine/rcache/dcache all dispatch through it)
zp_v1i_l = $45                    ; [bsp]; v1 vertex key lo (idx & 255) banked
zp_v1i_b = $46                    ; [bsp]; ... key B (idx >> 3) across the v2
                                  ; transform for the vertex-span emitter
; $52/$53 FREE (EV16 took them 2026-08-09; TRUE16 freed them 2026-08-10). (zp_vs_il/ib retired 2026-07-25: call sites probe VDONE
; inline and the fresh path re-reads the key from its home pair)
; $47 free (zp_vs_d retired 2026-07-25: vs_go dispatches on A directly)
zp_vs_x  = $4D                    ; [bsp]; vs_vertex: struct offset save
zp_vs_i  = $4F                    ; [bsp]; vs_vertex: explicit-table cursor
zp_vs_hl = $50                    ; [bsp]; vs_vertex: clamped span lo height
zp_vs_hh = $51                    ; [bsp]; vs_vertex: clamped span hi height
zp_br_t0 = $20                    ; [bsp]
zp_br_t1 = $21                    ; [bsp]
zp_br_t2 = $22                    ; [bsp]
zp_br_t3 = $23                    ; [bsp]
zp_br_t4 = $24                    ; [bsp]; back-face u24 product hi bytes —
zp_br_t5 = $25                    ; [bsp]; |P1|=(t2,t3,t4) |P2|=(t0,t1,t5),
ANIM_VAL = $27                    ; [bsp]; anim: patch value (registered
;   2026-07-10 — was an unregistered squatter at $F0)
ANIM_CUR = $29                    ; [bsp]; anim: mover index (was $F1)
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
VX1 = $E2
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
; page numbers (clip-local equate) — the trap that bit the VXC move.
; Records arenas moved UP 2026-08-14 (Eben: 'move the records up, keep
; the span state down for has_gap'): banked = the bank C free block left
; by the VXC-planes-to-main move (all touchers run under the emit
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
zp_seg_ep = $26                   ; [bsp]; per-endpoint STRUCT offset into
; VX1 (0 = v1, 15 = VX_STRIDE = v2): the generators write evy/evx/sx/sy/
; recip DIRECTLY into the endpoint structs via ,X = this offset. Set by
; the seg loop before each transform / projection / reprojection.
; $27 -> zp_tw (TRIPWIRE, debug). Verified free by poisoning it and
; running the full render + anim_tick + pm_frame: zero writes, unlike
; $4C/$7C/$CA/$C6/$1F which all carry stale FREE notes and ARE written.
zp_tw = $27                       ; [debug]; tripwire latch, 0 = not tripped
zp_ri_d_l = $28                   ; [bsp]
; $29 FREE (2026-07-09): zp_seg_bfh retired — back floor read on demand
; from header+12 via (zp_seg_hdr_p),Y (stride-16 heights; solids never
; touch it).
zp_rs_h = $2A                     ; [bsp] sin-side rotate result hi (pairs $1E)
; (was zp_par_zone — zone inheritance removed 2026-07-18)
zp_ri_d_h = $2C                   ; [bsp]; (was unused; s16 hi byte of d)
pa_dx = $30                       ; [ang]; s16 in ; w=2
pa_dy = $32                       ; [ang]; s16 in ; w=2
zp_bbox_side = $34                ; [bsp]
zp_br_dx_h = $35                  ; [bsp]
zp_br_dy_h = $36                  ; [bsp]
; (was zp_v_x_l)
pa_res = $39                      ; [ang]; u16 out (fineangle) ; w=2
bca_afn = $3B                     ; [ang]; a_fine (s16) -- ZP (freed from pa_adx); hot in corner_phi ; w=2
zp_bf_dir = $3D                   ; [bsp]; diagonal back-face DIR-table index;
; the |dx'|/|dy'| magnitudes load lazily in the mul tier via this stash
; (dead-write tracker 2026-07-11: sign-shortcut exits never read them).
zp_cpm_slot = $3E                 ; [ang]; memo hash slot, probe -> store
; (was zp_cpm_frame; briefly free 2026-07-17 when the epoch died — the
;  slot stash saves the store-side hash recompute, X dies in the miss
;  pipeline)
zp_seg_flags = $3F                ; [bsp]; u8
pa_ptr = $40                      ; [ang]; 16-bit table pointer ; w=2
zp_ys_done = $42                  ; [bsp]; 1 = the PREVIOUS seg ran the
; post-has_gap y stage (its VX2 sy pairs are live for the chain);
; cleared per seg at the chain decision, set at y-stage end
zp_ss_eskip = $4C                 ; [bsp]; subsector eyeline edge-skip:
                                  ; $80 = ch <= vz (no top edges),
                                  ; $40 = fh >= vz (no bottom edges);
                                  ; built in the subsector prologue,
                                  ; BIT-tested at the ft/fb arm heads
zp_ys_v1ok = $43                  ; [bsp]; 1 = this seg's chained v1
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
zp_vf_vec0 = $7B                  ; [bsp]; VXC fetch vector, junior side —
                                  ; vxc_frame aims it at sxv0_vfoff (off)
                                  ; or sxv0_vxcon (on); bca VECTORED idiom.
                                  ; (Briefly deleted for TRUE16 always-on
                                  ; 2026-08-10, restored same day: the off
                                  ; arm is compute-only per the canonical
                                  ; cache contract.) $7B-$7E were the
                                  ; boot-time tube-detect scratch — phase-
                                  ; disjoint.
zp_vf_vec1 = $7D                  ; [bsp]; senior-side twin ($7D/$7E)
; FREE 2026-07-15 (cross-core unification): zp_node_dy_h = $53
zp_node_ch_l = $58                ; [bsp]; current child (lo, hi: 16-bit id)
; $59 free (was zp_node_ch_h — ids are u8 end to end, 2026-07-15)
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pym_h = $5B
; $5A FREE (was zp_sx_ord — the reversal latch died when the drop
;     moved into the stage-3 range gate, 2026-08-12)
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
bca_ab = BCA_AB                   ; [ang+bsp]; = $62 (zp_buf's slot, freed
                                  ; with span_read 2026-07-26): per-frame
                                  ; view angle byte (was BCA_WS+$2F). ONE
                                  ; truth: the value lives in the generated
                                  ; abi.inc (included above) — drivers
                                  ; poke the same constant. vxc_ab aliases.
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
RASTER_ZP_SCRSTRT = $70           ; [clip]
; $73 free (was pa_sx — lf_ns reads L8_TAB,Y direct, 2026-07-19)
zp_seg_v_idx_l = $77             ; [bsp]; cached: vertex index (u16)
zp_seg_v_idx_b = $78              ; [bsp]; B = idx>>3 (bitmap/VXC byte
; index, stored pre-derived in the header; idx = B*8 + (lo&7))
; $79 free — INSIDE THE RASTERIZER'S SCRATCH RANGE (measured 2026-07-25:
; RASTER_ENTRY writes it mid-frame; nothing may live here across draws)
zp_seg_v_bitm = $47               ; [bsp]; valid-bitmap mask (1 << (idx & 7));
zp_pm_p = $59                       ; [bsp]; pmove: collision list pointer ; w=2
                                  ; SURVIVES DRAWS (the old $79 home was
                                  ; raster scratch — reads were only safe
                                  ; adjacent to the store); the vs2 serve
                                  ; site + vs_fresh2 now reuse it across
                                  ; the emit cascade ($47 = zp_vs_d's
                                  ; slot, freed 98fc1b3)
; $7A free for bsp use (was zp_seg_v_cache_l; NB the NJ rasteriser
; scratches $7A as errs — phase-disjoint). $7B free (was _cache_h) —
; the vcache is page-split SoA with baked senior arms, no pointer.
; FREE 2026-07-15 (cross-core unification): zp_seg_dxraw_l = $7C
; ($7D NOT free despite the old dxraw_h note: zp_vf_vec1 = $7D-$7E.)
; ($7E/$7F: zp_vf_vec1 hi byte — see the $7B block)
; (were the dyraw pair, free since the cross-core unification).
RASTER_ZP_X0 = $82                ; [clip]
RASTER_ZP_Y0 = $83                ; [clip]
RASTER_ZP_X1 = $84                ; [clip]
RASTER_ZP_Y1 = $85                ; [clip]
bca_boxp = $86                    ; [ang]; ROM box pointer: caller points this at the 8-byte box
; $89-$8C TAKEN 2026-08-09: zp_cr_* EV16 crossing scratch (see the
; block above the div slots) — were pa_sy / pa_oct / bca_hi frees.
bca_pxs = $8D                     ; [ang]; px sign-extended (s16) ; w=2
zp_br_px2_l  = $1C               ; [bsp]; tie-broken doubled raw x:
zp_br_px2_h  = $1D               ;   (raw<<1) | (world frac > 0) — the
zp_br_py2_l  = $7F               ;   EXACT axis point-on-side compares
zp_br_py2_h  = $BA               ;   this against the baked 2*nx/2*ny
                                 ;   ($F8/$F9 were the free-list's THIRD
                                 ;   rot: VX2+9/+10 live there — ysb
                                 ;   writes them every mover back pair)
zp_br_pxraw_l = $90              ; [bsp]; s16 player x relative to map_center (raw)
zp_br_pxraw_h = $91              ; [bsp]
zp_br_pyraw_l = $92              ; [bsp]
zp_br_pyraw_h = $93              ; [bsp]
; $94 free (was zp_v_x_x)
zp_seg_hdr_p = $96                ; [bsp]; persistent seg-header ptr (advances +12/seg)
zp_seg_hdr_p_h = $97              ; [bsp]
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pxm_l = $98
; FREE 2026-07-16 (write-only since the C-form): zp_bf_pxm_h = $99
; back-face C-form magnitudes (signs read live from px_e/py_e bit7)
zp_pyc_idx = $9A                  ; [bsp]; projection-cache probe index (X save)
bca_pys = $9B                     ; [ang]; py sign-extended (s16) ; w=2
; --- $A8: overlay group (3 phase-disjoint users) ---
; ($A8 shared: zp_line_xl_l below — the old zp_ms_emit flag was GC'd
; 2026-07-12: no 6502 reader existed)
zp_line_xl_l = $A8                  ; [bsp+clip]; u8, left X (oriented left-to-right)
; --- $A9: overlay group (2 phase-disjoint users) ---
zp_line_yl_l = $A9                  ; [bsp+clip]; u8, Y at xl
; --- $AA: overlay group (2 phase-disjoint users) ---
zp_line_xr_l = $AA                  ; [bsp+clip]; u8, right X
; --- $AB: overlay group (2 phase-disjoint users) ---
zp_line_yr_l = $AB                  ; [bsp+clip]; u8, Y at xr
zp_line_dx = $AC                  ; [clip]; u8, xr - xl (>= 0)
zp_line_dy = $AD                  ; [clip]; s8, yr - yl
zp_line_y_l = $AE                 ; [clip]; u8, min(yl, yr) — running Y bbox
zp_line_y_h = $AF                 ; [clip]; u8, max(yl, yr) — running Y bbox
zp_seg_start_x = $B0              ; [clip]; u8, $FF = NULL (no segment started)
zp_seg_start_y = $B1              ; [clip]; u8, Y at seg_start_x
; --- $B2: overlay group (3 phase-disjoint users) ---
zp_cb_cx1 = $B2                   ; [clip]; u8, clipped left X
zp_line_xl_h = $B2                    ; [clip]
; --- $B3: overlay group (3 phase-disjoint users) ---
zp_cb_cy1 = $B3                   ; [clip]; u8, clipped left Y (line Y at cx1)
zp_line_yl_h = $B3                    ; [clip]
; --- $B4: overlay group (3 phase-disjoint users) ---
zp_cb_cx2 = $B4                   ; [clip]; u8, clipped right X
zp_line_xr_h = $B4                    ; [clip]
; --- $B5: overlay group (3 phase-disjoint users) ---
zp_cb_cy2 = $B5                   ; [clip]; u8, clipped right Y (line Y at cx2)
zp_line_yr_h = $B5                    ; [clip]
; --- $B6: overlay group (4 phase-disjoint users) ---
zp_cb_top1 = $B6                  ; [clip]; u8, span top at cx1
; --- $B7: overlay group (3 phase-disjoint users) ---
; --- $B8: overlay group (3 phase-disjoint users) ---
zp_cb_bot1 = $B8                  ; [clip]; u8, span bot at cx1
; --- $B9: overlay group (3 phase-disjoint users) ---
; --- $BA: FREE (zp_tg_cont retired 2026-08-23 -- the portal-continuation
;     state had no reader anywhere in the tree; storescan found the store)
zp_bf_lv1 = $BC                   ; [bsp]; diagonal backface LV1 record id
                                  ; (stashed for bf_band's K-plane read;
                                  ; $BC was zp_dcl_rec_buf until the FUSED
                                  ; walker killed the records, 2026-08-25)
zp_ys_bs = $BD                    ; [bsp]; per-seg back-pair S bump (0 static /
                                  ; nonzero mover): ys back projections re-stage
                                  ; S+1 + kernel when set
zp_vs_cfh = $BE                   ; [bsp]; vsx_expl clamp copy of fh (doubled
                                  ; for H2 mover-jamb entries, 2026-08-25)
zp_head = $C0                     ; [clip]
; SPAN_IS_NOT_FULL (2026-07-26, replaces IS_FULL_B and the retired
; span_is_full routine): the clipper's whole occlusion truth is
; zp_head == 0 (active span list empty) and ZP is unbanked — no JSR,
; no bank-C page, no materialized 0/1. The macro JUST TESTS zp_head:
; A = zp_head, Z = screen fully solid. Callers branch themselves
; (BEQ done / BNE continue).
.macro SPAN_IS_NOT_FULL
   LDA zp_head
.endmacro
zp_free = $C1                     ; [clip]
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
zp_i_l = $C2                      ; [clip+ang]; interval lo (= bca_ilo)
zp_i_h = $C3                      ; [clip+ang]; interval hi (= bca_ihi)
                                  ; directly; $BB/$BF freed)
zp_hg_cache = $D0                 ; [clip]; has_gap coherence cache: last-matching span offset
zp_hg_ihi = $5B                     ; [clip]; has_gap: stashed interval hi
zp_seg_end_x = $65                  ; [clip]; DCL: right end of the open
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
zp_prod_l = $DA                  ; [bsp+clip]
zp_div_l = $DA                   ; [bsp+clip]
; --- $DB: overlay group (2 phase-disjoint users) ---
zp_prod_h = $DB                  ; [bsp+clip]
zp_div_h = $DB                   ; [bsp+clip]
zp_div_den = $DC                  ; [bsp+clip]
; --- $DD: overlay group (2 phase-disjoint users) ---
zp_tmp0 = $DE                     ; [bsp+clip]; umul8 scratch (matches span_clip); free outside span_clip
zp_tmp1 = $DF                     ; [clip]
zp_tmp2 = $E0                     ; [clip]
zp_plot_i = $95                     ; [clip]; plot_h byte-index scratch
; --- $E1: vsx_expl clamp copy (both prior users died) ---
zp_vs_cch = $E1                   ; [bsp]; vsx_expl clamp copy of ch (doubled
                                  ; for H2 mover-jamb entries, 2026-08-25)

; EV16 crossing scratch (2026-08-09): the CLIPPED endpoint's recovered
; s24 view totals, banked across the second cr_recover call (which
; lands the unclipped endpoint in the zp_br_vx/vy working slots).
; Live only inside reproject_at_crossing; free everywhere else.
; ORDER MIRRORS the zp_br working slots ($11-$14 pair block + $2E/$2F
; ext pair) so cr_recover_clipped's stash is an indexed loop.
; NOT $E3+: that range sits INSIDE the VX1/VX2 endpoint structs
; ($E2-$FF, stride 15) — zpcheck's free list does not expand w= struct
; widths (the $64 trap, again). NOT $7E: zp_vf_vec1 spans $7D-$7E
; (the dxraw_h 'free' note was stale — vector hi byte, VXC dispatch
; corrupts). Homes: the ang module's registered free singles $89-$8C
; + the twice-audited $52/$53 pair.
zp_cr_vx_l = $89                  ; [bsp]; clipped total vx (s16 counts)
zp_cr_vx_h = $8A                  ; [bsp]
zp_cr_vy_l = $8B                  ; [bsp]; clipped total vy (s16 counts)
zp_cr_vy_h = $8C                  ; [bsp]
; ($52/$53 FREE again 2026-08-10: the zp_cr ext bytes died with TRUE16
;  — totals are s16 counts)
zp_save0 = $6A                    ; [clip]; DCL line-clip scratch (also
;   carries bca_vis's old duty? NO — bca_vis/ccsave own $64/$65 solo)
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
; ANGX/ANIM*/RCCODE/VXCODE/.._BK twins) died here; so did its landmine
; class (ZZTAIL fall-through, cfg-order region shifts).
; ============================================================================
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
.segment "PMB1"                   ; banked $B500-$B6FF: the frame flow
.endmacro
.macro SEG_PMB2
.segment "PMB2"                   ; banked $B198-$B2FF: project/split
.endmacro
.macro SEG_PMB3
.segment "PMB3"                   ; banked $B348-$B3FF: packed trig+unit
.endmacro
.macro SEG_PMB4
.segment "PMB4"                   ; banked $B862-$B8BF: the DIR stride
.endmacro                         ;  shadow (dirs<=118 asserted)
.macro SEG_PMH
.segment "PMH"                    ; pm single-step: banked = the
.endmacro                        ;  PMOVE area, flat = PMBF
.macro SEG_PMEXT
.segment "PMEXT"                  ; pm helpers past the flat CODE cap
.endmacro                         ;  (banked: CODE tail; flat: $DF80)
.macro SEG_PMZ
.if ::BANKED
.segment "PMB4"                   ; pmove_try's zonly tail: banked rides
.else                             ;  PMB4; flat takes the $4D80 half page
.segment "PMZ"                    ;  (above the DBOUND plane, below the
.endif                            ;  $4E00 VXC planes — ships zero,
.endmacro                         ;  render-untouched, audited 2026-08-29)
.macro SEG_PMCND
.if ::BANKED
.segment "PMB4"                   ; pmf_cand: banked rides the CODE tail
.else                             ;  with the rest of PMB4; flat moves to
.segment "PMCND"                  ;  the VPLOTF hole so the CODE area stays
.endif                            ;  walled at $4D00 (ROM_DBOUND_C page —
.endmacro                         ;  the loader POKES dbound there and the
                                  ;  ang-module region reload would serve
                                  ;  code bytes as bounds; 2026-08-29)
.macro SEG_PMCOL
.if ::BANKED
.segment "CODE"                   ; pm_column: banked stays in CODE (its
.else                             ;  pre-physics home — moving it shifted
.segment "PMOVE"                  ;  the render tail, +0.35% MEAN in pure
.endif                            ;  alignment noise); flat CODE is at the
.endmacro                         ;  $4E00 cap, so flat rides PMOVE slack
.macro SEG_BANKC
.if ::BANKED
.segment "BANKC"
.else
.segment "CLIPF"                        ; flat: the bank-C-equivalent lives
                                        ; ABOVE the 22K line ($5800 area) —
                                        ; the bottom-22K map is IDENTICAL
                                        ; between builds (Eben, 2026-08-09)
.endif
.endmacro


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
