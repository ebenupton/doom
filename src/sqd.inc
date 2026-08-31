; GENERATED: SQD_H — even-extended quarter-square DIFF table, HI
; bytes only (2026-08-11, Eben: reuse the lower-address table).
; The diff LO side reuses sqr_l itself + a 32-byte mirrored prefix
; at SQR_MIRROR ($01E0 below the sqr quad since the $0200 swap; this
; note said $19E0 long after the move — see bsp/header.s, n_verts
; <= 480 asserted at pack) — filled by rot_select on a fresh code
; image (rwp_stamp), so boot zeroing self-heals. The HI side needs
; this dedicated copy: the 32 bytes below sqr_h are sqr_l's top
; entries, live for umul8's full-range sums.
; Entry k = f(|k-32|) >> 8, logical index k-32 in [-32, 254].
SQD_H:
   .byte 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
   .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
   .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
   .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
   .byte 1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2
   .byte 2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3
   .byte 4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,6
   .byte 6,6,6,6,6,7,7,7,7,7,7,8,8,8,8,8
   .byte 9,9,9,9,9,9,10,10,10,10,10,11,11,11,11,12
   .byte 12,12,12,12,13,13,13,13,14,14,14,14,15,15,15,15
   .byte 16,16,16,16,17,17,17,17,18,18,18,18,19,19,19,19
   .byte 20,20,20,21,21,21,21,22,22,22,23,23,23,24,24,24
   .byte 25,25,25,25,26,26,26,27,27,27,28,28,28,29,29,29
   .byte 30,30,30,31,31,31,32,32,33,33,33,34,34,34,35,35
   .byte 36,36,36,37,37,37,38,38,39,39,39,40,40,41,41,41
   .byte 42,42,43,43,43,44,44,45,45,45,46,46,47,47,48,48
   .byte 49,49,49,50,50,51,51,52,52,53,53,53,54,54,55,55
   .byte 56,56,57,57,58,58,59,59,60,60,61,61,62,62,63,63
; entry 287 (logical index 255) ADDED 2026-08-31: the 8-bit trig restore
; lets mag5' = 0 reach SQD_H+32+255 -- the old "never mag 0" dispatch
; invariant was silently doubling as this table's bounds guard.
