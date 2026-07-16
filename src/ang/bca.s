
; ============================================================================
; bbox_check_angle — angle-space bbox visibility (bca_check_op default target).
; Mirrors angle_bbox.bbox_check_angle exactly: faithful DOOM R_CheckBBox in
; our negated-phi convention, conservative screen-column extent, no rotation
; (0 muls; per corner: octant fold + 1 SlopeDiv + tantoangle lookup).
;   in : bca_boxp     -> the 8-byte s16 ROM box (top,bot,left,right)
;        bca_pxs/pys  player int position sign-extended s16 (frame-const)
;        bca_afn      a_fine = view angle in fineangles (frame-const)
;   out: bca_vis (1 visible / 0 cull); bca_ilo/bca_ihi (u8 column extent,
;        valid only when bca_vis=1)
; pseudocode (angle_bbox.bbox_check_angle):
;   if box contains player: return full (0,255)      [box_classify short-exit]
;   cc = checkcoord[boxy*4 + boxx]                    [box_classify -> X]
;   p1 = phi(box[cc0]-px, box[cc1]-py)                # LEFT silhouette corner
;   p2 = phi(box[cc2]-px, box[cc3]-py)                # RIGHT silhouette corner
;   -> bca_tail (span / FOV clip / column lookup, shared with the rot cache)
; ============================================================================

full_vis:                               ; span >= ANG180: full width
   LDA #0
   STA bca_ilo
   LDA #255
   STA bca_ihi
   LDA #1                                  ; vis LAST: A/Z = verdict at RTS
   STA bca_vis
   RTS
cull:
   LDA #0                                  ; A=0/Z=1: culled
   STA bca_vis
   RTS

bbox_check_angle:
; (scope opened out to file level so the rotation cache — bbox_check_angle_cached
;  + bca_frame below — can share box_classify, corner_phi and the bca_tail
;  span/clip/column code. Tail labels ck_*/full_vis/cull are unique file-wide.)
; (No bca_vis entry preset: EVERY exit stores the verdict — full_vis/cull/
;  cull_far/visok, and box_classify's inside-escape goes through full_vis —
;  so the old LDA #0/STA preset was 5 dead cycles per check, 2026-07-16.)
; bca_pxs/bca_pys (px,py sign-extended to s16) are precomputed once/frame
; by br_view_setup — frame-constant. Direct unit-test callers set them.
; bca_px/bca_py (s8) are still read below by ins_test/box_pos.
; inside test: left<=px<=right and bot<=py<=top  -> full (0,255)
; left<=px : px-left >= 0
; a_fine (bca_afn) is precomputed once/frame by the caller
; (br_view_setup), not recomputed here — it is frame-constant. Direct
; unit-test callers (test_bca, check_angle_calls) set bca_afn themselves.
; inside test + boxx/boxy classification share one set of subtractions:
   JSR box_classify                        ; -> X = boxpos (inside: full-exit)
; corners: zone/side arms with baked plane operands (zc_corners, ZC
; segment in corner_phi.s) — the cc indirection, the box pointer and
; the ccsave shuttle are gone (2026-07-15). X = boxpos in; raw phi1/2
; land in bca_p1/p2.
   JSR zc_corners
; --- Faithful DOOM R_CheckBBox, unsigned-BAM wraparound (FINEANGLES=4096).
; Our phi = -(DOOM view-relative angle), so DOOM angle1=-p1 (p1 = LEFT
; silhouette, checkcoord order), angle2=-p2 (RIGHT). All arithmetic is
; mod-4096 wraparound, which natively handles a silhouette corner behind
; the view plane — the case the old signed-sort logic mis-narrowed
; (over-culled straddling boxes -> far rooms drawn through walls).
; p1/p2 are s16 whose low 12 bits ARE the BAM value (sign extension adds
; multiples of 4096), so 16-bit sub/add + AND #$0F on the hi byte = BAM.
;
; span = (p2 - p1) & 4095 ; span >= ANG180(2048) -> viewer inside the
; box's angular span -> visible full-width.
;
; bca_tail pseudocode (CLIPANGLE=512, 2*CLIPANGLE=1024):
;   span = (p2 - p1) & 4095 ; if span >= 2048: full (0,255)
;   tspan = (512 - p1) & 4095                            # left corner vs FOV
;   if tspan > 1024: cull if tspan-1024 >= span else p1 = -512
;   tspan = (512 + p2) & 4095                            # right corner vs FOV
;   if tspan > 1024: cull if tspan-1024 >= span else p2 = +512
;   ilo = max(0, vatox[p1+512] - 1) ; ihi = min(255, vatox[p2+512] + 1)
;   cull if ilo > ihi else visible
bca_tail:                               ; shared by bbox_check_angle + _cached
   SEC
   LDA bca_p2
   SBC bca_p1
   STA t0
   LDA bca_p2+1
   SBC bca_p1+1
   AND #$0F
   STA t1
   CMP #8
   BCS full_vis                            ; span >= 2048
ck_left:
; left clip: tspan = (CLIPANGLE - p1) & 4095 ; if tspan > 2*CLIPANGLE:
;   wholly off left when tspan - 2*CLIPANGLE >= span, else p1 = -CLIPANGLE
   SEC
   LDA #<512
   SBC bca_p1
   TAX                                     ; tspan lo
   LDA #>512
   SBC bca_p1+1
   AND #$0F                                ; tspan hi (12-bit)
   CMP #4
   BCC ck_right                            ; tspan < 1024 -> in range
   BNE ck_left_out
   CPX #0
   BEQ ck_right                            ; tspan == 1024 exactly -> in range
ck_left_out:
; tspan > 1024: left corner outside the FOV. Compute tspan-1024 (12-bit) and
; test it against span with a discard-result 16-bit compare (CPX lo / SBC hi:
; only the carry survives; C=1 iff tspan-1024 >= span -> wholly off the left).
; The lo byte rides X, so CPX seeds the borrow WITHOUT touching A (2026-07-16
; hand edit: the old TAY/TXA/CMP/TYA shuffle parked A in Y just to run the
; lo compare through A — 6 cycles of choreography for one flag. Y is dead
; here: ck_done re-seeds it with LDY #0, cull never reads it).
   SEC
   SBC #4                                  ; tspan hi -= 4  (tspan - 1024)
   CPX t0                                  ; C = ((tspan-1024).lo >= span.lo)
   SBC t1
   BCS cull                                ; (tspan-2*CLIP) >= span: off left
ck_left_clip:
   LDA #$00                                ; p1 = -CLIPANGLE = -512 = $FE00
   STA bca_p1
   LDA #$FE
   STA bca_p1+1
ck_right:
; right clip: tspan = (CLIPANGLE + p2) & 4095 ; same, clamping p2 = +512.
; 512's low byte is 0, so the low-byte "add" is just p2's low byte (no
; carry possible) and only the high byte needs the +2 — unlike the left
; side, where 0 - p1_lo genuinely borrows. (Was CLC / LDA #<512 /
; ADC lo / TAX / LDA #>512 / ADC hi: 4 cycles of adding zero.)
   LDX bca_p2                              ; tspan lo = p2 lo
   LDA bca_p2+1
   CLC
   ADC #>512                               ; tspan hi = p2 hi + 2
   AND #$0F
   CMP #4
   BCC ck_done
   BNE ck_right_out
   CPX #0
   BEQ ck_done
ck_right_out:
; mirror of ck_left_out: 16-bit (tspan-1024) >= span test, carry-only
; (same CPX trick — lo rides X from the LDX bca_p2 above, Y dead).
   SEC
   SBC #4
   CPX t0
   SBC t1
   BCS cull                                ; off right
ck_right_clip:
   LDA #<512                               ; p2 = +CLIPANGLE
   STA bca_p2
   LDA #>512
   STA bca_p2+1
ck_done:
; the VATOX tail reads the clipped p1 (left) / p2 (right) directly, both
; in [-512,512] — the old bca_lo/bca_hi staging copies were pure channels
; (dead-write tracker, 2026-07-11) and are gone.
; ilo = VATOX[p1+512]-1 ; ihi = VATOX[p2+512]+1 ; clamp [0,255].
; VATOX holds only the used range (phi in [-512,512] -> index [0,1024]),
; so the bias is +512 (not +1024); the R_CheckBBox clip above guarantees
; lo/hi land in [-512,512].
; address = (VATOX+512) + lo : fold the +512 bias into the base so it's a
; single add (lo is signed s16; two's-complement add lands in range).
   CLC
   LDA #<(VATOX+512)
   ADC bca_p1
   STA pa_ptr
   LDA #>(VATOX+512)
   ADC bca_p1+1
   STA pa_ptr+1
   LDY #0
   LDA (pa_ptr),Y
; vatox[lo]
   SEC
   SBC #1
   BCS il1
   LDA #0
il1:
   STA bca_ilo
   CLC
   LDA #<(VATOX+512)
   ADC bca_p2
   STA pa_ptr
   LDA #>(VATOX+512)
   ADC bca_p2+1
   STA pa_ptr+1
   LDA (pa_ptr),Y                          ; vatox[hi]
   CLC
   ADC #1
   BCC ih1
   LDA #255                                ; (the old second min(255) was an
ih1:                                       ; identity — A <= 255 by now on
   STA bca_ihi                             ; every path)
; if ilo > ihi: cull
   LDA bca_ilo
   CMP bca_ihi
   BEQ visok
   BCS cull_far
; A-CONTRACT (2026-07-09, backface rule 1): every bbox_check_angle exit
; returns the verdict in A (Z valid) AS WELL AS in bca_vis — the byte
; stays for the D-cache store, but callers branch without reloading.
; full_vis is the CANONICAL full-visibility tail (rcache's two warm/store
; paths and corner_phi's inside-escape JMP here instead of local copies).
visok:
   LDA #1                                  ; A=1/Z=0: visible
   STA bca_vis
   RTS
cull_far:                               ; 3-instruction twin of cull (file
   LDA #0                                  ; head): the shared tail is out of
   STA bca_vis                             ; branch range (-167) from here
   RTS                                     ; after the 2026-07-16 exit hoist

; ============================================================================
; ROTATION COHERENCE CACHE
; ---------------------------------------------------------------------------
; The corner angle psi = point_to_angle(corner - player) depends ONLY on the
; integer player position; the view angle enters afterwards as phi = a_fine -
; psi (cp_havepsi). So on a frame where the integer player position is
; unchanged, every bbox's two silhouette psi are invariant and phi can be
; re-derived by one subtraction instead of the abs/octant/SlopeDiv/tantoangle.
; Output is bit-identical (only cycles change) -> no Python mirror needed.
;
