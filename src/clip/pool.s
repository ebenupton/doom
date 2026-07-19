
; ============================================================================
; clip/pool.s — clipper fragment 3 of 10 (module map: clip/header.s).
; Contents: span_init, the O(1) free-list allocator
; (alloc_span / free_span), and the udiv16_8 division primitive.
; Pool layout + field equates (POOL_*) are defined in clip/arith.s;
; ZP names come from src/zp.inc.
; ============================================================================

; ======================================================================
; SPAN_INIT: reset the clipper to one full-screen span
;
; Builds two structures:
;   FREE LIST -- singly-linked chain of unused slots 2..31
;   ACTIVE LIST -- single span (slot 1) covering [0,255] x [0,159]
;
; Called once per frame (linker-resolved; harness calls span_init by symbol)
; pages bank C and JSRs the jump-table slot before the render; the
; Python harness calls it per test frame. Runtime is negligible
; (< 0.5% of total).
;
; Input:  none.
; Output: zp_free = 2 (free chain 2->3->...->31->0),
;         zp_head = 1, slot 1 = full-screen span:
;           XSTART=XLO=0, XEND=DEN=255,
;           TL=TR=OT=IT=Y_BIAS (48), BL=BR=OB=IB=Y_BIAS+159 (207)
;           (screen-space Y is stored BIASED: visible [0,159] -> [48,207])
;         zp_hg_cache = 1 (has_gap coherence cache primed to the span).
; Clobbers A,X.  Python mirror: EndpointClipSpans.__init__.
; ======================================================================
span_init:
.scope
; Free list: slots 2..31 (indices 2,3,...,31).
   LDX #2                                  ; slot 2                                     ; |
   STX zp_free                             ; |
il:
   TXA
   BUMP
; ||
   CMP #NUM_SLOTS                          ; reached end? (= 32)                        ; |
   BCS id                                  ; |
   STA POOL_NEXT,X
   TAX
; ||
   BNE il                                  ; always taken                               ; |
id:
   LDA #0
   STA POOL_NEXT,X
; |
; Active list: slot 1 = full screen with biased Y [Y_BIAS, Y_BIAS+159].
   LDX #1                                  ; slot 1 (index 1)                           ; |
   STX zp_head                             ; |
   STA POOL_NEXT,X
   STA POOL_XLO,X
   STA POOL_XSTART,X
; |
   LDA #Y_BIAS                             ; |
   STA POOL_TL,X
   STA POOL_TR,X
; |
   STA POOL_OT,X
   STA POOL_IT,X
; | OT=IT=Y_BIAS
   LDA #255
   STA POOL_DEN,X
   STA POOL_XEND,X
; |
   LDA #(Y_BIAS + 159)                     ; |
   STA POOL_BL,X
   STA POOL_BR,X
; |
   STA POOL_OB,X
   STA POOL_IB,X
; | OB=IB=Y_BIAS+159
   STX zp_hg_cache                         ; init cache to slot 1 (the initial span)   ; |
   RTS                                     ; |
.endscope

; ======================================================================
; ALLOC_SPAN / FREE_SPAN: O(1) pool allocator via free-list push/pop
;
; alloc_span: pops free list head into X.  Z=0 on success, Z=1 if empty.
; free_span:  pushes slot X back onto free list.  Tail-callable (JMP).
;
; alloc_span — In: none. Out: X = slot (0 + Z=1 if pool exhausted).
;              Clobbers A. All other slot fields are stale — caller fills.
; free_span  — In: X = slot to free (must be unlinked from the active
;              list first). Out: slot pushed on free chain. Clobbers A;
;              X preserved.
; ======================================================================
alloc_span:
; Returns X = new span offset.  Z=1 if failed (X=0), Z=0 if success.
; Caller is responsible for setting POOL_NEXT (tg_append_x or mark_solid linking).
   LDX zp_free
   BEQ af
; |
   LDA POOL_NEXT,X
   STA zp_free
; |
   TXA                                     ; A=X≠0, sets Z=0                           ; |
af:
   RTS
; |

free_span:
   LDA zp_free
   STA POOL_NEXT,X
   STX zp_free
   RTS
; |||

; ======================================================================
; UMUL8: unsigned 8x8 multiply via quarter-square identity
;
; Computes A * zp_mul_b using: a*b = sqr(a+b) - sqr(a-b)
; where sqr(n) = floor(n^2/4).  Two table sets handle a+b < 256 vs
; a+b >= 256.  |a-b| is always < 256 so uses sqr_l/hi in both cases.
; Result: zp_prod_l:zp_prod_h (u16).
;
; This is the hottest subroutine -- called by every interpolation.
; ======================================================================
; (umul8 moved to the fixed $2030 slot below the jump table.)
; The code + full I/O header now live in clip/arith.s (included right
; after clip/header.s so the pin lands at $2030 in the flat build).

; (the historical umul8 alignment pad byte was deleted 2026-07-19 —
; umul8 has been at the pinned $2030 slot in clip/arith.s since
; 2026-07-12 and nothing anchors to the layout below.)

; (interp_core removed — inlined into interp_store below.)

; (smul8 removed — no longer used with u8 Y_BIAS pipeline)

; ======================================================================
; UDIV16_8: unsigned 16/8 restoring division
;
; Divides zp_div_l:hi by zp_div_den, quotient returned in A.
; FAST PATH (most common): div_hi < den => quot fits u8, 8 iterations.
; SLOW PATH: div_hi >= den (seg extrapolation), 16 iterations.
;
; Uses the INC-shift trick: as bits ASL out of div_lo, quotient bits
; accumulate via INC in the vacated positions.  After N iterations,
; div_lo == quotient.
;
; *** HOTTEST LOOP *** -- the 3-instruction shift chain (ASL/ROL/ROL)
; plus trial subtraction account for ~20% of all clipper cycles.
;
; Input:  zp_div_l:zp_div_h = dividend (u16; aliases zp_prod_l/hi so
;         umul8's product is already in place), zp_div_den = divisor
;         (u8, caller guarantees != 0).
; Output: A = quotient. Fast path: full u8 quotient. Slow path: LOW byte
;         of the 16-bit quotient (high byte is left in zp_div_h);
;         callers on that path only need the low 8 bits. Remainder is
;         discarded. Clobbers X and zp_div_l/hi; Y preserved.
;
; pseudocode:
;   if div_hi < den:                      # quotient fits u8
;       rem:acc = dividend (rem in A)     # 8 shift/trial-subtract steps,
;       skip leading 0 quotient bits cheaply, then main loop
;   else:                                 # rare: seg extrapolation
;       16 shift/trial-subtract steps, quotient spread over div_lo:div_hi
;   return div_lo
; ======================================================================
udiv16_8:
.scope
; Cell classify (2026-07-19, measured: 69% of calls have a u8
; dividend, 19% a zero quotient, 88% den >= 16 — and the d16 path
; never fires in the corpus):
;   div_h == 0, num < den            → q = 0, one compare (was 8 paid
;                                      skip iterations, 139 cycles)
;   div_h == 0, den >= 16            → q < 16 PROVABLY (num <= 255 <
;                                      16*den), so the first 4 skip
;                                      iterations can never commit —
;                                      replace them with direct 4-bit
;                                      shifts and enter the unroll at
;                                      its last four copies
;   anything else                    → the original routes, unchanged
   LDA zp_div_h
   BNE dv_wide                             ; 16-bit dividend: original route
   LDA zp_div_den
   CMP #16
   BCC dv_u8_z                             ; small den: full 8-copy walk
   LDA zp_div_l
   CMP zp_div_den
   BCC dv_zero                             ; num < den → quotient 0
; u8 num, den >= 16: rem:shifter = (num >> 4):(num << 4), quotient
; accumulator zeroed, then the last four skip copies finish the job.
; rem = num>>4 <= 15 < den, so no commit is lost by the pre-shift —
; bit-identical to walking all 8 copies.
   TAX                                     ; num banked across the shifts
   ASL A
   ASL A
   ASL A
   ASL A
   STA zp_div_h                            ; shifter = num << 4
   LDA #0
   STA zp_div_l                            ; quotient accumulator
   TXA
   LSR A
   LSR A
   LSR A
   LSR A                                   ; rem = num >> 4
   JMP dskip4
dv_zero:
   LDA #0
   RTS
dv_u8_z:
   LDA #0                                  ; A = initial rem = div_h (known 0
   BEQ dv_u8_all                           ; on this route; always taken)
dv_wide:
; Path select: den > div_hi ⇒ quotient < 256 ⇒ 8-iteration fast path.
; (A = div_h on arrival — it seeds the remainder in the setup below.)
   CMP zp_div_den
   BCS d16
dv_u8_all:
; FAST PATH: quotient fits in 8 bits.  Setup: rem = div_hi,
; div_hi = div_lo, div_lo = 0.  Then skip leading zero-bit
; iterations: shift rem:div_hi left, checking rem vs den each
; time.  Each skip iteration (~19 cyc) is cheaper than the main
; loop iteration (~33 cyc when the trial subtract fails), saving
; ~14 cyc per skipped iteration.
   LDX zp_div_l
   STX zp_div_h
   LDX #0
   STX zp_div_l
; --- Unrolled skip: consume leading zero quotient bits ---
; 8 copies; each branches to its own per-copy commit handler that sets
; X directly (saves DEX per skipped copy: −2 cyc per skip iteration).
; Each copy: shift rem(A):div_hi left one bit; the quotient bit is 1
; iff a bit fell out of A (BCS: rem >= 256 > den) or rem >= den (CMP).
; While bits are 0 there's nothing to write (div_lo is already 0), so
; skipping is pure profit; the first 1 bit jumps to dskip_cN with
; X = iterations remaining (this one included).
   ASL zp_div_h
   ROL A
   BCS dskip_c8
   CMP zp_div_den
   BCS dskip_c8
   ASL zp_div_h
   ROL A
   BCS dskip_c7
   CMP zp_div_den
   BCS dskip_c7
   ASL zp_div_h
   ROL A
   BCS dskip_c6
   CMP zp_div_den
   BCS dskip_c6
   ASL zp_div_h
   ROL A
   BCS dskip_c5
   CMP zp_div_den
   BCS dskip_c5
dskip4:                                    ; the den>=16 u8 cell enters here
   ASL zp_div_h                            ; (4 copies left: q < 16)
   ROL A
   BCS dskip_c4
   CMP zp_div_den
   BCS dskip_c4
   ASL zp_div_h
   ROL A
   BCS dskip_c3
   CMP zp_div_den
   BCS dskip_c3
   ASL zp_div_h
   ROL A
   BCS dskip_c2
   CMP zp_div_den
   BCS dskip_c2
   ASL zp_div_h
   ROL A
   BCS dskip_c1
   CMP zp_div_den
   BCS dskip_c1
; All 8 iterations zero → quotient = 0
   LDA #0
   RTS
dskip_c8:
   LDX #8
   BNE dskip_commit
dskip_c7:
   LDX #7
   BNE dskip_commit
dskip_c6:
   LDX #6
   BNE dskip_commit
dskip_c5:
   LDX #5
   BNE dskip_commit
dskip_c4:
   LDX #4
   BNE dskip_commit
dskip_c3:
   LDX #3
   BNE dskip_commit
dskip_c2:
   LDX #2
   BNE dskip_commit
dskip_c1:
   LDX #1
dskip_commit:
; First 1 quotient bit: commit the trial subtract and enter the main
; loop for the remaining X-1 iterations (X=1 ⇒ done, quotient=1 in
; div_lo). SBC is correct on both arrival paths: via CMP-BCS C=1 and
; rem>=den; via ROL-BCS the true 9-bit rem is 256+A, and 256+A-den
; still fits u8 with C=1.
   SBC zp_div_den                          ; carry already set (from BCS)
   INC zp_div_l                           ; set this quotient bit
   DEX
   BNE dl
; remaining iterations via main loop (rem in A)
   LDA zp_div_l
   RTS
d16:
; SLOW PATH: quotient can exceed u8. Full 16-iteration restoring divide
; over div_lo:div_hi; quotient bits accumulate across div_lo (low 8)
; and div_hi (high 8); only the low byte is returned.
   LDA #0
   LDX #16
; Main loop: remainder kept in A (saves LDA/STA zp_div_rem per iter)
; Per iteration: shift dividend/quotient register left (top bit into
; rem); if rem >= den (or a bit overflowed rem: dl_over) subtract den
; and set the vacated quotient bit via INC div_lo.
dl:
   ASL zp_div_l
   ROL zp_div_h
   ROL A
; ||||||||||||||||||||||||||||||||||||||||
   BCS dl_sub                              ; 9-bit overflow: subtract (C=1)
   CMP zp_div_den
   BCC ds
; |||||||||||||||||||||||||||||
dl_sub:
   SBC zp_div_den                          ; C=1 on both arrival paths
   INC zp_div_l                           ; |||||
ds:
   DEX
   BNE dl
; |||||||||||||
   LDA zp_div_l
   RTS
.endscope
