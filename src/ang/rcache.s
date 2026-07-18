; Per-bbox cache, keyed by k = node*2 + side (the box ordinal):
;   RC_P1L/P2L/PH planes : psi1/psi2 (12-bit; hi nibbles packed in PH)
;   RCACHE_COMPUTED      : 1 bit/bbox — psi valid for the cache position
;   RCACHE_FULL          : 1 bit/bbox — result is a_fine-INDEPENDENT full
;                          (viewer inside box, OR span>=ANG180); warm returns full
;
; bca_frame (per frame, from br_view_setup) SMC-patches the bbox.s call site (bca_check_op) between
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
RC_PH_S  = $0600                        ; the DEFQ page (FREE since d541b80;
                                        ; moved from $F000 2026-07-17 — the
                                        ; unrolled slope_div slow arm grew
                                        ; flat ANG past $F000 and CORRUPTED
                                        ; this plane: rotcache caught it)
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
;   out: bca_check_op (the bbox.s call-site JSR) operand SMC-patched to
;        bbox_check_angle (moved frame or cache disabled: verbatim original,
;        zero per-check overhead) or to bbox_check_angle_cached (stable
;        frame); COMPUTED bitmap cleared on the first stable frame at a new
;        position (new cache epoch).
; pseudocode:
;   if not ENABLE:        patch original; return
;   if pos != prevpos:    prevpos = pos; patch original; return    # moved
;   if pos != cachepos:   cachepos = pos; COMPUTED[:] = 0          # new epoch
;   patch cached                                                   # stable
.export bca_frame
.export bbox_check_angle_cached
; (SMC dispatch retired 2026-07-18: bca_frame now sets/clears bit 1 of
; zp_bv_mode and br_bbox_visible branches on it — cache and non-cache
; paths are plain code, selected by data.)
bca_frame:
   LDA RCACHE_ENABLE
   BNE bcf_enabled
bcf_off:
   LDA zp_bv_mode
   AND #$FD                                ; clear the rc bit
   STA zp_bv_mode
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
   JMP bcf_off
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
   LDA zp_bv_mode
   ORA #$02                                ; set the rc bit
   STA zp_bv_mode
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
; (no bca_vis entry preset — every exit tail stores it; see bca.s)
                                        ; their own ladders (cold re-writes)
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

; --- COLD: ONE ROUTE (2026-07-18) — run the pristine bbox_check_angle
; whole, then populate the cache from what it left behind. Two facts
; make this possible now: (1) the bias fold made bca_tail READ-ONLY on
; bca_p1/p2, so the RAW pre-clip phis survive the whole check (the old
; split classify/corners route existed only to snapshot before the
; tail's clamp write-backs — a clipped value baked the angle-dependent
; clip into the position-only psi cache); (2) the inside escape now
; publishes the p1/p2 FULL-span SENTINEL (cx_inside, corner_phi.s), so
; the ordinary span test below marks it FULL — the zone flag and the
; forced-inside route died with the zone byte (2026-07-19).
bcac_cold:
   JSR bbox_check_angle                    ; COMBINED verdict in A (the fused
   PHA                                     ; exits ran has_gap); raw p1/p2
   JSR bcac_index                          ; survive for the store
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
bcac_setfull:
   LDA RCACHE_FULL,X
   ORA rc_bit
   STA RCACHE_FULL,X
   PLA                                     ; the combined check+has_gap verdict
   RTS                                     ; (A/Z) banked at bcac_cold entry
bcac_notfull:
; clear the FULL bit (RCACHE_FULL is not cleared at epoch start; a stale set
; bit must be knocked down since warm reads it once COMPUTED is set).
   LDA rc_bit
   EOR #$FF
   AND RCACHE_FULL,X                       ; (X = rc_bytehi still)
   STA RCACHE_FULL,X
   PLA
   RTS


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
