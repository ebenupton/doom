
; ============================================================================
; Debug HUD — position and rotation on the top character row of the display.
;
; Renders "X=hhhh.hh Y=hhhh.hh R=hh" (map-relative prescaled position,
; s16 integer + 8-bit fraction of the driver's 8.8 fixed point, and the
; view angle byte) into the BACK buffer's first character row, after the
; frame render and before the flip, using the OS ROM font.  The fraction
; matters for exact position capture: the engine consumes the full 8.8,
; so an integer-only reading is up to 1 prescaled unit (8 world units)
; away from the true viewpoint.
;
; Mode 4 makes this cheap: a character cell on row 0 is 8 CONSECUTIVE
; bytes at FB + col*8, and an OS glyph is 8 consecutive bytes at
; $C000 + (ascii-32)*8 (OS 1.2 keeps the full 32..127 set there) — so a
; character is a straight 8-byte copy, background included (glyph zero
; bits overwrite any rendered line underneath, keeping the text legible).
;
;   for i, ch in enumerate(template):   # template = "X=....%.. Y=....%.. R=.."
;       if ch is a hex slot: ch = hexdigit(nibble of the referenced value)
;       dst = back_fb + i*8                  # back_fb page from the driver
;       dst[0..7] = os_font[(ch-32)*8 .. +7]
;
; Driver interface (walk_drv.asm): BOTH sides now derive the variable
; addresses from the abi.inc DV_* equates (DRV_VARS = $2080) — private
; address copies are banned here because of the bug this caused: when
; the driver vars moved (2026-07-10) this file's stale hardcoded $3D8x
; copies survived, HUD_BACKHI read an engine-code byte as the FB page,
; and every glyph blit sprayed 192 bytes over a random page — ZP when
; it landed on page 0, corrupting the VZ easing state.  Current layout:
;   $2180 angidx (view angle byte = angidx*4), $2181 backhi (FB page),
;   $2182/85 = x/y fraction bytes, $2183/84 = x int lo/hi,
;   $2186/87 = y int lo/hi, $2189 hud_en, $218A hud_prev (toggle edge
;   state).  The driver's hud_glue pages BANK_C and JSRs hud_draw
;   ($A400) when hud_en is nonzero.
;
; Banked-build only: the code lives in the bank C window (HUD region,
; $A400) and reads the OS ROM directly — the flat py65 harness has no OS,
; so the flat build emits nothing (test seeds a fake font instead).
; ============================================================================

.if ::BANKED

; zp scratch — frame-scoped: these sit inside the VX vertex structs
; ($E2-$FF), which are per-seg working state, dead between the frame's
; last seg and the next frame's first (the HUD runs post-render).
zp_hud_src = $EB                        ; font glyph pointer
zp_hud_dst = $ED                        ; framebuffer cell pointer
HUD_VAL    = $F0                        ; byte being hexed

HUD_ANGIDX = DV_ANGIDX                  ; driver vars via abi.inc —
HUD_BACKHI = DV_BACKHI                  ; no private address copies
HUD_XFRAC  = DV_PXF
HUD_XLO    = DV_PXL
HUD_XHI    = DV_PXH
HUD_YFRAC  = DV_PYF
HUD_YLO    = DV_PYL
HUD_YHI    = DV_PYH

HUD_FONT   = DV_HUD_FONT                ; found base (0 = not searched yet,
                                        ; $FFxx = searched and not found)
zp_hud_t   = $F1                        ; hud_char scratch (frame-scoped, as
                                        ; the pointers above)

.segment "HUD"

; --- hud_draw ($A400): entry. Emits the whole line. Clobbers A,X,Y. ---
hud_draw:
.scope
   LDA HUD_FONT+1                          ; font located yet?
   BNE hd_have
   JSR hud_find
   LDA HUD_FONT+1
hd_have:
   CMP #$FF                                ; searched, no font: draw nothing
   BNE hd_go
   RTS
hd_go:
   ZERO zp_hud_dst                         ; cell 0 (col*8 accumulates below)
   LDA HUD_BACKHI
   STA zp_hud_dst+1                        ; row-0 block = FB page start
; "X="
   LDA #'X'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_XHI
   JSR hud_hex
   LDA HUD_XLO
   JSR hud_hex
   LDA #'.'
   JSR hud_char
   LDA HUD_XFRAC
   JSR hud_hex
   LDA #' '
   JSR hud_char
; "Y="
   LDA #'Y'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_YHI
   JSR hud_hex
   LDA HUD_YLO
   JSR hud_hex
   LDA #'.'
   JSR hud_char
   LDA HUD_YFRAC
   JSR hud_hex
   LDA #' '
   JSR hud_char
; "R="
   LDA #'R'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_ANGIDX
   ASL A
   ASL A                                   ; angle byte = angidx*4
; fall through to hud_hex for the final value
.endscope

; --- hud_hex: A = byte -> two hex digit cells. Clobbers A,X,Y. ---
hud_hex:
.scope
   PHA
   LSR A
   LSR A
   LSR A
   LSR A
   TAX
   LDA hexdig,X
   JSR hud_char
   PLA
   AND #$0F
   TAX
   LDA hexdig,X
; fall through to hud_char
.endscope

; --- hud_char: A = ascii -> blit the OS glyph at the current cell and
;     advance one cell (zp_hud_dst += 8). Clobbers A,Y. ---
hud_char:
.scope
; font ptr = HUD_FONT + (A-32)*8: (A-32) < 96 so the product is 11 bits
; and BOTH halves matter — the base is no longer page-aligned ($F900 on
; a Master), so the low add can carry.
   SEC
   SBC #32
   STA zp_hud_t
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   STA zp_hud_t+1                          ; hi = (A-32) >> 5
   LDA zp_hud_t
   ASL A
   ASL A
   ASL A                                   ; lo = ((A-32) << 3) & $FF
   CLC
   ADC HUD_FONT
   STA zp_hud_src
   LDA zp_hud_t+1
   ADC HUD_FONT+1                          ; + the carry out of the low add
   STA zp_hud_src+1
   LDY #7
hc_row:
   LDA (zp_hud_src),Y
   STA (zp_hud_dst),Y
   DEY
   BPL hc_row
   CLC
   LDA zp_hud_dst
   ADC #8
   STA zp_hud_dst                          ; next cell (row 0 never crosses
   RTS                                     ; the page: 32 cells * 8 = 256)
.endscope

hexdig:
   .byte "0123456789ABCDEF"

; ============================================================================
; hud_find — locate the MOS font. The 96 glyphs (chars 32..127, 8 bytes
; each) are contiguous but NOT at a fixed address: OS 1.2 keeps them at
; $C000, MOS 3.20 at $F900. Reading $C000 on a Master gets MOS code (or
; HAZEL RAM, depending on ACCCON), which is exactly why the HUD came out
; as garbage there.
;
; So SEARCH rather than carry a per-machine table, and rather than bake a
; copy into RAM — this costs TWO bytes of state. Look for the 'A' glyph
; and derive the base, then confirm with '0'. Verified against both ROM
; images: the A pattern occurs EXACTLY ONCE in each across the scanned
; range, so it cannot land on the wrong thing.
;
; Starts at $C000+$108 so the derived base can never fall below $C000,
; and stops before $FC00 — FRED/JIM/SHEILA live there and READS have
; side effects.
; ============================================================================
hud_find:
.scope
   LDA #$08
   STA zp_hud_src
   LDA #$C1
   STA zp_hud_src+1
hf_loop:
   LDY #7
hf_cmp:
   LDA (zp_hud_src),Y
   CMP hud_ref_a,Y
   BNE hf_next
   DEY
   BPL hf_cmp
   SEC                                     ; base = match - ('A'-32)*8
   LDA zp_hud_src
   SBC #$08
   STA HUD_FONT
   LDA zp_hud_src+1
   SBC #$01
   STA HUD_FONT+1
   CLC                                     ; confirm '0' at base + $80
   LDA HUD_FONT
   ADC #$80
   STA zp_hud_dst
   LDA HUD_FONT+1
   ADC #0
   STA zp_hud_dst+1
   LDY #7
hf_ver:
   LDA (zp_hud_dst),Y
   CMP hud_ref_0,Y
   BNE hf_next
   DEY
   BPL hf_ver
   RTS                                     ; found
hf_next:
   INC zp_hud_src
   BNE hf_nohi
   INC zp_hud_src+1
hf_nohi:
   LDA zp_hud_src+1
   CMP #$FC
   BCC hf_loop
   LDA #$FF                                ; none: mark so we never rescan
   STA HUD_FONT+1
   RTS
.endscope
hud_ref_a:
   .byte $3C,$66,$66,$7E,$66,$66,$66,$00   ; 'A', identical in both ROMs
hud_ref_0:
   .byte $3C,$66,$6E,$7E,$76,$66,$3C,$00   ; '0'

; restore the segment for subsequently-included parts (they inherit)
SEG_CODE

.endif
