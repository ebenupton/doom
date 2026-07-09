
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
; Driver interface (walk_drv.asm):
;   $3D80 angidx (view angle byte = angidx*4), $3D81 backhi (FB page),
;   $3D82/85 = x/y fraction bytes, $3D83/84 = x int lo/hi,
;   $3D86/87 = y int lo/hi, $3D89 hud_en, $3D8A hud_prev (toggle edge
;   state).  The driver's hud_glue pages BANK_C and JSRs hud_draw
;   ($A400) when hud_en is nonzero.
;
; Banked-build only: the code lives in the bank C window (HUD region,
; $A400) and reads the OS ROM directly — the flat py65 harness has no OS,
; so the flat build emits nothing (test seeds a fake font instead).
; ============================================================================

.if ::BANKED

; zp scratch — frame-scoped, shared with the anim workers (the HUD runs
; after the render, when they are dead)
zp_hud_src = $EB                        ; font glyph pointer
zp_hud_dst = $ED                        ; framebuffer cell pointer
HUD_VAL    = $F0                        ; byte being hexed

HUD_ANGIDX = $3D80
HUD_BACKHI = $3D81
HUD_XFRAC  = $3D82
HUD_XLO    = $3D83
HUD_XHI    = $3D84
HUD_YFRAC  = $3D85
HUD_YLO    = $3D86
HUD_YHI    = $3D87

OS_FONT    = $C000                      ; OS 1.2 glyphs, chars 32..127

.segment "HUD"

; --- hud_draw ($A400): entry. Emits the whole line. Clobbers A,X,Y. ---
hud_draw:
.scope
   LDA #0
   STA zp_hud_dst                          ; cell 0 (col*8 accumulates below)
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
; font ptr = OS_FONT + (A-32)*8: (A-32) < 96 so the product is 11 bits —
; hi = >OS_FONT + (A-32)>>5, lo = ((A-32)<<3) & $FF
   SEC
   SBC #32
   PHA
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   CLC
   ADC #>OS_FONT
   STA zp_hud_src+1
   PLA
   ASL A
   ASL A
   ASL A
   STA zp_hud_src
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

; restore the segment for subsequently-included parts (they inherit)
.segment "MAIN"

.endif
