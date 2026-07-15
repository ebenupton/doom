; Per-bbox cache, keyed by k = node*2 + side (the box ordinal):
;   RC_P1L/P2L/PH planes : psi1/psi2 (12-bit; hi nibbles packed in PH)
;   RCACHE_COMPUTED      : 1 bit/bbox — psi valid for the cache position
;   RCACHE_FULL          : 1 bit/bbox — result is a_fine-INDEPENDENT full
;                          (viewer inside box, OR span>=ANG180); warm returns full
;
; bca_frame (per frame, from br_view_setup) SMC-patches jt_bca_check between
; bbox_check_angle (moved frame: verbatim, zero overhead) and
; bbox_check_angle_cached (stable frame). Stability = integer position
; ($01/$9D/$03/$9E) unchanged since last frame. First stable frame at a new
; position clears RCACHE_COMPUTED so entries repopulate lazily.

; PSI store = page-split SoA planes (2026-07-15): entry ordinal
; k = node*2 + side (u9; senior page = node bit 7, which falls out of
; the k-derivation ASL as the CARRY). psi values are 12-bit, so the two
; hi nibbles PACK into one plane: PH = psi1_hi | psi2_hi<<4. Three
; planes x 2 pages; junior/senior pages are independently placed, so
; the flat set scatters over audited free fragments and the $5000
; CODE-tail carve is GONE (flat CODE now runs to $5800 — main_tail).
.if BANKED
RC_P1L_J = $AD00                        ; bank L2 (old PSI head; $B300-$B45F freed)
RC_P1L_S = $AE00
RC_P2L_J = $AF00
RC_P2L_S = $B000
RC_PH_J  = $B100
RC_PH_S  = $B200
.else
RC_P1L_J = $1A00                        ; flat fragments (audited free):
RC_P1L_S = $9700                        ; below the VXC planes (DIRs
RC_P2L_J = $D400                        ;   asserted <= $9700 now)
RC_P2L_S = $DA00                        ; after VWHC
RC_PH_J  = $DB00
RC_PH_S  = $F000                        ; below the old TA_HI shadow
.endif
; State block (bitmaps + wipe keys) via abi.inc — same internal layout,
; flat base moved $5760 -> $F100 with the carve release:
RCACHE_COMPUTED = RCACHE_STATE          ; 59 bytes (bit per k>>3 group)
RCACHE_FULL = RCACHE_STATE + $40        ; 59 bytes
bca_prevpos = RCACHE_STATE + $80        ; 4 bytes: last frame's int position
bca_cachepos = RCACHE_STATE + $84       ; 4 bytes: position COMPUTED is valid for
.assert RCACHE_STATE + $88 = RCACHE_ENABLE, error, "rcache layout drifted from abi.inc"
; RCACHE_ENABLE comes from abi.inc; nonzero -> cache may engage (drivers set it;
                                        ; harness default 0 keeps every existing test
                                        ; on the original path, byte- and cycle-exact)
; scratch for the cached routine (dead outside a check)
rc_idxlo    = t0                        ; index-calc scratch (t0/t1 free at entry)
rc_idxhi    = t1
; ($C4/$C5 freed 2026-07-15: the PSI pointer died with the plane
;  conversion — k rides Y and the senior page is an arm.)
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
; (X still = rc_bytehi: AND zp doesn't touch it)
   LDA RCACHE_FULL,X
   AND rc_bit
   BNE bcac_warm_full
; load psi1, psi2 from the planes and re-apply a_fine (cp_havepsi).
; k = node*2+side rides Y; the ASL's carry IS the senior-page select.
   LDA zp_node_ch_l
   ASL A
   ORA zp_bbox_side
   STA rc_idxlo                            ; k & 255 (cp_havepsi eats Y)
   TAY
   BCS bw_hi
   LDA RC_P1L_J,Y
   STA pa_res
   LDA RC_PH_J,Y
   AND #$0F
   STA pa_res+1
   JSR cp_havepsi                          ; -> phi hi in A, lo in Y
   STA bca_p1+1
   STY bca_p1
   LDY rc_idxlo
   LDA RC_P2L_J,Y
   STA pa_res
   LDA RC_PH_J,Y
   LSR A
   LSR A
   LSR A
   LSR A
   STA pa_res+1
   JSR cp_havepsi
   STA bca_p2+1
   STY bca_p2
   JMP bca_tail
bw_hi:
   LDA RC_P1L_S,Y
   STA pa_res
   LDA RC_PH_S,Y
   AND #$0F
   STA pa_res+1
   JSR cp_havepsi
   STA bca_p1+1
   STY bca_p1
   LDY rc_idxlo
   LDA RC_P2L_S,Y
   STA pa_res
   LDA RC_PH_S,Y
   LSR A
   LSR A
   LSR A
   LSR A
   STA pa_res+1
   JSR cp_havepsi
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
   JSR bcac_index                          ; (bitmap byte/bit only now)
; psi1/psi2 = (a_fine - pK) & 4095, staged in pa_dx/pa_dy (dead here),
; hi nibbles packed for the PH plane; one armed 3-store drop.
   SEC
   LDA bca_afn
   SBC bca_p1
   STA pa_dx
   LDA bca_afn+1
   SBC bca_p1+1
   AND #$0F
   STA pa_dx+1
   SEC
   LDA bca_afn
   SBC bca_p2
   STA pa_dy
   LDA bca_afn+1
   SBC bca_p2+1
   ASL A
   ASL A
   ASL A
   ASL A                                   ; psi2 hi nibble << 4 (top bits shed)
   ORA pa_dx+1
   STA pa_dx+1                             ; packed PH byte
   LDA zp_node_ch_l
   ASL A
   ORA zp_bbox_side
   TAY                                     ; k & 255; C = senior
   BCS bcs_hi
   LDA pa_dx
   STA RC_P1L_J,Y
   LDA pa_dy
   STA RC_P2L_J,Y
   LDA pa_dx+1
   STA RC_PH_J,Y
   JMP bcs_done
bcs_hi:
   LDA pa_dx
   STA RC_P1L_S,Y
   LDA pa_dy
   STA RC_P2L_S,Y
   LDA pa_dx+1
   STA RC_PH_S,Y
bcs_done:
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
; (X = rc_bytehi still — nothing since the COMPUTED store touched it)
   LDA RCACHE_FULL,X
   ORA rc_bit
   STA RCACHE_FULL,X
   JMP bca_tail
bcac_notfull:
; clear the FULL bit (RCACHE_FULL is not cleared at epoch start; a stale set
; bit must be knocked down since warm reads it once COMPUTED is set).
   LDA rc_bit
   EOR #$FF
   AND RCACHE_FULL,X                       ; (X = rc_bytehi still)
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

bcac_index:
; Bitmap byte/bit from (zp_node_ch_l, zp_bbox_side) — the PSI pointer
; died with the plane conversion (2026-07-15):
;   byte = k>>3 = node>>2 (exact: side and node bit 0 shift out)
;   bit  = 1 << (k & 7) = 1 << (((node & 3) << 1) | side)
   LDA zp_node_ch_l
   LSR A
   LSR A
   STA rc_bytehi
   LDA zp_node_ch_l
   AND #3
   ASL A
   ORA zp_bbox_side
   TAX
   LDA rc_bitmask,X
   STA rc_bit
   RTS

rc_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80
.if BANKED
.segment "ANG_BK"                       ; back to the angle-module segment
.endif
