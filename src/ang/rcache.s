.import vc_bit_mask                     ; defq.s: 1 << (n & 7) table
; Per-bbox cache, keyed by k = node*2 + side (the box ordinal):
;   RC_P1L/P2L/PH planes : psi1/psi2 (12-bit; hi nibbles packed in PH)
;   RCACHE_COMPUTED      : 1 bit/bbox — psi valid for the cache position
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
; RCACHE_STATE+$40..+$7A FREE (RCACHE_FULL died 2026-07-20 — inside
;  boxes just recompute; 59 bytes reclaimed)
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
SEG_CODE
.endif
.export bca_frame
.export bbox_check_angle_cached
bca_frame:
; Per-frame EPOCH KEEPER (lazy refinement 2026-07-20): compare the
; integer position against bca_cachepos.
;   moved      -> record it, zp_rc_moved := $FF. No wipe, no stores
;                 anywhere this frame (the dispatcher routes every
;                 check to the pristine path) — and since nothing
;                 stores while moving, the bitmap needs wiping only
;                 ONCE, at the stop edge, not per moving frame.
;   stationary -> on the moved->stationary EDGE, wipe every valid bit
;                 (unrolled static STA block, 59 x 4 cycles) and arm
;                 the probe (zp_rc_moved := 0); thereafter 4 compares
;                 + a flag test per frame.
; Boot: cachepos/flag garbage resolves safely — any nonzero flag means
; passthru; the driver init seeds $FF so the first stop always wipes.
   LDA $01
   CMP bca_cachepos
   BNE bcf_new
   LDA $9D
   CMP bca_cachepos+1
   BNE bcf_new
   LDA $03
   CMP bca_cachepos+2
   BNE bcf_new
   LDA $9E
   CMP bca_cachepos+3
   BEQ bcf_stat                            ; stationary: forward, past the
                                           ; moved block (nothing may branch
                                           ; across the 177-byte wipe)
bcf_new:
   LDA $01
   STA bca_cachepos
   LDA $9D
   STA bca_cachepos+1
   LDA $03
   STA bca_cachepos+2
   LDA $9E
   STA bca_cachepos+3
   LDA #$FF
   STA zp_rc_moved
   RTS
bcf_stat:
; arm on the moved->stationary edge only
   LDA zp_rc_moved
   BNE bcf_arm
   RTS                                     ; already armed: the common
                                           ; standing-frame exit
bcf_arm:
   LDA #0
.repeat 59, I
   STA RCACHE_COMPUTED+I
.endrepeat
   STA zp_rc_moved                         ; A = 0: probe armed
   RTS

; --- bbox_check_angle_cached: rotation-coherent bbox visibility ---------------
; Same contract as bbox_check_angle (in: bca_boxp, bca_pxs/pys, bca_afn;
; out: bca_vis, bca_ilo/bca_ihi) and bit-identical results — only cycles
; change. Warm hits skip the per-corner abs/octant/SlopeDiv/tantoangle work
; and re-derive phi with one subtraction; FULL hits skip the tail entirely.
; pseudocode:
;   idx = bca_boxp - rom_bbox                    # node*16 + side*8
;   if COMPUTED[idx]:                            # --- WARM ---
;     p1 = sgnext((a_fine - psi1) & 4095)        # cp_havepsi
;     p2 = sgnext((a_fine - psi2) & 4095)
;     goto bca_tail
;   else:                                        # --- COLD ---
;     if viewer inside box: return full (UNCACHED — recomputes)
;     box_classify + 2x corner_phi -> RAW p1 (pre-clip) + memo slot 2
;     psi1 = (a_fine - p1) & 4095 ; psi2 = CPM_PSI[slot2] (identical
;       by the cp_havepsi algebra: memo[slot2] IS corner 2's psi)
;     store both ; set COMPUTED
;     goto bca_tail
bbox_check_angle_cached:
; THE bbox entry, every check, every frame (2026-07-20). Valid block
; offset + bit mask computed INLINE (bcac_index retired):
;   k = node*2 + side ; byte = k>>3 = node>>2 ; bit = 1 << (k & 7)
; and the bit table is vc_bit_mask (defq.s) — same 8 bytes the vertex
; cache uses. Check it always; on a miss the offset/mask pair is
; stashed ($CF/$65 are rcache-owned, they survive the full check) and
; the cache line is written on the way out.
   LDA zp_node_ch_l
   LSR A
   LSR A
   TAX                                     ; X = valid block offset (node>>2)
   LDA zp_node_ch_l
   AND #3
   ASL A
   ORA zp_bbox_side
   TAY                                     ; Y = k & 7
   LDA vc_bit_mask,Y
   AND RCACHE_COMPUTED,X
   BEQ bcac_cold
; --- WARM: psi1/psi2 from the planes, re-apply a_fine (cp_havepsi).
; (The FULL bit died 2026-07-20: its only remaining constituency was
; inside-boxes, which never set COMPUTED now — they re-run the plain
; path each frame, whose classify ladder detects inside almost as
; cheaply as the FULL probe cost EVERY warm hit here.)
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
   JMP bca_tail                            ; p2 rides A/Y, register-only
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
   JMP bca_tail                            ; p2 rides A/Y, register-only
; --- COLD: ONE ROUTE (2026-07-18) — run the pristine bbox_check_angle
; whole, then populate the cache from what it left behind. The two psi
; sources (2026-07-19, the bca_p2 kill): (1) raw p1 survives in memory
; (the bias fold made bca_tail read-only on it), so psi1 = (a_fine -
; p1) & 4095 as before; (2) p2 never lands in memory now — instead
; bca_tail banked corner 2's memo slot in zp_cpm_s2, and CPM_PSI at
; that slot IS corner 2's psi (the serve/store invariant holds on both
; corner_phi exits, and nothing runs between the arm and here to evict
; it). Bit-identical: (a_fine - p2) & 4095 == psi2 by the cp_havepsi
; algebra. The inside escape publishes the $80 marker in zp_cpm_s2
; (no corners ran) and short-circuits to COMPUTED+FULL.
bcac_cold:
   STX rc_bytehi                           ; stash the probe's offset + mask
   LDA vc_bit_mask,Y                       ; (Y intact from the probe) for
   STA rc_bit                              ; the write-back after the check
   JSR bbox_check_angle                    ; COMBINED verdict in A + the angle
   PHP                                     ; bit in C (the A/Z/C contract) —
   PHA                                     ; bank BOTH across the snapshot
   BIT zp_cpm_s2
   BMI bcs_uncacheable                     ; inside-escape ($80 marker): no
                                           ; corners ran, nothing to cache —
                                           ; COMPUTED stays clear and the box
                                           ; re-runs the plain path each frame
                                           ; (the classify ladder's inside
                                           ; detect is the cheap case)
bcs_corners:
; psi1/psi2 staged in pa_dx/pa_dy (dead here). NO span-FULL test any
; more (2026-07-20, the region-cell tail): corner-derived span >= 2048
; verdicts are angle-DEPENDENT under the cell table (a halo box can
; answer [col,255] at one angle and full at another), so the
; a_fine-independent FULL bit retreats to the inside-escape marker
; only — the corner path always leaves FULL clear and warm entries
; recompute the cells from the cached psi.
   SEC
   LDA bca_afn
   SBC bca_p1
   STA pa_dx                               ; psi1 lo
   LDA bca_afn+1
   SBC bca_p1+1
   AND #$0F
   STA pa_dx+1                             ; psi1 hi (0-15)
   LDX zp_cpm_s2
   LDA CPM_PSIL,X
   STA pa_dy                               ; psi2 lo
; pack the PH byte: psi2 hi << 4 (top bits shed by the shifts) | psi1 hi
   LDA CPM_PSIH,X
   ASL A
   ASL A
   ASL A
   ASL A
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
; set computed bit (no FULL bit any more — and with it went the whole
; stale-bit-clearing dance: COMPUTED is the only epoch state)
   LDX rc_bytehi
   LDA RCACHE_COMPUTED,X
   ORA rc_bit
   STA RCACHE_COMPUTED,X
bcs_uncacheable:
   PLA                                     ; the combined check+has_gap verdict
   PLP                                     ; + its C signature, banked at
   RTS                                     ; bcac_cold entry (Z: A unchanged)


; (bcac_index retired 2026-07-20: the offset/mask build is inlined at
;  the one entry and stashed across the check on misses.)

rc_bitmask:
   .byte $01,$02,$04,$08,$10,$20,$40,$80
.if BANKED
SEG_CODE                       ; back to the angle-module segment
.endif

end:
.if BANKED
; (ld65 writes this: SAVE "bsp_render_ang_bk.bin")
.else
.assert end <= $F100, error             ; flat ANG ceiling: RCACHE_STATE
                                        ; squats at $F100 (abi)
.endif

