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
; (VYCACHE: bank A, $3300-$36FF in-window — the la builder's recip copy
; guards against dragging garbage over the KEY plane.  VALID retired —
; RLO doubles as valid.  R_M8 plane retired 2026-07-26: the probe index
; is h ^ rhi, so the KEY plane's h implies rhi.)
VYCACHE_R_S = BANKA_ORG + $3300
VYCACHE_KEY = BANKA_ORG + $3400
VYCACHE_L = BANKA_ORG + $3500
VYCACHE_H = BANKA_ORG + $3600
SEG_CODE
