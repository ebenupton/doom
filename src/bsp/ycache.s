bsp_w_start:

; ============================================================================
; br_project_y — memoising front for br_project_y_raw (the VWHC cache).
;
;   Inputs:  zp_br_t0 = height delta (s8), zp_br_rhi/rlo = (M8, S) recip
;   Output:  zp_br_resl/h = screen y (s16, pre-biased by Y_BIAS)
;   Preserves the full input set; clobbers X and zp_pyc_idx (+ raw-path
;   scratch on a miss).
;
; Direct-mapped, 256 entries, six parallel 256-byte arrays (VALID / RHI /
; RLO / H / LO / HI — see the W-region layout in resolve_crossing.s).
; Probe index = (rlo + h + rhi) & 255, a cheap hash of the key; a HIT
; additionally requires all three key bytes to match, so the returned
; value is the one previously computed for exactly these inputs —
; bit-identical to calling _raw, by construction. Collisions just
; overwrite (miss path re-stores the new key+value).
;
; This plays the role of Python's VWH cache (_packed_read_vwh /
; _packed_write_vwh in packed_render_seg): Python keys by VWH table index
; per frame, the 6502 keys by the complete input tuple (rhi, rlo, h) —
; either way each distinct projection is computed once. Measured
; 58-64% of projections repeat within a frame; raw ~315 cycles, hit ~45.
;
;   Pseudocode:
;     i = (rlo + h + rhi) & 255
;     if VALID[i] and RHI[i]==rhi and RLO[i]==rlo and H[i]==h:
;         return (LO[i], HI[i])                     # hit
;     res = br_project_y_raw(h, rhi, rlo)           # miss
;     VALID[i]=1; RHI[i]=rhi; RLO[i]=rlo; H[i]=h; LO[i],HI[i] = res
;     return res
; ============================================================================
br_project_y:
.scope
   PAGE BANK_L2                            ; recip + VWHC cache live in bank L2
; probe: idx = (rlo + h + rhi) & 255
   LDA zp_br_rlo
   CLC
   ADC zp_br_t0
   ADC zp_br_rhi
   TAX
   LDA VWHC_VALID,X
   BEQ pyc_miss
   LDA VWHC_RHI,X
   CMP zp_br_rhi
   BNE pyc_miss
   LDA VWHC_RLO,X
   CMP zp_br_rlo
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
   LDA #1
   STA VWHC_VALID,X
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

; vwhc_clear — invalidate the projection + rotation-product caches (per frame).
;   Zeroes the 256-byte VWHC_VALID page (key/value pages may stay stale —
;   VALID gates every probe). NOTE: no longer run per frame — the cache
;   key is the complete input of a pure function, so entries stay correct
;   across frames; br_init_frame (walk.s) deliberately skips this and it
;   is needed ONCE at boot to scrub power-on garbage. Clobbers A, X.
vwhc_clear:
.scope
   LDA #0
   LDX #0
vc_loop:
   STA VWHC_VALID,X
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
