.import vc_bit_mask                     ; defq.s: 1 << (n & 7) table
; Per-bbox cache, keyed by k = node*2 + side (the box ordinal):
;   RC_P1L/P2L/PH planes : psi1/psi2 (12-bit; hi nibbles packed in PH)
;   RCACHE_COMPUTED      : 1 bit/bbox — psi valid for the cache position
;
;Frame classing is the zp_rc_moved flag (set here in bca_frame, read by
; bbox.s br_bbox_visible): moving frames dispatch straight to
; bbox_check_angle — no probe, no stores, bitmap stale-but-unread.
; The moved->stationary edge clears RCACHE_COMPUTED and arms the probe;
; standing frames then come here and entries repopulate lazily.

; PSI store = page-split SoA planes (2026-07-15; re-keyed by SIDE
; 2026-07-20): page = zp_bbox_side (0/1), byte index = node (u8,
; n_nodes <= 256 asserted at pack time) — no k derivation, no carry
; games. psi values are 12-bit, so the two
; hi nibbles PACK into one plane: PH = psi1_hi | psi2_hi<<4. Three
; planes x 2 pages; the side pages are independently placed, so
; the flat set scatters over audited free fragments and the $5000
; CODE-tail carve is GONE (flat CODE now runs to $5800 — main_tail).
.if BANKED
RC_P1L_0 = $AD00                        ; bank L2 (old PSI head; $B300-$B45F freed)
RC_P1L_1 = $AE00
RC_P2L_0 = $AF00
RC_P2L_1 = $B000
RC_PH_0  = $B100
RC_PH_1  = $B200
.else
RC_P1L_0 = $1A00                        ; flat fragments (audited free):
RC_P1L_1 = $9700                        ; below the VXC planes (DIRs
RC_P2L_0 = $D400                        ;   asserted <= $9700 now)
RC_P2L_1 = $DA00                        ; after VWHC
RC_PH_0  = $DB00
RC_PH_1  = $0600                        ; the DEFQ page (FREE since d541b80;
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
;   if COMPUTED[idx]:                            # --- HIT ---
;     p1 = sgnext((a_fine - psi1) & 4095)        # cp_havepsi
;     p2 = sgnext((a_fine - psi2) & 4095)
;     goto bca_tail
;   else:                                        # --- MISS ---
;     stash offset/mask ; tail-call bbox_check_angle — the stores
;     fire at birth inside it (corner2_* banks psi1, bca_tail banks
;     psi2 + sets COMPUTED; an inside box runs no corners, fires no
;     stores, stays naturally uncacheable)
bbox_check_angle_cached:
; THE bbox entry, every check, every frame (2026-07-20). Valid block
; offset + bit mask computed INLINE (bcac_index retired):
;   k = node*2 + side ; byte = k>>3 = node>>2 ; bit = 1 << (k & 7)
; and the bit table is vc_bit_mask (defq.s) — same 8 bytes the vertex
; cache uses. Check it always; on a miss the offset/mask pair is
; stashed ($CF/$65 are rcache-owned, they survive the full check) for
; the store-at-birth hooks inside the check (corner2_*/bca_tail).
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
   BEQ bcac_miss
; --- HIT: psi1/psi2 from the planes, re-apply a_fine (cp_havepsi).
; (The FULL bit died 2026-07-20: its only remaining constituency was
; inside-boxes, which never set COMPUTED now — they re-run the plain
; path each frame, whose classify ladder detects inside almost as
; cheaply as the FULL probe cost EVERY warm hit here.)
; page = zp_bbox_side, index = node (cp_havepsi eats Y; zp_node_ch_l
; is stable across it, so the second lookup just reloads it).
   LDY zp_node_ch_l
   LDA zp_bbox_side
   BNE bw_s1
   LDA RC_P1L_0,Y
   STA pa_res
   LDA RC_PH_0,Y
   AND #$0F
   STA pa_res+1
   JSR cp_havepsi                          ; -> phi hi in A, lo in Y
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   LDA RC_P2L_0,Y
   STA pa_res
   LDA RC_PH_0,Y
   LSR A
   LSR A
   LSR A
   LSR A
   STA pa_res+1
   JSR cp_havepsi
   JMP bca_tail_postrc                     ; p2 rides A/Y, register-only
bw_s1:
   LDA RC_P1L_1,Y
   STA pa_res
   LDA RC_PH_1,Y
   AND #$0F
   STA pa_res+1
   JSR cp_havepsi
   STA bca_p1+1
   STY bca_p1
   LDY zp_node_ch_l
   LDA RC_P2L_1,Y
   STA pa_res
   LDA RC_PH_1,Y
   LSR A
   LSR A
   LSR A
   LSR A
   STA pa_res+1
   JSR cp_havepsi
   JMP bca_tail_postrc                     ; p2 rides A/Y, register-only
; --- MISS: store-at-birth (2026-07-20, Eben's 'insert the cache into
; the workings') — stash the probe's offset/mask for the check to
; publish, then TAIL-CALL the pristine check. The stores live where
; the psi values are born: corner2_* (bca.s) banks psi1 while it is
; still live in pa_res, and bca_tail banks psi2 + sets COMPUTED from
; the stash. No verdict banking, no residue scavenging, no memo-slot
; coupling, no $80 marker: an inside box runs no corners, fires no
; stores, and stays naturally uncacheable. The A/Z/C verdict flows
; straight through to the walk.
bcac_miss:
   STX rc_bytehi                           ; stash the probe's offset + mask
   LDA vc_bit_mask,Y                       ; (Y intact from the probe) for
   STA rc_bit                              ; bca_tail's publish
   JMP bbox_check_angle

; (bcac_index retired 2026-07-20: the offset/mask build is inlined at
;  the one entry and stashed across the check on misses.)
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

