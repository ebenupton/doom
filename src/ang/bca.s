
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
   LDA #1
   STA bca_vis
   JMP SC_HAS_GAP                          ; FUSED EXIT (2026-07-18): every
                                           ; visible exit chains straight into
                                           ; has_gap on the freshly-written
                                           ; zp_i interval — the caller gets
                                           ; the COMBINED verdict in A/Z, and
                                           ; the bv wrapper's JSR/BNE/JMP
                                           ; round trip is gone. Cull exits
                                           ; still RTS (A=0/Z=1).

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
; JMP-THREADED CHAIN (2026-07-18, enabled by the cold-route
; unification making classify/corners single-caller): classify exits
; dispatch straight to the corner arm (push-push-RTS with the zone-
; composed index), the arm falls into bca_tail via JMP, and the tail's
; exits return to OUR caller — the JSR/RTS shuttles at every stage are
; gone. Inside boxes escape via cx_inside -> full_vis directly.
   JMP box_classify
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
; ENTRY CONTRACT (2026-07-19, Eben's convention flip, adjusted): the
; caller hands p2 IN REGISTERS — A = p2 hi, Y = p2 lo, exactly what
; cp_havepsi returns — and the TAIL owns the bca_p2 stores (the
; rcache cold snapshot still reads them from memory after the check).
; Every entry site dropped its STA/STY pair. NB hi-in-A is pinned by
; cp_havepsi's borrow direction (hi computes last); a lo-in-A flip
; costs a +4 shuffle per corner call — measured worse.
bca_tail:                               ; shared by bbox_check_angle + _cached
; F role bias (option F, 2026-07-17; EPSILON = 15 certified by
; tools/atanexp_cert.py): r1 -= EPS, r2 += EPS — every downstream
; verdict (span/full, the clip windows, the cull tests, the extents)
; becomes a SUPERSET of the exact convention's, so the framebuffer is
; bit-identical. FOLDED (2026-07-18): the bias never lands in memory —
; span carries it as the +30 constant ((r2+15)-(r1-15) = r2-r1+30
; mod 4096, exact by modular arithmetic), and each window test builds
; its biased operands in registers. bca_p1/p2 now stay RAW through the
; tail (the rcache psi snapshots always wanted that), and the full-vis
; exit skips the whole bias.
   STA bca_p2+1                            ; the tail owns the p2 stores
   TAX                                     ; p2 hi rides X past the lo math
   TYA
   STA bca_p2
   SEC
   SBC bca_p1
   STA t0                                  ; raw diff lo (pre +30)
   TXA
   SBC bca_p1+1                            ; (TYA/TXA/STA preserve the borrow)
   TAX                                     ; raw diff hi rides X
   LDA t0
   CLC
   ADC #30
   STA t0                                  ; span' lo
   TXA
   ADC #0
   AND #$0F
   STA t1                                  ; span' hi (u12 fold)
   CMP #8
   BCS full_vis                            ; span >= 2048
ck_left:
; INTERLEAVED clip+lookup (2026-07-16): left window test -> left VATOX
; lookup -> right window test -> right VATOX lookup. Each window test
; leaves EXACTLY the lookup's operands in registers (A = r hi12 after
; the mask, Y = r lo), so the pointer build is one immediate ADC — the
; bca_p1/p2 reloads AND both clamps' memory stores are gone (the
; lookups were the only post-clip readers; span and the rcache psi
; snapshots read the raw values before the tail).
;
; bca_p1/p2 hold r = phi+512 (the afn hoist is pre-biased, view.s).
; Window: tspan = (1024-r) & 4095 <= 1024 <=> r in [0,1024]; r is PURE
; U12 (cp_havepsi stopped sign-extending 2026-07-16), so wrapped phi
; lands at hi in [8,15] and the raw hi compare decides. Only the rare
; outside paths do 16-bit arithmetic.
;
; Carry choreography (all proven, nothing incidental):
;   every lk_* entry has C=0 — BCC arrivals, the ==1024 arms' CLC, and
;   the left clamp's BCC+LDA/TAY; the pointer ADCs' carry-out is
;   CONSTANT 0 (r_hi <= 4, >VATOX+4 never wraps — link-asserted), which
;   LDA (ptr),Y carries into the +-1 adjusts (SBC #0 / ADC #1, no
;   seeds); the out-arms' 16-bit ops inherit C=1 from CMP >= 4 or CPY.
   LDA bca_p1                              ; r1' = (r1 - 15) & 4095, built in
   SEC                                     ; registers (raw r1 stays in memory
   SBC #15                                 ; for the -r1' fold + the snapshots)
   TAY
   LDA bca_p1+1
   SBC #0
   AND #$0F
   CMP #4
   BCC lk_left                             ; r1' < 1024: C=0, A/Y = operands
   BNE ck_left_out
   CPY #0
   BNE ck_left_out
   LDA #254                                ; r1 == 1024 exactly: ilo is the
   BNE il1                                 ; CONSTANT VATOX[1024]-1 = 254
                                           ; (table ends seed-asserted;
                                           ; A != 0 so BNE always takes —
                                           ; no lookup, and lk_* now reads
                                           ; r <= 1023 only)
ck_left_out:
; r1' outside [0,1024]: left corner outside the FOV. tspan-1024 =
; (0 - r1') & 4095 = (15 - r1) & 4095 — the bias folds into the negate
; CONSTANT (raw r1 still in memory). Discard-result 16-bit compare vs
; span (CPX seeds the borrow; only the final carry survives): C=1 iff
; tspan-1024 >= span -> wholly off the left.
   LDA #15
   SBC bca_p1                              ; lo of 15-r1 (C=1 inbound: CMP >= 4
   TAX                                     ; or CPY fall-through)
   LDA #0
   SBC bca_p1+1
   AND #$0F                                ; hi of (15-r1) & 4095 = tspan-1024
   CPX t0                                  ; C = ((tspan-1024).lo >= span.lo)
   SBC t1
   BCS cull                                ; (tspan-2*CLIP) >= span: off left
ck_left_clip:
   BCC lk_lzero                            ; r1 = 0: ilo is the CONSTANT
                                           ; VATOX[0]-1 clamped = 0 — reuse
                                           ; lk_left's own LDA #0 (C=0: the
                                           ; BCS above fell; always taken)
lk_left:
   ADC #>VATOX                             ; C=0 (inbound invariant)
   STA pa_ptr+1
   LDA (pa_ptr),Y                          ; vatox[r1]
   SBC #0                                  ; C=0 (constant carry-out) -> v-1
   BCS il1                                 ; C=1: v >= 1
lk_lzero:
   LDA #0                                  ; v == 0: ilo clamps to 0 (no SEC:
il1:                                       ; the right window test re-seeds C)
   STA bca_ilo
ck_right:
; right window test: r2 IS the right tspan (bias trick) — same shape.
   LDA bca_p2                              ; r2' = (r2 + 15) & 4095, built in
   CLC                                     ; registers (raw r2 stays in memory)
   ADC #15
   TAY
   LDA bca_p2+1
   ADC #0
   AND #$0F
   CMP #4
   BCC lk_right                            ; r2 < 1024: C=0, A/Y = operands
   BNE ck_right_out
   CPY #0
   BEQ lk_r255                             ; r2 == 1024 exactly: ihi is the
                                           ; CONSTANT VATOX[1024]+1 clamped =
                                           ; 255 — ride lk_right's own LDA
                                           ; #255 (Z=1 from CPY: always taken)
ck_right_out:
; mirror of ck_left_out, minus the negate (r2 already IS tspan):
; tspan-1024 vs span, carry-only. C=1 inbound (CMP >= 4 / CPY) seeds
; the SBC #4 — the explicit SEC died with the interleave.
   SBC #4
   CPY t0
   SBC t1
   BCS cull                                ; off right
ck_right_clip:
   BCC lk_r255                             ; r2 = 1024: ihi is the CONSTANT
                                           ; 255 — reuse lk_right's LDA #255
                                           ; (C=0: the BCS above fell)
lk_right:
   ADC #>VATOX                             ; C=0 (inbound invariant)
   STA pa_ptr+1
   LDA (pa_ptr),Y                          ; vatox[r2]
   ADC #1                                  ; C=0 (constant carry-out) -> v+1
   BCC ih1
lk_r255:
   LDA #255                                ; (the old second min(255) was an
ih1:                                       ; identity — A <= 255 by now on
   STA bca_ihi                             ; every path)
; NO ilo > ihi cull (2026-07-19): it is unreachable by construction —
; the arms emit p1 <= p2 (left-to-right silhouette order), the window
; clamps only raise p1 to -512 / cap p2 at +512 (order preserved),
; vatox is monotone, and the -1/+1 adjusts EXPAND the interval, so
; ilo <= ihi always (0/255 clamps included). The python mirror keeps
; its check: any violation would fail check_angle per-call.
; A-CONTRACT (2026-07-09, backface rule 1): every bbox_check_angle exit
; returns the verdict in A (Z valid) AS WELL AS in bca_vis — the byte
; stays for the D-cache store, but callers branch without reloading.
; full_vis is the CANONICAL full-visibility tail (the rcache warm-full
; path and box_classify's inside case JMP here instead of local copies).
visok:
   LDA #1                                  ; visible: bca_vis for the D store,
   STA bca_vis                             ; then the fused has_gap exit — the
   JMP SC_HAS_GAP                          ; walk consumes has_gap's A/Z
cull:                                      ; THE cull exit (the file-head twin
   LDA #0                                  ; is gone, 2026-07-17: every BCS/BCC
   STA bca_vis                             ; cull now reaches FORWARD to here —
   RTS                                     ; ranges link-checked); A=0/Z=1

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
