bsp_w_start:

; ============================================================================
; br_project_y — memoising front for br_project_y_raw (the VWHC cache).
;
;   Inputs:  zp_br_t0 = height delta (s8), zp_br_rhi/rlo = (M8, S) recip
;   Output:  zp_br_resl/h = screen y (s16, pre-biased by Y_BIAS)
;   Preserves the full input set; clobbers X and zp_pyc_idx (+ raw-path
;   scratch on a miss).
;
; Direct-mapped, 256 entries, five parallel 256-byte arrays (RHI / RLO /
; H / LO / HI — see the W-region layout in resolve_crossing.s; RLO doubles
; as the valid flag since a live rlo is never 0).
; Probe index = h ^ rhi (2026-07-12: corpus-searched — see below); a HIT
; additionally requires all three key bytes to match, so the returned
; value is the one previously computed for exactly these inputs —
; bit-identical to calling _raw, by construction. Collisions just
; overwrite (miss path re-stores the new key+value).
;
; HASH SEARCH (2026-07-12, 10-frame key streams, steady-state replay):
; the ~140-unique-key working set in 256 slots sits AT the birthday
; bound — every decent mix (add/xor/shift combos, trained S-boxes,
; 2-way i^1 with and without LRU) lands within noise of ~24 recurring
; conflicts/frame, and S-boxes don't generalize across positions. So
; the only real degree of freedom is probe COST: h ^ rhi drops rlo
; from the mix (rlo stays in the tag compare — keys differing only in
; rlo just collide, 16 of 150 colliding pairs) and the CLC, for 8
; cycles vs 12. Steady conflicts 243 vs 265 per 10 frames — no worse.
;
; This plays the role of Python's VWH cache (_packed_read_vwh /
; _packed_write_vwh in packed_render_seg): Python keys by VWH table index
; per frame, the 6502 keys by the complete input tuple (rhi, rlo, h) —
; either way each distinct projection is computed once. Measured
; (2026-07-10): ~202 projections/frame, ~112 unique, 46.5% hit rate,
; conflict misses only ~1.2/frame; raw ~322 cycles, hit ~64.
;
;   Pseudocode:
;     i = h ^ rhi
;     if VALID[i] and RHI[i]==rhi and RLO[i]==rlo and H[i]==h:
;         return (LO[i], HI[i])                     # hit
;     res = br_project_y_raw(h, rhi, rlo)           # miss
;     VALID[i]=1; RHI[i]=rhi; RLO[i]=rlo; H[i]=h; LO[i],HI[i] = res
;     return res
; ============================================================================
; CONTRACT (2026-07-11): the CALLER guarantees BANK_L2 is paged (y_stage
; and apv_stage page once per run — consecutive projections used to
; re-page for nothing). Harness/jt users go through br_project_y_paged.
br_project_y_paged:
   PAGE BANK_L2
br_project_y:
.scope
; probe: idx = h ^ rhi
   LDA zp_br_t0
   EOR zp_br_rhi
   TAX
   LDA VWHC_RLO,X                          ; RLO doubles as the valid flag:
   CMP zp_br_rlo                           ; live rlo is always in [1,10]
   BNE pyc_miss                            ; (rns vectoring), so 0 = empty
   LDA VWHC_RHI,X
   CMP zp_br_rhi
   BNE pyc_miss
   LDA VWHC_H,X
   CMP zp_br_t0
   BNE pyc_miss
   LDA VWHC_LO,X
   STA zp_br_resl
   LDA VWHC_HI,X
   STA zp_br_resh
   RTS
pyc_miss:
   STX zp_pyc_idx
   JSR br_project_y_raw
   LDX zp_pyc_idx
   LDA zp_br_rhi
   STA VWHC_RHI,X
   LDA zp_br_rlo
   STA VWHC_RLO,X
   LDA zp_br_t0
   STA VWHC_H,X
   LDA zp_br_resl
   STA VWHC_LO,X
   LDA zp_br_resh
   STA VWHC_HI,X
   RTS
.endscope

; vwhc_clear — invalidate the projection cache (boot only).
;   Zeroes the 256-byte VWHC_RLO page: RLO doubles as the valid flag (a
;   live rlo is always in [1,10], so 0 never matches a probe). The other
;   key/value pages may stay stale — the RLO compare gates every probe.
;   NOTE: not run per frame — the cache key is the complete input of a
;   pure function, so entries stay correct across frames; br_init_frame
;   (walk.s) deliberately skips this and it is needed ONCE at boot to
;   scrub power-on garbage. Clobbers A, X.
vwhc_clear:
.scope
   LDA #0
   LDX #0
vc_loop:
   STA VWHC_RLO,X
   INX
   BNE vc_loop
; (RPC rotation-product cache removed: $DC00 reclaimed for angle TA_LO.)
   RTS
.endscope


bsp_w_end:
.assert bsp_w_end <= $DC00, error       ; stay below angle TA_LO (was RPC_VALID, removed)
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_w_bk.bin", $3900, bsp_w_end, $3900)
.else
; (ld65 writes this: SAVE "bsp_render_w.bin", $DAC0, bsp_w_end, $DAC0)
.endif

; ============================================================================
; OVERFLOW REGION — bsp_render.bin is bound to $4800-$57FF (4096 bytes max,
; framebuffer starts at $5800). Helpers that don't fit live here at $1C00 and
; are loaded as a separate binary by span_clip_6502.py (bsp_render_lo.bin).
; ============================================================================
.segment "LO"
