
; ======================================================================
; SPAN_INIT: reset the clipper to one full-screen span
;
; Builds two structures:
;   FREE LIST -- singly-linked chain of unused slots 2..31
;   ACTIVE LIST -- single span (slot 1) covering [0,255] x [0,159]
;
; Called once per frame. Runtime is negligible (< 0.5% of total).
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
; a+b >= 256.  |a-b| is always < 256 so uses sqr_lo/hi in both cases.
; Result: zp_prod_lo:zp_prod_hi (u16).
;
; This is the hottest subroutine -- called by every interpolation.
; ======================================================================
; (umul8 moved to the fixed $2030 slot below the jump table.)

.byte 0                                 ; 1-byte pad: optimal alignment for umul8

; (interp_core removed — inlined into interp_store below.)

; (smul8 removed — no longer used with u8 Y_BIAS pipeline)

; ======================================================================
; UDIV16_8: unsigned 16/8 restoring division
;
; Divides zp_div_lo:hi by zp_div_den, quotient returned in A.
; FAST PATH (most common): div_hi < den => quot fits u8, 8 iterations.
; SLOW PATH: div_hi >= den (seg extrapolation), 16 iterations.
;
; Uses the INC-shift trick: as bits ASL out of div_lo, quotient bits
; accumulate via INC in the vacated positions.  After N iterations,
; div_lo == quotient.
;
; *** HOTTEST LOOP *** -- the 3-instruction shift chain (ASL/ROL/ROL)
; plus trial subtraction account for ~20% of all clipper cycles.
; ======================================================================
udiv16_8:
.scope
LDA zp_div_hi
CMP zp_div_den
BCS d16
; FAST PATH: quotient fits in 8 bits.  Setup: rem = div_hi,
; div_hi = div_lo, div_lo = 0.  Then skip leading zero-bit
; iterations: shift rem:div_hi left, checking rem vs den each
; time.  Each skip iteration (~19 cyc) is cheaper than the main
; loop iteration (~33 cyc when the trial subtract fails), saving
; ~14 cyc per skipped iteration.
LDX zp_div_lo
STX zp_div_hi
LDX #0
STX zp_div_lo
; --- Unrolled skip: consume leading zero quotient bits ---
; 8 copies; each branches to its own per-copy commit handler that sets
; X directly (saves DEX per skipped copy: −2 cyc per skip iteration).
ASL zp_div_hi
ROL A
BCS dskip_c8
CMP zp_div_den
BCS dskip_c8
ASL zp_div_hi
ROL A
BCS dskip_c7
CMP zp_div_den
BCS dskip_c7
ASL zp_div_hi
ROL A
BCS dskip_c6
CMP zp_div_den
BCS dskip_c6
ASL zp_div_hi
ROL A
BCS dskip_c5
CMP zp_div_den
BCS dskip_c5
ASL zp_div_hi
ROL A
BCS dskip_c4
CMP zp_div_den
BCS dskip_c4
ASL zp_div_hi
ROL A
BCS dskip_c3
CMP zp_div_den
BCS dskip_c3
ASL zp_div_hi
ROL A
BCS dskip_c2
CMP zp_div_den
BCS dskip_c2
ASL zp_div_hi
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
SBC zp_div_den                          ; carry already set (from BCS)
INC zp_div_lo                           ; set this quotient bit
DEX
BNE dl
; remaining iterations via main loop (rem in A)
LDA zp_div_lo
RTS
d16:
LDA #0
LDX #16
; Main loop: remainder kept in A (saves LDA/STA zp_div_rem per iter)
dl:
ASL zp_div_lo
ROL zp_div_hi
ROL A
; ||||||||||||||||||||||||||||||||||||||||
BCS dl_over                             ; |||||
CMP zp_div_den
BCC ds
; |||||||||||||||||||||||||||||
SBC zp_div_den                          ; |
dl_commit:
INC zp_div_lo                           ; |||||
ds:
DEX
BNE dl
; |||||||||||||
LDA zp_div_lo
RTS
; |||
dl_over:
SBC zp_div_den                          ; carry already set from BCS dl_over
JMP dl_commit
.endscope
