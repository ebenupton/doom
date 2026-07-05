
compute_crossover:
.scope
; den = |d0| + |d1| (u16; sufficient since post-wrapper |d| ≤ ~32800)
LDA zp_tmp0
CLC
ADC zp_tmp2
STA zp_cc_den_lo
; |
LDA zp_tmp1
ADC zp_tmp3
STA zp_cc_den_hi
; |
ORA zp_cc_den_lo
BEQ early_none
; |
; ex = ox1 - ox0 (always ≥ 1 since ox0 < ox1 in tighten)
LDA zp_ox1
SEC
SBC zp_ox0
BNE ex_ok
; |
early_none:
LDA #0
RTS
ex_ok:
STA zp_mul_b                            ; |
; Low u16 of num = |d0|_lo * ex (one umul8 call).
; zp_prod_lo:hi aliases zp_div_lo:hi.
LDA zp_tmp0
JSR umul8
; |
; Fast path: if den fits u8 (cc_den_hi == 0), then |d0|+|d1| ≤ 255
; so both |d0| and |d1| fit u8 → num fits u16. Quot fits u8
; (bounded by ex), so num_hi < den, letting us run the 8-iter
; restoring divide directly.
LDA zp_cc_den_hi
BNE slow_setup
; |
LDA zp_cc_den_lo
STA zp_div_den
; |
; Setup: rem(A) = num_hi, div_hi = num_lo, div_lo = 0 (quot accum).
LDA zp_div_hi                           ; A = rem = num_hi                      ; |
LDX zp_div_lo
STX zp_div_hi
; div_hi = num_lo (shift source)     ; |
LDX #0
STX zp_div_lo
; div_lo = 0 (quotient accumulator)  ; |
LDX #8                                  ; |
fast_loop:
ASL zp_div_lo
ROL zp_div_hi
ROL A
; |
BCS fast_over                           ; |
CMP zp_div_den
BCC fast_next
; |
SBC zp_div_den                          ; |
fast_commit:
INC zp_div_lo                           ; |
fast_next:
DEX
BNE fast_loop
; |
LDA zp_div_lo                           ; A = quot                             ; |
JMP cx_from_quot                        ; |
fast_over:
SBC zp_div_den                          ; carry already set from BCS fast_over
JMP fast_commit
; (1-byte cx fast pad removed)

slow_setup:
; Slow path: build the u24 num and run the u24/u16 restoring divide.
; The first umul8 result gets copied to cc_num_lo:mid (needed because
; the second umul8 below clobbers zp_prod_*).
LDA zp_prod_lo
STA zp_cc_num_lo
LDA zp_prod_hi
STA zp_cc_num_mid
ZERO zp_cc_num_hi
LDA zp_tmp1
BEQ num_done
; |d0|_hi == 0 → num is already u16
; Add |d0|_hi * ex, shifted up one byte into mid:hi.
JSR umul8
LDA zp_prod_lo
CLC
ADC zp_cc_num_mid
STA zp_cc_num_mid
LDA zp_prod_hi
ADC zp_cc_num_hi
STA zp_cc_num_hi
num_done:
; 8-iter restoring u24/u16 divide. Uses the same INC-the-shift-source
; trick: quot bits accumulate in cc_num_lo as the original bits get
; ASL'd out, so cc_num_lo == quot after 8 iterations.
LDY #8
slow_loop:
ASL zp_cc_num_lo
ROL zp_cc_num_mid
ROL zp_cc_num_hi
BCS slow_force_commit                   ; rem overflowed u16 → must subtract
; Compare rem (num_hi:num_mid) with den (cc_den_hi:cc_den_lo).
LDA zp_cc_num_hi
CMP zp_cc_den_hi
BCC slow_skip
BNE slow_do_commit
LDA zp_cc_num_mid
CMP zp_cc_den_lo
BCC slow_skip
slow_do_commit:
slow_force_commit:
LDA zp_cc_num_mid
SEC
SBC zp_cc_den_lo
STA zp_cc_num_mid
LDA zp_cc_num_hi
SBC zp_cc_den_hi
STA zp_cc_num_hi
INC zp_cc_num_lo                        ; set current quot bit (bit 0 after ASL)
slow_skip:
DEY
BNE slow_loop
LDA zp_cc_num_lo                        ; A = quot

cx_from_quot:
CLC
ADC zp_ox0
; |
BEQ none                                ; |
CMP zp_ox0
BEQ none
; cx at left edge: not strictly inside ; |
CMP zp_ox1
BCS none
; cx >= ox1: not strictly inside       ; |
RTS                                     ; |
none:
LDA #0
RTS
.endscope
