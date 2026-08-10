; GENERATED: RECIP_S junior-page S table, NIBBLE-SWAPPED layout
; (Eben 2026-08-10): entry swap(idx) holds S(idx) = bit_length(idx-1)
; (low clamp baked: S[0..2] = 1, matching the M8 table's [0..2]).
; The fast-path index is (vy_l & $F0) | vy_h — see seg_xform nc_ok.
; Map-independent, static forever.
   .byte 1,4,5,6,6,7,7,7,7,8,8,8,8,8,8,8
   .byte 1,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 1,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 2,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 2,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 3,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 3,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 3,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 3,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
   .byte 4,5,6,6,7,7,7,7,8,8,8,8,8,8,8,8
