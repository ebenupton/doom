#!/usr/bin/env python3
"""Print the BBC Micro DOOM memory map."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw

rm = len(dw.packed_rom_main)
rd = len(dw.packed_rom_detail)
bb = len(dw.packed_bbox_table)
rast = os.path.getsize('linedraw_bank2.bin')
clip = os.path.getsize('clipper_bank2.bin') if os.path.exists('clipper_bank2.bin') else 0
code = os.path.getsize('doom_fe.bin')

# Actual addresses from doom_fe.asm ORG $2640, tables at $4F7E
CODE_START = 0x22D2
TABLE_START = 0x4F7E
CODE_BUDGET = TABLE_START - CODE_START  # 10,558 bytes

D = '\u0024'  # dollar sign

print()
print("  BBC Micro Model B \u2014 DOOM Memory Map")
print("  " + "\u2550" * 55)
print()
print(f"  RAM ({D}0000-{D}57FF)                              22,016 B")
print("  " + "\u2500" * 55)
print(f"  {D}0000-{D}00FF  Zero page                            256 B")
print(f"  {D}0100-{D}01FF  Hardware stack                        256 B")
print(f"  BSS (zero-initialised, {D}0200-{D}22D1):")
print(f"  {D}0200-{D}02D7  BSP node stack (72\u00d73)                 216 B")
print(f"  {D}02D8-{D}02EF  Layout offsets                         24 B")
print(f"  {D}02F0-{D}02FF  [pad / saved screen byte at {D}02F8]     16 B")
print(f"  {D}0300-{D}0469  Deferred queue (1+18\u00d720)              362 B")
print(f"  {D}046A-{D}066B  Scratch spans (514B)                   514 B")
print(f"  {D}0670-{D}166F  Vertex cache (512\u00d78)               4,096 B")
print(f"  {D}1670-{D}16AF  Vcache valid bitmap                    64 B")
print(f"  {D}16B0-{D}202F  VWH cache (1216\u00d72)                 2,432 B")
print(f"  {D}2030-{D}20CF  VWH valid bitmap                      160 B")
print(f"  {D}20D0-{D}22D1  Spans array (2+32\u00d716)                514 B")
print(f"  Code ({D}22D2-{D}4F7D):")
print(f"  {D}22D2+       doom_fe code                    {code:>5,} B / {CODE_BUDGET:,} B")
print(f"  Tables ({D}4F7E-{D}57FF, loaded from disc):")
print(f"  {D}4F7E-{D}537F  Reciprocal + sin/cos tables          1,154 B")
print(f"  {D}5400-{D}57FF  Quarter-square tables (4\u00d7256)       1,024 B")
print()
print(f"  SCREEN ({D}5800-{D}7FFF)                            10,240 B")
print("  " + "\u2500" * 55)
print(f"  {D}5800-{D}6BFF  Framebuffer 0 (Mode 4)             5,120 B")
print(f"  {D}6C00-{D}7FFF  Framebuffer 1 (double-buffer)      5,120 B")
print()
print(f"  SIDEWAYS ROM ({D}8000-{D}BFFF)          bank-switched via {D}FE30")
print("  " + "\u2500" * 55)
print(f"  Bank 0: rom_main                             {rm:>6,} B / 16,384 B")
print(f"           Vertices    467\u00d74                     1,868 B")
print(f"           Nodes       236\u00d716                    3,776 B")
print(f"           Subsectors  237\u00d74                       948 B")
print(f"           Seg headers 679\u00d712                    8,148 B")
print(f"           VWH heights 1206\u00d71                    1,206 B")
print(f"  Bank 1: rom_detail                            {rd:>6,} B / 16,384 B")
print(f"           Seg detail  679\u00d724                   16,296 B")
print(f"  Bank 2: bbox + rasteriser + clipper              {bb+rast+clip:>5,} B / 16,384 B")
print(f"           Bbox table  236\u00d716                    {bb:>5,} B")
print(f"           NJ rasteriser                         {rast:>5,} B")
print(f"           Cyrus-Beck clipper                    {clip:>5,} B")
print()
print(f"  OS ROM ({D}C000-{D}FFFF)                            16,384 B")
print("  " + "\u2500" * 55)
print(f"  MOS (untouched)")
print()
print("  " + "\u2550" * 55)
print(f"  Code budget:   {code:>6,} / {CODE_BUDGET:,}  ({CODE_BUDGET-code:>4,} spare)")
print(f"  Bank 0 budget: {rm:>6,} / 16,384  ({16384-rm:>4,} spare)")
print(f"  Bank 1 budget: {rd:>6,} / 16,384  ({16384-rd:>4,} spare)")
print(f"  Bank 2 budget: {bb+rast+clip:>6,} / 16,384  ({16384-bb-rast-clip:>4,} spare)")
print("  " + "\u2550" * 55)
print()
