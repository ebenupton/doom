bsp_d_start:

; (bsp_resolve_child inlined into walk.s bsp_deferred 2026-07-14 — it
; had exactly one caller and the JSR/RTS pair was pure tax.)


SEG_CODE
; rns24 half constants, indexed S-1:
;   half = 2^(S-1), S in [1,4] ONLY (rns24's whole domain since the s10
;   kernel returned and rns32 died, 2026-07-13): fits the low byte, so
;   the mid table is deleted and this one is 4 entries.
rns_half_l:
   .byte $01, $02, $04, $08


bsp_d_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_d_bk.bin", $3BC0, bsp_d_end, $3BC0)
.else
; (D-region ceiling retired 2026-07-12: D floats in the one CODE region.)
; (D segment floats in the one CODE region — no separate bin since 2026-07-12)
.endif





; ============================================================================
; VYCACHE ARRAY EQUATES — the Y-projection memo's five parallel 256-byte
; arrays (the CODE lives with project_y in project.s; only the DATA
; addresses live here, historically, because this file owned the old W
; region). Flat: $D500-$D9FF, the BSS window between the bbox table
; (ends $D4BF) and TA_LO ($DC00). Banked: bank L2 window $B500-$B9FF.
; Both builds page-aligned (2026-07-12 — the old flat $D5C0 offset made
; ~75% of abs,X probes pay the page-cross +1, a harness-only tax).
; The W segment itself floats inside the one CODE region in BOTH builds
; (2026-07-12 flat merge); there is no W memory area any more.
;
; project_y (project.s) memoises the inlined raw body: the key is
; the COMPLETE input tuple (rhi, rlo, h), so a hit returns exactly the
; previously computed value — bit-identical by construction. See
; project.s for the probe hash and its 2026-07-12
; corpus search (~24 recurring conflicts/frame = the birthday bound;
; raw ~322 cycles, hit ~64).
; ============================================================================
.if ::BANKED
; (VYCACHE lives in the L2 CACHES group since the 2026-07-21 regroup.
; VALID retired earlier — RLO doubles as valid.)
; (VYCACHE_R_M8 plane RETIRED 2026-07-26: the probe index is h ^ rhi, so
; the KEY plane's h implies rhi = idx ^ h — the compare was redundant.
; $AE00 is a FREE L2 page.)
VYCACHE_R_S = $B300
VYCACHE_KEY = $B400
VYCACHE_L = $B500
VYCACHE_H = $B600
SEG_CODE
.else
; PAGE-ALIGNED 2026-07-12 (were $D5C0-$D9C0: the $C0 offset made ~75% of
; abs,X probes pay the page-cross +1 — flat build only; banked was
; already aligned, so the harness metric overcharged the y-cache).
; BSS window $D4C0-$DABF: aligned tables span $D500-$D9FF, $D4C0-$D4FF
; and $DA00-$DABF free.
; (VYCACHE_R_M8 retired 2026-07-26 — $8100 free; see the banked note.)
VYCACHE_R_S = $8200
VYCACHE_KEY = $8300
VYCACHE_L = $8400
VYCACHE_H = $8500
SEG_HIGHX
.endif
