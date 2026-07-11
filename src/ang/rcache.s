; Per-bbox cache (indexed by (boxp - rom_bbox) i.e. node*16+side*8, so the
; 4-byte psi slot is at RCACHE_PSI + (diff>>1)):
;   RCACHE_PSI[idx]   : psi1, psi2 (2 bytes each, the raw point_to_angle)
;   RCACHE_COMPUTED   : 1 bit/bbox — psi valid for the cache position
;   RCACHE_FULL       : 1 bit/bbox — result is a_fine-INDEPENDENT full
;                       (viewer inside box, OR span>=ANG180); warm returns full
;
; bca_frame (per frame, from br_view_setup) SMC-patches jt_bca_check between
; bbox_check_angle (moved frame: verbatim, zero overhead) and
; bbox_check_angle_cached (stable frame). Stability = integer position
; ($01/$9D/$03/$9E) unchanged since last frame. First stable frame at a new
; position clears RCACHE_COMPUTED so entries repopulate lazily.
.if BANKED
RCACHE      = $AD00                     ; bank L2 window, free tail after the VWHC
                                        ; cache arrays ($A700-$ACFF; VWHC_HI ends
                                        ; $ACFF — see resolve_crossing.s). Every
                                        ; consumer runs
                                        ; with L2 paged: the bbox path pages L2 in
                                        ; br_bbox_visible, bca_frame is paged in by
                                        ; its caller (view.s), and the drivers page
                                        ; bank 7 before the init clear. ($2000 was
                                        ; WRONG: sqr tables $2000-$23FF + FHCH
                                        ; $2400-$3377 live there in the banked map.)
.else
RCACHE      = $3800                     ; CLIP-reserved tail (flat harness); zero RAM
.endif
; rom_bbox base pointer (set per frame by the loader; BSP-unit zp $0BEA/$0BEB)
; (zp_rom_bbox retired 2026-07-10 — ROM_BBOX_C in layout.inc)
RCACHE_PSI  = RCACHE                    ; 472*4 = 1888 bytes ($760)
RCACHE_COMPUTED = RCACHE + $760         ; 59 bytes
RCACHE_FULL = RCACHE + $7A0             ; 59 bytes
bca_prevpos = RCACHE + $7E0             ; 4 bytes: last frame's int position
bca_cachepos = RCACHE + $7E4            ; 4 bytes: position RCACHE_COMPUTED is valid for
.assert RCACHE + $7E8 = RCACHE_ENABLE, error, "rcache layout drifted from abi.inc"
.assert RCACHE + $760 = RCACHE_STATE, error, "rcache state head drifted from abi.inc"
; RCACHE_ENABLE comes from abi.inc; nonzero -> cache may engage (drivers set it;
                                        ; harness default 0 keeps every existing test
                                        ; on the original path, byte- and cycle-exact)
; scratch for the cached routine (dead outside a check)
rc_idxlo    = t0                        ; index-calc scratch (t0/t1 free at entry)
rc_idxhi    = t1
rc_psilo    = $C4                       ; ZP ptr into RCACHE_PSI (for (),Y — idx>>1
rc_psihi    = $C5                       ; spans 0..1887, needs a full 16-bit ptr)
rc_bytehi   = val_hi                    ; bitmap byte offset idx>>6 (<=58, fits u8)
rc_bit      = bca_ccsave                ; bit mask for (idx>>3)&7

; --- bca_frame + bbox_check_angle_cached live in their own segment so the
; banked build can place them in the free low RAM at $2800 (ANG_BK has no
; room after W_BK at $3900). Flat keeps them in ANG. They reference ANG(_BK)
; labels (bca_tail/box_classify/corner_phi/cp_havepsi) and RAM equates
; (RCACHE); all resolved by the linker. Banked: code AND data live in the
; bank L2 window (callers guarantee L2 is paged — see RCACHE note above). ---
.if BANKED
.segment "RCCODE"
.endif
; --- bca_frame: per-frame stability check + dispatch patch --------------------
; Called by br_view_setup after it has set the integer player position ZP.
;   in : RCACHE_ENABLE; player int position ZP $01/$9D (x lo/hi), $03/$9E
;        (y lo/hi); bca_prevpos/bca_cachepos (persistent across frames)
;   out: jt_bca_check operand SMC-patched to bbox_check_angle (moved frame or
;        cache disabled: verbatim original, zero per-check overhead) or to
;        bbox_check_angle_cached (stable frame); COMPUTED bitmap cleared on
;        the first stable frame at a new position (new cache epoch).
; pseudocode:
;   if not ENABLE:        patch original; return
;   if pos != prevpos:    prevpos = pos; patch original; return    # moved
;   if pos != cachepos:   cachepos = pos; COMPUTED[:] = 0          # new epoch
;   patch cached                                                   # stable
.export jt_bca_frame
jt_bca_frame: JMP bca_frame
bca_frame:
   LDA RCACHE_ENABLE
   BNE bcf_enabled
; disabled: force the original routine (idempotent re-patch, ~20 cyc)
   LDA #<bbox_check_angle
   STA jt_bca_check+1
   LDA #>bbox_check_angle
   STA jt_bca_check+2
   RTS
bcf_enabled:
; stable = ($01,$9D,$03,$9E) == bca_prevpos ?
   LDA $01
   CMP bca_prevpos
   BNE bcf_moved
   LDA $9D
   CMP bca_prevpos+1
   BNE bcf_moved
   LDA $03
   CMP bca_prevpos+2
   BNE bcf_moved
   LDA $9E
   CMP bca_prevpos+3
   BEQ bcf_stable
bcf_moved:
; record this position, disable the cache (original routine).
   LDA $01
   STA bca_prevpos
   LDA $9D
   STA bca_prevpos+1
   LDA $03
   STA bca_prevpos+2
   LDA $9E
   STA bca_prevpos+3
   LDA #<bbox_check_angle
   STA jt_bca_check+1
   LDA #>bbox_check_angle
   STA jt_bca_check+2
   RTS
bcf_stable:
; same position as last frame. If the computed bitmap belongs to a DIFFERENT
; position, clear it (new stable epoch).
   LDA $01
   CMP bca_cachepos
   BNE bcf_newpos
   LDA $9D
   CMP bca_cachepos+1
   BNE bcf_newpos
   LDA $03
   CMP bca_cachepos+2
   BNE bcf_newpos
   LDA $9E
   CMP bca_cachepos+3
   BEQ bcf_enable
bcf_newpos:
   LDA $01
   STA bca_cachepos
   LDA $9D
   STA bca_cachepos+1
   LDA $03
   STA bca_cachepos+2
   LDA $9E
   STA bca_cachepos+3
   LDA #0
   LDX #59
bcf_clr:
   DEX
   STA RCACHE_COMPUTED,X
   BNE bcf_clr
bcf_enable:
   LDA #<bbox_check_angle_cached
   STA jt_bca_check+1
   LDA #>bbox_check_angle_cached
   STA jt_bca_check+2
   RTS

; --- bbox_check_angle_cached: rotation-coherent bbox visibility ---------------
; Same contract as bbox_check_angle (in: bca_boxp, bca_pxs/pys, bca_afn;
; out: bca_vis, bca_ilo/bca_ihi) and bit-identical results — only cycles
; change. Warm hits skip the per-corner abs/octant/SlopeDiv/tantoangle work
; and re-derive phi with one subtraction; FULL hits skip the tail entirely.
; pseudocode:
;   idx = bca_boxp - rom_bbox                    # node*16 + side*8
;   if COMPUTED[idx]:                            # --- WARM ---
;     if FULL[idx]: return full (0,255)          # a_fine-independent result
;     p1 = sgnext((a_fine - psi1) & 4095)        # cp_havepsi
;     p2 = sgnext((a_fine - psi2) & 4095)
;     goto bca_tail
;   else:                                        # --- COLD ---
;     if viewer inside box: set COMPUTED+FULL; return full
;     box_classify + 2x corner_phi -> RAW p1/p2 (pre-clip!)
;     psi_k = (a_fine - p_k) & 4095 ; store ; set COMPUTED
;     FULL := (span = (p2-p1) & 4095) >= 2048    # a_fine cancels in span
;     goto bca_tail
bbox_check_angle_cached:
   LDA #0
   STA bca_vis
   JSR bcac_index                          ; -> rc_psilo/hi, rc_bytehi, rc_bit
   LDX rc_bytehi
   LDA RCACHE_COMPUTED,X
   AND rc_bit
   BEQ bcac_cold
; --- WARM: full (a_fine-independent) result cached? ---
   LDX rc_bytehi
   LDA RCACHE_FULL,X
   AND rc_bit
   BNE bcac_warm_full
; load psi1, psi2 and re-apply a_fine (cp_havepsi) -> phi
   LDY #0
   LDA (rc_psilo),Y
   STA pa_res
   INY
   LDA (rc_psilo),Y
   STA pa_res+1
   JSR cp_havepsi                          ; -> phi hi in A, lo in Y
   STA bca_p1+1
   STY bca_p1
   LDY #2
   LDA (rc_psilo),Y
   STA pa_res
   INY
   LDA (rc_psilo),Y
   STA pa_res+1
   JSR cp_havepsi                          ; -> phi hi in A, lo in Y
   STA bca_p2+1
   STY bca_p2
   JMP bca_tail
bcac_warm_full:
   JMP full_vis                            ; canonical tail (bca.s): sets
                                           ; ilo/ihi/vis, A/Z = verdict

; --- COLD: compute fresh (box_classify + 2 corner_phi), then populate cache ---
bcac_cold:
; box_classify escapes via PLA PLA RTS when the viewer is INSIDE the box.
; Push a fake return so that escape lands in bcac_cold_inside; the outside
; path returns after the JSR and we pop the fake return.
   LDA #>(bcac_cold_inside-1)
   PHA
   LDA #<(bcac_cold_inside-1)
   PHA
   JSR box_classify
; --- OUTSIDE path: X = boxpos. Drop the fake inside-return we pushed. ---
; Corners are computed INLINE (duplicating the original block) because the
; raw bca_p1/p2 must be snapshotted into the cache BEFORE bca_tail runs:
; the tail CLIPS p1/p2 to +/-CLIPANGLE for corners outside the FOV, and a
; clipped value bakes the (angle-dependent) clip into the position-only
; psi cache — the bug that produced wrong warm results at other angles.
   PLA
   PLA
   TXA
   ASL A
   ASL A
   TAX
; corner1 -> bca_p1  (same corner load as bbox_check_angle)
   LDY bca_cc,X
   SEC
   LDA (bca_boxp),Y
   SBC bca_pxs
   STA pa_dx
   INY
   LDA (bca_boxp),Y
   SBC bca_pxs+1
   STA pa_dx+1
   LDY bca_cc+1,X
   SEC
   LDA (bca_boxp),Y
   SBC bca_pys
   STA pa_dy
   INY
   LDA (bca_boxp),Y
   SBC bca_pys+1
   STA pa_dy+1
   STX bca_ccsave
   JSR corner_phi                          ; -> phi hi in A, lo in Y
   STA bca_p1+1
   STY bca_p1
   LDX bca_ccsave
; corner2 -> bca_p2
   LDY bca_cc+2,X
   SEC
   LDA (bca_boxp),Y
   SBC bca_pxs
   STA pa_dx
   INY
   LDA (bca_boxp),Y
   SBC bca_pxs+1
   STA pa_dx+1
   LDY bca_cc+3,X
   SEC
   LDA (bca_boxp),Y
   SBC bca_pys
   STA pa_dy
   INY
   LDA (bca_boxp),Y
   SBC bca_pys+1
   STA pa_dy+1
   JSR corner_phi                          ; -> phi hi in A, lo in Y
   STA bca_p2+1
   STY bca_p2
; --- populate cache from RAW bca_p1/p2 (pre-clip), then run the tail once ---
   JSR bcac_index
; store psi1 = (a_fine - p1) & 4095, psi2 = (a_fine - p2) & 4095
   SEC
   LDA bca_afn
   SBC bca_p1
   LDY #0
   STA (rc_psilo),Y
   LDA bca_afn+1
   SBC bca_p1+1
   AND #$0F
   INY
   STA (rc_psilo),Y
   SEC
   LDA bca_afn
   SBC bca_p2
   LDY #2
   STA (rc_psilo),Y
   LDA bca_afn+1
   SBC bca_p2+1
   AND #$0F
   INY
   STA (rc_psilo),Y
; set computed bit
   LDX rc_bytehi
   LDA RCACHE_COMPUTED,X
   ORA rc_bit
   STA RCACHE_COMPUTED,X
; full (a_fine-independent) iff span = (p2-p1)&4095 >= 2048 (a_fine cancels).
   SEC
   LDA bca_p2
   SBC bca_p1
   LDA bca_p2+1
   SBC bca_p1+1
   AND #$0F
   CMP #8
   BCC bcac_notfull                        ; span < 2048
   LDX rc_bytehi
   LDA RCACHE_FULL,X
   ORA rc_bit
   STA RCACHE_FULL,X
   JMP bca_tail
bcac_notfull:
; clear the FULL bit (RCACHE_FULL is not cleared at epoch start; a stale set
; bit must be knocked down since warm reads it once COMPUTED is set).
   LDA rc_bit
   EOR #$FF
   LDX rc_bytehi
   AND RCACHE_FULL,X
   STA RCACHE_FULL,X
   JMP bca_tail

; inside -> a_fine-independent full. Set computed+full, return full.
bcac_cold_inside:
   JSR bcac_index
   LDX rc_bytehi
   LDA RCACHE_COMPUTED,X
   ORA rc_bit
   STA RCACHE_COMPUTED,X
   LDA RCACHE_FULL,X
   ORA rc_bit
   STA RCACHE_FULL,X
   JMP full_vis                            ; canonical tail (bca.s)

; bcac_index: from bca_boxp derive rc_psilo/hi (16-bit ptr = RCACHE_PSI +
; idx>>1), rc_bytehi (bitmap byte idx>>6), rc_bit (mask for (idx>>3)&7).
; idx = boxp - rom_bbox = node*16 + side*8 (0..3768).
bcac_index:
; ROM_BBOX is page-aligned (loaders assert), so idx = boxp - base is just
; the boxp low byte plus a single hi-byte subtract.
   LDA bca_boxp
   STA rc_idxlo
   SEC
   LDA bca_boxp+1
   SBC #>ROM_BBOX_C                        ; layout.inc constant
   STA rc_idxhi
   LSR rc_idxhi                             ; idx>>1 (11-bit)
   ROR rc_idxlo
   CLC
   LDA rc_idxlo
   ADC #<RCACHE_PSI
   STA rc_psilo
   LDA rc_idxhi
   ADC #>RCACHE_PSI
   STA rc_psihi
   LSR rc_idxhi                             ; idx>>2
   ROR rc_idxlo
   LSR rc_idxhi                             ; idx>>3 (9-bit: rc_idxhi is 0/1)
   ROR rc_idxlo
   LDA rc_idxlo
   AND #7
   TAX
   LDA rc_bitmask,X
   STA rc_bit
   LSR rc_idxhi                             ; idx>>4 (rc_idxhi -> 0)
   ROR rc_idxlo
   LSR rc_idxlo                             ; idx>>5
   LSR rc_idxlo                             ; idx>>6 (<=58)
   LDA rc_idxlo
   STA rc_bytehi
   RTS

rc_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80
.if BANKED
.segment "ANG_BK"                       ; back to the angle-module segment
.endif
