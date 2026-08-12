; ============================================================================
; clip/arith.s — clipper fragment 2 of 10 (see clip/header.s for the module
; map and entry contracts). Contents: udiv16_8 (first code in the CLIP
; segment; umul8 unified into bsp/header.s 2026-08-09 — main RAM, imported
; here — and the old $2030 first-code pin died with it), the
; span-pool field equates (POOL_*), Y_BIAS, sqr table aliases, the records /
; LINE_OUT / rasteriser interface constants, the ZP layout notes, and
; s16_interp (at the end — moved from dcl_s16.s 2026-08-09).
; Sibling cross-refs: pool.s (allocator + udiv16_8), interp.s (interp_store),
; dcl.s (records + LINE_OUT writers), tfr.s (records consumer).
; ============================================================================

; ======================================================================
; (umul8 UNIFIED into bsp/header.s 2026-08-09: the bit-identical local
; copy there — main RAM, always mapped, reachable from the bank-C
; clipper — is now THE multiplier; this file's copy and its $2030
; first-code pin are gone. clip/header.s imports the symbol; callers
; are unchanged. udiv16_8 below is now the first code in the CLIP
; segment.)
; ======================================================================

; ======================================================================
; (udiv16_8 moved here from clip/pool.s 2026-08-09: the mul/div pair
; lives together — umul8's product aliases udiv16_8's dividend — and
; the arithmetic primitives all home in arith.s per the file-DAG
; organization. Callers: dcl.s, interp.s, s16_interp below.)
; ======================================================================
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
; ======================================================================
; --- rare arms as ISLANDS above the entry (2026-08-12; scope-free —
; the ip_* labels are file-unique in arith.s): the hot sum<256 /
; no-round-carry path falls straight into udiv16_8 below ---
ip_uo:
   LDA SQR2_LO,X                           ; (carry already set from BCS)
   SBC SQR_LO,Y
   STA zp_prod_l
   LDA SQR2_HI,X
   SBC SQR_HI,Y
   STA zp_prod_h
   LDA zp_div_den                          ; per-arm rounding tail (keeps
   LSR A                                   ; the hot arm fall-through)
   CLC
   ADC zp_prod_l
   STA zp_prod_l
   BCS ip_rn_c
   JMP udiv16_8
ip_rn_c:
   INC zp_prod_h
   JMP udiv16_8                            ; tail-call
umul_round_div:
; umul8 INLINED (2026-08-09 — this one site carries HALF of all umul8
; traffic, 35 calls/frame; the JSR/RTS was 417 cyc/frame). Identical
; quarter-square math on the same SQR_* tables (abi.inc — main RAM,
; reachable from bank C). Each sum arm carries its own rounding tail so
; the common sum<256 arm keeps umul8's zero-overhead fall-through; the
; rare round-carry bump is shared (ip_rn_c).
   TAX                                     ; stash |dy| in X
   SEC
   SBC zp_mul_b
   BCS ip_pos
   EOR #$FF
   ADC #1                                  ; |dy - offset| (C=0 from SBC)
ip_pos:
   TAY                                     ; Y = |diff|
   TXA
   CLC
   ADC zp_mul_b
   TAX                                     ; X = sum & $FF
   BCS ip_uo                               ; sum >= 256: sqr2 tables
   LDA SQR_LO,X
   SEC
   SBC SQR_LO,Y
   STA zp_prod_l
   LDA SQR_HI,X
   SBC SQR_HI,Y
   STA zp_prod_h
; 16-bit add of den//2 into the product (prod aliases the div dividend)
   LDA zp_div_den
   LSR A
   CLC
   ADC zp_prod_l
   STA zp_prod_l
   BCS ip_rn_c                             ; round-carry rare (3.6% —
; (falls THROUGH into udiv16_8 — the tail-call JMP died 2026-08-12)
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
   ZERO zp_div_l                          ; quotient accumulator
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

; === Pool constants and field offsets ===
; The span pool uses block layout at $0400: each field is a contiguous
; 32-byte block, one byte per slot.  Slot N is at POOL_FIELD + N.
; X register holds the slot number directly (0-31).
; Slot 0 is the null sentinel; slot 1 is the initial active span;
; slots 2..31 start on the free list.
;
; Field blocks (32 bytes each):
;   NEXT     linked-list next (slot number, 0 = end)
;   XLO      line anchor x left  (immutable after span creation)
;   DEN      xhi - xlo (precomputed denominator for interp, immutable)
;   TL       top y at XLO
;   BL       bot y at XLO
;   TR       top y at XLO+DEN
;   BR       bot y at XLO+DEN
;   XSTART   active range start (mutable: shrunk by mark_solid / tighten fragments)
;   XEND     active range end   (mutable)
;   OT       min(TL, TR) — outer top (precomputed bbox)
;   OB       max(BL, BR) — outer bot (precomputed bbox)
;   IT       max(TL, TR) — inner top (precomputed bbox)
;   IB       min(BL, BR) — inner bot (precomputed bbox)
;
; Spans interpolate y at any column x ∈ [XSTART, XEND] using the line through
; (XLO, TL/BL) — (XLO+DEN, TR/BR). XLO/DEN need not match XSTART/XEND once
; a span has been narrowed: the line is preserved across mark_solid splits
; and left/right-fragment creation in tighten, so no interp_store is needed
; for those operations.
POOL = $0400
POOL_NEXT = $0400
POOL_XLO = $0420
POOL_DEN = $0440                        ; precomputed xhi - xlo (denominator for interp)
POOL_TL = $0460
POOL_BL = $0480
POOL_TR = $04A0
POOL_BR = $04C0
POOL_XSTART = $04E0
POOL_XEND = $0500
POOL_OT = $0520
POOL_OB = $0540
POOL_IT = $0560
POOL_IB = $0580
NUM_SLOTS = 32

Y_BIAS = 48                             ; bias Y so visible [0,159] maps to [48,207] within u8
VIS_YMAX = Y_BIAS + 159                 ; = 207: maximum biased visible Y

; (sqr table aliases deleted with the unified umul8 2026-08-09 — the
; quarter-square tables at SQR_BASE are read only by bsp/header.s's
; umul8 now; abi.inc owns the base.)

; === RETIRED tighten ZP notes (rewritten 2026-07-12) ===
; The blocks that lived here — "seg value cache $A0-$A4", "running seg
; bounds $A5-$A7", "static seg Y bbox $A8-$AB", "tighten pre-dominance
; flags $B6", "tighten secondary seg params $B2-$B5" — all described
; the RETIRED per-span tighten (tg_go / mel / span_tighten; see the
; retirement note in clip/query.s).  None of those symbols exist in
; src/zp.inc any more, and $A0-$A7 belong to the bsp/ang modules today.
; src/zp.inc is the single source of truth for the live map.

; === Draw-clipped-line ZP ($A8-$B9) ===
; Caller sets zp_line_xl/yl/xr/yr ($A8-$AB); DCL computes dx/dy/ylo/yhi
; ($AC-$AF); seg_start $B0/$B1; CB-clip working set $B2-$B9 (overlaid
; with the s16 line HI bytes — phase-disjoint, see zp.inc).  $A8 also
; overlaid the old zp_ms_emit flag (GC'd 2026-07-12: it had no 6502 reader)
; any more (the harness pins it to 0).
; ===== DCL records hook ($BC-$BE) =====
; When zp_dcl_rec_buf_h ($BD) is non-zero, dcl_emit_segment appends ONE
; 4-byte record (xl, yl, xr, yr — biased Y) per SURVIVING segment to the
; buffer at (zp_dcl_rec_buf), bumping the count in byte 0;
; zp_dcl_rec_off ($BE) is the 1-based write offset. Callers arm with hi
; byte $07 (TOP_RECORDS) or $08 (BOT_RECORDS) and disarm with $00.
; br_init_frame grounds the pointer once per frame; every DCL call site
; arms/disarms explicitly.  (An older note here described the legacy
; 6-byte clip_line_records format and a $03/$01/$02 side mask — both
; retired; see the LEGACY note under TOP_RECORDS below.)

; === Line output buffer ($0200) ===
; (LINE_OUT capture RETIRED 2026-07-26: it was harness-only, and the
; engine paid a LINE_OUT_EN gate test on EVERY emitted line (41/frame
; measured) plus two per-call count-zeroings for it. The harness now
; PC-traps the plot entries (plot_h / plot_v / RASTER_ENTRY) and reads
; the staged RASTER_ZP_X0/Y0/X1/Y1 directly — same tuples, zero engine
; cost. Freed: $0200-$02xx scratch (which had OVERLAPPED the D-cache
; range $0210-$03F7 whenever a stray emit ran with EN garbage) and the
; $0BE8 flag byte.)

; === Tighten records buffers ($0700, $0800) ===
; clip_line_records writes per-span sub-records here; tighten_from_records
; consumes them. Each buffer: byte 0 = record count, then records (6
; bytes each) at offset +1. Top buffer for yt-line, bot buffer for yb-line.
;   Record format: si (slot index), sox0, sox1, verdict, cy0, cy1
;     verdict: 0 = above, 1 = inside, 2 = below
;     cy0, cy1 only meaningful for verdict=inside (line y at sox0, sox1)
; NOTE (2026-07): the 6-byte verdict record layout above is the LEGACY
; Phase-A format and is retained as a historical reference only.  The
; shipping records path uses 4-byte segment records (xl, yl, xr, yr) —
; one per surviving DCL segment — written by dcl_emit_segment (clip/dcl.s)
; and consumed by tighten_from_records (clip/tfr.s).  Byte 0 of each
; buffer is still the record COUNT; records start at offset 1.
; REC_BYTES/REC_VERDICT_* below are unreferenced (kept: equates emit no
; bytes and record the old scheme).
; (TOP_RECORDS/BOT_RECORDS moved to zp.inc 2026-08-09 — the arm sites
; in bsp/seg_emit.s used to HARDCODE #$07/$0700 because the equates
; were clip-unit-local; the silent-collision that bit the VXC-planes
; move. One registry now.)
REC_BYTES = 6                           ; bytes per record
REC_VERDICT_ABOVE = 0
REC_VERDICT_INSIDE = 1
REC_VERDICT_BELOW = 2

; === NJ rasteriser integration ===
; The NJ rasteriser is NOT part of this link — the flat build loads its
; binary at $A900 (see nj_raster.py for the pixel-exact reference).
; dcl.s's emit dispatch (des_dispatch / dv_emit) tail-calls it for
; diagonal segments; axis-aligned ones (~70% of pixels) go to the local
; plot_h / plot_v in clip/plot_axis.s instead.
; ZP $82-$85 = x0,y0,x1,y1 (rasteriser inputs, no conflict with clipper ZP).
; ZP $70 = screen start hi byte, set per frame by the caller (the walk
; driver stores the back-buffer page; the Python harness sets it in
; flat tests).
.if ::BANKED
RASTER_ENTRY = $A800                    ; bank C window (down a page 2026-08-11: unrolled steep)
.else
RASTER_ENTRY = $7500                    ; flat: above-line (2026-08-09 —
                                        ; the $2000-$29FF exception DIED;
                                        ; $2000-$2BFF is the shared driver
                                        ; reservation in BOTH builds)
.endif

; === Zero-page workspace ===
; src/zp.inc is the single source of truth (one registry shared by the
; whole link).  Clipper-owned highlights (2026-07-12): list head/free +
; query range $C0-$C3, has_gap cache $D0, interp workspace $D1-$D5,
; mul/div set $D9-$DD, tmps $DE-$E0, DCL line + CB clip $A8-$B9,
; records pointer $BC-$BE, save/tfr scratch $6A-$6F, prev/buf $61-$63,
; rasteriser args $70 + $82-$85.  ($E2-$FF is the bsp module's packed
; vertex structs — NOT clipper space; the old "$C0-$FF" claim predates
; that carve-out.)
; Note: prod_lo aliases div_lo -- multiply output feeds directly into
; division input, saving two loads per interp call.
; s16 line endpoints for the s16 clipper enter through zp_line_*_lo/_hi
; (hi bytes overlay the CB-clip slots); the LC_* absolute working set
; for s16 math is declared in clip/tfr.s ($0938-$0958).

; ======================================================================
; s16_interp — moved here from clip/dcl_s16.s 2026-08-09 (call-graph
; file DAG: both dcl.s (dcl_yband_clip, swapped axes) and dcl_s16.s call
; it, so it lives with the arithmetic primitives — no back edge).
; LC_* working-set addresses are declared in clip/tfr.s (forward refs:
; absolute $09xx, resolved at link). udiv16_8 lives in clip/pool.s.
; ======================================================================
; (umul16x16 inlined+specialised into si_general 2026-07-16 —
; single caller; operands read straight from LC_OFF/LC_DY, the
; LC_M_A/B staging slots are dead.)


; (udiv32_16 inlined into si_general 2026-07-16 — single caller.)


; ===================================================================
; s16_interp — find target axis at given free-axis value
; The "free" axis is the one whose value we know (the clip target);
; the "target" axis is the one we want to compute. Caller sets:
;   LC_TGT_LO/HI       = target free-axis value (s16)
;   LC_OX1_LO/HI etc.  = anchor 1 (free, target)
;   LC_OX2_LO/HI etc.  = anchor 2 (free, target)
; To clip x at boundary: free=x, target=y, OX*=x, OY*=y.
; To clip y at boundary: free=y, target=x, OX*=y, OY*=x.
; Output: A = clamped u8 result, LC_RES_LO/HI = unclamped s16 result.
; Clobbers: many.
;
; Python mirror: _interp_store_s16 (endpoint_spans.py).  Computes with
; |offset|, |den|, |dy| and a +den//2 bias before the divide, then
; adds/subtracts the quotient — i.e. rounds half AWAY FROM ZERO (see
; the mirror's docstring for the 1px descending-line bug this fixed).
; Pseudocode:
;   off = tgt - x0; den = x1 - x0
;   if den < 0: off, den = -off, -den
;   if den == 0 or off == 0: return y0     # degenerate / at anchor 1
;   if off == den: return y1               # at anchor 2
;   dy = y1 - y0; if dy == 0: return y0    # horizontal
;   q = (|off| * |dy| + den//2) // den     # u8 fast path: umul8 +
;                                          # udiv16_8; else 16x16/32:16
;   res = y0 + q if dy > 0 else y0 - q
;   A = clamp(res, 0, 255); LC_RES = res
; NOTE: no directed rounding here — callers that need floor/ceil
; behaviour (dcl_boundary_ix) do their own arithmetic.
s16_interp:
.scope
; offset = target - x0
   LDA LC_TGT_LO
   SEC
   SBC LC_OX1_LO
   STA z:LC_OFF_LO
   LDA LC_TGT_HI
   SBC LC_OX1_HI
   STA z:LC_OFF_HI
; den = x1 - x0
   LDA LC_OX2_LO
   SEC
   SBC LC_OX1_LO
   STA z:LC_DEN_LO
   LDA LC_OX2_HI
   SBC LC_OX1_HI
   STA z:LC_DEN_HI
; If den < 0, negate both offset and den. (A and N are the SBC's — no
; reload needed for the sign test.)
   BPL si_den_pos
   LDA #0
   SEC
   SBC z:LC_OFF_LO
   STA z:LC_OFF_LO
   LDA #0
   SBC z:LC_OFF_HI
   STA z:LC_OFF_HI
   LDA #0
   SEC
   SBC z:LC_DEN_LO
   STA z:LC_DEN_LO
   LDA #0
   SBC z:LC_DEN_HI
   STA z:LC_DEN_HI
si_den_pos:
; Trivial: den == 0 (degenerate line) → return y0
   LDA z:LC_DEN_LO
   ORA z:LC_DEN_HI
   BNE si_den_nz
   JMP si_return_y0
si_den_nz:
; Trivial: offset == 0 (target == x0) → return y0
   LDA z:LC_OFF_LO
   ORA z:LC_OFF_HI
   BNE si_off_nz
   JMP si_return_y0
si_off_nz:
; Trivial: offset == den (target == x1) → return y1
   LDA z:LC_OFF_LO
   CMP z:LC_DEN_LO
   BNE si_off_lt_den
   LDA z:LC_OFF_HI
   CMP z:LC_DEN_HI
   BNE si_off_lt_den
   JMP si_return_y1
si_off_lt_den:
; dy = y1 - y0 (s16)
   LDA LC_OY2_LO
   SEC
   SBC LC_OY1_LO
   STA z:LC_DY_LO
   LDA LC_OY2_HI
   SBC LC_OY1_HI
   STA z:LC_DY_HI
; Trivial: dy == 0 (horizontal line) → return y0. dy-hi is still in
; A from the store — ORA the lo byte instead of reloading both.
   ORA z:LC_DY_LO
   BNE si_dy_nz
   JMP si_return_y0
si_dy_nz:
; |dy|, sign tracked in LC_DY_NEG
   LDA z:LC_DY_HI
   BPL si_dy_pos
   STA LC_DY_NEG                           ; A = dy hi, BPL-proven negative:
                                        ; the flag is zero/nonzero only
                                        ; (LDX/BNE, LDA/BNE), so the old
                                        ; LDA #1 coercion was dead weight
   LDA #0
   SEC
   SBC z:LC_DY_LO
   STA z:LC_DY_LO
   LDA #0
   SBC z:LC_DY_HI
   STA z:LC_DY_HI
   JMP si_dy_done
si_dy_pos:
   ZERO LC_DY_NEG
si_dy_done:
; Fast path: |offset|, |den|, |dy| all fit u8 → use existing
; umul8 + udiv16_8 (one multiply, one divide-with-skip-zeros).
   LDA z:LC_OFF_HI
   ORA z:LC_DEN_HI
   ORA z:LC_DY_HI
   BNE si_general
   LDA z:LC_DY_LO
   STA z:zp_mul_b
   LDA z:LC_OFF_LO
   JSR umul8
; round: prod += (den / 2)
   LDA z:LC_DEN_LO
   LSR A
   CLC
   ADC zp_prod_l
   STA zp_div_l
   LDA #0
   ADC zp_prod_h
   STA zp_div_h
   LDA z:LC_DEN_LO
   STA zp_div_den
   JSR udiv16_8                            ; A = u8 quotient
   LDX LC_DY_NEG
   BNE si_u8_sub
   CLC
   ADC LC_OY1_LO
   STA LC_RES_LO
   LDA LC_OY1_HI
   ADC #0
   STA LC_RES_HI
   JMP si_clamp
si_u8_sub:
   STA z:LC_TMP_LO
   LDA LC_OY1_LO
   SEC
   SBC z:LC_TMP_LO
   STA LC_RES_LO
   LDA LC_OY1_HI
   SBC #0
   STA LC_RES_HI
   JMP si_clamp
si_general:
; multiply: |offset| × |dy| → u32, INLINE (was umul16x16 — single
; caller): operands read straight from LC_OFF/LC_DY, no staging; the
; a_hi=0/b_hi=0 fast paths survive.
.scope

; Always need p1 = a_lo * b_lo.
   LDA z:LC_DY_LO
   STA z:zp_mul_b
   LDA z:LC_OFF_LO
   JSR umul8
   STA z:LC_M_R1                             ; A = prod_hi (umul8 contract)
   LDA z:zp_prod_l
   STA z:LC_M_R0
   ZERO LC_M_R2, LC_M_R3


; Fast paths: skip multiplies whose factor is zero.
   LDA z:LC_DY_HI
   BEQ skip_p2

   STA z:zp_mul_b                            ; A = b_hi from the test above
   LDA z:LC_OFF_LO
   JSR umul8
; p2 = a_lo * b_hi
   LDA z:zp_prod_l
   CLC
   ADC z:LC_M_R1
   STA z:LC_M_R1
   LDA z:zp_prod_h
   ADC LC_M_R2
   STA LC_M_R2
   LDA #0
   ADC LC_M_R3
   STA LC_M_R3
skip_p2:

   LDA z:LC_OFF_HI
   BEQ skip_p3_p4

   LDA z:LC_DY_LO
   STA z:zp_mul_b
   LDA z:LC_OFF_HI
   JSR umul8
; p3 = a_hi * b_lo
   LDA z:zp_prod_l
   CLC
   ADC z:LC_M_R1
   STA z:LC_M_R1
   LDA z:zp_prod_h
   ADC LC_M_R2
   STA LC_M_R2
   LDA #0
   ADC LC_M_R3
   STA LC_M_R3

   LDA z:LC_DY_HI
   BEQ skip_p3_p4
; if b fits u8, p4 = a_hi * 0 = 0
   STA z:zp_mul_b                            ; A = b_hi from the test above
   LDA z:LC_OFF_HI
   JSR umul8
; p4 = a_hi * b_hi
   LDA z:zp_prod_l
   CLC
   ADC LC_M_R2
   STA LC_M_R2
   LDA z:zp_prod_h
   ADC LC_M_R3
   STA LC_M_R3
skip_p3_p4:
.endscope
; round-to-nearest: add (den / 2) before divide
   LDA z:LC_DEN_HI
   LSR A
   STA LC_TMP_HI
   LDA z:LC_DEN_LO
   ROR A
   CLC                                     ; (ROR left bit 0 in C)
   ADC z:LC_M_R0                             ; den/2 lo rides A into the
   STA z:LC_M_R0                             ; add — no TMP_LO staging
   LDA z:LC_M_R1
   ADC LC_TMP_HI
   STA z:LC_M_R1
   BCC m_r_nc                              ; BCC/INC 2-byte propagate:
   INC LC_M_R2                             ; wrap of R2 carries into R3
   BNE m_r_nc
   INC LC_M_R3
m_r_nc:
.scope

   ZERO z:LC_QUOT_LO, z:LC_QUOT_HI


; ---- Fast path: quotient fits u16 ----
; True iff top 16 bits of dividend < den. Pre-load rem = R3:R2 and
; run 16 iterations on the low 16 bits (skip the first 16 no-op
; iterations the standard loop would do). For typical s16 clipper
; inputs (product u20-u22, den u12) this is always true.
   LDA LC_M_R3
   CMP z:LC_DEN_HI
   BCC u16_quot_noreload
   BNE nq_j
   LDA LC_M_R2
   CMP z:LC_DEN_LO
   BCC u16_quot
nq_j:
   JMP no_u16_quot                         ; (the u8 tier pushed the slow
                                           ; path out of branch range)
u16_quot:
   LDA LC_M_R3                             ; (lo-tier fall only: the hi BCC
u16_quot_noreload:                         ; arrives with R3 live)
; ---- u8-quotient tier (2026-07-19, measured: every corpus call lands
; here): quot < 256 iff D>>8 = R3:R2:R1 < den, i.e. R3 == 0 and
; R2:R1 < DEN_HI:DEN_LO. Then rem preloads from R2:R1 (< den = u12,
; fits u16) and EIGHT iterations over R0 finish — half the loop, and
; each iteration drops the R1 ROL and the QUOT_HI ROL. ----
   BNE u16_full                            ; R3 != 0 → 16-bit quotient
   LDA LC_M_R2
   CMP z:LC_DEN_HI
   BCC u8_tier                             ; R2 < den hi → q < 256
   BNE u16_full
   LDA z:LC_M_R1
   CMP z:LC_DEN_LO
   BCS u16_full                            ; R2:R1 >= den → q >= 256
u8_tier:
   LDA LC_M_R2
   STA z:LC_REM_HI
   LDA z:LC_M_R1
   STA z:LC_REM_LO
   LDX #8
u8_loop:
   ASL z:LC_M_R0
   ROL z:LC_REM_LO
   ROL z:LC_REM_HI
   LDA z:LC_REM_LO
   SEC
   SBC z:LC_DEN_LO
   STA z:LC_TMP_LO
   LDA z:LC_REM_HI
   SBC z:LC_DEN_HI
   BCC u8_set                              ; no-sub: C=0 rides into the ROL
   STA z:LC_REM_HI
   LDA z:LC_TMP_LO
   STA z:LC_REM_LO                           ; sub taken: C=1 from the SBC
u8_set:
   ROL z:LC_QUOT_LO                          ; QUOT_HI stays its pre-zeroed 0
   DEX
   BNE u8_loop
   JMP udv_done
u16_full:
   LDA LC_M_R3
   STA z:LC_REM_HI
   LDA LC_M_R2
   STA z:LC_REM_LO
   LDX #16
u16_loop:
   ASL z:LC_M_R0
   ROL z:LC_M_R1
   ROL z:LC_REM_LO
   ROL z:LC_REM_HI
   LDA z:LC_REM_LO
   SEC
   SBC z:LC_DEN_LO
   STA z:LC_TMP_LO
   LDA z:LC_REM_HI
   SBC z:LC_DEN_HI
   BCS u16_sub                             ; sub arm out of the fall path
                                           ; (census 2026-07-27: no-sub is
                                           ; 76.6% — C=0 rides into the ROL)
u16_set:
   ROL z:LC_QUOT_LO
   ROL z:LC_QUOT_HI
   DEX
   BNE u16_loop
   JMP udv_done
u16_sub:
   STA z:LC_REM_HI
   LDA z:LC_TMP_LO
   STA z:LC_REM_LO                           ; C=1 from the SBC rides the ROLs
   ROL z:LC_QUOT_LO                          ; (duplicated tail: a jump back
   ROL z:LC_QUOT_HI                          ; to u16_set costs more than it
   DEX                                     ; saves at 23% sub rate)
   BNE u16_loop
   JMP udv_done

no_u16_quot:
; ---- Slow path: u32 ÷ u16 → up to u17 quotient ----
; (Rare for s16 clipper; kept for correctness.) Use byte-level skip
; + bit-level skip to trim no-op iterations.
   ZERO z:LC_REM_LO, z:LC_REM_HI

; Byte-level skip: while the top dividend byte (R3) is zero, shift the
; dividend left 8 bits in one move (R2->R3, R1->R2, R0->R1, 0->R0) and
; drop the iteration count by 8.  X = 32/24/16/8 iterations remaining.
   LDX #32
   LDA LC_M_R3
   BNE bit_skip
   LDA LC_M_R2
   STA LC_M_R3
   LDA z:LC_M_R1
   STA LC_M_R2
   LDA z:LC_M_R0
   STA z:LC_M_R1
   ZERO LC_M_R0
   LDX #24
   LDA LC_M_R3
   BNE bit_skip
   LDA LC_M_R2
   STA LC_M_R3
   LDA z:LC_M_R1
   STA LC_M_R2
   ZERO z:LC_M_R0, z:LC_M_R1

   LDX #16
   LDA LC_M_R3
   BNE bit_skip
   LDA LC_M_R2
   STA LC_M_R3
   ZERO z:LC_M_R0, z:LC_M_R1, LC_M_R2

   LDX #8
   LDA LC_M_R3
   BNE bit_skip
   JMP udv_done                                     ; dividend == 0 → quot = rem = 0
bit_skip:
; Bit-level skip: shift left until the dividend MSB is set (those
; iterations can never make rem >= den since rem stays 0).
   BMI div_loop
bs_loop:
   ASL z:LC_M_R0
   ROL z:LC_M_R1
   ROL LC_M_R2
   ROL LC_M_R3
   DEX
   LDA LC_M_R3
   BPL bs_loop
div_loop:
   ASL z:LC_M_R0
   ROL z:LC_M_R1
   ROL LC_M_R2
   ROL LC_M_R3
   ROL z:LC_REM_LO
   ROL z:LC_REM_HI
   LDA z:LC_REM_LO
   SEC
   SBC z:LC_DEN_LO
   STA z:LC_TMP_LO
   LDA z:LC_REM_HI
   SBC z:LC_DEN_HI
   BCC div_no_sub
   STA z:LC_REM_HI
   LDA z:LC_TMP_LO
   STA z:LC_REM_LO
   SEC
   JMP div_setbit
div_no_sub:
   CLC
div_setbit:
   ROL z:LC_QUOT_LO
   ROL z:LC_QUOT_HI
   DEX
   BNE div_loop
udv_done:
.endscope
; result = y0 ± quot
   LDA LC_DY_NEG
   BNE si_sub
   LDA LC_OY1_LO
   CLC
   ADC z:LC_QUOT_LO
   STA LC_RES_LO
   LDA LC_OY1_HI
   ADC z:LC_QUOT_HI
   STA LC_RES_HI
   JMP si_clamp
si_sub:
   LDA LC_OY1_LO
   SEC
   SBC z:LC_QUOT_LO
   STA LC_RES_LO
   LDA LC_OY1_HI
   SBC z:LC_QUOT_HI
   STA LC_RES_HI
si_clamp:
; (no load: ALL six inbound paths — add/sub, u8 fast pair, return_y0/
; y1 — end STA LC_RES_HI, so A converges holding it; regscan 2026-07-19)
   BMI si_clamp_zero
   BNE si_clamp_max
   LDA LC_RES_LO
   RTS
si_clamp_zero:
   LDA #0
   RTS
si_clamp_max:
   LDA #$FF
   RTS
si_return_y0:
   LDA LC_OY1_LO
   STA LC_RES_LO
   LDA LC_OY1_HI
   STA LC_RES_HI
   JMP si_clamp
si_return_y1:
   LDA LC_OY2_LO
   STA LC_RES_LO
   LDA LC_OY2_HI
   STA LC_RES_HI
   JMP si_clamp
.endscope
