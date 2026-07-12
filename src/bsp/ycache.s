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
; 2026-07-12 (post Y-deferral): ~118 probes/frame, ~79 unique; steady-
; state recurring conflicts ~24/frame = the birthday bound (see HASH
; SEARCH above); raw ~322 cycles, hit ~64. (The old '1.2 conflicts/
; frame' note was measured before deferral changed the mix.)
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
   LDA zp_br_t0                            ; jt/harness contract: h staged in
                                        ; ZP; native callers enter below
                                        ; with h in A (REG CONTRACT
                                        ; 2026-07-12) — saves the STA/LDA
                                        ; round-trip at every call site
br_project_y:
.scope
; probe: idx = h ^ rhi (h arrives in A; store it for the tag compare +
; the raw body's h<<8 / sign reads)
   STA zp_br_t0
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
   LDY VWHC_LO,X                           ; REG CONTRACT: Y = lo, A = hi at
   STY zp_br_resl                          ; RTS (ZP still written: the
   LDA VWHC_HI,X                           ; harness/tests read memory, and
   STA zp_br_resh                          ; px staging reuses the slots)
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
   TYA                                     ; raw returned Y = lo, A = hi;
   STA VWHC_LO,X                           ; the key stores above spared Y
   LDA zp_br_resh
   STA VWHC_HI,X                           ; (and re-establish A = hi)
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
; (W-region ceiling retired 2026-07-12: W floats in the one CODE region.)

; ============================================================================
; LO SEGMENT — historically the "overflow region" for code that outgrew
; MAIN's old 4K island; since the 2026-07-12 flat merge it simply floats
; inside the one CODE region in both builds (no separate bin, no ceiling).
; The name survives as a link-order label only.
; ============================================================================
.segment "LO"
